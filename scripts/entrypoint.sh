#!/usr/bin/env bash
set -e

STATE_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

echo "[entrypoint] state dir: $STATE_DIR"
echo "[entrypoint] workspace dir: $WORKSPACE_DIR"

# ── Install extra apt packages (if requested) ────────────────────────────────
if [ -n "${OPENCLAW_DOCKER_APT_PACKAGES:-}" ]; then
  echo "[entrypoint] installing extra packages: $OPENCLAW_DOCKER_APT_PACKAGES"
  apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      $OPENCLAW_DOCKER_APT_PACKAGES \
    && rm -rf /var/lib/apt/lists/*
fi

# ── Require OPENCLAW_GATEWAY_TOKEN ───────────────────────────────────────────
if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
  echo "[entrypoint] ERROR: OPENCLAW_GATEWAY_TOKEN is required."
  echo "[entrypoint] Generate one with: openssl rand -hex 32"
  exit 1
fi
GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN"

# ── Require at least one AI provider API key env var ─────────────────────────
# Providers always read API keys from env vars, never from JSON config.
HAS_PROVIDER=0
for key in ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GEMINI_API_KEY \
           XAI_API_KEY GROQ_API_KEY MISTRAL_API_KEY CEREBRAS_API_KEY \
           VENICE_API_KEY MOONSHOT_API_KEY KIMI_API_KEY MINIMAX_API_KEY \
           ZAI_API_KEY AI_GATEWAY_API_KEY OPENCODE_API_KEY OPENCODE_ZEN_API_KEY \
           SYNTHETIC_API_KEY COPILOT_GITHUB_TOKEN XIAOMI_API_KEY; do
  [ -n "${!key:-}" ] && HAS_PROVIDER=1 && break
done
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] && HAS_PROVIDER=1
[ -n "${OLLAMA_BASE_URL:-}" ] && HAS_PROVIDER=1
if [ "$HAS_PROVIDER" -eq 0 ]; then
  echo "[entrypoint] ERROR: At least one AI provider API key env var is required."
  echo "[entrypoint] Providers read API keys from env vars, never from the JSON config."
  echo "[entrypoint] Set one of: ANTHROPIC_API_KEY, OPENAI_API_KEY, OPENROUTER_API_KEY, GEMINI_API_KEY,"
  echo "[entrypoint]   XAI_API_KEY, GROQ_API_KEY, MISTRAL_API_KEY, CEREBRAS_API_KEY, VENICE_API_KEY,"
  echo "[entrypoint]   MOONSHOT_API_KEY, KIMI_API_KEY, MINIMAX_API_KEY, ZAI_API_KEY, AI_GATEWAY_API_KEY,"
  echo "[entrypoint]   OPENCODE_API_KEY, SYNTHETIC_API_KEY, COPILOT_GITHUB_TOKEN, XIAOMI_API_KEY"
  echo "[entrypoint] Or: AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY (Bedrock), OLLAMA_BASE_URL (local)"
  exit 1
fi

mkdir -p "$STATE_DIR" "$WORKSPACE_DIR"
mkdir -p "$STATE_DIR/agents/main/sessions" "$STATE_DIR/credentials"
chmod 700 "$STATE_DIR"

# Export state/workspace dirs so openclaw CLI + configure.js see them
export OPENCLAW_STATE_DIR="$STATE_DIR"
export OPENCLAW_WORKSPACE_DIR="$WORKSPACE_DIR"

# Set HOME so that ~/.openclaw resolves to $STATE_DIR directly.
# This avoids "multiple state directories" warnings from openclaw doctor
# (symlinks are detected as separate paths).
export HOME="${STATE_DIR%/.openclaw}"

# ── Configure openclaw from env vars ─────────────────────────────────────────
echo "[entrypoint] running configure..."
node /app/scripts/configure.js
chmod 600 "$STATE_DIR/openclaw.json"

# ── Auto-fix doctor suggestions (e.g. enable configured channels) ─────────
echo "[entrypoint] running openclaw doctor --fix..."
cd /opt/openclaw/app
openclaw doctor --fix 2>&1 || true

# ── WhatsApp QR Capture ─────────────────────────────────────────────────────
# If WhatsApp is configured but no credentials exist, we need to run the login
# process to capture the QR code and send it via webhook to the dashboard.
WHATSAPP_CREDS_DIR="$STATE_DIR/credentials/whatsapp/default"
WHATSAPP_CONFIGURED=0

# Check if WhatsApp is configured via env vars
if [ -n "${WHATSAPP_ALLOW_FROM:-}" ] || [ -n "${WHATSAPP_DM_POLICY:-}" ]; then
  WHATSAPP_CONFIGURED=1
fi

# Also check the generated config for whatsapp channel
if [ "$WHATSAPP_CONFIGURED" -eq 0 ]; then
  WHATSAPP_CONFIGURED=$(node -e "
    try {
      const c = JSON.parse(require('fs').readFileSync('$STATE_DIR/openclaw.json','utf8'));
      if (c.channels && c.channels.whatsapp) process.stdout.write('1');
      else process.stdout.write('0');
    } catch { process.stdout.write('0'); }
  " 2>/dev/null || echo "0")
fi

if [ "$WHATSAPP_CONFIGURED" -eq 1 ]; then
  echo "[entrypoint] WhatsApp channel is configured"

  # Check if credentials already exist
  if [ -d "$WHATSAPP_CREDS_DIR" ] && [ "$(ls -A "$WHATSAPP_CREDS_DIR" 2>/dev/null)" ]; then
    echo "[entrypoint] WhatsApp credentials found, skipping QR capture"
  else
    echo "[entrypoint] No WhatsApp credentials found, will run QR capture after gateway starts"

    # Check if we have the required env vars for webhook
    if [ -n "${WEBHOOK_URL:-}" ] && [ -n "${INSTANCE_ID:-}" ]; then
      # Enable WhatsApp plugin first
      echo "[entrypoint] Enabling WhatsApp plugin..."
      openclaw plugins enable whatsapp 2>&1 || echo "[entrypoint] WhatsApp plugin enable failed or already enabled"

      # Mark that we need to run QR capture after gateway starts
      export RUN_QR_CAPTURE=1
    else
      echo "[entrypoint] WEBHOOK_URL or INSTANCE_ID not set, skipping QR capture"
      echo "[entrypoint] Set these env vars to enable automatic QR code delivery"
    fi
  fi
else
  echo "[entrypoint] WhatsApp channel not configured, skipping QR capture"
fi

# ── Read hooks path from generated config (if hooks enabled) ─────────────────
HOOKS_PATH=""
HOOKS_PATH=$(node -e "
  try {
    const c = JSON.parse(require('fs').readFileSync('$STATE_DIR/openclaw.json','utf8'));
    if (c.hooks && c.hooks.enabled) process.stdout.write(c.hooks.path || '/hooks');
  } catch {}
" 2>/dev/null || true)
if [ -n "$HOOKS_PATH" ]; then
  echo "[entrypoint] hooks enabled, path: $HOOKS_PATH (will bypass HTTP auth)"
fi

# ── Generate nginx config ────────────────────────────────────────────────────
AUTH_PASSWORD="${AUTH_PASSWORD:-}"
AUTH_USERNAME="${AUTH_USERNAME:-admin}"
NGINX_CONF="/etc/nginx/conf.d/openclaw.conf"

AUTH_BLOCK=""
if [ -n "$AUTH_PASSWORD" ]; then
  echo "[entrypoint] setting up nginx basic auth (user: $AUTH_USERNAME)"
  htpasswd -bc /etc/nginx/.htpasswd "$AUTH_USERNAME" "$AUTH_PASSWORD" 2>/dev/null
  AUTH_BLOCK='auth_basic "Openclaw";
        auth_basic_user_file /etc/nginx/.htpasswd;'
else
  echo "[entrypoint] no AUTH_PASSWORD set, nginx will not require authentication"
fi

# Build hooks location block (skips HTTP basic auth, openclaw validates hook token)
HOOKS_LOCATION_BLOCK=""
if [ -n "$HOOKS_PATH" ]; then
  HOOKS_LOCATION_BLOCK="location ${HOOKS_PATH} {
        proxy_pass http://127.0.0.1:${GATEWAY_PORT};
        proxy_set_header Authorization \"Bearer ${GATEWAY_TOKEN}\";

        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;

        proxy_http_version 1.1;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        error_page 502 503 504 /starting.html;
    }"
fi

# ── Write startup page for 502/503/504 while gateway boots ───────────────────
mkdir -p /usr/share/nginx/html
cat > /usr/share/nginx/html/starting.html <<'STARTPAGE'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Openclaw - Starting</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: ui-sans-serif, system-ui, -apple-system, sans-serif; background: #0a0a0a; color: #e5e5e5; display: flex; align-items: center; justify-content: center; min-height: 100vh; }
    .card { text-align: center; max-width: 480px; padding: 2.5rem; }
    h1 { font-size: 1.5rem; font-weight: 600; margin-bottom: 1rem; }
    p { color: #a3a3a3; line-height: 1.6; margin-bottom: 1.5rem; }
    .spinner { width: 32px; height: 32px; border: 3px solid #333; border-top-color: #e5e5e5; border-radius: 50%; animation: spin 0.8s linear infinite; margin: 0 auto 1.5rem; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .retry { color: #737373; font-size: 0.85rem; }
  </style>
</head>
<body>
  <div class="card">
    <div class="spinner"></div>
    <h1>Openclaw is starting up</h1>
    <p>The gateway is initializing.</p>
    <p>This usually takes a few minutes.</p>
    <p class="retry">This page will auto-refresh.</p>
  </div>
  <script>setTimeout(function(){ location.reload(); }, 3000);</script>
</body>
</html>
STARTPAGE

cat > "$NGINX_CONF" <<NGINXEOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 8080 default_server;
    server_name _;

    location = /healthz {
        access_log off;
        proxy_pass http://127.0.0.1:${GATEWAY_PORT}/;
        proxy_set_header Host \$host;
        proxy_connect_timeout 2s;
        error_page 502 503 504 = @healthz_fallback;
    }

    location @healthz_fallback {
        return 200 '{"ok":true,"gateway":"starting"}';
        default_type application/json;
    }

    ${HOOKS_LOCATION_BLOCK}

    location / {
        ${AUTH_BLOCK}

        proxy_pass http://127.0.0.1:${GATEWAY_PORT};
        proxy_set_header Authorization "Bearer ${GATEWAY_TOKEN}";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        error_page 502 503 504 /starting.html;
    }

    location = /starting.html {
        root /usr/share/nginx/html;
        internal;
    }
}
NGINXEOF

# ── Start nginx ──────────────────────────────────────────────────────────────
echo "[entrypoint] starting nginx on port ${PORT:-8080}..."
nginx

# ── Clean up stale lock files ────────────────────────────────────────────────
rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$STATE_DIR/gateway.lock" 2>/dev/null || true

# ── Start openclaw gateway ───────────────────────────────────────────────────
echo "[entrypoint] starting openclaw gateway on port $GATEWAY_PORT..."

GATEWAY_ARGS=(
  gateway
  --port "$GATEWAY_PORT"
  --verbose
  --allow-unconfigured
  --bind loopback
)

GATEWAY_ARGS+=(--token "$GATEWAY_TOKEN")

# cwd must be the app root so the gateway finds dist/control-ui/ assets
cd /opt/openclaw/app

# If QR capture is needed, start gateway in background and run capture
if [ "${RUN_QR_CAPTURE:-0}" -eq 1 ]; then
  echo "[entrypoint] Starting gateway in background for QR capture..."

  # Start gateway in background
  openclaw "${GATEWAY_ARGS[@]}" &
  GATEWAY_PID=$!

  # Wait for gateway to be ready (check health endpoint)
  echo "[entrypoint] Waiting for gateway to be ready..."
  for i in $(seq 1 30); do
    if curl -s "http://127.0.0.1:$GATEWAY_PORT/" > /dev/null 2>&1; then
      echo "[entrypoint] Gateway is ready!"
      break
    fi
    echo "[entrypoint] Waiting for gateway... ($i/30)"
    sleep 2
  done

  # Run QR capture script
  echo "[entrypoint] Running QR capture script..."
  node /app/scripts/qr-capture.mjs || echo "[entrypoint] QR capture finished (may have failed)"

  # Wait for gateway process (keep container running)
  echo "[entrypoint] QR capture complete, waiting for gateway..."
  wait $GATEWAY_PID
else
  # Normal startup - exec replaces shell with gateway
  exec openclaw "${GATEWAY_ARGS[@]}"
fi
