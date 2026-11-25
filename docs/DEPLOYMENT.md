# Deploying to a public server

This guide runs voice-agent all the time on a Linux server, so anyone with the link can use it. It restarts by itself after a crash or a reboot. For a local install on a Mac, see [INSTALLATION.md](INSTALLATION.md).

## Why a server and not a tunnel from your Mac

Browser calls use WebRTC with **no STUN or TURN servers** ([SECURITY.md](SECURITY.md)), so call audio has to reach the machine directly over UDP. Tunnels such as ngrok only forward HTTP, so other people could open the dashboard but would hear no audio. A server with a **public IP on its network interface** fixes this. Hetzner Cloud and DigitalOcean droplets have one. AWS EC2 and Google Cloud put servers behind NAT, which breaks this setup unless you add a TURN server.

## What you need

| Item | Notes |
|---|---|
| **Ubuntu 24.04 server** with a public IPv4 | 8 vCPU and 16 GB RAM is a comfortable size. With no GPU, the language model runs on the CPU, so replies are slower than on an Apple Silicon Mac. |
| **A domain name** | Create a DNS `A` record (for example `voice.example.com`) that points at the server's IP **before** you install, so Caddy can get the HTTPS certificate. Browsers only allow the microphone over HTTPS. |
| **SSH access** as a normal user with `sudo` | Don't run the setup as root. |

## 1. Install the prerequisites (once)

Run these on the server:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs
```

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

```bash
ollama pull qwen3:4b-instruct-2507-q4_K_M
```

Open a new shell afterwards so `uv` is on your `PATH`. Install Node system-wide as shown, not with nvm, because the dashboard service runs `node` from the system path. The Ollama installer creates its own `ollama` service, which listens on `127.0.0.1` only.

## 2. Get the code and run the setup

```bash
git clone <repository url> voice-agent && cd voice-agent
```

```bash
./scripts/setup-linux.sh --models --yes
```

`setup-linux.sh` installs the missing apt packages (`ffmpeg`, build tools, `caddy`, `ufw`, `lsof`) and builds `whisper-server` from whisper.cpp v1.7.6 into `.tools/whisper.cpp`. It then runs the same steps as the Mac setup ([INSTALLATION.md, step 2](INSTALLATION.md#2-run-the-setup-script)): environments, Piper, dashboard dependencies, database and speech models. Last, it makes the production build of the dashboard. You can run it again safely.

## 3. Install the always-on services

```bash
sudo ./scripts/install-server.sh voice.example.com
```

This:

1. Sets the production values in `.env`: `VA_ENV=production`, `VA_COOKIE_SECURE=true`, and `VA_ALLOWED_HOSTS` / `VA_CORS_ORIGINS` for your domain. Your other lines are kept.
2. Writes and starts five systemd services, each with `Restart=always`, running as your user and starting on boot:
   `voice-agent-whisper`, `voice-agent-piper`, `voice-agent-api`, `voice-agent-scheduler`, `voice-agent-web`.
   Every service still listens on `127.0.0.1` only.
3. Writes `/etc/caddy/Caddyfile`, keeping the original as `Caddyfile.before-voice-agent`. Caddy serves `https://your.domain`, gets and renews the certificate itself, and sends `/api/*` to the API and everything else to the dashboard.
4. Turns on the `ufw` firewall with only these open: your SSH port, 80/tcp, 443/tcp+udp, and the kernel's ephemeral UDP range (usually 32768–60999). aiortc gives call audio a random port from that range and has no setting to narrow it. **If your cloud provider has its own firewall, open the same ports there too.**

Run it again after changing ports or the domain.

## 4. First use

1. Open `https://voice.example.com` and create the owner account. Do this straight away, because until you do, anyone who opens the site can create it.
2. To let **anyone talk to an agent without an account**, set `VA_PUBLIC_CALLS_ENABLED=true` in `.env`, run `sudo systemctl restart voice-agent-api`, then turn on the public link for one agent. You get a `/talk/<token>` page to share. Each IP can start 5 sessions per 10 minutes.
3. To give people dashboard access, invite them as users with the lowest role that fits. Don't share the owner login.

## Running it

| Task | Command |
|---|---|
| Status of everything | `systemctl status 'voice-agent-*' ollama caddy` |
| Follow the API log | `journalctl -u voice-agent-api -f` |
| Check every component | `./scripts/health-check.sh` |
| Restart after changing `.env` | `sudo systemctl restart voice-agent-api voice-agent-scheduler` |
| Update to a new version | `git pull && ./scripts/setup-linux.sh --models --yes && sudo systemctl restart 'voice-agent-*'` |
| Back up | `./scripts/backup.sh` (copy the archive off the server) |

Don't use `start.sh` or `stop.sh` on the server, because systemd runs the services. To apply a staged backup restore, stop the services first (`sudo systemctl stop 'voice-agent-*'`). Then, from `backend/`, run `PYTHONPATH=$PWD:$PWD/.. .venv/bin/python -m app.system.backup apply-pending` and start the services again.

## Capacity

The `.env` defaults (`VA_AI_CONCURRENCY=1`, `VA_MAX_VOICE_SESSIONS=2`) allow two calls at a time, and only one model reply is generated at a time. Raise them only if the server keeps response times acceptable. The call page shows per-turn timings.
