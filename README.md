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

## Current deployment (2026-11-01)

Jitsi is **self-hosted on one Oracle Cloud Linux VM**. Nothing is deployed to a
managed video service, and nothing in this repo is imported by the web app —
Vercel/Netlify host the Next.js frontend, Oracle hosts the rooms.

| | |
| --- | --- |
| Provider | Oracle Cloud Infrastructure (OCI), Always Free account |
| Region | UK South (London), `uk-london-1`, availability domain AD-1 — roughly 60–80 ms from Egypt |
| Instance | `ana-quran-instance-20261101`, shape `VM.Standard.A1.Flex` (Ampere, arm64) |
| Size | **4 OCPU / 24 GB** (23 GiB usable in the OS). This is the *entire* Always Free Ampere allowance for the tenancy — no second A1 instance will ever fit |
| OS | Ubuntu 24.04.5 LTS |
| Public IPv4 | `143.47.237.128` — 1:1 NAT, so `JVB_ADVERTISE_IPS` must be this public address, never `10.0.0.30` |
| Private IP | `10.0.0.30` on VNIC `ana-quran-vnic` |
| Hostname | `meet.143-47-237-128.sslip.io` — temporary, no domain is owned yet |
| Networking | VCN `ana-quran-vc` (10.0.0.0/16), public subnet, internet gateway, NSG `ig-quick-action-NSG` |
| Firewall | **Three layers**: OCI security list + NSG + iptables baked into the Ubuntu image. A port is open only if all applicable layers allow it |
| TLS | Caddy 2.11 on the host, Let's Encrypt via HTTP-01, auto-renewing (cert valid to 2027-01-30) |
| SSH | `ssh -i ~/.ssh/oci-anaquran.key ubuntu@143.47.237.128` (deploy user is **uid 1001**) |
| Code | `~/ana-quran-infra` on the VM, clone of `khaled9912/ana-quran-infra`; compose project `ana-quran-jitsi` |
| Containers | `ana-quran-jitsi-{web,prosody,jicofo,jvb}-1`, policy `unless-stopped` |
| Edge config | `/etc/caddy/Caddyfile` — a **host** file, not managed by the repo |
| Secrets | `~/ana-quran-infra/jitsi/.env` (generated passwords). Back this up; it is gitignored |

Verified on 2026-11-01 from outside the network:

| Check | Expected |
| --- | --- |
| `https://meet.143-47-237-128.sslip.io/` | 200 |
| `/external_api.js`, `/config.js`, `/http-bind` | 200 |
| Inbound TCP 80 / 443 | reachable |
| Inbound UDP 10000 | reachable (proven with `tcpdump -i any udp port 10000` while sending test packets) |

`https://143.47.237.128/` (raw IP) fails on purpose — Caddy only answers
requests whose SNI matches the configured hostname.

### OCI specifics that cost hours if forgotten

- **Both firewall layers.** The security list and the attached NSG must each
  allow the port; adding rules to only one changes nothing. The console had two
  NSGs with the same name — the right one is the one whose *VNICs* tab lists
  `ana-quran-vnic`.
- **UDP, not TCP, on 10000.** The security list is easy to fill in wrong; a
  `10000/tcp` row looks correct and silently breaks relay media.
- **Editing shape** requires the instance to be Stopped; "Edit shape" lives in
  the **Shape configuration** panel on the Details tab, not in the Actions
  dropdown.
- **Reserved IP.** Assign and reserve the public IP before relying on it — the
  hostname, `PUBLIC_URL` and `JVB_ADVERTISE_IPS` all embed it.
- **Image firewall.** Oracle's Ubuntu image ships iptables rules that REJECT
  everything but SSH; see the `iptables -I INPUT 1 …` block below.

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

Target: Ubuntu 22.04/24.04, **2–4 vCPU / 4–8 GB** while sessions are one-to-one
(they run peer-to-peer and the server only relays signalling). The live box is
deliberately oversized at 4 OCPU / 24 GB because transcription will join rooms
as a third participant, which forces relay. Any provider below works; Oracle is
the current one only because it is free.

### Oracle Cloud (OCI)

OCI filters traffic twice — in the VCN *and* in an iptables ruleset baked into
the Ubuntu image that rejects everything except SSH. Opening only one of the two
is the usual reason a room loads but calls connect with no audio/video.

- **Shape**: Ampere `VM.Standard.A1.Flex` (arm64; the always-free allowance is
  up to 4 OCPU / 24 GB) or `VM.Standard.E4.Flex` (x86). Not the 1 GB micro
  shape — the JVMs need 4 GB minimum. The pinned `stable-11248-2` images
  publish `linux/arm64`, so Ampere works without emulation.
- **Image**: Canonical Ubuntu 22.04/24.04.
- **Public IP**: assign one and reserve it. It is 1:1 NAT, so
  `JVB_ADVERTISE_IPS` takes the **public** IPv4, never the `10.x` address on
  the VNIC.
- **VCN → Security List** (and the NSG too, if the VNIC has one): ingress
  TCP 80, TCP 443 and UDP 10000 from `0.0.0.0/0`; SSH 22 from your IP only.

Then add the same three rules on the instance, above the image's REJECT rule,
and persist them:

```bash
sudo iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT 1 -p udp --dport 10000 -j ACCEPT
sudo netfilter-persistent save   # apt install iptables-persistent if missing
sudo iptables -L INPUT -n --line-numbers | head
```

