# Installation

This guide installs voice-agent on a Mac, starts it, and walks through first-time setup in the browser. It is written for developers and for small-business operators comfortable with the Terminal.

## Contents

- [Prerequisites](#prerequisites)
- [1. Get the code](#1-get-the-code)
- [2. Run the setup script](#2-run-the-setup-script)
- [3. Start, stop and check](#3-start-stop-and-check)
- [4. First-run setup in the browser](#4-first-run-setup-in-the-browser)
- [5. Choose a language model](#5-choose-a-language-model)
- [6. Import the sample workspace (optional)](#6-import-the-sample-workspace-optional)
- [Make targets](#make-targets)
- [Configuration (.env)](#configuration-env)
- [Where data lives](#where-data-lives)
- [Ports](#ports)
- [Backups and restore](#backups-and-restore)
- [Updating](#updating)
- [Uninstalling](#uninstalling)

## Prerequisites

| Requirement | Notes |
|---|---|
| **Apple Silicon Mac** (M1 or newer) | 16 GB memory recommended. Intel Macs work, but whisper.cpp then has no Metal acceleration. The scripts target macOS only. |
| **[Homebrew](https://brew.sh)** | Required, and the only thing you must install yourself. The setup script uses it to install anything missing: `ffmpeg`, `whisper-cpp`, `uv`, `node`, and (with `--with-ollama`) `ollama`. |
| **Node.js 20 or newer** | The setup script stops if Node is older than 20. The project uses **npm**, not pnpm. |
| **[uv](https://docs.astral.sh/uv/)** | Creates the Python 3.12 environments. Python 3.14 is not supported, because aiortc, onnxruntime and PyAV wheels are needed. The backend requires Python ≥ 3.11 and < 3.14, and the script uses 3.12. |
| **[Ollama](https://ollama.com/download)** and a local model | Either let the setup script do it (`--with-ollama`, which asks before installing Ollama and before downloading the model), or install Ollama yourself and pull a model, for example `ollama pull qwen3:4b-instruct-2507-q4_K_M`. Without that flag the script never installs Ollama or downloads a language model. `ollama list` shows what is installed. |
| Disk space | About 1 GB for dependencies plus about 125 MB for the default speech models, plus the size of your Ollama model(s) (about 2.5 GB for the default). |

## 1. Get the code

```bash
git clone https://github.com/priyanshu-shroti01/voice-agent.git
cd voice-agent
```

## 2. Run the setup script

**One command for everything** (tools, environments, database, speech models, Ollama and the default language model):

```bash
./scripts/setup-mac.sh --models --with-ollama     # or: make setup-all
```

Other variants:

```bash
./scripts/setup-mac.sh                            # tools, environments, database only
./scripts/setup-mac.sh --models                   # + speech models (~125 MB)
./scripts/setup-mac.sh --ollama-only              # only Ollama + the language model   (make ollama)
./scripts/setup-mac.sh --models --with-ollama --yes   # non-interactive: answer yes to every question
VA_DEFAULT_LLM_MODEL=llama3.2:3b ./scripts/setup-mac.sh --ollama-only   # choose a different model
./scripts/setup-mac.sh --help
```

Every download and installation is announced first, with its size, and needs a "y" unless you pass `--yes`.

The script installs only what is missing and can be run again safely. It:

1. Checks the platform, memory and free disk space.
2. Installs any missing Homebrew packages (`ffmpeg`, `whisper-cpp`, `uv`, `node`) and checks Node ≥ 20.
3. Creates the folders, `.env` and environments described below.
4. Creates `data/` and its subdirectories with owner-only permissions (`0700`). It copies `.env.example` to `.env` (mode `0600`) if `.env` does not exist.
5. Creates the backend environment `backend/.venv` with Python 3.12 (`uv sync`).
6. Installs **Piper TTS 1.8.0 (GPL-3.0)** into its own environment, `.tools/piper`. voice-agent never imports Piper; it runs as a separate process (see [MODEL-LICENSING.md](MODEL-LICENSING.md)).
7. Installs the dashboard dependencies with `npm ci`.
8. Creates or migrates the SQLite database and generates the per-install secret `data/.secret_key` (mode `0600`).
9. With `--models`, downloads the speech models from their official sources after asking:
   * `ggml-base.en-q5_1.bin` from the `ggerganov/whisper.cpp` Hugging Face repository (about 57 MB, MIT)
   * Piper voice `en_GB-alba-medium` (`.onnx`, `.onnx.json` and its `MODEL_CARD`) from `rhasspy/piper-voices` (about 60 MB, CC BY 4.0)
   * `silero_vad.onnx` from the `snakers4/silero-vad` GitHub repository (about 2 MB, MIT)
10. **Ollama and the language model.**
    * Without `--with-ollama`: only checks whether Ollama is installed and running and whether the default model (`VA_DEFAULT_LLM_MODEL`) is present, then prints advice. Nothing is installed or downloaded.
    * With `--with-ollama` (or `--ollama-only`):
      1. If Ollama is missing, asks, then runs `brew install ollama`.
      2. If Ollama is not running, starts it **temporarily on 127.0.0.1:11434** for the download and stops it afterwards. `start.sh` manages it from then on.
      3. If the model is missing, shows its size and checks this Mac's memory and free disk (warning below 8 GB of memory or 6 GB of disk). It then asks, and runs `ollama pull <model>`.
      4. An already installed Ollama or model is left untouched; nothing is reinstalled or downloaded again.

Without `--models`, the script lists the missing speech models and tells you how to fetch them.

## 3. Start, stop and check

```bash
./scripts/start.sh          # production mode if a dashboard build exists, otherwise the dev server
./scripts/start.sh --dev    # always run the dashboard with `next dev` (hot reload)
./scripts/health-check.sh   # check every component
./scripts/stop.sh           # stop what start.sh started
```

`start.sh` starts the services in order. Each one binds to `127.0.0.1` and logs to `logs/`:

1. Applies a staged backup restore, if there is one and nothing is running.
2. **Ollama.** If it is already reachable it is used as is. Otherwise, if `ollama` is installed, `ollama serve` is started with `OLLAMA_HOST=127.0.0.1:11434`.
3. **whisper-server** on port 8178, with `data/models/whisper/$VA_WHISPER_MODEL`.
4. **Piper HTTP server** on port 5005, with `data/models/piper/$VA_DEFAULT_TTS_VOICE.onnx`.
5. **API** (uvicorn) on port 8000. The script waits for `/api/health`.
6. **Scheduler** (`python -m app.scheduler.main`).
7. **Dashboard** on port 3000. It runs `next start` if `apps/dashboard/.next/BUILD_ID` exists (create it with `make build`, or `npm run build` in `apps/dashboard`). Otherwise it runs `next dev`.

If a speech service cannot start (model missing, port taken by another program), the script warns and continues. Voice calls then fail with an explicit error until it is fixed. If port 8000 or 3000 is taken by another program, the script stops with an error.

`stop.sh` stops the dashboard, scheduler, API, Piper, whisper-server and Ollama, but **only processes voice-agent started itself**. Each PID file in `.run/` stores the PID together with a command-line signature, and the signature must match. An Ollama you started yourself is left running.

`health-check.sh` checks the dashboard, API, database, Ollama, that the default model is installed, whisper-server, Piper, the VAD model, FFmpeg and the scheduler. It also warns if Ollama listens on a non-loopback address. The exit code is the number of failed required checks, so 0 means healthy.

## 4. First-run setup in the browser

Open **http://localhost:3000**. On a fresh install the dashboard sends you to the setup page, where you create:

* the **administrator account**: name, email and password. The password must be at least 10 characters, must not be a very common password, and must not contain the name part of your email address;
* your **first workspace**: the business the agents will speak for.

Setup can only be done once. After that, `POST /api/auth/setup` returns `409 already_setup`. The administrator can add more users under **Settings → Users** and add them to workspaces with a role (owner, admin, editor or viewer).

Next:

1. Fill in the business profile under **Settings → Workspace**. Agents introduce themselves on behalf of this business.
2. Review **Compliance** (calling hours, consent, DND, disclosures, retention) before running any campaign.
3. Create an agent (**Agents → New agent**), then try it in the **Voice playground**. Allow microphone access when the browser asks. Headphones prevent the agent from hearing itself.

## 5. Choose a language model

Go to **Settings → AI models**. It lists the models your Ollama installation reports, with size, quantisation and whether each one is local. From there you can:

* set the installation's **default model** (the initial value comes from `VA_DEFAULT_LLM_MODEL`, default `qwen3:4b-instruct-2507-q4_K_M`);
* **test** a model with a short prompt, which reports time to first token;
* **warm up** a model, which loads it into memory so the first reply is fast.

Each agent can override the model in the agent builder. Models that Ollama proxies to a remote host (for example tags ending in `:cloud`) are reported as **not local** and are refused unless you set `VA_ALLOW_REMOTE_LLM_MODELS=true`. On a 16 GB Mac, a 4-bit 4B–8B model leaves room for speech recognition and synthesis.

## 6. Import the sample workspace (optional)

`demo/shrotihost/workspace.json` is a fictional web-hosting business with two agents, six knowledge entries, eight fictional contacts and a draft **simulation** campaign. It contains no real prices and no real people.

* Dashboard: **Settings → New workspace → Import a workspace**, then choose `demo/shrotihost/workspace.json`.
* API: `POST /api/workspaces/import` with a multipart `file` field (see [demo/shrotihost/README.md](../demo/shrotihost/README.md)).

An import always creates a **new** workspace owned by you. Imported campaigns arrive as drafts in `SIMULATION` mode; an import can never create a real-calling campaign. `demo/shrotihost/contacts-sample.csv` contains the same contacts for trying the CSV import wizard.

## Make targets

The `Makefile` at the repository root wraps the scripts and test commands. `make help` lists them all.

| Target | What it does |
|---|---|
| `make setup` | `./scripts/setup-mac.sh` |
| `make setup-models` | `./scripts/setup-mac.sh --models` |
| `make dev` | `./scripts/start.sh --dev` (dashboard with hot reload) |
| `make start` | `./scripts/start.sh` |
| `make stop` | `./scripts/stop.sh` |
| `make health` | `./scripts/health-check.sh` |
| `make backup` | `./scripts/backup.sh` |
| `make build` | `npm run build` in `apps/dashboard` (production build, so `start.sh` uses `next start`) |
| `make test` | `make test-backend` (pytest: `backend/tests` and `tests`) and `make test-frontend` (`npx vitest run`). Real-model tests skip themselves when the services are down. |
| `make test-real` | Tests against the real local models (`tests/integration/test_real_providers.py -m "ollama or speech"`). Run `./scripts/start.sh` first. |
| `make test-e2e` | `npx playwright test`: browser tests in Chrome against an isolated instance (API :8100, dashboard :3100, temporary data directory) |
| `make lint` | `ruff check` (Python) and `npx eslint src` (dashboard) |
| `make typecheck` | `mypy app ../engine` (backend) and `npx tsc --noEmit` (dashboard) |
| `make migrations-check` | Check that the models match the Alembic migrations, using a throwaway database |
| `make security` | bandit, pip-audit, `npm audit` and gitleaks (if installed) |
| `make format` | `ruff format` and safe `ruff check --fix` |

See [TESTING.md](TESTING.md) for test results.

## Configuration (.env)

Settings are environment variables prefixed `VA_`, read from `.env` at the repository root (see `.env.example`). Restart after changing them (`./scripts/stop.sh && ./scripts/start.sh`).

| Variable | Default | Purpose |
|---|---|---|
| `VA_ENV` | `development` | `development`, `production` or `test`. In `production` the OpenAPI docs (`/api/docs`) are switched off. |
| `VA_HOST`, `VA_PORT` | `127.0.0.1`, `8000` | API address. `start.sh` always binds to 127.0.0.1. |
| `VA_WEB_PORT` | `3000` | Dashboard port. |
| `VA_DATA_DIR` | `./data` | Data directory. |
| `VA_SECRET_KEY` | unset | Leave unset to use the generated `data/.secret_key`. It is used to derive the key that encrypts provider credentials, so changing it makes saved provider secrets unreadable. |
| `VA_COOKIE_SECURE` | `false` | Set to `true` only when the dashboard is served over HTTPS (for example behind your own reverse proxy). This also enables HSTS. |
| `VA_ALLOWED_HOSTS` | `["localhost","127.0.0.1","[::1]"]` | Host headers the API accepts (protects against DNS rebinding). A JSON list. |
| `VA_CORS_ORIGINS` | `["http://localhost:3000","http://127.0.0.1:3000"]` | Origins allowed to make credentialed and state-changing requests. A JSON list. |
| `VA_OLLAMA_URL` | `http://127.0.0.1:11434` | Ollama endpoint. |
| `VA_DEFAULT_LLM_MODEL` | `qwen3:4b-instruct-2507-q4_K_M` | Default model, until changed in Settings. |
| `VA_ALLOW_REMOTE_LLM_MODELS` | `false` | Allow models that Ollama proxies to a remote host. Leave `false` to stay local. |
| `VA_WHISPER_SERVER_URL` | `http://127.0.0.1:8178` | whisper-server endpoint. |
| `VA_WHISPER_MODEL` | `ggml-base.en-q5_1.bin` | Whisper model file in `data/models/whisper/`. |
| `VA_PIPER_URL` | `http://127.0.0.1:5005` | Piper HTTP server endpoint. |
| `VA_DEFAULT_TTS_VOICE` | `en_GB-alba-medium` | Piper voice. `start.sh` loads `data/models/piper/<voice>.onnx`. |
| `VA_VAD_KIND` | `silero` | `silero`, or `energy` (a simple fallback). |
| `VA_AI_CONCURRENCY` | `1` | Concurrent AI inferences per process. |
| `VA_MAX_VOICE_SESSIONS` | `2` | Concurrent browser voice sessions. |
| `VA_TELEPHONY_CONCURRENCY` | `4` | Concurrent campaign calls in the scheduler. |
| `VA_PUBLIC_CALLS_ENABLED` | `false` | Allow customer "talk to us" links (each agent must also enable its own). |
| `VA_REAL_TELEPHONY_ENABLED` | `false` | Allow real PSTN calling (see [TELEPHONY.md](TELEPHONY.md) and [COMPLIANCE.md](COMPLIANCE.md)). |
| `VA_ALLOW_REMOTE_PROVIDER_HOSTS` | `false` | Allow provider URLs that resolve to public addresses. |
| `VA_BACKUP_PASSPHRASE` | unset | If set, `scripts/backup.sh` encrypts archives (AES-256-GCM). |

There are also settings not listed in `.env.example`, with these defaults: `VA_SESSION_TTL_HOURS=72`, `VA_SESSION_IDLE_HOURS=12`, `VA_LOGIN_MAX_ATTEMPTS=5`, `VA_LOGIN_WINDOW_SECONDS=300`, `VA_MAX_UPLOAD_MB=10`, and `VA_DATABASE_URL` (SQLite is the only supported database). The script-level overrides `VA_WHISPER_PORT` and `VA_PIPER_PORT` change the ports `start.sh` uses for the speech servers. If you change them, update `VA_WHISPER_SERVER_URL` and `VA_PIPER_URL` to match.

Provider endpoints, voices, audio and turn-taking settings, and telephony can also be changed in the dashboard under **Settings** (instance administrators only). Those values are stored in the database and take precedence over the `.env` defaults.

## Where data lives

Everything is under the repository directory. Nothing is sent anywhere.

| Path | Contents |
|---|---|
| `data/database/voice_agent.db` (+ `-wal`, `-shm`) | SQLite database (WAL mode) |
| `data/.secret_key` | Per-install secret (mode `0600`) |
| `data/recordings/<workspace_id>/` | Call recordings (WAV, mode `0600`). Only created if recording is enabled in the workspace's compliance policy. |
| `data/transcripts/` | Reserved directory. Transcripts are stored in the database. |
| `data/uploads/` | Temporary CSV uploads and workspace logos |
| `data/backups/` | Backup archives and pre-restore copies |
| `data/restore-pending/` | A verified restore waiting to be applied on the next start |
| `data/models/{whisper,piper,vad}/` | Speech model files (not in git) |
| `logs/` | `api.log`, `scheduler.log`, `web.log`, `whisper.log`, `piper.log`, `ollama.log` (if voice-agent started Ollama) |
| `.run/` | PID files of the processes started by `start.sh` |
| `.tools/piper/` | Piper's separate Python environment |
| `backend/.venv/` | Backend Python environment |

`data/`, `logs/`, `.run/`, `.tools/` and `.env` are git-ignored.

## Ports

| Port | Service | Bound to |
|---|---|---|
| 3000 | Dashboard (Next.js) | 127.0.0.1 |
| 8000 | API (FastAPI / uvicorn); docs at http://127.0.0.1:8000/api/docs outside production | 127.0.0.1 |
| 11434 | Ollama | 127.0.0.1 (when started by `start.sh`; set `OLLAMA_HOST=127.0.0.1` if you start it yourself) |
| 8178 | whisper.cpp `whisper-server` | 127.0.0.1 |
| 5005 | Piper HTTP server | 127.0.0.1 |

WebRTC audio uses ephemeral UDP ports chosen by aiortc. No STUN or TURN servers are used. The isolated end-to-end test instance uses 8100 and 3100.

## Backups and restore

```bash
./scripts/backup.sh                          # create an archive in data/backups/
VA_BACKUP_PASSPHRASE='long passphrase' ./scripts/backup.sh   # encrypted (AES-256-GCM, key from scrypt)
./scripts/backup.sh list
./scripts/backup.sh verify data/backups/<file>
./scripts/backup.sh restore data/backups/<file>   # verify and stage; applied on the next start
```

A backup contains the database (taken with SQLite's online backup API, so it is consistent while the app runs), recordings and uploads. A restore is **staged**: it is verified (checksums and database integrity) and extracted to `data/restore-pending/`. `start.sh` applies it the next time nothing is running, and keeps the previous data in `data/backups/pre-restore-<timestamp>/`. Instance administrators can do the same from **Settings → Backups**.

Model files and `.env` are not part of a backup. Keep a copy of `data/.secret_key`, or your `VA_SECRET_KEY`, with your backups. Without it, saved provider credentials (such as an Asterisk ARI password) cannot be decrypted and must be entered again.

## Updating

```bash
./scripts/stop.sh
git pull
./scripts/setup-mac.sh    # installs new dependencies and applies database migrations
./scripts/start.sh
```

Take a backup before updating.

## Uninstalling

Stop the services (`./scripts/stop.sh`), back up `data/` if you want to keep it, then delete the repository directory. Homebrew packages and Ollama are left in place; remove them with Homebrew and the Ollama uninstaller if you no longer need them.
