# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `setup-mac.sh --with-ollama` (`make setup-all`) installs Ollama with Homebrew and pulls the default language
  model, asking first and checking memory and free disk. `--ollama-only` (`make ollama`) runs just that step.
  If Ollama isn't running, it is started temporarily on 127.0.0.1 for the download and stopped afterwards.

### Fixed
- Variables set on the command line now take precedence over `.env` in the shell scripts.
- The setup script's model check no longer misreports an installed model when a pipe closes early.
- Documented speech-model download size corrected to ~125 MB.

## [0.1.0] - 2026-11-25

Initial release: a local-first AI voice-agent platform for macOS. Speech recognition, the language model and speech synthesis all run on the Mac.

### Added

- **Voice conversations in the browser** over WebRTC (aiortc). Silero VAD turn detection, whisper.cpp speech-to-text (per turn), streamed responses from a local Ollama model, sentence-pipelined Piper TTS (or macOS `say`), barge-in and manual interrupt, mute, silence re-prompt and hang-up, maximum call duration, an AI-capacity limit with a "waiting" state, and fallback speech on provider failure. No STUN/TURN servers are used.
- **Agent builder** with instructions, objectives, business knowledge, greeting, voice, model and call rules; version history and restore; duplicate and activate; a text test console with dry-run tools.
- **Agent tools** from a fixed, validated registry: end call, request callback, request appointment, record opt-out, search knowledge, record interest, capture lead.
- **Lead capture** from any real conversation: deduplicated contacts, and follow-up consent recorded only on an explicit yes.
- **Customer "talk to us" links** per agent (off by default, token-based, rate limited).
- **Multi-workspace** tenancy with owner, admin, editor and viewer roles, and strict workspace isolation (foreign resources return 404).
- **Contacts and CSV import**: phone normalisation (libphonenumber), duplicate detection, column mapping, validation and preview, CSV formula-injection protection, consent recorded only with evidence, export.
- **Knowledge base** per workspace: FAQs, text, Markdown, CSV and PDF uploads, with local SQLite FTS5/BM25 retrieval on every turn.
- **Campaigns** on a persistent SQLite scheduler: calling windows, retries, attempt limits, per-campaign and global concurrency, singleton lock, deduplicated jobs, atomic claims, restart recovery, and auto-pause after repeated provider failures.
- **Compliance controls (India-oriented defaults)**: consent records, suppression list, in-call opt-outs, DND scrub import, calling window (09:00–21:00 IST by default), frequency caps, fail-closed eligibility checks, AI-identity and recording disclosures, retention, erasure workflow, audit log, and PSTN prerequisite attestations.
- **Calls**: transcripts, LLM summaries and outcomes, per-turn latency metrics, opt-in recordings with audited playback, callback requests, export.
- **Analytics** computed from stored records.
- **Telephony**: a deterministic simulator for outbound and inbound calls with scripted or LLM-played callee personas, and an Asterisk ARI + RTP adapter for real PSTN calls (integration-ready, disabled by default, tested only against a mocked ARI server).
- **Security**: Argon2id passwords, hashed session tokens, CSRF double-submit, Origin and TrustedHost checks, login rate limiting, an SSRF guard for provider URLs, security headers and CSP, upload content sniffing, log redaction, encrypted provider credentials, refusal of remote models, localhost-only binding.
- **Operations**: `setup-mac.sh`, `start.sh`, `stop.sh`, `health-check.sh`, `backup.sh` (optional AES-256-GCM encryption, verified and staged restore), a Makefile, CI workflow, and an importable sample workspace (`demo/shrotihost`).
- **Documentation**: architecture, installation, security, compliance, telephony, API, model licensing, troubleshooting.

### Known limitations

- Speech-to-text is not streamed (one transcription per turn). TTS is pipelined per sentence, not streamed below sentence level.
- English speech models only by default.
- Real PSTN calling is not production-verified, real inbound calls are not wired into the backend, DTMF is not handled, and PSTN calls are not recorded.
- No independent security audit or penetration test has been performed.
