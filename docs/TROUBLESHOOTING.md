# Troubleshooting

Start with the built-in checks:

```bash
./scripts/health-check.sh      # every component; exit code = number of failed required checks
tail -n 50 logs/api.log        # also: scheduler.log, web.log, whisper.log, piper.log, ollama.log
```

In the dashboard, **Settings → Diagnostics** shows component health, model files and recent system events. The status strip at the top of the dashboard shows the same health at a glance.

## Contents

- [Local AI (Ollama)](#local-ai-ollama)
- [Speech services](#speech-services)
- [Voice calls in the browser](#voice-calls-in-the-browser)
- [Campaigns and the scheduler](#campaigns-and-the-scheduler)
- [Installation and start-up](#installation-and-start-up)
- [Sign-in and access](#sign-in-and-access)
- [Backups and the database](#backups-and-the-database)

## Local AI (Ollama)

### "Local LLM unavailable" / `llm_unavailable` / "Cannot connect to Ollama"

Ollama is not running, or not at `VA_OLLAMA_URL` (default `http://127.0.0.1:11434`).

```bash
curl -s http://127.0.0.1:11434/api/version      # should print a version
OLLAMA_HOST=127.0.0.1 ollama serve              # start it, bound to localhost only
```

`./scripts/start.sh` starts Ollama this way if it is installed and not already running. If you use the Ollama desktop app, make sure it is running. If Ollama isn't installed, run `./scripts/setup-mac.sh --ollama-only` (it asks before installing anything), or get it from <https://ollama.com/download>.

### "Model '…' is not installed in Ollama" / `model_not_found`

The agent (or the installation default) names a model that `ollama list` does not show. Either:

* choose an installed model under **Settings → AI models** (installation default) or in the agent builder (per agent), or
* install it: `./scripts/setup-mac.sh --ollama-only` (asks before downloading), or `ollama pull qwen3:4b-instruct-2507-q4_K_M`.

Model names must match exactly, including the tag.

### "… is not local" / `remote_model_refused`

The model is a cloud proxy (for example a `:cloud` tag, or a model with a `remote_host`). voice-agent refuses these so that no conversation leaves the machine. Pick a local model. Only if you deliberately accept cloud processing, set `VA_ALLOW_REMOTE_LLM_MODELS=true` and restart.

### The first reply is slow (several seconds)

The first request after Ollama loads a model includes the model load: about **3–4 seconds** for a 4B model on an M1 Pro. After that, the first token typically arrives in about 0.1 s.

* voice-agent warms the model while the agent's greeting plays, which hides most of the load time.
* **Settings → AI models → Warm up** loads it ahead of time.
* Models stay loaded for `keep_alive` (default 15 minutes) after the last use, then unload. The first call after an idle period is slow again.
* Larger models load and run more slowly. On 16 GB, stay at about 4–8B parameters with 4-bit quantisation.
* If the model takes longer than 120 s to produce a first token, or stalls for 30 s mid-reply, the call fails with `llm_timeout`. This usually means memory pressure: close other heavy apps or choose a smaller model.

### The agent's reply says "waiting for local AI capacity"

Another conversation, simulation or analysis is using the model, and `VA_AI_CONCURRENCY` (default 1) allows one inference at a time per process. The reply starts when the slot frees up. Raise the value only if you have the memory for it.

## Speech services

### whisper-server or Piper not reachable (`stt_unavailable`, `tts_unavailable`)

Check the logs and the model files:

```bash
tail -n 50 logs/whisper.log logs/piper.log
ls data/models/whisper data/models/piper data/models/vad
```

* **Model missing**: run `./scripts/setup-mac.sh --models`.
* **`VA_WHISPER_MODEL` or `VA_DEFAULT_TTS_VOICE` names a file that does not exist** in `data/models/…`: fix the name in `.env`.
* **"Port 8178/5005 busy (not ours)"**: another program holds the port. `start.sh` skips the service rather than killing an unknown process. See [Port already in use](#port-already-in-use).
* **Piper environment missing** (`.tools/piper`): run `./scripts/setup-mac.sh` again.
* As a workaround for TTS, choose **macOS voices** under **Settings → Speech and audio**.

### "Voice activity detection unavailable" / `vad_unavailable`

`data/models/vad/silero_vad.onnx` is missing. Run `./scripts/setup-mac.sh --models`.

## Voice calls in the browser

### Microphone access blocked or not found

* The browser asks for permission on the first call. If you blocked it, allow the microphone in the site settings (the icon in the address bar) and reload.
* On macOS, also check **System Settings → Privacy & Security → Microphone** for your browser.
* Browsers only allow microphone access in a **secure context**: `http://localhost` or `http://127.0.0.1`, or **HTTPS**. Opening the dashboard as `http://<your-mac's-LAN-IP>:3000` will not work for voice. Use an HTTPS reverse proxy for anything other than localhost.

### The call connects but I hear nothing

* Check the output device and volume. Agent audio plays through an `<audio>` element, and some browsers block autoplay until you have interacted with the page, so click on the page and try again.
* Check that Piper is healthy (`./scripts/health-check.sh`) and preview a voice under **Settings → Speech and audio**.
* Look for an error message in the call panel. Provider errors are shown there: recoverable ones as a line in the transcript, fatal ones as the call's error.
* If the connection never establishes, the call ends after 30 s with `connection_timeout`. A VPN or firewall that blocks local UDP can cause this, because WebRTC media uses UDP on the local machine.

### The agent interrupts itself or stops mid-sentence (echo)

With loudspeakers, the microphone hears the agent's own voice, which can trigger barge-in.

* **Use headphones.** This is the most effective fix.
* Raise **Settings → Speech and audio → Turn-taking → "Talk-over needed to interrupt (ms)"** (`barge_in_min_ms`, default 300 ms; try 600–900 ms), or turn barge-in off.
* Raise the **speech threshold** slightly in noisy rooms.

### The agent replies before I have finished speaking

Increase **"End-of-turn silence (ms)"** (`end_silence_ms`, default 700 ms) in the turn-taking settings, or per agent in the agent builder. Larger values feel slower but cut people off less.

### "All N voice slots are busy" (`503 capacity`)

`VA_MAX_VOICE_SESSIONS` (default 2) browser sessions are already active, including public-link calls. End one, or wait for it to finish. Sessions end automatically after the agent's silence timeout or maximum duration.

### Transcripts contain words nobody said

Whisper can hallucinate on noise. Very short noise bursts and known phrases such as "Thank you." are filtered out. A quieter room, a headset microphone, or a higher VAD threshold help. The `small.en` Whisper model is more accurate than `base.en` (`VA_WHISPER_MODEL=ggml-small.en-q5_1.bin`, file downloaded separately).

## Campaigns and the scheduler

### The scheduler is not running

`./scripts/health-check.sh` reports **Scheduler not running**, or the dashboard health shows the scheduler as unavailable (no heartbeat in the last 20 s).

```bash
tail -n 50 logs/scheduler.log
./scripts/stop.sh && ./scripts/start.sh
```

If the log says `scheduler not started: another scheduler is running`, a previous scheduler's heartbeat is less than 20 seconds old. Wait 20 seconds and start again. Only one scheduler may run at a time. On restart, jobs interrupted by a crash are re-queued automatically, and their in-progress calls are marked `interrupted_by_restart`.

### A campaign is running but nothing is being called

Open the campaign's contact list, which shows each contact's status and **skip reason**, and the **eligibility panel** on a contact's page, which lists every check with pass/fail and a reason. Common causes:

* **Outside the calling window.** The effective window is the overlap of the workspace window (**Compliance**, default 09:00–21:00 Mon–Sat) and the campaign window (default 10:00–19:00), in the campaign's timezone. Contacts wait until the window opens. Simulation campaigns can be set to ignore the window for testing.
* **No consent recorded** for the campaign's purpose (consent is required for promotional, service and inquiry follow-up calls by default). A CSV import does not create consent unless consent evidence columns were mapped.
* **DND status unknown or stale** for promotional campaigns. Import fresh scrub results under **Compliance → Apply DND scrub results**.
* **Suppressed number** (opt-out, wrong number, erasure) or contact status `do_not_call`.
* **Frequency caps** (default 1 call per day and 3 per week per number, per mode).
* **Campaign paused automatically** after 3 consecutive provider failures (for example Ollama stopped). The campaign shows the reason. Fix the provider, then **Resume**.
* **PSTN campaign paused** because `VA_REAL_TELEPHONY_ENABLED` is not `true`, or PSTN prerequisites are missing.
* **Scheduled start** in the future (status `scheduled`), or the schedule end has passed.
* The **scheduler is not running** (above).

### Simulated calls fail with a provider error

Simulations use the real local model. If Ollama is down, the call fails, the contact's attempt is not counted, and the contact is retried after 2 minutes. Start Ollama and check **Settings → AI models**.

## Installation and start-up

### Port already in use

```bash
lsof -nP -iTCP:8000 -sTCP:LISTEN     # likewise 3000, 8178, 5005, 11434
```

If the process is an old voice-agent instance, `./scripts/stop.sh` stops it (it only stops processes it started; PID files are in `.run/`). Otherwise stop the other program, or move voice-agent: `VA_PORT`/`VA_WEB_PORT` in `.env`, and `VA_WHISPER_PORT`/`VA_PIPER_PORT` together with `VA_WHISPER_SERVER_URL`/`VA_PIPER_URL`. If you change `VA_PORT`, start the dashboard with `VA_API_ORIGIN=http://127.0.0.1:<port>` so its `/api` proxy points at the right place, and update `VA_CORS_ORIGINS` if you change `VA_WEB_PORT`.

### Python 3.14 errors during setup (aiortc, onnxruntime, av wheels)

The backend supports Python 3.11–3.13. The setup script creates the environment with **Python 3.12** (`uv venv --python 3.12`), which uv downloads if needed. If an old `backend/.venv` was created with another version, delete it and run `./scripts/setup-mac.sh` again:

```bash
rm -rf backend/.venv && ./scripts/setup-mac.sh
```

### pnpm fails (`Cannot find module …/pnpm.cjs`) or a corepack error

The project uses **npm** (`package-lock.json`); pnpm is not needed. A broken corepack pnpm shim does not affect setup, which runs `npm ci`. Use `npm` commands in `apps/dashboard`.

### "Dashboard dependencies missing" / "Backend environment missing"

Run `./scripts/setup-mac.sh`.

### "No production build found; starting the dev server"

`start.sh` runs `next start` only if a production build exists. Run `make build` (or `npm run build` in `apps/dashboard`), or use `./scripts/start.sh --dev` on purpose.

## Sign-in and access

* **"Too many sign-in attempts"** (`429`): the login rate limit is 5 failed attempts per account and 20 per IP within 5 minutes. Wait a few minutes. The limiter is in memory, so restarting the API also clears it.
* **"Invalid host header"** / **400 from the API** when using a hostname other than localhost: add the hostname to `VA_ALLOWED_HOSTS` (a JSON list).
* **"Cross-origin request refused"** (`bad_origin`): the page origin is not in `VA_CORS_ORIGINS`. Add your dashboard's origin (scheme, host and port).
* **"Missing or invalid CSRF token"**: your session cookie changed (for example after signing in in another tab). Reload the page. API clients must send `x-csrf-token` with the value of the `va_csrf` cookie.
* **A workspace or record returns 404**: you are not a member of that workspace, or the record belongs to another workspace. Ask a workspace owner or admin to add you.
* **Forgotten administrator password**: there is no email reset. Another instance administrator can create a new admin user. If you were the only one, see [Resetting the database](#resetting-the-database) (this loses data), or restore a backup.

## Backups and the database

### A restore is pending but has not been applied

A restore uploaded in **Settings → Backups** (or `./scripts/backup.sh restore FILE`) is only verified and staged in `data/restore-pending/`. It is applied by `./scripts/start.sh` while the API and scheduler are **stopped**:

```bash
./scripts/stop.sh && ./scripts/start.sh
```

If `start.sh` prints "A restore is staged; stop the app first", something was still running; stop it and start again. The previous data is kept in `data/backups/pre-restore-<timestamp>/`.

### Saved provider credentials stopped working after a restore or move

Provider secrets (such as the ARI password) are encrypted with a key derived from `data/.secret_key` or `VA_SECRET_KEY`. If that secret changed, re-enter the credentials under **Settings → Telephony**.

### Resetting the database

This starts over with an empty installation: you will see the first-run setup again. Move the old data aside rather than deleting it:

```bash
./scripts/stop.sh
mv data/database "data/database.old-$(date +%Y%m%d-%H%M%S)"
mkdir -p data/database && chmod 700 data/database
./scripts/start.sh            # the API creates and migrates a fresh database on start-up
```

Recordings and uploads in `data/recordings/` and `data/uploads/` belong to the old database. Move them aside too if you want a completely clean start. Your speech models in `data/models/` are unaffected.
