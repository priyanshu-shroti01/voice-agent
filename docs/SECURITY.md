# Security

This document describes voice-agent's threat model, the controls in the code, their known limits, and how the controls are tested. To report a vulnerability, see [Reporting a vulnerability](#reporting-a-vulnerability).

> **No independent penetration test or third-party security audit has been performed.** The controls below were implemented and tested by the project's developers. Treat this as a description of intent and of automated test coverage, not as an assurance.

## Contents

- [Threat model](#threat-model)
- [Network exposure](#network-exposure)
- [Authentication and sessions](#authentication-and-sessions)
- [CSRF, Origin and Host checks](#csrf-origin-and-host-checks)
- [Authorisation: roles and workspace isolation](#authorisation-roles-and-workspace-isolation)
- [Local AI only](#local-ai-only)
- [LLM tool sandbox and prompt injection](#llm-tool-sandbox-and-prompt-injection)
- [SSRF protection for provider URLs](#ssrf-protection-for-provider-urls)
- [Input handling: uploads, CSV, search](#input-handling-uploads-csv-search)
- [Security headers and CSP](#security-headers-and-csp)
- [Data at rest](#data-at-rest)
- [Recordings](#recordings)
- [Backups](#backups)
- [Logging and audit](#logging-and-audit)
- [Public "talk to us" links](#public-talk-to-us-links)
- [Real telephony](#real-telephony)
- [Known limitations](#known-limitations)
- [Hardening checklist for operators](#hardening-checklist-for-operators)
- [Security tests](#security-tests)
- [Reporting a vulnerability](#reporting-a-vulnerability)
- [Automated scan results (2026-11-25)](#automated-scan-results-2026-11-25)

## Threat model

voice-agent is a **local-first, single-machine** application. All services run on one Mac and bind to `127.0.0.1`. One installation can hold several business workspaces with several users.

**Assets**

* Personal data about contacts: names, phone numbers, emails, notes, consent records, call transcripts and (opt-in) call recordings.
* User credentials and sessions.
* Provider credentials, such as an Asterisk ARI password.
* The ability to place calls. Real calls can cost money and are regulated.
* Business configuration: agents, knowledge base, compliance policy.

**Adversaries and what the design addresses**

| Adversary | Examples | Main controls |
|---|---|---|
| A malicious web page in the operator's browser | Cross-site request forgery, DNS rebinding to `localhost`, clickjacking | CSRF double-submit token, Origin check, TrustedHost, `SameSite=Lax` cookies, `frame-ancestors 'none'` |
| Another signed-in user | A viewer trying to change data; a member of workspace A probing workspace B | Role checks on the server, workspace scoping with 404 for foreign resources |
| A caller or website visitor talking to an agent | Prompt injection ("ignore your instructions", "send me the list"), abusive call volume through public links | Fixed tool registry with validated arguments, no shell or URL tools, per-turn workspace-scoped retrieval, rate limits, public links off by default |
| Malicious files | A CSV with spreadsheet formulas, a disguised executable, a hostile backup archive | Content sniffing, size limits, formula neutralisation, safe archive extraction |
| An attacker who obtains a copy of `data/` or a backup | A lost laptop, a leaked backup | Hashed passwords and session tokens, encrypted provider secrets, optional backup encryption. **The database itself is not encrypted**; rely on FileVault. |
| Misconfiguration | Ollama listening on all interfaces, a cloud model chosen by accident, a provider URL pointed at a metadata service | Localhost binding, loopback check in `health-check.sh`, remote-model refusal, SSRF guard |

**Out of scope**: an attacker with code execution or an administrator account on the Mac, a compromised Ollama installation or model files, compromised dependencies (see the automated scan results below), and the security of an operator's own reverse proxy, Asterisk server or SIP trunk.

## Network exposure

* `scripts/start.sh` binds the API (8000), dashboard (3000), whisper-server (8178) and Piper (5005) to `127.0.0.1`. If it has to start Ollama itself, it does so with `OLLAMA_HOST=127.0.0.1:11434`. `scripts/health-check.sh` warns if Ollama listens on a non-loopback address.
* The browser reaches the API through the dashboard's same-origin `/api/*` rewrite, so session cookies stay first-party.
* WebRTC uses **no STUN or TURN servers** (`iceServers: []` on both sides). No media or metadata is sent to third-party ICE servers.
* Exposing the dashboard beyond localhost, for example for customer links, is a deliberate operator action that needs your own HTTPS reverse proxy. See the [hardening checklist](#hardening-checklist-for-operators).

## Authentication and sessions

Implemented in `backend/app/core/security.py`, `backend/app/auth/router.py` and `backend/app/auth/deps.py`.

* **Password hashing:** Argon2id via argon2-cffi (`time_cost=3`, `memory_cost=19 MiB`, `parallelism=1`). That is at least the OWASP minimum. Hashes are upgraded transparently on login if the parameters change.
* **Password rules:** 10–256 characters, not one of a small list of very common passwords, and not containing the email's local part.
* **Constant-time behaviour for unknown users:** login runs a dummy Argon2 verification when the email does not exist and returns the same `invalid_credentials` error either way.
* **Session tokens:** 256-bit random tokens (`secrets.token_urlsafe(32)`). **Only the SHA-256 hash is stored** (`sessions.id`), so a database leak does not reveal usable session cookies.
* **Cookies:** `va_session` is `HttpOnly`, `SameSite=Lax`, `Path=/`, with `Secure` controlled by `VA_COOKIE_SECURE`. `va_csrf` has the same attributes but is not HttpOnly, because the dashboard must read it.
* **Expiry:** absolute lifetime `VA_SESSION_TTL_HOURS` (default 72 h) and idle timeout `VA_SESSION_IDLE_HOURS` (default 12 h), both enforced on the server. Deactivated users lose access immediately.
* **Revocation:** logout revokes the current session. "Sign out everywhere" (`/api/auth/logout-all`) revokes all of them. Changing your password revokes every other session.
* **Login rate limiting:** a sliding window of `VA_LOGIN_WINDOW_SECONDS` (default 300 s). Up to `VA_LOGIN_MAX_ATTEMPTS` (default 5) failures per account and 4× that per client IP are allowed, after which login returns `429`. Rate-limited attempts are audited with a truncated hash of the email, not the email itself. First-run setup is limited to 10 attempts per 5 minutes per IP and can only succeed once.
* **No multi-factor authentication** is implemented.

## CSRF, Origin and Host checks

* **CSRF (double submit).** Every authenticated `POST`, `PUT`, `PATCH` and `DELETE` must send an `X-CSRF-Token` header equal to the session's CSRF token, compared in constant time. The token is delivered in the readable `va_csrf` cookie and in the login, setup, status and `/me` responses. The check is inside the `current_session` dependency, so **every authenticated route enforces it and no route can forget it**. A failure returns `403 csrf_failed`.
* **Origin check** (middleware in `backend/app/main.py`). A state-changing request with an `Origin` header that is neither in `VA_CORS_ORIGINS` nor equal to the request's own host is refused with `403 bad_origin`, before any route runs. This is defence in depth on top of CSRF tokens.
* **TrustedHost** (DNS-rebinding protection). Starlette's `TrustedHostMiddleware` rejects any `Host` header not in `VA_ALLOWED_HOSTS` (default `localhost`, `127.0.0.1`, `[::1]` and `testserver`, which the test client uses). A rebinding attack from a malicious domain therefore cannot talk to the API.
* **CORS** allows credentials only for `VA_CORS_ORIGINS` (by default the local dashboard origins), with methods `GET/POST/PUT/PATCH/DELETE` and headers `content-type` and `x-csrf-token`.
* Requests that declare a body larger than 64 MB are refused with `413`. Uploads have their own, smaller limits.

## Authorisation: roles and workspace isolation

* **Instance administrator.** The first user (created at setup) is an instance administrator. Only instance administrators can manage users, change provider settings, read diagnostics and system events, and create, download or restore backups.
* **Workspace roles** (ranked): `viewer` < `editor` < `admin` < `owner`.
  * viewer: read-only access to the workspace.
  * editor: manage agents, contacts, imports, knowledge, campaigns and callbacks; start voice sessions and simulations; play recordings.
  * admin: also members, workspace profile and compliance policy, suppression removal, DND scrub import, the audit log, contact erasure, call deletion, and contact, call and workspace export.
  * owner: also delete the workspace. The last owner cannot be removed or demoted.
  * Editors cannot grant themselves or others higher roles. The tests cover this.
* **Server-side enforcement.** Each workspace route depends on `ws_viewer`, `ws_editor`, `ws_admin` or `ws_owner` (`backend/app/auth/deps.py`). These resolve membership from the session user and the `workspace_id` in the URL path. A `workspace_id` supplied in a request body is ignored.
* **Isolation with 404.** If the user is not a member of the workspace, the API returns **404 Not Found** rather than 403, so a workspace's existence is not revealed. Every query filters on `workspace_id`. An entity ID that belongs to another workspace (agent, contact, call, consent, campaign, document, recording, live session) also returns 404. Knowledge search, FTS5 retrieval and live voice sessions are scoped to the workspace too.

## Local AI only

* The LLM, STT and TTS all run on the machine: Ollama, whisper.cpp and Piper or macOS `say`. **There is no cloud fallback.** If a local provider is down, the call fails with an explicit error.
* **Remote-model refusal.** Ollama can proxy some models to a remote host (for example `*:cloud` tags, or models with a `remote_host`). `OllamaProvider` marks these as not local and refuses them (`remote_model_refused`) unless `VA_ALLOW_REMOTE_LLM_MODELS=true`. The voice-session preflight checks this as well.
* The application itself never downloads LLMs. Only the setup script runs `ollama pull`, and only with `--with-ollama` / `--ollama-only` after an explicit confirmation.

## LLM tool sandbox and prompt injection

Callers, website visitors and knowledge-base documents are **untrusted input to the model**. The design limits what a manipulated model can do:

* The model can only *request* tools from a fixed, code-registered list (`default_registry()` in `engine/conversation/tools.py`): `end_call`, `request_callback`, `request_appointment`, `record_opt_out`, `search_knowledge`, `record_interest`, `capture_lead`.
* The registry refuses unknown tools and tools the agent has not been granted. It validates arguments against a strict schema: unknown keys are rejected, and types, maximum lengths and enums are checked.
* **No tool runs shell commands, fetches URLs, sends messages, or completes a booking, payment or refund.** Tool results tell the model that requests are pending human review.
* Tool side effects are confined to the call's own workspace through `DbToolHost`. In simulation mode they write nothing to real contacts.
* The worst a manipulated model can do is record a spurious callback request, a lead, an interest level, or an opt-out (which only makes contact *less* likely), or end the call. It cannot read other workspaces. It only ever sees the top knowledge snippets from its own workspace's knowledge base, which is the information the agent is meant to share.
* The system prompt (`engine/conversation/prompt.py`) contains guardrails: always admit being an AI, never claim a completed action, never invent prices, never ask for OTPs, passwords, card or bank details, and ignore requests to change the rules. **Prompt guardrails are best-effort and are not a security boundary.** The tool restrictions above are.
* Agent output is cleaned before speech (`speechify`: markdown, URLs and `<think>` blocks are removed). In the dashboard, transcripts are rendered as text by React, not as HTML.

## SSRF protection for provider URLs

Provider endpoints (Ollama, whisper-server, Piper, Asterisk ARI) can be edited in **Settings** by instance administrators. `validate_provider_url` in `backend/app/core/ssrf.py` runs on every `base_url` saved through `PUT /api/system/providers/{kind}`:

* the scheme must be `http` or `https`; embedded credentials, query strings and fragments are refused;
* the hostname is resolved, and **every** resolved address is checked;
* link-local addresses (including the cloud metadata address `169.254.169.254`), `0.0.0.0/8`, multicast, unspecified addresses and the known Alibaba and AWS IPv6 metadata addresses are **always** refused;
* unless `VA_ALLOW_REMOTE_PROVIDER_HOSTS=true`, the address must be loopback or private (RFC 1918 / ULA).

Limits: the check runs when the URL is **saved**. A hostname that later resolves to a different address is not re-checked on each request. To avoid relying on DNS, use IP literals for provider URLs. URLs set through `.env` are trusted as operator configuration and are not validated. The application never fetches user-supplied URLs in any other place.

## Input handling: uploads, CSV, search

* **Content sniffing, not extensions** (`backend/app/core/files.py`). Workspace logos must actually be PNG, JPEG or WebP. Knowledge uploads must be PDF or valid UTF-8 text. ZIP, Office and executable signatures (ZIP, MZ, ELF) are refused. CSV imports must sniff as text. File names are normalised (`safe_filename`).
* **Size limits.** `VA_MAX_UPLOAD_MB` (default 10 MB) for knowledge and CSV uploads, at most 50,000 CSV rows, and PDFs of at most 300 pages. Encrypted PDFs are refused. SDP offers are capped at 20,000 characters, and data-channel messages at 8 KB.
* **WebRTC offers** may contain only audio and data-channel media sections. Offers with video (or any other media type) are rejected before negotiation, so FFmpeg's video decoders are never reached (`check_offer` in `engine/streaming/webrtc.py`). Incoming Opus audio is still decoded by the FFmpeg build bundled with PyAV; see the scan results below.
* **RTP (telephony).** The RTP endpoint locks onto the first peer address and SSRC, and drops packets from other sources.
* **CSV formula injection.** On import, cells starting with `=`, `+`, `-`, `@`, tab, carriage return (or their full-width equivalents) are neutralised with a leading apostrophe. Plain phone numbers and negative numbers are recognised as data. On export (contacts, calls), every cell is escaped the same way (`backend/app/contacts/csv_safety.py`). The raw CSV upload is deleted after the import is committed.
* **Full-text search injection.** User text is tokenised and every token is quoted before it reaches SQLite FTS5 (`fts_query`), so FTS operators cannot be injected. All other queries use SQLAlchemy with bound parameters.
* **Validation.** Request bodies are Pydantic models with lengths, enums and patterns. Validation errors return 422 with a structured body.
* **Workspace import** validates the whole JSON document. It always creates a new workspace, never imports real-calling campaigns, and neutralises formula-like contact fields.

## Security headers and CSP

**API** (middleware in `backend/app/main.py`): `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Permissions-Policy: camera=(), geolocation=(), microphone=(self)`, `Cross-Origin-Opener-Policy: same-origin`, and `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'` (except on `/api/docs`). `Cache-Control: no-store` is set on `/api/*` responses. `Strict-Transport-Security` is sent when `VA_COOKIE_SECURE=true`. uvicorn runs with `--no-server-header`.

**Dashboard** (`apps/dashboard/next.config.ts`): `X-Powered-By` is disabled, plus this policy:

```text
default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline';
img-src 'self' data: blob:; font-src 'self' data:; media-src 'self' blob:; connect-src 'self';
frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'
```

along with `X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer` and `Permissions-Policy: microphone=(self), camera=(), geolocation=()`.

**`script-src` includes `'unsafe-inline'`** because Next.js injects inline bootstrap scripts, and the project does not use nonce-based CSP middleware. This weakens the CSP as an XSS mitigation. The main XSS defences are React's output escaping and the API's JSON-only responses. In development mode the CSP also allows `'unsafe-eval'` and `ws:`/`wss:` for hot reload.

## Data at rest

* **The SQLite database is not encrypted.** It contains contact personal data, transcripts and consent records. Protect the Mac with FileVault and a strong login password. `data/` and its subdirectories are created with mode `0700`.
* **Per-install secret:** `data/.secret_key`, 48 random bytes (URL-safe), created with mode `0600` and `O_EXCL`. `VA_SECRET_KEY` can supply it instead.
* **Provider credentials** (such as the ARI password) are encrypted with **Fernet**. The key is derived from the install secret with **HKDF-SHA256** (salt `voice-agent/secretbox`, info `provider-credentials`), and the ciphertext is stored in `provider_configs.secrets_encrypted`. A `password` key is always removed from plain provider configuration. The API only reports `has_secrets: true/false` and never returns a secret.
* **Passwords and session tokens** are stored only as Argon2id hashes and SHA-256 digests respectively.
* `.env` is created with mode `0600` and is git-ignored.

## Recordings

* Recording is **off by default** per workspace (`recording_enabled` in the compliance policy). When it is on, the recording disclosure is added to the agent's opening line.
* Recordings are written as `data/recordings/<workspace_id>/<call_id>.wav` with mode **`0600`**, and their SHA-256 is stored.
* Playback requires the **editor** role in the owning workspace. The resolved path must lie inside that workspace's recordings directory. **Every access is audited** (`recording.accessed`).
* Recordings are deleted by retention (default 90 days), call deletion and contact erasure.

## Backups

* A backup (`scripts/backup.sh` or **Settings → Backups**, instance admins only) contains the database, recordings and uploads. It is written with mode `0600`.
* **Optional encryption:** AES-256-GCM, with the key derived from a passphrase by **scrypt** (`n=2^15, r=8, p=1`) and a random 16-byte salt and 12-byte nonce. In the dashboard the passphrase must be at least 10 characters. **Unencrypted backups contain all personal data in plain form.**
* Restores are verified before staging: decryption, format and version, safe tar members (no absolute paths, no `..`, no links, only expected directories), per-file SHA-256 against the manifest, and `PRAGMA integrity_check`. They are applied only while the services are stopped. Backup creation, download and restore are audited.

## Logging and audit

* **Log redaction** (`backend/app/core/logging.py`): a logging filter on the root handler replaces values after `password`, `secret`, `token`, `api_key`, `authorization` and `cookie`, and replaces email addresses and phone-number patterns (E.164 and Indian 5+5 groupings) before anything is written. The patterns avoid matching IP addresses, ports and timestamps. Redaction is pattern-based, so it is best effort.
* **Audit log** (`audit_logs` table), written in the same transaction as the change it records. It covers sign-in events and failures, setup, password changes, provider settings, members, compliance policy changes, consent recorded or revoked, suppression changes, DND scrub imports, blocked calls, opt-outs, lead capture, recording access, call deletion, contact erasure, exports, imports, public-link changes, voice sessions, and backups. Workspace admins can read their workspace's audit log in the dashboard.

## Public "talk to us" links

* Disabled unless `VA_PUBLIC_CALLS_ENABLED=true` **and** the agent's link is enabled by an editor.
* Tokens are 192-bit random values. Only their SHA-256 is stored. Re-enabling rotates the token.
* Unauthenticated endpoints are rate limited per client IP: 60 info requests per minute and 5 sessions per 10 minutes. Sessions also count toward `VA_MAX_VOICE_SESSIONS`.
* The page tells the visitor they are speaking with an AI and whether the call is recorded.
* Unknown, disabled or rotated tokens return 404.

## Real telephony

Real PSTN calling is disabled unless `VA_REAL_TELEPHONY_ENABLED=true`, an Asterisk ARI provider is configured and enabled by an instance admin, and the workspace's PSTN attestations are recorded. The eligibility engine fails closed for every call. The ARI adapter validates destination numbers against `^\+?[0-9]{6,16}$` and its Stasis app name against `^[A-Za-z0-9_-]{1,64}$`. Securing the Asterisk server itself (ARI credentials, binding ARI to localhost, TLS for remote ARI, SIP trunk security, toll-fraud prevention) is the operator's responsibility. See [TELEPHONY.md](TELEPHONY.md).

## Known limitations

* No independent penetration test or audit.
* The dashboard CSP needs `'unsafe-inline'` for scripts (see above).
* No multi-factor authentication, and no account lockout beyond rate limiting.
* The database and transcripts are not encrypted at the application level.
* Rate limits are kept **in memory per process**. They reset when the process restarts and are not shared between processes. Per-IP limits depend on the client address the API sees. Behind the dashboard's proxy or your own reverse proxy, check that it reflects the real client (uvicorn trusts forwarding headers only from `127.0.0.1` by default).
* The SSRF check runs when a URL is saved, not on every request.
* Prompt-level guardrails can be bypassed by a determined caller. The tool sandbox limits the impact.
* `VA_ALLOWED_HOSTS` includes `testserver` by default. Set `VA_ALLOWED_HOSTS` explicitly to remove it.
* The OpenAPI docs (`/api/docs`) are served unless `VA_ENV=production`. They are only reachable from localhost by default.

## Hardening checklist for operators

1. Turn on FileVault and use a strong macOS account password.
2. Keep every service on `127.0.0.1`. Start Ollama with `OLLAMA_HOST=127.0.0.1` and run `./scripts/health-check.sh` to confirm.
3. If you expose the dashboard (for example for customer links), put it behind your own HTTPS reverse proxy, then set `VA_COOKIE_SECURE=true`, `VA_ALLOWED_HOSTS` and `VA_CORS_ORIGINS` to your hostname, and `VA_ENV=production`. On a Linux server, `scripts/install-server.sh` does this ([DEPLOYMENT.md](DEPLOYMENT.md)).
4. Leave `VA_ALLOW_REMOTE_LLM_MODELS`, `VA_ALLOW_REMOTE_PROVIDER_HOSTS`, `VA_PUBLIC_CALLS_ENABLED` and `VA_REAL_TELEPHONY_ENABLED` set to `false` unless you need them.
5. Give people the lowest workspace role that works for them. Keep the number of instance administrators small.
6. Use encrypted backups (`VA_BACKUP_PASSPHRASE`) and store the passphrase and `data/.secret_key` safely.
7. Keep recording off unless you need it, and review the retention periods.
8. Keep dependencies up to date (`./scripts/setup-mac.sh` after `git pull`).

## Security tests

The security-relevant tests run with `make test` (or `backend/.venv/bin/python -m pytest backend/tests tests`):

| File | What it covers |
|---|---|
| `tests/security/test_web_security.py` | Security headers; CORS only for the local dashboard; request validation (oversized and malformed bodies); SQL-injection payloads in filters are inert; XSS payloads are stored as data and returned as JSON; logo upload content validation; public-link lifecycle and rate limit; log redaction; SSRF validator allow and block cases |
| `tests/security/test_workspace_isolation.py` | Cross-workspace reads return 404; foreign IDs inside your own workspace return 404; a client-supplied `workspace_id` in a body is ignored; knowledge search is workspace-scoped; transcripts are not visible across workspaces |
| `backend/tests/test_auth.py` | Setup creates the owner and session, and runs only once; weak passwords rejected; login and logout; unknown user gets the same error; login rate limit; CSRF required for mutations; cross-origin mutation refused; untrusted Host rejected; unauthenticated access denied; deactivated user loses access; password change revokes other sessions; non-admins cannot manage users |
| `backend/tests/test_workspaces.py` | Role enforcement; editors cannot escalate; last owner protected; soft-deleted workspaces hidden; export/import round trip and rejection of malformed imports; compliance policy validation |
| `backend/tests/test_contacts_imports.py` | CSV upload validation; import workflow; export neutralises formulas; formula detection; erasure keeps suppression; phone normalisation |
| `backend/tests/test_knowledge_agents.py` | Knowledge upload rejects bad files; query sanitising; remote model refused; agent validation; test console uses dry-run tools |
| `backend/tests/test_compliance_campaigns.py` | Eligibility fails closed; DND and stale scrubs; consent expiry and frequency caps; PSTN campaigns refused by default; calling-window waits; restart recovery without duplicates; second scheduler refused |
| `backend/tests/test_calls_system.py` | Opt-out during a real call suppresses the number; simulations never write leads; lead capture; backup create, verify and restore |
| `backend/tests/test_demo_workspace.py` | The sample workspace imports and contains no price figures |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report privately through **GitHub Security Advisories**: on the repository page, open the **Security** tab and choose **Report a vulnerability**. Include:

* the affected version or commit;
* steps to reproduce, or a proof of concept;
* the impact you expect (for example "a viewer can modify contacts in another workspace");
* any suggested fix.

We aim to acknowledge reports within a few days, agree a fix and disclosure timeline with you, and credit you in the advisory if you wish. voice-agent is maintained by volunteers, so response times are best effort. Please give us reasonable time to fix an issue before disclosing it publicly, and do not access other people's data or place real calls while testing.

## Automated scan results (2026-11-25)

> **Scope and limits.** These are the results of automated static analysis, dependency auditing and secret scanning, triaged by hand. This is **not** an independent penetration test or a full manual code review. A clean scanner result means no *known pattern* matched, not that the code has no vulnerabilities. Scanners ran locally. The only network traffic was rule-pack downloads and advisory-database lookups (PyPI/OSV for pip-audit, the npm registry for `npm audit`, the Grype DB). semgrep ran with `--metrics=off` and no cloud login, and no project code was uploaded.

### Tools and versions

| Tool | Version | Target |
|---|---|---|
| bandit | 1.9.4 | `backend/app`, `engine/` (Python SAST) |
| semgrep (OSS, local rules) | 1.179.0 | `backend/app`, `engine/`, `apps/dashboard/src`, `scripts/` |
| pip-audit | 2.10.1 | backend venv (94 packages) and `uv export` of `backend/uv.lock` |
| npm audit | npm 10.9.3 / node v22.20.0 | `apps/dashboard` (771 packages: 305 prod, 428 dev) |
| gitleaks | 8.30.1 | working tree (no git history yet, `--no-git`) |
| grype | 0.120.1 | `backend/.venv`, `apps/dashboard` |

### Commands

```sh
# 1. bandit (all severities, then medium+)
cd backend && .venv/bin/bandit -r app ../engine -c pyproject.toml -f txt
cd backend && .venv/bin/bandit -r app ../engine -c pyproject.toml -f txt -ll

# 2. pip-audit (installed venv, then the lockfile export)
cd backend && .venv/bin/pip-audit
cd backend && uv export --format requirements-txt --no-hashes --frozen > req.txt && .venv/bin/pip-audit -r req.txt --no-deps --disable-pip

# 3. npm audit
cd apps/dashboard && npm audit --omit=dev
cd apps/dashboard && npm audit

# 4. semgrep (two passes, local execution, metrics off)
semgrep scan --config p/python --config p/typescript --config p/secrets --config p/javascript --config p/react \
  --metrics=off --exclude node_modules --exclude .venv --exclude .next --exclude .next-e2e \
  backend/app engine apps/dashboard/src scripts
semgrep scan --config p/owasp-top-ten --config p/fastapi --config p/nextjs --config p/jwt --config p/sql-injection \
  --config p/command-injection --config p/default --config p/cwe-top-25 --config p/xss --config p/insecure-transport \
  --metrics=off --exclude node_modules --exclude .venv --exclude .next --exclude .next-e2e \
  backend/app engine apps/dashboard/src scripts

# 5. gitleaks (default rules + temp config that allowlists node_modules, .venv, .tools, .next, .next-e2e,
#    data/models, .run, caches), then a separate pass over apps/dashboard/.next-e2e because it is not git-ignored
gitleaks detect --no-git --source . --config gitleaks.toml --redact -v --max-target-megabytes 5
gitleaks detect --no-git --source apps/dashboard/.next-e2e --redact --max-target-megabytes 20

# ignore-coverage check (nothing was staged or committed)
git check-ignore -v .env data/.secret_key data/database/voice_agent.db \
  data/models/whisper/ggml-base.en-q5_1.bin backend/.venv apps/dashboard/node_modules .tools logs .run
git status --porcelain --untracked-files=all

# 6. grype
grype dir:backend/.venv -o json      # ~2.5 min
grype dir:apps/dashboard -o json     # ~13 s
```

The `p/bash` semgrep pack returned HTTP 404 from the registry and was dropped. semgrep's bash parser partially failed on `scripts/setup-mac.sh:12` (a `case` arm), so that file was only partly analysed.

### Counts by severity

| Scanner | Critical | High | Medium | Low / Info | Notes |
|---|---|---|---|---|---|
| bandit | 0 | 0 | 0 | 23 | 9,818 LOC; `-ll` run: 0 issues |
| semgrep pass 1 (261 rules, 175 files) | – | 0 ERROR | 1 WARNING | 0 | false positive |
| semgrep pass 2 (489 rules, 177 files) | – | 0 ERROR | 1 WARNING | 0 | same finding |
| pip-audit (venv, 94 pkgs) | 0 | 0 | 0 | 0 | no known vulnerabilities |
| pip-audit (uv.lock export, 269 lines) | 0 | 0 | 0 | 0 | no known vulnerabilities |
| npm audit `--omit=dev` | 0 | 0 | 4 | 0 | a single advisory (minimatch) counted 4 times along one chain |
| npm audit (full) | 0 | 0 | 4 | 0 | same 4; no dev-only advisories |
| gitleaks (tree, excluding build/deps) | – | – | – | 0 leaks | 4.73 MB scanned |
| gitleaks (`apps/dashboard/.next-e2e`) | – | – | – | 5 hits | 4 real build secrets, 1 FP; see below |
| grype `dir:backend/.venv` | 0 | 30 | 91 | 4 | 125 unique CVEs, **all** CPE matches on FFmpeg 9.0.2 bundled in PyAV (`av` 19.0.2) `.dylibs`; see triage item 10 |
| grype `dir:apps/dashboard` | 0 | 0 | 1 | 0 | same minimatch advisory as npm audit |

### Triage

| # | Finding | Location | Verdict | Reasoning / mitigation |
|---|---|---|---|---|
| 1 | **`apps/dashboard/.next-e2e/` is not git-ignored** (389 MB, 627 files). It contains Next.js per-build secrets: `previewModeSigningKey` and `previewModeEncryptionKey` (`dev/server/preview-props.json:3-4`), the server-actions `encryptionKey` (`dev/server/server-reference-manifest.json:4`) and `encryption.key` (`dev/cache/.rscinfo:1`) | `.gitignore`, `apps/dashboard/.gitignore` | **Real (repo hygiene / secret exposure)** | Playwright starts the e2e server with `NEXT_DIST_DIR: ".next-e2e"` (`apps/dashboard/playwright.config.ts:56`), but both ignore files cover only `.next/`. A first `git add .` would commit build output and build-scoped keys. Impact is limited because these keys belong to a throwaway e2e dev build and are regenerated per build. Still, they must not enter history. **Fix:** add `.next-e2e/` (or `.next*/`) to the root `.gitignore`. |
| 2 | RTP media accepts packets from any source after latching | `engine/providers/telephony/rtp.py:117-122` | **Real, low** (manual review, not scanner) | The first packet sets `self.remote`. Later packets from *any* address are still decoded and fed to the audio handler, and `payload_type` is overwritten on each packet. While `rtp_bind_host` keeps its default of `127.0.0.1` (`asterisk_ari.py:52`), only local processes can reach the socket. If it is bound to a LAN interface, a host that can guess the port could inject audio into a live call or win the first-packet race. **Fix:** after latching, drop datagrams whose `addr != self.remote` (optionally also pin the SSRC), and do not let a packet change `payload_type`. Document that the RTP bind host must stay on loopback or a trusted network. |
| 3 | B311 `random.randint` for RTP seq / timestamp / SSRC | `engine/providers/telephony/rtp.py:92-94` | False positive | RFC 3550 asks for *random* initial values for collision avoidance, not unpredictability. The stream is plain RTP with no SRTP, so a CSPRNG would add no protection. If hardening anyway, `secrets.randbits` is a drop-in replacement. |
| 4 | B311 `random.Random` in the call simulator | `engine/providers/telephony/simulator.py:192` | False positive | Deterministic, seeded persona selection for simulated calls. It is intentionally reproducible and has no security role. |
| 5 | B101 `assert` used (19 sites) | `engine/audio/pcm.py:93`; `backend/app/calls/pstn.py:61,70`; `calls/service.py:291,315,324`; `core/errors.py:35`; `database/session.py:43,50`; `scheduler/worker.py:298,301,331`; `users/router.py:46,56`; `workspaces/router.py:112,126,153,255`; `workspaces/transfer.py:104` | Not a vulnerability (code-quality note) | Every site narrows a type (`x is not None`) after a lookup that was already authorised and scoped by a dependency (`current_user`, `ws_admin`, `ws_owner`) or a row the code itself created. No assert guards authentication, authorisation or input validation. Under `python -O` a missing row would raise `AttributeError` (HTTP 500) instead of `AssertionError` (also 500), with the same outcome. Optional: replace with explicit `if x is None: raise not_found(...)` for clearer errors. |
| 6 | semgrep `insecure-file-permissions` (`os.chmod(d, 0o700)`) | `backend/app/core/config.py:100` | False positive | `0o700` on a *directory* is owner-only. It is more restrictive than the rule's suggested `0o644`. This is the intended hardening of the data directories. |
| 7 | gitleaks `generic-api-key` in a dev chunk | `apps/dashboard/.next-e2e/dev/static/chunks/src_0h5oev3pip7l5._.js:1615` | False positive | It is a React Fast Refresh hook signature (`_s2(useWsApi, "<hash>")`), not a credential. It disappears once item 1 is fixed. |
| 8 | npm: minimatch DoS via globparts amplification, GHSA-g3hv-75wg-m249 (moderate) | `shadcn@4.23.0 → ts-morph@26.0.0 → @ts-morph/common@0.27.0 → minimatch@10.2.6` | Accepted risk / not reachable | Affected `>=7.0.0 <11.0.1`; **fixed in minimatch 11.0.1** (ts-morph ≥ 27.0.3). `shadcn` is a production dependency only because `src/app/globals.css:3` imports `shadcn/tailwind.css`. The vulnerable code sits in the shadcn *CLI* (ts-morph), which never runs in the served app and never handles untrusted glob patterns. npm's suggested fix (`shadcn@1.0.0`) is a breaking downgrade; do **not** run `npm audit fix --force`. Optional: add `"overrides": {"@ts-morph/common": {"minimatch": "^11.0.1"}}` and re-test `npx shadcn`, or wait for shadcn to move to ts-morph ≥ 27.0.3. |
| 9 | `apps/dashboard/AGENTS.md` would be committed | `apps/dashboard/AGENTS.md` | Judgment call (not a security issue) | Generated and re-added by `next dev` (Next.js agent rules). It holds no secrets. Commit it to keep the tree clean, or ignore it. Either is fine. |
| 10 | grype: 125 FFmpeg CVEs (30 High, 91 Medium, 4 Low) in the FFmpeg 9.0.2 libraries bundled in the PyAV wheel | `backend/.venv/.../site-packages/av/.dylibs/libavcodec.63.1.102.dylib` etc.; used by `engine/streaming/webrtc.py:24,143`, `engine/audio/pcm.py:73-87`, and aiortc's Opus codec (`aiortc/codecs/opus.py:4`) | **Real exposure, partially reachable; no fixed version available** | `av` 19.0.2 is the newest release on PyPI, and grype reports no fix state (NVD CPE match "through 9.0.2"). Most CVEs are in demuxers and codecs this app never invokes (RTSP, IMF, GIF/JPEG/WebP, Blu-ray/DVD PCM, VAAPI/VDPAU/V4L2, LCEVC). The app does decode **remote Opus audio through libavcodec** (aiortc) from authenticated dashboard users, and from anyone with a public talk link when `VA_PUBLIC_CALLS_ENABLED=true` (off by default; `backend/app/audio/router.py:80-98`). `WebRTCTransport.accept_offer` (`engine/streaming/webrtc.py:97-125`) does not reject a `m=video` section, so a peer could negotiate H.264 and have aiortc decode it with libavcodec (`aiortc/codecs/h264.py`), which several of the listed H.264/CBS CVEs target. **Mitigation:** reject offers that contain a non-audio m-line (or stop non-audio transceivers after `setRemoteDescription`) so only Opus is decoded. Keep public links disabled unless needed. Upgrade `av`/`aiortc` as soon as a wheel bundles a fixed FFmpeg, and re-run grype. |

Additional manual spot checks that found **no** issue: subprocess calls (`engine/providers/tts/macos_say.py:44,72`, `engine/providers/stt/whisper_cpp.py:120`) use `create_subprocess_exec` with argv lists and no shell. The voice name is allow-listed (`_SAFE_VOICE`, `macos_say.py:23`). Backup restore (`backend/app/system/backup.py:132-161`) rejects absolute, `..`, link and unexpected entries and extracts with `filter="data"`. No `dangerouslySetInnerHTML`, `eval` or `new Function` in `apps/dashboard/src`. No f-string SQL in the backend.

Informational hardening notes for `backup.py` (admin-only path):
- `MAX_ARCHIVE_BYTES` (8 GiB, `backup.py:42`) limits the *compressed* size only, so consider capping the total uncompressed member size.
- Manifest `files[].path` values are joined to the target without a containment check (`backup.py:162-163`). This is read-only (sha256 comparison) and low impact, but checking that `p.resolve().is_relative_to(target)` is cheap.

### Dependency advisories

| Ecosystem | Package | Installed | Advisory | Severity | Fixed version | Path / reachability |
|---|---|---|---|---|---|---|
| npm | minimatch | 10.2.6 | GHSA-g3hv-75wg-m249 | moderate | 11.0.1 | via shadcn CLI → ts-morph 26.0.0 → @ts-morph/common 0.27.0; not used at runtime |
| npm | @ts-morph/common, ts-morph, shadcn | 0.27.0, 26.0.0, 4.23.0 | (inherit the advisory above) | moderate | ts-morph ≥ 27.0.3 | same chain |
| PyPI | – | – | none found (94 installed, 269-line lock export) | – | – | – |
| PyPI (bundled binary) | ffmpeg (inside `av` wheel) | 9.0.2 (`av` 19.0.2) | 125 CVEs, e.g. CVE-2026-107696, CVE-2026-125227, CVE-2026-125269 | 30 High / 91 Medium / 4 Low | none published (`av` 19.0.2 is latest) | via aiortc Opus decode for browser/public WebRTC peers; H.264 only if a video m-line is accepted (triage item 10) |

### Secrets and git-ignore coverage

- `git check-ignore` confirms each of these is ignored: `.env` (`.gitignore:2`), `data/.secret_key` (`.gitignore:9`, `data/*`), `data/database/voice_agent.db` (`.gitignore:22`, `*.db`; the `-wal`/`-shm` files are covered by lines 23-24), `data/models/whisper/ggml-base.en-q5_1.bin` (`.gitignore:20`), `backend/.venv` (`:40`), `apps/dashboard/node_modules` (`apps/dashboard/.gitignore:4`), `.tools` (`:41`), `logs` (`:35`), `.run` (`:34`).
- The local `.env` is byte-identical to `.env.example` and contains only non-secret settings. The session signing secret lives in `data/.secret_key` (mode 0600, ignored). A search for that key's value across every file that `git status` would add found 0 occurrences.
- `test-results/`, `playwright-report/`, `*.tsbuildinfo`, `next-env.d.ts`, `.next/`, `__pycache__/`, `.pytest_cache/` and `.ruff_cache/` are all ignored.
- **Would be wrongly committed:** everything under `apps/dashboard/.next-e2e/` (627 files; see triage item 1). Nothing else inappropriate showed up among the remaining 240 would-be-added paths (source, tests, configs, lockfiles, `.gitkeep` files, the demo workspace with `example.com` / `+91 99999 000xx` sample contacts, and docs).
