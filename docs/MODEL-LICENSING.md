# Model and component licensing

voice-agent's own source code is released under the [MIT License](../LICENSE). It depends on third-party software and machine-learning models that carry their own licences. This page lists them, explains how the GPL-licensed Piper TTS is kept separate, and notes the points you should check yourself.

> This is a good-faith summary, not legal advice. Licences can change between versions. Check each component's own licence text before redistributing it or using it commercially.

## Model weights are not in this repository

No model weights are committed to the repository (`*.bin`, `*.onnx` and `*.gguf` are git-ignored, as is `data/models/`). `./scripts/setup-mac.sh --models` downloads the default speech models **from their official sources** onto your machine, after asking you:

| File | Source |
|---|---|
| `data/models/whisper/ggml-base.en-q5_1.bin` | `huggingface.co/ggerganov/whisper.cpp` |
| `data/models/piper/en_US-libritts_r-medium.onnx`, `.onnx.json`, `.MODEL_CARD` | `huggingface.co/rhasspy/piper-voices` |
| `data/models/vad/silero_vad.onnx` | `github.com/snakers4/silero-vad` |

Optional models (the `small.en` Whisper model and the `en_US-libritts_r-medium` voice) are not downloaded by the script; you fetch them yourself from the same repositories. Language models are downloaded only through Ollama: either by you (`ollama pull`) or by `setup-mac.sh --with-ollama` / `--ollama-only`, which asks before pulling. The weights stay in Ollama's own store (`~/.ollama`) and are never copied into this repository.

## Speech and language models

