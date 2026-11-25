#!/usr/bin/env bash
# One-time setup on Apple Silicon macOS. Installs only what is missing.
#
#   ./scripts/setup-mac.sh                          tools + environments + database
#   ./scripts/setup-mac.sh --models                 also download speech models (~125 MB, asks first)
#   ./scripts/setup-mac.sh --with-ollama            also install Ollama and pull the default LLM (~2.5 GB, asks first)
#   ./scripts/setup-mac.sh --models --with-ollama   everything (same as `make setup-all`)
#   ./scripts/setup-mac.sh --ollama-only            only the Ollama + LLM step
#   add --yes to answer "yes" to every question (non-interactive)
#
# Without --with-ollama / --ollama-only it never installs Ollama and never downloads a language model.
# The default model is VA_DEFAULT_LLM_MODEL (.env) or qwen3:4b-instruct-2507-q4_K_M; override per run with
#   VA_DEFAULT_LLM_MODEL=<name> ./scripts/setup-mac.sh --with-ollama
set -euo pipefail
source "$(dirname "$0")/lib.sh"

WANT_MODELS=0; WANT_OLLAMA=0; OLLAMA_ONLY=0; ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --models) WANT_MODELS=1 ;;
    --with-ollama) WANT_OLLAMA=1 ;;
    --ollama-only) WANT_OLLAMA=1; OLLAMA_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "unknown option: $a (see --help)"; exit 2 ;;
  esac
done
confirm() { [[ $ASSUME_YES == 1 ]] && return 0; read -r -p "$1 [y/N] " r; [[ "$r" =~ ^[Yy]$ ]]; }

DEFAULT_MODEL="${VA_DEFAULT_LLM_MODEL:-qwen3:4b-instruct-2507-q4_K_M}"
mem_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
free_gb() { df -g "$ROOT" | awk 'NR==2{print $4}'; }

# ----------------------------------------------------------------------------- Ollama + LLM
# Installs Ollama (Homebrew) and pulls the default model, each only after asking. Ollama is
# only ever started bound to 127.0.0.1, and only for the duration of the download if it was
# not already running.
ollama_models() { curl -fsS -m 5 "$OLLAMA_URL/api/tags" 2>/dev/null || true; }

setup_ollama() {
  echo
  info "Ollama and local language model"
  if ! command -v ollama >/dev/null; then
    warn "Ollama is not installed."
    if confirm "Install Ollama with Homebrew now (brew install ollama)?"; then
      command -v brew >/dev/null || { err "Homebrew is required: https://brew.sh"; return 1; }
      brew install ollama
    else
      info "Skipped. Install it later from https://ollama.com/download or with: brew install ollama"
      return 0
    fi
  fi
  ok "Ollama $(ollama --version 2>&1 | grep -o '[0-9][0-9.]*' | tail -1) installed"

  local started_here=0 pid=""
  if [[ -z "$(ollama_models)" ]]; then
    info "Starting Ollama temporarily on 127.0.0.1:11434 for the download…"
    OLLAMA_HOST=127.0.0.1:11434 nohup ollama serve >>"$LOG_DIR/ollama-setup.log" 2>&1 &
    pid=$!
    started_here=1
    if ! wait_http "$OLLAMA_URL/api/version" 60; then
      err "Ollama did not start (see logs/ollama-setup.log)"
      kill "$pid" 2>/dev/null || true
      return 1
    fi
  fi

  local tags; tags="$(ollama_models)"
  if [[ "$tags" == *"\"$DEFAULT_MODEL\""* ]]; then
    ok "Language model $DEFAULT_MODEL already installed (nothing downloaded)"
  else
    local need_disk=6
    if [[ "$DEFAULT_MODEL" == "qwen3:4b-instruct-2507-q4_K_M" ]]; then
      info "Default model: $DEFAULT_MODEL (about 2.5 GB download, about 3.2 GB in memory while loaded)"
    else
      info "Model: $DEFAULT_MODEL (download size depends on the model; check https://ollama.com/library)"
    fi
    info "This Mac: ${mem_gb} GB memory, $(free_gb) GB free disk"
    if (( mem_gb < 8 )); then
      warn "Less than 8 GB of memory: this model plus speech recognition and synthesis will be slow or may not fit."
    fi
    if (( $(free_gb) < need_disk )); then
      warn "Less than ${need_disk} GB of free disk; the download may fail."
    fi
    if confirm "Download $DEFAULT_MODEL now with 'ollama pull'?"; then
      OLLAMA_HOST=127.0.0.1:11434 ollama pull "$DEFAULT_MODEL"
      tags="$(ollama_models)"
      if [[ "$tags" == *"\"$DEFAULT_MODEL\""* ]]; then ok "Language model $DEFAULT_MODEL installed"
      else err "The model did not appear in 'ollama list' after pulling"; fi
    else
      info "Skipped. Later: ollama pull $DEFAULT_MODEL (or pick any installed local model in Settings → AI models)"
    fi
  fi

  if [[ $started_here == 1 ]]; then
    kill "$pid" 2>/dev/null || true
    info "Stopped the temporary Ollama server (./scripts/start.sh starts it when needed)"
  fi
}

