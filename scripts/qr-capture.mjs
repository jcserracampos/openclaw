#!/usr/bin/env node
/**
 * QR Code capture script for WhatsApp login
 * Captures QR from OpenClaw login and sends via webhook
 *
 * Adapted for coollabsio/openclaw image structure
 */

import { spawn } from 'child_process';
import { createHmac, createHash } from 'crypto';
import https from 'https';
import http from 'http';
import fs from 'fs';
import path from 'path';

const INSTANCE_ID = process.env.INSTANCE_ID || '';
const ENCRYPTION_KEY = process.env.ENCRYPTION_KEY || '';
const WEBHOOK_URL = process.env.WEBHOOK_URL || '';

// coollabsio/openclaw uses /data/.openclaw as state dir
const OPENCLAW_STATE_DIR = process.env.OPENCLAW_STATE_DIR || '/data/.openclaw';

// OpenClaw saves credentials in a 'default' subdirectory
const CREDS_DIR = path.join(OPENCLAW_STATE_DIR, 'credentials', 'whatsapp', 'default');

// Path to openclaw binary in coollabsio/openclaw image
const OPENCLAW_BIN = '/usr/local/bin/openclaw';

/**
 * Wait for credentials directory to have files with retries
 */
async function waitForCredentials(maxAttempts = 10, delayMs = 500) {
  for (let i = 0; i < maxAttempts; i++) {
    if (fs.existsSync(CREDS_DIR)) {
      const files = fs.readdirSync(CREDS_DIR);
      if (files.length > 0) {
        console.log(`[QR Capture] Credentials found at: ${CREDS_DIR}`);
        console.log(`[QR Capture] Files: ${files.join(', ')}`);
        return true;
      }
    }
    console.log(`[QR Capture] Waiting for credentials... (attempt ${i + 1}/${maxAttempts})`);
    await new Promise(resolve => setTimeout(resolve, delayMs));
  }

  // Debug: list what's in the parent directory
  const parentDir = path.dirname(CREDS_DIR);
  if (fs.existsSync(parentDir)) {
    console.log(`[QR Capture] Files in ${parentDir}:`, fs.readdirSync(parentDir));
  } else {
    console.log(`[QR Capture] Parent directory does not exist: ${parentDir}`);
  }

  return false;
}

// Calculate signature secret (must match bot-webhook/route.ts)
const signatureSecret = createHash('sha256')
  .update(INSTANCE_ID + ENCRYPTION_KEY)
  .digest('hex')
  .slice(0, 32);

function sendWebhook(status, qrBase64 = '', phone = '') {
  if (!WEBHOOK_URL) {
    console.log(`[QR Capture] No WEBHOOK_URL set, skipping webhook for status: ${status}`);
    return;
  }

  const payload = JSON.stringify({
    instance_id: INSTANCE_ID,
    status,
    ...(qrBase64 && { qr_base64: qrBase64 }),
    ...(phone && { phone }),
  });

  const signature = createHmac('sha256', signatureSecret)
    .update(payload)
    .digest('hex');

  const url = new URL(`${WEBHOOK_URL}/api/bot-webhook`);
  const client = url.protocol === 'https:' ? https : http;

  const req = client.request(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Webhook-Signature': `sha256=${signature}`,
    },
  }, (res) => {
    console.log(`[QR Capture] Webhook response: ${res.statusCode}`);
  });

  req.on('error', (e) => {
    console.error(`[QR Capture] Webhook error: ${e.message}`);
  });

  req.write(payload);
  req.end();
}

// WhatsApp pairing code pattern (starts with "2@" followed by base64-like data)
const PAIRING_CODE_REGEX = /2@[A-Za-z0-9+/=,]+/;

// QR code ASCII art patterns to detect
const QR_START_PATTERNS = ['▄▄▄▄▄▄▄', '█ ▄▄▄▄▄'];

// Connection success patterns
const CONNECTED_PATTERNS = [
  'WhatsApp Web connected',
  'Linked after restart',
  'web session ready',
  'Session authenticated',
  'WhatsApp connected',
  'logged in',
];

let capturingQr = false;
let qrLines = [];
let lastQrSent = '';
let connectedSent = false;

function processLine(line) {
  // Check for connection success - send "configuring" status (not "connected" yet)
  if (!connectedSent && CONNECTED_PATTERNS.some(p => line.toLowerCase().includes(p.toLowerCase()))) {
    connectedSent = true;
    console.log('[QR Capture] WhatsApp connected! Sending configuring status...');
    sendWebhook('configuring');
    return;
  }

  // First, try to find the raw pairing code (preferred)
  const match = line.match(PAIRING_CODE_REGEX);
  if (match && match[0].length > 50) {
    const pairingCode = match[0];
    if (pairingCode !== lastQrSent) {
      lastQrSent = pairingCode;
      console.log('[QR Capture] Pairing code detected!');
      console.log('[QR Capture] Code length:', pairingCode.length);
      sendWebhook('qr_ready', pairingCode);
      return;
    }
  }

  // Fallback: capture ASCII art QR code
  if (!capturingQr && QR_START_PATTERNS.some(p => line.includes(p))) {
    capturingQr = true;
    qrLines = [];
  }

  if (capturingQr) {
    qrLines.push(line);

    // Detect QR code end
    if (qrLines.length > 10 && line.includes('█▄▄▄▄▄▄▄█')) {
      capturingQr = false;
      console.log('[QR Capture] ASCII QR code detected!');

      const qrAscii = qrLines.join('\n');
      const qrBase64 = Buffer.from(qrAscii).toString('base64');

      if (qrBase64 !== lastQrSent) {
        lastQrSent = qrBase64;
        sendWebhook('qr_ready', qrBase64);
      }
      qrLines = [];
    }
  }
}

// Start the login process and capture output
console.log('[QR Capture] Starting WhatsApp login capture...');
console.log(`[QR Capture] Using openclaw at: ${OPENCLAW_BIN}`);
console.log(`[QR Capture] Credentials dir: ${CREDS_DIR}`);

// Use the openclaw command which is in PATH in coollabsio/openclaw image
const login = spawn(OPENCLAW_BIN, ['channels', 'login', '--channel', 'whatsapp', '--verbose'], {
  stdio: ['inherit', 'pipe', 'pipe'],
  env: process.env,
  cwd: '/opt/openclaw/app',
});

login.stdout.on('data', (data) => {
  const lines = data.toString().split('\n');
  lines.forEach(line => {
    console.log(line);
    processLine(line);
  });
});

login.stderr.on('data', (data) => {
  const lines = data.toString().split('\n');
  lines.forEach(line => {
    console.error(line);
    processLine(line);
  });
});

login.on('close', async (code) => {
  console.log(`[QR Capture] Login process exited with code ${code}`);

  if (code === 0 && connectedSent) {
    // Login reported success - verify credentials actually exist
    console.log('[QR Capture] Login reported success, verifying credentials...');
    const credsExist = await waitForCredentials(10, 500);

    if (credsExist) {
      console.log('[QR Capture] Login complete. Credentials verified.');
      process.exit(0);
    } else {
      console.log('[QR Capture] Login reported success but credentials not found!');
      process.exit(1);
    }
  } else if (code === 0) {
    // Login finished but connection not confirmed - check credentials anyway
    console.log('[QR Capture] Login finished. Checking credentials...');
    const credsExist = await waitForCredentials(5, 500);
    process.exit(credsExist ? 0 : 1);
  } else {
    // Login failed
    console.log('[QR Capture] Login failed with code:', code);
    process.exit(code);
  }
});
