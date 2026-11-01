#!/usr/bin/env bash
# Ana Quran — Jitsi Meet deployment helper.
#
#   ./deploy.sh              validate .env, then start/recreate the stack
#   ./deploy.sh down         stop the stack (state under config/ is kept)
#   ./deploy.sh restart web  restart one container (re-applies config/ overlay)
#   ./deploy.sh logs jvb     follow a container's logs
#
# The upstream compose file and image sources are vendored in this repo, so
# there is nothing to clone. See the README for the VPS prerequisites.
set -euo pipefail

cd "$(dirname "$0")"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2- || true; }

rotate_passwords() {
  local key value
  for key in JICOFO_AUTH_PASSWORD JVB_AUTH_PASSWORD JIGASI_XMPP_PASSWORD \
             JIGASI_TRANSCRIBER_PASSWORD JIBRI_RECORDER_PASSWORD JIBRI_XMPP_PASSWORD; do
    if grep -qE "^${key}=(change-me)?$" .env; then
      value="$(openssl rand -hex 16)"
      sed -i.bak "s#^${key}=.*#${key}=${value}#" .env
      rm -f .env.bak
    fi
  done
}

# --- .env bootstrap -----------------------------------------------------------
[ -f .env ] || { log "Creating .env from .env.example"; cp .env.example .env; }

# CONFIG has to be absolute: a relative or empty value makes the compose mounts
# resolve outside this directory (empty becomes "/").
sed -i.bak "s#^CONFIG=.*#CONFIG=$PWD/config#" .env
rm -f .env.bak

# --- commands that never start anything --------------------------------------
case "${1:-up}" in
  down)    docker compose down; exit 0 ;;
  restart) docker compose restart "${2:-web}"; exit 0 ;;
  logs)    docker compose logs -f "${2:-web}"; exit 0 ;;
  up) ;;
  *) echo "usage: $0 [up|down|restart [service]|logs [service]]" >&2; exit 1 ;;
esac

# --- up: validate, then start -------------------------------------------------
rotate_passwords

public_url="$(env_value PUBLIC_URL)"
[ -n "$public_url" ] || die "PUBLIC_URL is empty in .env"
case "$public_url" in
  *example.com*) die "PUBLIC_URL is still the placeholder ($public_url) — set the real domain or https://localhost:8443" ;;
esac

advertise="$(env_value JVB_ADVERTISE_IPS)"
case "$public_url" in
  *localhost*|*127.0.0.1*) ;;
  *)
    [ -n "$advertise" ] || die "JVB_ADVERTISE_IPS is empty — set it to the server's public IP"
    [ "$advertise" != "127.0.0.1" ] || die "JVB_ADVERTISE_IPS is still 127.0.0.1 while PUBLIC_URL is $public_url — set the server's public IP"
    ;;
esac

# Created ahead of the containers so the bind mounts never fall back to "/".
mkdir -p config/storage/web config/prosody config/jicofo config/jvb config/tmp

# The images run as uid 1000. Cloud images don't always give the deploy user
# that uid (Oracle's ubuntu user is 1001), and the entrypoints refuse to start
# when the bind mounts are not writable by 1000.
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" != "1000" ]; then
  sudo chown -R 1000:1000 config
fi

log "Starting Jitsi"
docker compose up -d

log "Waiting for the web container"
http_port="$(env_value HTTP_PORT)"
http_port="${http_port##*:}"
if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found — skipping the HTTP check. Inspect with: ./deploy.sh logs web" >&2
  exit 0
fi
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${http_port}/" || true)"
  if [ "$code" = "200" ]; then
    log "Jitsi is up (HTTP ${code})"
    exit 0
  fi
  sleep 2
done

echo "Jitsi did not answer with HTTP 200 — inspect: ./deploy.sh logs web" >&2
exit 1
