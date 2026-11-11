# Ana Quran — infrastructure

Self-hosted video infrastructure for Ana Quran lessons. Kept out of the web app
repo so the Next.js codebase stays deployable to Vercel/Netlify and this stack
stays deployable to a Linux VPS.

The web app is a plain client of Jitsi: it loads `/external_api.js` from the
domain in `NEXT_PUBLIC_JITSI_DOMAIN` and embeds the room in an iframe. Nothing
here is imported by the app.

**Product context:** [`../docs/business-requirements/06-live-lessons.md`](../docs/business-requirements/06-live-lessons.md) explains the room rules, admin support joins, the lesson pen, and the access limitations. [`../docs/business-requirements/07-transcripts-and-support-review.md`](../docs/business-requirements/07-transcripts-and-support-review.md) explains why transcript capture belongs in this deployment.

Business constraints that must survive infrastructure changes:

- The room is **unlisted, not access-controlled**. Do not claim otherwise in the product; JWT/lobby enforcement is not built yet.
- A third participant (admin "Academy support") joins confirmed lessons; 1:1 calls are peer-to-peer, but 3+ participants use the JVB relay on UDP 10000.
- **Never enable the public `/transcripts` static route.** Transcript text must go to the API (`POST /api/lessons/{id}/transcript`), not to a guessable public folder. `jitsi/config/web/nginx-custom/transcript-privacy.conf` answers `404` for `/transcripts` and everything under it (verified locally with `nginx -t` and curl; not yet deployed).
- The room UI is English-only and unbranded by request; keep it that way.
- The camera backdrop is off by default: it is one of the lesson-room feature flags the API serves from `GET /api/config/lesson-room` (`LessonRoom__CameraBackground` on the app server), and both clients disable virtual backgrounds while it is off. When it is on, the picture is the academy's plain green frame with **no logo in it** — the mark belongs to the room's own top-left overlay, never behind live video.

## What runs