Ports 80/443 must be accepted in `INPUT` because Caddy runs as a host process;
UDP 10000 is forwarded by Docker but the VCN rule is still required.

The image's `ubuntu` user is **uid 1001**, while the Jitsi containers run as
**uid 1000**. On a fresh clone the web and prosody containers restart-loop with
`directory '/storage' is not writable by the container user (uid 1000)`;
`deploy.sh` now chowns `config/` to 1000:1000 on Linux to prevent that.

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

## Moving to another provider

The stack is portable: one Linux VM, Docker Compose, and a Caddy binary. No
database, no uploads, no proprietary services. Budget a couple of hours.

### What actually has to move

| Item | Where it lives | Notes |
| --- | --- | --- |
| The repo | `~/ana-quran-infra` on the VM | `git clone` on the new box; nothing is stored on the server that is not in git |
| `.env` | `jitsi/.env` | **Copy it.** It holds the generated XMPP/JVB passwords; regenerating means every container restarts with new secrets (harmless, but the file is the only record) |
| `Caddyfile` | `/etc/caddy/Caddyfile` | Copy and change the hostname |
| `config/` state | `jitsi/config/` | Optional. It is regenerated at boot from `.env`; skip it unless you have customised a XMPP user by hand |
| DNS | Your registrar | The only external dependency that changes |

Nothing else. Certificates are re-issued automatically; there is no data to
dump.

### Order of operations (avoids downtime)

1. **Lower the DNS TTL** for the meet hostname to 60 s and wait for the old TTL
   to expire (a day is safest).
2. **Provision** the new VM: Ubuntu 22.04/24.04, 2+ vCPU, 4+ GB RAM, a static
   public IPv4, inbound 22/80/443 TCP and 10000 UDP.
3. **Install** Docker and Caddy, clone the repo, copy `.env`, set
   `PUBLIC_URL` and `JVB_ADVERTISE_IPS` to the *new* address, run `./deploy.sh`.
4. **Check readiness before switching traffic** — `curl http://127.0.0.1:8000/`
   on the new box must return 200, and every container must be `Up`.
5. **Switch the A record** to the new IP, then `systemctl reload caddy` on the
   old and new hosts. Caddy re-issues the certificate within a minute.
6. **Verify** the four public checks from the table above, then run one real
   two-browser call.
7. **Keep the old VM** up for a few days as rollback, then delete it.

### What breaks on a move, and why

| Symptom | Cause |
| --- | --- |
| Certificate never issues | DNS not pointing at the new IP, or 80/tcp blocked at the provider |
| Room loads, but no audio/video | `JVB_ADVERTISE_IPS` still the old address, or 10000/udp closed |
| Browser shows "Failed to load external_api.js" | The frontend still has the old `NEXT_PUBLIC_JITSI_DOMAIN` — it is baked in at build time, so redeploy |
| Everything works on the VM, nothing works remotely | The provider's edge firewall (security group / cloud firewall) — a common trap on AWS Lightsail, Hetzner Cloud and GCP, not just OCI |
| Containers restart-loop with `'/storage' is not writable` | Deploy user is not uid 1000; `deploy.sh` chowns `config/` on Linux, check it ran |

Provider notes: the pinned `stable-11248-2` images publish both `linux/amd64`
and `linux/arm64`, so Hetzner (x86 or Ampere), DigitalOcean, Vultr, Lightsail
and Contabo all work unchanged. What differs is only the edge firewall UI and
whether a static IP is free (Hetzner: yes; Lightsail: yes).

## Operations

### CI deploys (GitHub Actions)

`.github/workflows/deploy-jitsi.yml` deploys on every push to `master` that
touches `jitsi/**` (or on manual dispatch). It does three things:

1. SSHes to the VM with a restricted key — no command, because the server-side
   `authorized_keys` entry forces `/home/ubuntu/deploy-jitsi.sh`.
2. That script runs `git fetch` + `git merge --ff-only origin/master`, then
   `./deploy.sh` (idempotent: unchanged containers are left running).
3. Polls `https://<host>/external_api.js` from the runner and fails the job if
   it does not return 200.

Setup, once per repo:

- **Secret** `JITSI_DEPLOY_KEY` = the private half of the deploy keypair
  (`~/.ssh/gh-jitsi-deploy` locally). Settings → Secrets and variables →
  Actions → New repository secret.
- **Server**: `/home/ubuntu/deploy-jitsi.sh` (mode 755) and one line in
  `~/.ssh/authorized_keys`. The script is deliberately *not* in the repo: a
  compromised repository should not be able to rewrite what a key can execute.

  ```
  command="/home/ubuntu/deploy-jitsi.sh",restrict ssh-ed25519 AAAA… github-actions-jitsi-deploy
  ```

  `restrict` disables shell, pty and forwarding, so a leaked key can only
  trigger a deploy.

Rotating the key: `ssh-keygen -t ed25519 -C github-actions-jitsi-deploy -f ~/.ssh/gh-jitsi-deploy`,
replace the matching `authorized_keys` line, update the secret.

**Caveats.** There is no "is a lesson running?" check — a push touching
`jitsi/**` reconciles containers within seconds. That is fine for config-only
changes (no restart) but a compose/image change will drop active calls. Docs
changes under `README`, `FE/` or the API are ignored by the `paths` filter. If
you want a human gate, delete the `push` trigger and keep only
`workflow_dispatch`, or attach a GitHub Environment with required reviewers.

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
