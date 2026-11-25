#!/usr/bin/env bash
# Platform-independent setup steps, sourced by setup-mac.sh and setup-linux.sh after their own
# prerequisite checks. Expects lib.sh loaded and WANT_MODELS, ASSUME_YES and confirm() defined.

# --- directories
mkdir -p "$ROOT"/data/{database,recordings,transcripts,uploads,backups,models/{whisper,piper,vad}}
chmod 700 "$ROOT"/data "$ROOT"/data/{database,recordings,transcripts,uploads,backups}
[[ -f "$ROOT/.env" ]] || { cp "$ROOT/.env.example" "$ROOT/.env"; chmod 600 "$ROOT/.env"; ok "Created .env from .env.example"; }

# --- backend environment (Python 3.12: wheels for aiortc/onnxruntime are available)
cd "$ROOT/backend"
uv venv --python 3.12 .venv -q 2>/dev/null || true
uv sync -q
SITE=$("$VENV/bin/python" -c 'import site; print(site.getsitepackages()[0])')
echo "$ROOT" > "$SITE/voice_agent_root.pth"
ok "Backend environment ready ($("$VENV/bin/python" --version))"

# --- Piper (GPL-3.0) in its own isolated environment
if [[ ! -x "$PIPER_VENV/bin/python" ]]; then
  uv venv --python 3.12 "$PIPER_VENV" -q
fi
uv pip install --python "$PIPER_VENV/bin/python" -q "piper-tts[http]==1.8.0"
ok "Piper TTS installed in .tools/piper (separate process, GPL-3.0)"

# --- dashboard
cd "$ROOT/apps/dashboard"
npm ci --no-audit --no-fund --loglevel=error
ok "Dashboard dependencies installed"

# --- database
cd "$ROOT/backend"
PYTHONPATH="$ROOT/backend:$ROOT" "$VENV/bin/python" - <<'PY'
import asyncio
from app.core.config import get_settings
from app.database.migrate import upgrade_database
from app.database.session import dispose_engine
async def main():
    get_settings().ensure_dirs(); get_settings().resolved_secret()
    await upgrade_database(); await dispose_engine()
asyncio.run(main())
PY
ok "Database migrated ($(ls "$ROOT/data/database"))"

# --- speech models
download() { # url dest
  [[ -f "$2" ]] && { info "exists: ${2#$ROOT/}"; return; }
  curl -fL --progress-bar -o "$2.part" "$1" && mv "$2.part" "$2"
}
missing_models=()
[[ -f "$MODELS/whisper/ggml-base.en-q5_1.bin" ]] || missing_models+=("whisper base.en q5_1 (57 MB, MIT)")
[[ -f "$MODELS/piper/en_GB-alba-medium.onnx" ]] || missing_models+=("Piper en_GB-alba-medium (60 MB, CC BY 4.0)")
[[ -f "$MODELS/vad/silero_vad.onnx" ]] || missing_models+=("Silero VAD (2 MB, MIT)")
if ((${#missing_models[@]})); then
  warn "Missing speech models:"; printf '    - %s\n' "${missing_models[@]}"
  if [[ $WANT_MODELS == 1 ]] && confirm "Download them now (~125 MB)?"; then
    HF=https://huggingface.co
    download "$HF/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q5_1.bin" "$MODELS/whisper/ggml-base.en-q5_1.bin"
    for ext in onnx onnx.json; do
      download "$HF/rhasspy/piper-voices/resolve/main/en/en_GB/alba/medium/en_GB-alba-medium.$ext" \
        "$MODELS/piper/en_GB-alba-medium.$ext"
    done
    download "$HF/rhasspy/piper-voices/resolve/main/en/en_GB/alba/medium/MODEL_CARD" "$MODELS/piper/en_GB-alba-medium.MODEL_CARD"
    download "https://raw.githubusercontent.com/snakers4/silero-vad/master/src/silero_vad/data/silero_vad.onnx" "$MODELS/vad/silero_vad.onnx"
    ok "Speech models downloaded"
  else
    info "Re-run with --models to download them."
  fi
else
  ok "Speech models present"
fi