A vendored copy of [docker-jitsi-meet](https://github.com/jitsi/docker-jitsi-meet)
at **`stable-11248-2`**, plus a small deployment overlay:

| File | Purpose |
| --- | --- |
| `jitsi/.env.example` | Non-secret configuration (public URL, ports, media IP, auth flags). `.env` is generated from it. |
| `jitsi/deploy.sh` | Validates `.env`, generates the component passwords, starts/stops the stack. |
| `jitsi/Caddyfile` | Production edge: TLS + WebSocket proxy in front of the web container. |
| `jitsi/config/web/custom-config.js` | Forces the room UI to English (otherwise it follows the viewer's browser language and Arabic browsers get an RTL room). Also points `dynamicBrandingUrl` at the branding file below and blocks custom background uploads. The clients only ask the room for a background when the `LessonRoom__CameraBackground` flag is on, so this config is inert while the flag is off. |
| `jitsi/config/web/custom-interface_config.js` | Removes the Jitsi watermark, brand mark and "powered by" footer. |
| `jitsi/config/web/nginx-custom/branding.conf` | Rewrites the room page's `<title>` / Open Graph tags so WhatsApp and other link previews say "Ana Quran lesson room" instead of "Jitsi Meet", and serves everything under `/branding/` from the overlay. |
| `jitsi/config/web/branding/ana-quran.png` | Preview image referenced by `og:image`. |
| `jitsi/config/web/branding/ana-quran-branding.json` | Dynamic branding: the one picture the background picker offers. |
| `jitsi/config/web/branding/ana-quran-lesson-background.jpg` | 1280×720 academy backdrop — a plain deep green frame with **no logo in it**, because the room overlay already carries the mark and nothing should sit behind live video. The web client applies it automatically when its flag is on; the native SDK has no such command, so mobile students pick it from the list. Jitsi stretches it to the camera's own aspect ratio. To change it, edit the `.svg` next to it, then re-render: `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars --window-size=1280,720 --screenshot=/tmp/bg.png file:///tmp/wrapper.html && sips -s format jpeg -s formatOptions 82 /tmp/bg.png --out ana-quran-lesson-background.jpg` (the wrapper is an `<img>` of the SVG at 1280×720 with zero body margin). |

```
jitsi/
├── .env.example
├── Caddyfile
├── deploy.sh
├── config/
│   └── web/                     # overlay config the web image copies at boot
│       ├── custom-config.js
│       ├── custom-interface_config.js
│       ├── nginx-custom/
│       │   └── branding.conf   # link-preview metadata, serves /branding/
│       └── branding/
│           ├── ana-quran.png                    # og:image for shared links
│           ├── ana-quran-branding.json          # offers the backdrop below in the picker
│           ├── ana-quran-lesson-background.jpg  # logo-free green backdrop
│           └── ana-quran-lesson-background.svg  # editable source for the image above
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

## Current deployment (2026-11-11)

Jitsi is **self-hosted on one Oracle Cloud Linux VM**. Nothing is deployed to a
managed video service, and nothing in this repo is imported by the web app —
Vercel/Netlify host the Next.js frontend, Oracle hosts the rooms.

| | |
| --- | --- |
| Provider | Oracle Cloud Infrastructure (OCI), Free Tier account with an active Free Trial; not Pay As You Go, confirmed in the console on 2026-11-11 |
| Region | UK South (London), `uk-london-1`, availability domain AD-1 — roughly 60–80 ms from Egypt |
| Instance | `ana-quran-instance-20261101`, shape `VM.Standard.A1.Flex` (Ampere, arm64) |
| Size | **2 OCPU / 12 GB**, resized from 4 OCPU / 24 GB on 2026-11-11 and confirmed over SSH (`nproc`: 2; approximately 11.65 GiB RAM available to the OS) |
| OS | Ubuntu 24.04.5 LTS |
| Public IPv4 | `143.47.237.128` — 1:1 NAT, so `JVB_ADVERTISE_IPS` must be this public address, never `10.0.0.30` |
| Private IP | `10.0.0.30` on VNIC `ana-quran-vnic` |
| Hostname | `meet.143-47-237-128.sslip.io` — temporary room hostname |
| Networking | VCN `ana-quran-vc` (10.0.0.0/16), public subnet, internet gateway, NSG `ig-quick-action-NSG` |
| Firewall | **Three layers**: OCI security list + NSG + iptables baked into the Ubuntu image. A port is open only if all applicable layers allow it |
| TLS | Caddy 2.11 on the host, Let's Encrypt via HTTP-01, auto-renewing (cert valid to 2027-01-30); HTTPS certificate verification passed on 2026-11-11 |
| SSH | `ssh -i ~/.ssh/oci-anaquran.key ubuntu@143.47.237.128` (deploy user is **uid 1001**) |
| Code | `~/ana-quran-infra` on the VM, clone of `khaled9912/ana-quran-infra`; compose project `ana-quran-jitsi` |
| Containers | `ana-quran-jitsi-{web,prosody,jicofo,jvb,whiteboard}-1`, policy `unless-stopped` |
| Edge config | `/etc/caddy/Caddyfile` — a **host** file, not managed by the repo |
| Secrets | `~/ana-quran-infra/jitsi/.env` (generated passwords). Back this up; it is gitignored |

### Post-resize verification (2026-11-11)

Read-only SSH and external HTTPS checks after the reboot:

| Check | Observed result |
| --- | --- |
| Host memory | Approximately 974 MiB used and 10 GiB available shortly after boot; an idle snapshot, not a load test |
| Root filesystem | 45 GiB filesystem, 5.7 GiB used; this does not establish total OCI provisioned storage |
| Containers and Caddy | All five containers running; Caddy active; no container restarts or OOM flags, and no error-level entries in the post-reboot logs checked |
| `https://meet.143-47-237-128.sslip.io/` | HTTP 200; TLS certificate verification passed |
| `/external_api.js`, `/config.js`, `/http-bind` | HTTP 200 |
| Video bridge | JVB authenticated with XMPP and registered with Jicofo |
| UDP 10000 | Listening on the host; external UDP reachability was not retested |

The optional JVB/Jicofo REST monitoring endpoints are not enabled; bridge
readiness was checked through container state and registration logs instead.
These checks did not change production settings or restart services.
**No browser/E2E call, microphone/camera test, or concurrency load test was run.**
A two-device lesson test is still needed to verify actual audio/video after the
resize. For relay coverage, test a third participant as well; a successful
peer-to-peer call alone does not prove JVB media routing.

Inbound TCP 80/443 and external UDP 10000 reachability were previously verified
on 2026-11-01; the UDP check used packet capture while sending test packets.

`https://143.47.237.128/` (raw IP) fails on purpose — Caddy only answers
requests whose SNI matches the configured hostname.

### Free Tier status and limits (checked 2026-11-11)

- The console's **Free Tier / Free Trial** banner describes the account, not a
  sizing error. Resizing does not end the trial or remove that banner. Per
  [Oracle's Free Tier documentation](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier.htm),
  the card is not charged unless the account is explicitly upgraded; paid
  trial resources can be reclaimed after the trial instead of being billed.
- Oracle's [Always Free resource documentation](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
  currently lists **1,500 OCPU-hours and 9,000 GB-hours per month**, equivalent
  to **2 OCPU / 12 GB**. The console instead advertised **3,000 / 18,000**,
  equivalent to **4 OCPU / 24 GB**. This discrepancy is unresolved: the console
  banner and an “Always Free-eligible” shape label do not prove that 4/24 will
  remain free for this tenancy after the trial.
- The instance was manually reduced to **2 OCPU / 12 GB** to fit the lower
  documented allowance. Do not rely on Oracle to automatically resize an
  over-limit instance; obtain account-specific confirmation before increasing
  resources on the assumption they remain free.
- Always Free compute and boot/block storage must be in the tenancy's **home
  region**. Combined provisioned boot/block volumes must stay within **200 GB**. Home
  region status and the full OCI volume inventory have **not** been verified;
  free space inside the VM is not a substitute for that check.
- Always Free has no scheduled expiry, but Oracle can reclaim idle compute.
  Keep backups; free eligibility is not a guarantee of uninterrupted hosting.

### OCI specifics that cost hours if forgotten

- **Both firewall layers.** The security list and the attached NSG must each
  allow the port; adding rules to only one changes nothing. The console had two
  NSGs with the same name — the right one is the one whose *VNICs* tab lists
  `ana-quran-vnic`.
- **UDP, not TCP, on 10000.** The security list is easy to fill in wrong; a
  `10000/tcp` row looks correct and silently breaks relay media.
- **Editing shape** interrupts service and restarts the instance. Back up
  important data and wait until no lessons are active. Open the instance's
  **Shape configuration** editor, keep **Ampere / VM.Standard.A1.Flex**, expand
  its row using the small triangle, set **2 OCPU / 12 GB**, and save/confirm
  the restart. Do not terminate or recreate the instance; resizing preserves
  the boot disk. Recheck the size, services, and a test call after it returns.
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

The current host is Ubuntu 24.04 on **2 OCPU / 12 GB**, verified after the
2026-11-11 resize. One-to-one sessions prefer peer-to-peer media, but failed
P2P connections and a third participant require JVB relay. Recording and
server-side transcription are not running; adding Whisper/Jigasi requires
separate CPU, memory, and bandwidth measurements, not just spare idle RAM.
See [Capacity notes](#capacity-notes) for the initial planning target.

### Oracle Cloud (OCI)

OCI filters traffic twice — in the VCN *and* in an iptables ruleset baked into
the Ubuntu image that rejects everything except SSH. Opening only one of the two
is the usual reason a room loads but calls connect with no audio/video.

- **Shape**: Ampere `VM.Standard.A1.Flex` at **2 OCPU / 12 GB** (arm64),
  matching the lower documented Always Free allowance; see the account-status
  caveats above. Do not substitute the 1 GB micro shape for this stack.
  `VM.Standard.E4.Flex` (x86) is not covered by the A1 free allowance. The
  pinned `stable-11248-2` images publish `linux/arm64`, so Ampere works
  without emulation.
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
`jitsi/**` reconciles containers within seconds. That is fine for compose or
image changes (containers are recreated) but overlay edits under
`jitsi/config/web/**` are only copied into the container at boot, so they need
`./deploy.sh restart web` before they take effect. Docs changes under `README`,
`FE/` or the API are ignored by the `paths` filter. If you want a human gate,
delete the `push` trigger and keep only `workflow_dispatch`, or attach a GitHub
Environment with required reviewers.

#### Do I have to pull on the VM by hand?

**No.** Pushing to `master` *is* the deploy. GitHub runs `git fetch` +
`git merge --ff-only` on the box and then `./deploy.sh`; you never log in for a
normal change.

The `git pull` is performed on the VM, but it is triggered by the runner after
your push — the VM itself has no watcher, cron job or webhook listener.

Manual work is only needed in these cases:

| Situation | What you do |
| --- | --- |
| Rollback | `git revert <sha>`, push, let the Action deploy |
| Action failed, disabled, or GitHub outage | `ssh ubuntu@<ip>`, then `cd ~/ana-quran-infra && git pull --ff-only && cd jitsi && ./deploy.sh` |
| You edited `jitsi/.env` on the server | Nothing is pulled (it is gitignored); run `./deploy.sh` to apply |
| You changed `jitsi/config/web/**` (room UI or link-preview overlay) | `./deploy.sh restart web` — the overlay is copied at container boot |
| Checking what is actually running | `git -C ~/ana-quran-infra log --oneline -1` |
| First install on a new box | see "Moving to another provider" |

If you ever hand-edit a **tracked** file on the VM, `--ff-only` will refuse to
merge until you revert or commit that edit — by design, so a stray edit cannot
be silently overwritten.

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
- **Restarting the box** interrupts active lessons. Confirm downtime first;
  containers use `unless-stopped` to resume after boot unless manually stopped.

## Capacity notes

- Plan initially for **5–10 simultaneous 1:1 lessons** on **2 OCPU / 12 GB**:
  5–10 students plus their teachers. This is a conservative planning estimate,
  **not a measured maximum or a demonstrated concurrency guarantee**.
- **70 enrolled students** is a reasonable starting target if the timetable
  keeps peak simultaneous lessons within that range. Total enrollment alone
  does not determine video-server capacity.
- Two-person rooms prefer a direct peer-to-peer connection, leaving the VPS
  mostly handling signalling. If P2P fails, or support joins as a third
  participant, JVB must relay media. Capacity then depends on active senders,
  recipients, video quality, network conditions, and server CPU/bandwidth.
- Recording and server-side speech recognition are **excluded** from this
  estimate. The post-resize idle snapshot (~1 GiB host RAM used) does not prove
  loaded capacity. Measure real calls and relay usage before increasing the
  planned concurrency or adding capture services.
- Meetings have **no configured duration cap** in this self-hosted setup.

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
