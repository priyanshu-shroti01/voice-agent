# voice-agent

Build, test and run AI voice agents on your own Mac. Speech recognition, the language model and the voice all
run locally: no cloud AI service, no subscription, no data leaving the machine.

voice-agent gives a small business (or several businesses) a dashboard to create phone-style AI agents, talk to them
through the browser, let customers talk to them, capture leads from those conversations, and run outbound
campaigns. Campaigns run as simulations until real telephony is deliberately set up.

![Overview](docs/screenshots/overview-light.png)

## What it does

- **Live voice conversations in the browser** over WebRTC: microphone in, agent voice out, live transcript,
  mute, interrupt-by-talking (barge-in) and a manual interrupt.
- **Local AI end to end.** Silero VAD for turn detection, whisper.cpp (Metal) for speech-to-text, any local
  Ollama model for the conversation, and Piper (or macOS voices) for speech. Cloud-proxied Ollama models are
  detected and refused; there is no silent cloud fallback.
- **Agent builder** with instructions, objectives, business knowledge, voice, model, call rules, version history,
  a text test chat and simulated calls.
- **Every conversation can become a lead.** Agents collect name, number and need, read the number back, ask
  permission to follow up, and save a deduplicated contact with the consent evidence linked to the call.
- **Customer links** (off by default): a "talk to us" page per agent that customers open in their browser.
- **Multiple businesses** in one installation, with strict workspace isolation enforced in the backend and
  owner/admin/editor/viewer roles.
- **Contacts and CSV import** with phone normalisation, duplicate detection, a mapping wizard, CSV-injection
  protection, and consent recorded only when the file carries real evidence.
- **Campaigns** with calling windows, retries, attempt limits and concurrency, all on a persistent SQLite job
  queue that survives restarts without duplicating calls.
- **Compliance controls for India**: consent records, a do-not-call list, opt-outs during calls, DND scrub
  imports, calling hours, frequency caps, AI and recording disclosures, retention, erasure and an audit log.
  Checks fail closed. (This is tooling, not legal advice; see [docs/COMPLIANCE.md](docs/COMPLIANCE.md).)
- **Knowledge base** per workspace (FAQs, policies, pricing, PDFs) with local full-text retrieval.
- **Transcripts, summaries and outcomes** for every call, generated locally. Plus analytics computed from your
  records, callback requests, recordings (opt-in, audited) and backup/restore.
- **Telephony**: a simulator for inbound and outbound calls, and an Asterisk ARI adapter for real SIP/PSTN calls
  (integration-ready, disabled by default, not yet verified on a live carrier).

| Voice playground | Agent builder |
|---|---|
| ![Playground](docs/screenshots/playground-dark.png) | ![Agent](docs/screenshots/agent-light.png) |
| **Call detail** | **Analytics** |
| ![Call](docs/screenshots/call-light.png) | ![Analytics](docs/screenshots/analytics-dark.png) |

## How it works

```text
 Browser (Next.js dashboard)                         This Mac, all bound to 127.0.0.1
 ┌──────────────────────────┐   WebRTC (Opus)   ┌──────────────────────────────────────────────┐
 │ mic ─┐        ┌─ speaker │◄────────────────► │ aiortc transport                             │
 │      │        │          │  data channel     │   │ 16 kHz PCM            ▲ 48 kHz PCM       │
 │ transcript, state, ctrl  │◄────────────────► │   ▼                       │                  │
 └──────────────────────────┘                   │ Silero VAD → turn end     │ audio queue      │
             │ HTTPS/HTTP /api (cookie + CSRF)  │   ▼                       │                  │
             ▼                                  │ whisper.cpp ─► session ─► Piper TTS          │
 ┌──────────────────────────┐                   │ (whisper-server)  │  ▲   (per sentence)      │
 │ FastAPI backend          │──────────────────►│                   ▼  │                       │
 │ auth · workspaces · CRM  │                   │            Ollama (local model)              │
 │ campaigns · compliance   │                   │            + tools + knowledge (FTS5)        │
 │ SQLite (WAL) + files     │◄─ scheduler ─────►│ simulator / Asterisk ARI (optional)          │
 └──────────────────────────┘                   └──────────────────────────────────────────────┘
```

The conversation engine (`engine/`) does not know about transports. The same pipeline serves browser calls,
simulated calls and SIP calls. The LLM streams token by token. Speech is synthesised one sentence at a time and
playback starts as soon as the first sentence is ready (it is not sub-sentence streaming). Details are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Measured on an M1 Pro / 16 GB with `qwen3:4b-instruct-2507` ([docs/BENCHMARKS.md](docs/BENCHMARKS.md)): once the
caller's end-of-turn pause is detected, the agent starts speaking after **1.06 s at the median and 2.04 s at p95**.
Speech-to-text takes about 0.17 s, the warm model's first token about 0.2 s, and the first sentence's synthesis
about 0.1 s.

## Technology

| Area | Stack |
|---|---|
| Dashboard | Next.js 16, React 19, TypeScript, Tailwind CSS 4, shadcn/ui (Base UI), TanStack Query, React Hook Form, Zod, Recharts, Lucide |
| Backend | Python 3.12, FastAPI, Pydantic 2, SQLAlchemy 2 (async), Alembic, SQLite (WAL, FTS5) |
| Voice | aiortc (WebRTC), PyAV, Silero VAD (onnxruntime), whisper.cpp, Piper, FFmpeg |
| AI | Ollama with any local model; the default is Qwen3 4B Instruct |
| Telephony | Built-in simulator; Asterisk ARI + RTP adapter |

