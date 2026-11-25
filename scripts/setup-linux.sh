#!/usr/bin/env bash
# One-time setup on an Ubuntu 24.04 server (x86_64 or arm64). Installs only what is missing.
#   ./scripts/setup-linux.sh            dependencies + environments + database
#   ./scripts/setup-linux.sh --models   also download speech models (~125 MB, asks first)
#   ./scripts/setup-linux.sh --yes      non-interactive (assume yes)
# Run as your normal user (it uses sudo for apt). Never downloads an LLM and never installs Ollama.
# Afterwards: sudo ./scripts/install-server.sh your.domain   (see docs/DEPLOYMENT.md)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

WANT_MODELS=0; ASSUME_YES=0
for a in "$@"; do
  case "$a" in --models) WANT_MODELS=1 ;; --yes|-y) ASSUME_YES=1 ;; esac
done
confirm() { [[ $ASSUME_YES == 1 ]] && return 0; read -r -p "$1 [y/N] " r; [[ "$r" =~ ^[Yy]$ ]]; }

echo "voice-agent setup (Linux server)"
echo "================================"

[[ "$(uname -s)" == "Linux" ]] || { err "This script targets Linux. On a Mac use ./scripts/setup-mac.sh."; exit 1; }
[[ $EUID -ne 0 ]] || { err "Run as your normal user, not root (sudo is used where needed)."; exit 1; }
command -v apt-get >/dev/null || { err "apt-get not found. This script targets Ubuntu 24.04."; exit 1; }
info "CPU: $(nproc) cores · Memory: $(free -g | awk '/^Mem:/{print $2}') GB · Free disk: $(df -h "$ROOT" | awk 'NR==2{print $4}')"

# --- system packages (only if missing)
need_apt=()
for pkg in ffmpeg build-essential cmake git curl lsof caddy ufw; do
  dpkg -s "$pkg" >/dev/null 2>&1 || need_apt+=("$pkg")
done
if ((${#need_apt[@]})); then
  info "Installing missing packages: ${need_apt[*]}"
  sudo apt-get update -q
  sudo apt-get install -y -q "${need_apt[@]}"
fi
ok "System packages present"

# --- tools the user installs themselves (one command each, see docs/DEPLOYMENT.md)
command -v uv >/dev/null || { err "uv is required: curl -LsSf https://astral.sh/uv/install.sh | sh  (then open a new shell)"; exit 1; }
command -v node >/dev/null || { err "Node.js 20+ is required (Ubuntu's own package is too old). See docs/DEPLOYMENT.md."; exit 1; }
node_major=$(node --version | sed 's/v\([0-9]*\).*/\1/')
(( node_major >= 20 )) || { err "Node.js 20+ required (found $(node --version))"; exit 1; }
ok "uv $(uv --version | awk '{print $2}') · node $(node --version)"
if command -v ollama >/dev/null; then ok "Ollama installed"
else warn "Ollama not installed. Install it with: curl -fsSL https://ollama.com/install.sh | sh"; fi

# --- whisper.cpp server, built from a pinned release (Homebrew provides it on macOS)
WHISPER_TAG=v1.7.6
WHISPER_DIR="$ROOT/.tools/whisper.cpp"
if [[ ! -x "$WHISPER_DIR/build/bin/whisper-server" ]]; then
  info "Building whisper.cpp $WHISPER_TAG (a few minutes)"
  rm -rf "$WHISPER_DIR"
  git clone -q --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp.git "$WHISPER_DIR"
  cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$WHISPER_DIR/build" -j "$(nproc)" --target whisper-server >/dev/null
fi
ok "whisper-server built ($WHISPER_TAG)"

source "$(dirname "$0")/setup-common.sh"

# --- dashboard production build
cd "$ROOT/apps/dashboard"
npm run build --silent
ok "Dashboard production build ready"

echo
ok "Setup complete. Next: sudo ./scripts/install-server.sh your.domain"
