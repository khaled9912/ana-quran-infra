#!/usr/bin/env bash
# Ana Quran — Jitsi Meet deployment helper.
#
#   ./deploy.sh            pull the pinned upstream stack, then start it
#   ./deploy.sh down       stop the stack (state under config/ is kept)
#   ./deploy.sh logs web   follow container logs
#
# The upstream repo is cloned into vendor/ at a fixed tag; this repo only
# carries the overlay (config/web/*.js, .env.example) and this script.
set -euo pipefail

cd "$(dirname "$0")"

UPSTREAM_REPO="https://github.com/jitsi/docker-jitsi-meet.git"
UPSTREAM_TAG="stable-11248-2"
UPSTREAM_DIR="vendor/docker-jitsi-meet"

log() { printf '\n==> %s\n' "$*"; }

if [ ! -d "$UPSTREAM_DIR/.git" ]; then
  log "Cloning ${UPSTREAM_TAG}"
  mkdir -p vendor
  git clone --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_REPO" "$UPSTREAM_DIR"
else
  log "Using existing ${UPSTREAM_DIR}"
fi

if [ ! -f .env ]; then
  log "Creating .env from .env.example"
  cp .env.example .env
fi

# CONFIG has to be absolute: the compose file lives in vendor/, and relative
# bind-mount paths there would resolve against the wrong directory.
config_dir="$(cd config && pwd)"
sed -i.bak "s#^CONFIG=.*#CONFIG=${config_dir}#" .env
rm -f .env.bak

log "Generating missing component passwords"
for key in JICOFO_AUTH_PASSWORD JVB_AUTH_PASSWORD JIGASI_XMPP_PASSWORD \
           JIGASI_TRANSCRIBER_PASSWORD JIBRI_RECORDER_PASSWORD JIBRI_XMPP_PASSWORD; do
  if grep -qE "^${key}=(change-me)?$" .env; then
    value="$(openssl rand -hex 16)"
    sed -i.bak "s#^${key}=.*#${key}=${value}#" .env
    rm -f .env.bak
  fi
done

# Created ahead of the containers so the bind mounts do not fail on a fresh box.
mkdir -p config/storage/web config/prosody config/jicofo config/jvb config/tmp

compose() {
  docker compose --env-file "$PWD/.env" -f "$UPSTREAM_DIR/docker-compose.yml" "$@"
}

case "${1:-up}" in
  up) ;;
  down)
    compose down
    exit 0
    ;;
  logs)
    compose logs -f "${2:-web}"
    exit 0
    ;;
  *)
    echo "usage: $0 [up|down|logs [service]]" >&2
    exit 1
    ;;
esac

log "Starting Jitsi"
compose up -d

http_port="$(grep -E '^HTTP_PORT=' .env | cut -d= -f2-)"
http_port="${http_port##*:}"

log "Waiting for http://127.0.0.1:${http_port}/"
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