## Requirements

- An Apple Silicon Mac (M1 or newer). 16 GB memory recommended. Intel Macs work without Metal acceleration.
- macOS with [Homebrew](https://brew.sh), Node.js 20+, [uv](https://docs.astral.sh/uv/)
- [Ollama](https://ollama.com/download) and a local model. The setup script can install both for you
  (`--with-ollama`, which asks first), or use what you already have (`ollama list`).
- About 1 GB of free disk for dependencies and speech models, plus about 2.5 GB for the default language model.

## Install and run

```bash
git clone https://github.com/priyanshu-shroti01/voice-agent.git && cd voice-agent
./scripts/setup-mac.sh --models --with-ollama   # everything: tools, speech models (~125 MB), Ollama + default LLM (~2.5 GB)
                                                # installs only what's missing and asks before every download
./scripts/start.sh                # Ollama (if not running), whisper-server, Piper, API, scheduler, dashboard
./scripts/health-check.sh         # verifies every component
```

Open **http://localhost:3000**. The first visit asks you to create the administrator account and your first
business workspace.

```bash
./scripts/stop.sh                 # stops only the processes voice-agent started
```

`make setup-all`, `make setup`, `make ollama`, `make dev`, `make stop`, `make health`, `make test`, `make lint`, `make typecheck` and `make backup`
wrap the same scripts. See [docs/INSTALLATION.md](docs/INSTALLATION.md) for details and `.env.example` for every setting.

### Ollama and models

Ollama should listen on `127.0.0.1:11434` (the start script launches it that way if it isn't running). Pick the
model under **Settings → AI models**, where each model is listed with its size and whether it is local. Models that
Ollama proxies to a cloud host (for example `*:cloud` tags) are shown as remote and cannot be selected. On a
16 GB Mac, models up to about 4–8 B parameters at 4-bit quantisation leave room for speech recognition and synthesis.

### Try your first conversation

1. **Agents → New agent**: give it a name, a greeting and some business knowledge, then save.
2. **Voice playground**: choose the agent and press **Start conversation**. Allow the microphone. Headphones avoid
   echo.
3. Open the call record afterwards for the transcript, summary, outcome and response times.

### Sample workspace

`demo/shrotihost/workspace.json` is an optional sample web-hosting business with two agents, a knowledge base,
fictional contacts and a draft simulation campaign. Import it from **Settings → New workspace → Import a workspace**.
It contains no real prices and no real people. See [demo/shrotihost/README.md](demo/shrotihost/README.md).

### Workspaces

Each business is a workspace with its own agents, contacts, knowledge, campaigns, calls, recordings, analytics
and compliance policy. Switch workspaces from the top of the sidebar. Members get roles per workspace. The backend
checks membership on every request, and resources from another workspace answer "not found".

### Real phone calls (optional)

Real calling is disabled until you set `VA_REAL_TELEPHONY_ENABLED=true`, connect your own Asterisk server and SIP
trunk under **Settings → Telephony**, and record the workspace's prerequisites under **Compliance** (authorisation,
telemarketer registration, number series, A2P declaration to your provider). Calls to Indian numbers may incur
charges and are regulated by TRAI. Read [docs/TELEPHONY.md](docs/TELEPHONY.md) and [docs/COMPLIANCE.md](docs/COMPLIANCE.md)
first.

## Testing

```bash
make test        # backend + engine + security tests (pytest) and dashboard tests (vitest)
make test-real   # real-model tests: whisper.cpp + Piper + Ollama (needs ./scripts/start.sh)
make test-e2e    # Playwright in Chrome against an isolated instance, including a live voice conversation
```

Results and exact commands are in [docs/TESTING.md](docs/TESTING.md).

## Security and privacy

Everything binds to localhost. Passwords use Argon2id. Sessions use HttpOnly cookies with CSRF tokens.
Provider URLs are SSRF-checked, uploads are content-sniffed, CSV exports are formula-escaped and logs are
redacted. Provider credentials are encrypted at rest. The LLM can only request a fixed set of validated actions;
it cannot run commands or fetch URLs. See [docs/SECURITY.md](docs/SECURITY.md). No independent penetration test
has been performed.

## Licensing

voice-agent is MIT licensed ([LICENSE](LICENSE)). Piper TTS is GPL-3.0. It is installed into its own environment
and runs as a separate process that voice-agent talks to over HTTP. Model weights are not included in this
repository; review each model's licence in [docs/MODEL-LICENSING.md](docs/MODEL-LICENSING.md).

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). The usual suspects: Ollama not running, a model name that
isn't installed, microphone permission, and the first reply after a cold model load taking a few seconds.

## Roadmap

- Streaming speech recognition (partial transcripts) and sub-sentence TTS streaming
- Multilingual speech models (Hindi and other Indian languages) with matching Piper voices
- Verified Asterisk/SIP integration with a real carrier; additional provider adapters
- Embedding-based retrieval as an option alongside full-text search
- Calendar integrations for confirmed appointments (with human approval)

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