| Model | Used for | Licence | Notes |
|---|---|---|---|
| Whisper `ggml-base.en` (q5_1), default | Speech-to-text | MIT (OpenAI Whisper weights), converted to GGML by the whisper.cpp project | Downloaded by the setup script. |
| Whisper `ggml-small.en` (q5_1), optional | Speech-to-text (more accurate) | MIT (OpenAI) | Set `VA_WHISPER_MODEL=ggml-small.en-q5_1.bin`. |
| Piper voice `en_US-libritts_r-medium`, optional (not the default) | Text-to-speech | Model card: dataset **LibriTTS-R, CC BY 4.0** (<http://www.openslr.org/141/>). **Attribution required.** | 904 speakers, 22.05 kHz. The model card states it was "Fine-tuned from English lessac medium on train-clean-360" (see [Points to check](#points-to-check)). |
| Piper voice `en_GB-alba-medium`, optional | Text-to-speech (British English) | Model card: dataset licence **CC BY 4.0** (<https://datashare.ed.ac.uk/handle/10283/3270>). **Attribution required.** | Model card: fine-tuned from the US English `hifi_tts_92` base model. Requires Piper ≥ 1.5. |
| Silero VAD v5 (`silero_vad.onnx`) | Voice activity detection | MIT | Run through onnxruntime. PyTorch is not needed. |
| Qwen3 4B Instruct 2507 (`qwen3:4b-instruct-2507-q4_K_M` via Ollama), default suggestion | Conversation, call analysis | Apache-2.0 (as published by the Qwen team) | **Not distributed or downloaded by voice-agent.** You choose and install any Ollama model yourself, so **check the licence of the model you use**, including any use restrictions. |

The exact model-card text in `data/models/piper/` (from the dev install) reads:

* `en_US-libritts_r-medium.MODEL_CARD`: "Dataset — URL: http://www.openslr.org/141/ — License: CC BY 4.0 … Fine-tuned from English lessac medium on train-clean-360."
* `en_GB-alba-medium.MODEL_CARD`: "Dataset — URL: https://datashare.ed.ac.uk/handle/10283/3270 — License: https://creativecommons.org/licenses/by/4.0/ … Finetuned from the U.S. English hifi_tts_92 base model (medium quality; the voice of Cori Samuel, Hi-Fi TTS reader 92), with MRD and SDP."

### Attribution for CC BY 4.0 voices

If you publish or distribute audio made with these voices (for example, recordings shared outside your organisation), give credit in a reasonable place such as your website's credits or privacy page. A suggested wording:

> Speech synthesised with Piper TTS using the `en_GB-alba-medium` voice, trained on the Alba speech corpus (University of Edinburgh, CC BY 4.0, https://datashare.ed.ac.uk/handle/10283/3270) and fine-tuned from the Hi-Fi TTS reader 92 base model.

> Speech synthesised with Piper TTS using the `en_GB-alba-medium` voice, trained on data licensed under CC BY 4.0 (https://datashare.ed.ac.uk/handle/10283/3270).

### Voices deliberately not used

Several popular Piper voices were **not** downloaded or set as defaults because their training data carries restrictive terms:

| Voice | Reason |
|---|---|
| `en_US-lessac-*` | Trained on the Lessac data from the Blizzard Challenge, released under the Blizzard licence, which is not a permissive open licence |
| `en_US-ryan-*` | Dataset licensed **CC BY-NC-SA** (non-commercial) |
| `hi_IN-pratham-*` | Dataset licensed **CC BY-NC-SA** (non-commercial) |

If you add other voices, read each voice's `MODEL_CARD` first. Non-commercial (NC) licences are unsuitable for a business using voice-agent with customers.

## Piper TTS and the GPL

**Piper TTS (`piper-tts` 1.8.0) is licensed GPL-3.0-or-later.** voice-agent is MIT. They are kept separate as follows:

* `setup-mac.sh` installs Piper into its **own Python environment**, `.tools/piper`, separate from the backend's `backend/.venv`.
* `start.sh` runs it as a **separate process** (`python -m piper.http_server`) listening on `127.0.0.1:5005`.
* voice-agent **never imports Piper** and does not link against it. It sends text over HTTP (`POST /synthesize`, `GET /voices`) and receives WAV audio (`engine/providers/tts/piper_http.py`).
* Piper is not included in this repository.

Two independent programs that communicate over a network protocol at arm's length are generally treated as an "aggregate" under the GPL, rather than as one combined work. On that basis, the GPL's conditions apply to Piper itself but do not extend to voice-agent's MIT-licensed code. This is the project's reading of the GPL FAQ, not a legal opinion.

**If you redistribute Piper**, for example by shipping a pre-built Mac bundle or disk image that includes `.tools/piper`, you must comply with the GPL-3.0 for Piper: provide its source code (or a written offer), keep its licence notices, and pass on the same rights. If you only run `setup-mac.sh` on your own machine, Piper is installed from PyPI by you and nothing is redistributed.

If the GPL is a problem for you, select **macOS `say`** as the TTS provider (**Settings → Speech and audio**). It uses the operating system's built-in voices, under Apple's macOS licence, for local use.

## Native tools and services

| Component | Licence | How it is used |
|---|---|---|
| whisper.cpp (`whisper-server`, `whisper-cli`) | MIT | Installed with Homebrew (`whisper-cpp`) and run as a separate local server |
| Ollama | MIT | Installed by you, or by `setup-mac.sh --with-ollama` via Homebrew after asking. It runs as a separate local server bound to 127.0.0.1. |
| Piper TTS | GPL-3.0-or-later | Separate process; see above |
| FFmpeg (Homebrew) | LGPL/GPL depending on build | Installed by the setup script as a general utility. voice-agent's code does not call the `ffmpeg` binary. |
| Asterisk (optional, yours) | GPL-2.0 | Not included. voice-agent only talks to it over the ARI HTTP/WebSocket API. |

## Python dependencies (backend)

Verified from the installed package metadata (`importlib.metadata`) in `backend/.venv`:

| Package | Version checked | Licence |
|---|---|---|
| FastAPI | 0.165.0 | MIT |
| Starlette | 1.10.0 | BSD-3-Clause |
| uvicorn | 0.54.0 | BSD-3-Clause |
| Pydantic / pydantic-settings | 2.14.4 / 2.16.3 | MIT |
| SQLAlchemy | 2.1.9 | MIT |
| Alembic | 1.20.1 | MIT |
| aiosqlite | 0.22.1 | MIT |
| aiortc | 1.16.0 | BSD-3-Clause |
| aioice, pylibsrtp | 0.14.1, 1.0.0 | BSD-3-Clause |
| PyAV (`av`) | 19.0.2 | BSD-3-Clause (see note) |
| onnxruntime | 1.32.0 | MIT |
| numpy | 2.5.5 | BSD-3-Clause (with bundled components under 0BSD, MIT, Zlib, CC0-1.0) |
| httpx | 0.28.1 | BSD-3-Clause |
| websockets | 17.4 | BSD-3-Clause |
| phonenumbers (libphonenumber port) | 9.0.44 | Apache-2.0 |
| argon2-cffi / argon2-cffi-bindings | 25.1.0 / 26.2.0 | MIT |
| cryptography | 50.0.2 | Apache-2.0 OR BSD-3-Clause |
| pypdf | 7.1.1 | BSD-3-Clause |
| python-multipart | 0.0.34 | Apache-2.0 |
| psutil | 7.2.2 | BSD-3-Clause |
| pyee | 16.1.0 | MIT |

**Note on PyAV.** The PyAV binary wheel from PyPI bundles FFmpeg 9.0.2 shared libraries and codec libraries in `av/.dylibs/`. The bundled FFmpeg reports its own licence as "LGPL version 3 or later", but the wheel also ships `libx264` and `libx265`, which are GPL-licensed. voice-agent uses PyAV only for Opus audio and resampling. If you redistribute a bundle that includes these wheels, review the bundled libraries' licences.

Re-check with:

```bash
backend/.venv/bin/python -c "import importlib.metadata as m
for d in sorted(m.distributions(), key=lambda d: d.metadata['Name'].lower()):
    md = d.metadata
    print(md['Name'], d.version, md.get('License-Expression') or md.get('License') or
          [c for c in (md.get_all('Classifier') or []) if c.startswith('License')])"
```

## JavaScript dependencies (dashboard)

Verified from the `license` field of each package's `package.json` in `apps/dashboard/node_modules`:

| Package | Version checked | Licence |
|---|---|---|
| Next.js (`next`) | 16.4.6 | MIT |
| React / React DOM | 19.3.0 | MIT |
| Tailwind CSS, `@tailwindcss/turbopack` | 4.3.3 | MIT |
| shadcn/ui (`shadcn`, components copied into `src/components/ui`) | 4.23.0 | MIT |
| Base UI (`@base-ui/react`) | 1.9.0 | MIT |
| Recharts | 3.11.1 | MIT |
| IBM Plex Sans / Mono (`@fontsource/ibm-plex-*`) | 5.3.0 | OFL-1.1 (SIL Open Font License) |
| TanStack Query | 5.108.4 | MIT |
| React Hook Form, `@hookform/resolvers` | 7.92.0, 7.0.9 | MIT |
| Zod | 4.6.7 | MIT |
| Lucide (`lucide-react`) | 1.79.0 | ISC |
| class-variance-authority | 0.7.1 | Apache-2.0 |
| clsx, tailwind-merge, tw-animate-css, sonner, next-themes | — | MIT |

Re-check a package with `node -p "require('./apps/dashboard/node_modules/<pkg>/package.json').license"`, or audit the whole tree with a licence checker of your choice.

## Points to check

* **Default voice choice.** Because of the lineage question below, the default voice is `en_GB-alba-medium` (CC BY 4.0, fine-tuned from the Hi-Fi TTS base model, CC BY 4.0). `setup-mac.sh --models` downloads only alba.
* **`en_US-libritts_r-medium` and its base model.** The model card lists only the LibriTTS-R dataset (CC BY 4.0). It also says the voice was fine-tuned from the `lessac` medium checkpoint, which was trained on Blizzard-licensed data. This project uses the voice on the basis of the model card. Whether the base checkpoint's data terms carry over to the fine-tuned voice is not settled. If that matters for your use, choose a voice whose whole lineage has permissive licences, or use macOS `say`.
* **Your language model.** Whatever you run in Ollama is your choice, and its licence (and acceptable-use policy, if any) applies to you.
* **Generated audio and recordings** may contain your customers' personal data. That is a privacy matter (see [COMPLIANCE.md](COMPLIANCE.md)), separate from licensing.
