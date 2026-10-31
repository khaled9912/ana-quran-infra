# Ana Quran — infrastructure

Self-hosted video infrastructure for Ana Quran lessons. Kept out of the web app
repo so the Next.js codebase stays deployable to Vercel/Netlify and this stack
stays deployable to a Linux VPS.

The web app is a plain client of Jitsi: it loads `/external_api.js` from the
domain in `NEXT_PUBLIC_JITSI_DOMAIN` and embeds the room in an iframe. Nothing
here is imported by the app.

## What runs

A vendored copy of [docker-jitsi-meet](https://github.com/jitsi/docker-jitsi-meet)
at **`stable-11248-2`**, plus a small deployment overlay:

| File | Purpose |
| --- | --- |
| `jitsi/.env.example` | Non-secret configuration (public URL, ports, media IP, auth flags). `.env` is generated from it. |
| `jitsi/deploy.sh` | Validates `.env`, generates the component passwords, starts/stops the stack. |
| `jitsi/Caddyfile` | Production edge: TLS + WebSocket proxy in front of the web container. |
| `jitsi/config/web/custom-config.js` | Forces the room UI to English (otherwise it follows the viewer's browser language and Arabic browsers get an RTL room). |
| `jitsi/config/web/custom-interface_config.js` | Removes the Jitsi watermark, brand mark and "powered by" footer. |

```
jitsi/
├── .env.example
├── Caddyfile
├── deploy.sh
├── config/
│   └── web/                     # overlay config the web image copies at boot
│       ├── custom-config.js
│       └── custom-interface_config.js
├── docker-compose.yml           # upstream, two local changes (see below)
├── web/ prosody/ jicofo/ jvb/   # upstream images + entrypoints
└── ...                          # rest of docker-jitsi-meet
```

Committed: the vendored source, the overlay, and this doc.
Not committed: `.env`, container state (`config/storage`, `config/prosody`,
`config/jicofo`, `config/jvb`), certificates and keys.

**Local changes to the upstream tree** — all three fix footguns that only bite
on a real server or on a fresh clone:

1. Every `${CONFIG}` mount is now `${CONFIG:?CONFIG is not set …}`, so a missing
   `.env` fails with a clear message instead of mounting the host's `/web`,
   `/jvb`, `/prosody/config`.
2. `web` publishes `8000`/`8443` on **127.0.0.1** by default, so they are never
   reachable from the internet — Caddy owns 443 in production, and locally the
   browser only needs `localhost`.
3. `jitsi/.gitignore` re-includes `.env.example`, which upstream's `.env*` rule
   would otherwise hide.

## Local development (macOS)

Prerequisites: Docker Desktop, `openssl`, and [mkcert](https://github.com/FiloSottile/mkcert).

```bash
cd jitsi
cp .env.example .env
```

Edit `.env` for local use:

```
PUBLIC_URL=https://localhost:8443
JVB_ADVERTISE_IPS=127.0.0.1
```

Plain HTTP is not an option locally: the Jitsi external API always loads
`https://<domain>/external_api.js`, so the container must speak TLS the browser
trusts. Generate a certificate for `localhost` with mkcert:

```bash
mkcert -install                     # one-time, asks for your keychain password
mkdir -p config/storage/web/keys
mkcert -cert-file config/storage/web/keys/cert.crt \
       -key-file  config/storage/web/keys/cert.key \
       localhost 127.0.0.1 ::1
./deploy.sh
```

Then point the app at it — `FE/.env.local`:

```
NEXT_PUBLIC_JITSI_DOMAIN=localhost:8443
```

Verify:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost:8443/            # 200
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost:8443/external_api.js
```

The certificate is local-only: it is gitignored, and production never uses it.

## Production VPS

Target: Ubuntu 22.04/24.04, **4 vCPU / 8 GB** if several group lessons can
overlap; 2 vCPU / 4 GB is enough while most sessions are one-to-one (those run
peer-to-peer and the server only relays signalling).

### 1. Network

| Port | Protocol | Why |
| --- | --- | --- |
| 80 | TCP | Let's Encrypt HTTP challenge + redirect to HTTPS |
| 443 | TCP | Jitsi web behind Caddy |
| 10000 | UDP | JVB media relay (rooms with 3+ participants) |
| 22 | TCP | SSH — restrict to your IP if possible |

Point a DNS `A` record (e.g. `meet.yourdomain.com`) at the VPS before starting,
otherwise Caddy cannot issue the certificate. `8000` and `8443` stay on
loopback; do not open them.

### 2. Install

```bash
# Docker Engine + compose plugin
curl -fsSL https://get.docker.com | sudo sh

# Caddy (TLS + reverse proxy)
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy

git clone https://github.com/khaled9912/ana-quran-infra.git
cd ana-quran-infra/jitsi
cp .env.example .env
$EDITOR .env          # PUBLIC_URL=https://meet.yourdomain.com
                      # JVB_ADVERTISE_IPS=<public IPv4>
./deploy.sh           # validates .env, generates passwords, starts the stack
```

Then install the edge proxy:

```bash
sudo cp Caddyfile /etc/caddy/Caddyfile
sudo $EDITOR /etc/caddy/Caddyfile     # replace meet.example.com
sudo systemctl reload caddy
```

### 3. Verify

```bash
curl -o /dev/null -w '%{http_code}\n' https://meet.yourdomain.com/          # 200
curl -o /dev/null -w '%{http_code}\n' https://meet.yourdomain.com/external_api.js
docker ps --format '{{.Names}}\t{{.Status}}'                                # web, prosody, jicofo, jvb
```

A real call needs two browsers; open the same room URL in both and confirm
audio/video both ways, then check `./deploy.sh logs jvb` shows the bridge
registered.

### 4. Point the app at it

`NEXT_PUBLIC_JITSI_DOMAIN=meet.yourdomain.com` (domain only, no scheme, no
trailing slash) in the frontend host's environment — Production **and** Preview
— then redeploy; `NEXT_PUBLIC_*` values are inlined at build time.

No backend or API changes are needed, and the Jitsi domain does not belong in
the API's `AllowedOrigins` (that list is about browser calls to the API).

## Operations

```bash
./deploy.sh               # start / recreate after an .env change
./deploy.sh restart web   # re-apply config/web/*.js after editing the overlay
./deploy.sh down          # stop everything (state under config/ survives)
./deploy.sh logs jvb      # follow a container's logs
```

- **Updating Jitsi**: the source is vendored, so there is no `git pull`. Fetch
  the new upstream tag into a scratch directory and diff it against `jitsi/`
  (expect only the overlay files and the two compose changes above), copy the
  new tree in, then `./deploy.sh`. Re-check `custom-interface_config.js` against
  the release notes — branding settings occasionally move.
- **Backups**: nothing here is user data. Room history, recordings and class
  reports live in the app and its database.
- **Restarting the box** is safe; containers use `unless-stopped`.

## Capacity notes

- Two people in a room negotiate a direct peer-to-peer connection; the server
  only handles signalling, so 1:1 lessons barely touch the VPS.
- Three or more participants are relayed by the JVB at roughly
  `participants × 2.5 Mbps` in, `participants × 2.5 Mbps` out for 720p (~0.5 Mbps
  at 360p). Vendor benchmarks show a 4 vCPU / 8 GB host relaying around 45
  simultaneous 720p senders; plan bandwidth before CPU.
- Meetings have **no duration cap** — that was a meet.jit.si (the free public
  service) limit, not a Jitsi one.

## Hardening backlog

Not needed to launch, listed so nothing is forgotten:

1. **Server-side join control.** The app hides the join button until the teacher
   arrives, but the URL itself works for anyone who has it. Enforcing
   teacher-first for real needs `ENABLE_AUTH=1` + a JWT token endpoint, with the
   room name embeddable in the token (Jitsi's own JWT is not room-scoped, so a
   per-room room-name check is still required).
2. **TURN on 443/TCP** for networks that block UDP entirely (some schools and
   mobile carriers). Needs a second public IP because Caddy already owns 443.
3. **Rotating room names** per lesson (e.g. a suffix issued by the API) so an old
   link cannot be replayed later.
