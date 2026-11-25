#!/usr/bin/env bash
# Shared helpers for voice-agent scripts. Sourced, not executed.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$ROOT/.run"
LOG_DIR="$ROOT/logs"
VENV="$ROOT/backend/.venv"
PIPER_VENV="$ROOT/.tools/piper"
MODELS="$ROOT/data/models"
mkdir -p "$RUN_DIR" "$LOG_DIR"

# load .env (only simple KEY=VALUE lines; never executed as code)
if [[ -f "$ROOT/.env" ]]; then
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    value="${value%\"}"; value="${value#\"}"
    # variables already set in the environment win over .env (same precedence as the backend)
    [[ -n "${!key+x}" ]] || export "$key=$value"
  done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$ROOT/.env")
fi

API_PORT="${VA_PORT:-8000}"
WEB_PORT="${VA_WEB_PORT:-3000}"
WHISPER_PORT="${VA_WHISPER_PORT:-8178}"
PIPER_PORT="${VA_PIPER_PORT:-5005}"
WHISPER_MODEL="${VA_WHISPER_MODEL:-ggml-base.en-q5_1.bin}"
PIPER_VOICE="${VA_DEFAULT_TTS_VOICE:-en_GB-alba-medium}"
OLLAMA_URL="${VA_OLLAMA_URL:-http://127.0.0.1:11434}"

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_END=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_END=""
fi
ok()   { echo "${C_OK}✔${C_END} $*"; }
warn() { echo "${C_WARN}!${C_END} $*"; }
err()  { echo "${C_ERR}✘${C_END} $*" >&2; }
info() { echo "${C_DIM}•${C_END} $*"; }

# pid file contains "<pid> <signature>"; the signature must appear in the process
# command line, so a recycled PID belonging to an unrelated process is never touched.
pid_alive() {
  local name="$1" file="$RUN_DIR/$1.pid"
  [[ -f "$file" ]] || return 1
  local pid sig
  read -r pid sig < "$file" || return 1
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -qF -- "$sig"
}

pid_of() { awk '{print $1}' "$RUN_DIR/$1.pid" 2>/dev/null; }

port_in_use() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

wait_http() {
  local url="$1" tries="${2:-60}"
  for _ in $(seq 1 "$tries"); do
    curl -fsS -m 2 "$url" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

# start_service NAME SIGNATURE LOGFILE -- command...
start_service() {
  local name="$1" sig="$2" log="$3"; shift 4
  if pid_alive "$name"; then
    info "$name already running (pid $(pid_of "$name"))"
    return 0
  fi
  nohup "$@" >>"$log" 2>&1 &
  local pid=$!
  echo "$pid $sig" > "$RUN_DIR/$name.pid"
  sleep 0.3
  if ! kill -0 "$pid" 2>/dev/null; then
    err "$name failed to start — see $log"
    rm -f "$RUN_DIR/$name.pid"
    return 1
  fi
}

stop_service() {
  local name="$1"
  if ! pid_alive "$name"; then
    rm -f "$RUN_DIR/$name.pid"
    return 0
  fi
  local pid; pid="$(pid_of "$name")"
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "$name did not exit after SIGTERM; sending SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$RUN_DIR/$name.pid"
  ok "stopped $name"
}