echo "voice-agent setup"
echo "================="

# --- platform
[[ "$(uname -s)" == "Darwin" ]] || { err "This script targets macOS."; exit 1; }
if [[ "$(uname -m)" == "arm64" ]]; then ok "Apple Silicon ($(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo arm64))"
else warn "Intel Mac detected: works, but whisper.cpp Metal acceleration is unavailable"; fi
info "Memory: ${mem_gb} GB, free disk: $(free_gb) GB"

if [[ $OLLAMA_ONLY == 1 ]]; then
  setup_ollama
  echo
  ok "Done."
  exit 0
fi

# --- Homebrew packages (only if missing)
command -v brew >/dev/null || { err "Homebrew is required: https://brew.sh"; exit 1; }
need_brew=()
command -v ffmpeg >/dev/null || need_brew+=(ffmpeg)
command -v whisper-server >/dev/null || need_brew+=(whisper-cpp)
command -v uv >/dev/null || need_brew+=(uv)
command -v node >/dev/null || need_brew+=(node)
if ((${#need_brew[@]})); then
  info "Installing missing packages: ${need_brew[*]}"
  brew install "${need_brew[@]}"
fi
ok "ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')"
ok "whisper.cpp $(brew list --versions whisper-cpp 2>/dev/null | awk '{print $2}')"
ok "uv $(uv --version | awk '{print $2}'), node $(node --version)"
node_major=$(node --version | sed 's/v\([0-9]*\).*/\1/')
(( node_major >= 20 )) || { err "Node.js 20+ required"; exit 1; }

source "$(dirname "$0")/setup-common.sh"

# --- Ollama and the language model
if [[ $WANT_OLLAMA == 1 ]]; then
  setup_ollama
else
  # check only: nothing is installed or downloaded without --with-ollama
  if command -v ollama >/dev/null; then
    ok "Ollama $(ollama --version 2>&1 | grep -o '[0-9][0-9.]*' | tail -1) installed"
    tags="$(ollama_models)"
    if [[ -z "$tags" ]]; then
      warn "Ollama is not running (./scripts/start.sh starts it on 127.0.0.1)"
    elif [[ "$tags" == *"\"$DEFAULT_MODEL\""* ]]; then
      ok "Language model $DEFAULT_MODEL available"
    else
      warn "Language model '$DEFAULT_MODEL' not installed. Run ./scripts/setup-mac.sh --ollama-only, or pick another installed model in Settings."
    fi
  else
    warn "Ollama not installed. Run ./scripts/setup-mac.sh --ollama-only (asks first), or install from https://ollama.com/download"
  fi
fi

echo
ok "Setup complete. Start with: ./scripts/start.sh"
