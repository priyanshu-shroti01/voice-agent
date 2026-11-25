#!/usr/bin/env bash
# Turn a set-up Linux server into an always-on public deployment:
#   sudo ./scripts/install-server.sh voice.example.com
# - systemd services for whisper, Piper, API, scheduler and dashboard (restart on crash, start on boot)
# - Caddy with automatic HTTPS for the domain (/api/* -> API, everything else -> dashboard)
# - production settings in .env for that domain
# - firewall: SSH, HTTP/HTTPS and the UDP range WebRTC call audio uses
# Re-run it after changing ports in .env. Run ./scripts/setup-linux.sh --models first.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DOMAIN="${1:-}"
[[ $EUID -eq 0 ]] || { err "Run with sudo: sudo $0 your.domain"; exit 1; }
[[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
  || { err "Usage: sudo $0 your.domain   (lowercase hostname whose DNS A record points at this server)"; exit 1; }
RUN_USER="${SUDO_USER:-}"
[[ -n "$RUN_USER" && "$RUN_USER" != root ]] || { err "Run via sudo from the user that owns $ROOT"; exit 1; }
RUN_GROUP="$(id -gn "$RUN_USER")"
chown "$RUN_USER:$RUN_GROUP" "$RUN_DIR" "$LOG_DIR"  # lib.sh may have just created them as root

NODE="$(command -v node || true)"
WHISPER_BIN="$ROOT/.tools/whisper.cpp/build/bin/whisper-server"
missing=()
[[ -x "$VENV/bin/python" ]] || missing+=("backend environment")
[[ -x "$PIPER_VENV/bin/python" ]] || missing+=("Piper environment")
[[ -x "$WHISPER_BIN" ]] || missing+=("whisper-server build")
[[ -f "$MODELS/whisper/$WHISPER_MODEL" && -f "$MODELS/piper/$PIPER_VOICE.onnx" && -f "$MODELS/vad/silero_vad.onnx" ]] || missing+=("speech models")
[[ -f "$ROOT/apps/dashboard/.next/BUILD_ID" ]] || missing+=("dashboard production build")
[[ -n "$NODE" ]] || missing+=("node on root's PATH (install Node.js system-wide, see docs/DEPLOYMENT.md)")
if ((${#missing[@]})); then
  err "Not ready: ${missing[*]}. Run ./scripts/setup-linux.sh --models as $RUN_USER first."; exit 1
fi

# --- production settings for this domain (other .env lines are kept)
set_env() { # KEY VALUE — replace or append; `cat >` keeps the file's owner and 0600 mode
  local f="$ROOT/.env"
  { grep -v "^$1=" "$f" || true; printf '%s=%s\n' "$1" "$2"; } > "$f.tmp"
  cat "$f.tmp" > "$f"; rm -f "$f.tmp"
}
set_env VA_ENV production
set_env VA_COOKIE_SECURE true
set_env VA_ALLOWED_HOSTS "[\"$DOMAIN\",\"localhost\",\"127.0.0.1\"]"
set_env VA_CORS_ORIGINS "[\"https://$DOMAIN\"]"
ok "Updated .env for https://$DOMAIN"

# --- systemd services
unit() { # NAME DESCRIPTION WORKDIR EXEC [EXTRA_LINES]
  cat > "/etc/systemd/system/voice-agent-$1.service" <<EOF
[Unit]
Description=voice-agent $2
After=network-online.target ollama.service
Wants=network-online.target

[Service]
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$3
ExecStart=$4
$5
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}
PY_ENV="Environment=PYTHONPATH=$ROOT/backend:$ROOT"
threads=$(( $(nproc) / 2 )); (( threads >= 2 )) || threads=2
unit whisper "speech-to-text (whisper.cpp)" "$ROOT" \
  "$WHISPER_BIN -m $MODELS/whisper/$WHISPER_MODEL --host 127.0.0.1 --port $WHISPER_PORT -t $threads"
unit piper "text-to-speech (Piper, GPL-3.0, separate process)" "$ROOT" \
  "$PIPER_VENV/bin/python -m piper.http_server --host 127.0.0.1 --port $PIPER_PORT -m $MODELS/piper/$PIPER_VOICE.onnx --data-dir $MODELS/piper"
# Caddy on 127.0.0.1 sets X-Forwarded-For; trusting only loopback gives the API the real visitor IP
# (the login and public-call rate limits are per IP).
unit api "API" "$ROOT/backend" \
  "$VENV/bin/uvicorn app.main:app --host 127.0.0.1 --port $API_PORT --no-server-header --proxy-headers --forwarded-allow-ips 127.0.0.1" \
  "$PY_ENV"
unit scheduler "campaign scheduler" "$ROOT/backend" "$VENV/bin/python -m app.scheduler.main" "$PY_ENV"
unit web "dashboard" "$ROOT/apps/dashboard" \
  "$NODE $ROOT/apps/dashboard/node_modules/next/dist/bin/next start -H 127.0.0.1 -p $WEB_PORT" \
  "Environment=NODE_ENV=production"
SERVICES=(voice-agent-whisper voice-agent-piper voice-agent-api voice-agent-scheduler voice-agent-web)
systemctl daemon-reload
systemctl enable -q "${SERVICES[@]}"
systemctl restart "${SERVICES[@]}"
ok "Services enabled: ${SERVICES[*]} (restart on crash, start on boot)"

# --- HTTPS reverse proxy (Caddy gets and renews the certificate itself)
CADDYFILE=/etc/caddy/Caddyfile
[[ -f "$CADDYFILE" && ! -f "$CADDYFILE.before-voice-agent" ]] && cp "$CADDYFILE" "$CADDYFILE.before-voice-agent"
cat > "$CADDYFILE" <<EOF
# Written by voice-agent scripts/install-server.sh (original kept as Caddyfile.before-voice-agent)
$DOMAIN {
	encode zstd gzip
	handle /api/* {
		reverse_proxy 127.0.0.1:$API_PORT
	}
	handle {
		reverse_proxy 127.0.0.1:$WEB_PORT
	}
}
EOF
caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null
systemctl enable -q caddy
systemctl reload-or-restart caddy
ok "Caddy serving https://$DOMAIN"

# --- firewall. WebRTC audio uses random UDP ports from the kernel's ephemeral range
# (aiortc has no port setting), so that range is opened; the app uses no STUN/TURN servers.
read -r udp_lo udp_hi < /proc/sys/net/ipv4/ip_local_port_range
ssh_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
ufw allow "${ssh_port:-22}/tcp" >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
ufw allow "$udp_lo:$udp_hi/udp" >/dev/null
ufw --force enable >/dev/null
ok "Firewall: SSH ${ssh_port:-22}, 80, 443 and UDP $udp_lo-$udp_hi open; everything else closed"
info "If your cloud provider has its own firewall, open the same ports there too."

# --- LLM check (no download: pulling a model is your decision)
model="${VA_DEFAULT_LLM_MODEL:-qwen3:4b-instruct-2507-q4_K_M}"
if ! curl -fsS -m 3 "$OLLAMA_URL/api/tags" 2>/dev/null | grep -qF "\"$model\""; then
  warn "LLM '$model' not available in Ollama. Install Ollama and run: ollama pull $model"
fi

echo
ok "Done. Open https://$DOMAIN (the certificate can take a minute on first start)."
echo "  Status:  systemctl status 'voice-agent-*'"
echo "  Logs:    journalctl -u voice-agent-api -f"
echo "  Health:  ./scripts/health-check.sh"
