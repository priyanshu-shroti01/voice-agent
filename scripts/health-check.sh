#!/usr/bin/env bash
# Validate every component. Exit code = number of failed required checks.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

fail=0
check() { # name, required(1/0), command...
  local name="$1" required="$2"; shift 2
  if "$@" >/dev/null 2>&1; then ok "$name"; else
    if [[ "$required" == 1 ]]; then err "$name"; fail=$((fail + 1)); else warn "$name"; fi
  fi
}

check "Dashboard     http://127.0.0.1:$WEB_PORT" 1 curl -fsS -m 5 "http://127.0.0.1:$WEB_PORT/login"
check "API           http://127.0.0.1:$API_PORT/api/health" 1 curl -fsS -m 5 "http://127.0.0.1:$API_PORT/api/health"
db_status="$(curl -fsS -m 5 "http://127.0.0.1:$API_PORT/api/health" 2>/dev/null | grep -o '"database":true' || true)"
if [[ -n "$db_status" ]]; then ok "Database      SQLite reachable"; else err "Database"; fail=$((fail + 1)); fi
check "Ollama        $OLLAMA_URL" 1 curl -fsS -m 5 "$OLLAMA_URL/api/version"
model="${VA_DEFAULT_LLM_MODEL:-qwen3:4b-instruct-2507-q4_K_M}"
if curl -fsS -m 5 "$OLLAMA_URL/api/tags" 2>/dev/null | grep -qF "\"$model\""; then ok "Model         $model installed"
else err "Model         $model not installed (ollama list)"; fail=$((fail + 1)); fi
check "Speech-to-text whisper-server :$WHISPER_PORT" 1 curl -fsS -m 5 "http://127.0.0.1:$WHISPER_PORT/health"
check "Text-to-speech Piper :$PIPER_PORT" 1 curl -fsS -m 5 "http://127.0.0.1:$PIPER_PORT/voices"
check "VAD model     data/models/vad/silero_vad.onnx" 1 test -f "$MODELS/vad/silero_vad.onnx"
check "FFmpeg" 0 command -v ffmpeg
if pid_alive scheduler; then ok "Scheduler     running (pid $(pid_of scheduler))"
elif systemctl is-active --quiet voice-agent-scheduler 2>/dev/null; then ok "Scheduler     running (systemd)"
else err "Scheduler     not running"; fail=$((fail + 1)); fi
echo "${C_DIM}• Telephony     simulator always available; real PSTN is ${VA_REAL_TELEPHONY_ENABLED:-false} (disabled unless configured)${C_END}"
# Ollama must not listen on a public interface
if lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | grep -vqE '^(127\.0\.0\.1|\[::1\]|localhost):'; then
  warn "Ollama appears to listen on a non-loopback address — set OLLAMA_HOST=127.0.0.1"
else ok "Ollama bound to loopback only"; fi
echo
[[ $fail -eq 0 ]] && ok "All required checks passed" || err "$fail required check(s) failed"
exit $fail
