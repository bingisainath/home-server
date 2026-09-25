#!/bin/bash
# Drive the containerised stack. Run from the repo root: bash scripts/stack.sh <command>
#
#   prepare  collect secrets from the working host setup into ./secrets (git-ignored)
#   test     build and smoke-test a THROWAWAY stack on spare ports with a temp data dir
#   up       cut over: stop the host systemd services, then start the containers
#   down     stop the containers and hand back to the host systemd services
#   status   what is running where
#
# The one rule this enforces: the host services and the containers must never run together, because
# both would open the same SQLite database and the second writer corrupts the first one's view.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck disable=SC1091
[ -f .env ] && . ./.env
APP_REPO=${APP_REPO:-$HOME/github.com/pocket-drive}
HOST_SERVICES="pocket-drive nginx cloudflared"
SECRETS=$ROOT/secrets

# Adding a user to the docker group does not affect shells that were already running. Rather than
# telling the caller to log out, re-exec once under the group if they are a member on paper.
if command -v docker >/dev/null && ! docker info >/dev/null 2>&1 \
   && [ -z "${STACK_SH_REEXEC:-}" ] && getent group docker | grep -q "\b$(id -un)\b" \
   && command -v sg >/dev/null; then
  export STACK_SH_REEXEC=1
  exec sg docker -c "$(printf '%q ' bash "$0" "$@")"
fi

have_docker() { command -v docker >/dev/null && docker info >/dev/null 2>&1; }
host_running() { for s in $HOST_SERVICES; do systemctl is-active --quiet "$s" && return 0; done; return 1; }
compose() { docker compose "$@"; }

case "${1:-}" in

prepare)
  mkdir -p "$SECRETS"; chmod 700 "$SECRETS"
  # App settings: keep the secrets, drop anything that describes the HOST's filesystem or ports —
  # the container sets those itself, and a stale DATA_DIR here would point the app outside its mounts.
  grep -vE '^(DATA_DIR|STORAGE_DIR|HOST|PORT|TRUST_PROXY|FRONTEND_DIST)=' \
    "$APP_REPO/backend/.env" >"$SECRETS/pocket-drive.env"
  chmod 600 "$SECRETS/pocket-drive.env"
  echo "wrote secrets/pocket-drive.env ($(grep -c . "$SECRETS/pocket-drive.env") settings)"

  # Tunnel credentials and a config rendered with the real tunnel id.
  # /etc/cloudflared/config.yml is root:cloudflared 0640, so this needs sudo. Without `|| true` a
  # failed read aborts the script at this assignment (set -e + pipefail) before the message below.
  ID=$(sudo sed -n 's/^tunnel: *//p' /etc/cloudflared/config.yml 2>/dev/null | head -1 || true)
  [ -n "$ID" ] || { echo "cannot read the tunnel id from /etc/cloudflared/config.yml (is the host tunnel installed?)"; exit 1; }
  sudo cat "/etc/cloudflared/$ID.json" >"$SECRETS/tunnel.json"
  chmod 600 "$SECRETS/tunnel.json"
  sed "s/<TUNNEL_ID>/$ID/g" cloudflared/config.docker.yml >"$SECRETS/cloudflared.yml"
  echo "wrote secrets/tunnel.json and secrets/cloudflared.yml (tunnel $ID)"
  ;;

test)
  have_docker || { echo "docker is not installed or not running"; exit 1; }
  WORK=$(mktemp -d /tmp/pocket-stack-test-XXXXXX)
  trap 'compose -p pocket-test down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
  mkdir -p "$WORK/data" "$WORK/files" "$WORK/portfolio"
  cp -r /var/www/portfolio/. "$WORK/portfolio/" 2>/dev/null || echo "<h1>test</h1>" >"$WORK/portfolio/index.html"
  # A throwaway password so the test can actually sign in; never the real one.
  PW=stack-test-password
  HASH=$(cd "$APP_REPO/backend" && node -e "import('./src/auth.js').then(m=>console.log(m.hashPassword(process.argv[1])))" "$PW")
  printf 'PASSWORD_HASH=%s\nOWNER_EMAIL=owner@example.com\n' "$HASH" >"$WORK/app.env"

  echo "== building and starting a throwaway stack (no tunnel, port 8099)"
  APP_REPO="$APP_REPO" APP_ENV_FILE="$WORK/app.env" \
  DATA_DIR="$WORK/data" STORAGE_DIR="$WORK/files" PORTFOLIO_DIST="$WORK/portfolio" \
  NGINX_PORT=8099 compose -p pocket-test up -d --build pocket-drive nginx

  B=http://127.0.0.1:8099
  code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@"; }
  for i in $(seq 60); do [ "$(code -H 'Host: drive.bingisainath.com' $B/api/health)" = 200 ] && break; sleep 2; done

  pass=0; fail=0
  check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (expected $2, got $3)"; fail=$((fail+1)); fi; }
  D=(-H "Host: drive.bingisainath.com"); P=(-H "Host: bingisainath.com")
  check "drive health"            200 "$(code "${D[@]}" $B/api/health)"
  check "drive needs auth"        401 "$(code "${D[@]}" $B/api/list)"
  check "portfolio served"        200 "$(code "${P[@]}" $B/)"
  check "portfolio SPA fallback"  200 "$(code "${P[@]}" $B/project/1)"
  check "dotfiles blocked"        403 "$(code "${P[@]}" $B/.git/config)"
  check "unknown host dropped"    000 "$(code -H 'Host: nope.example' $B/)"
  # Login + upload + byte-identical download, through the containerised nginx.
  JAR=$WORK/jar
  check "login"                   204 "$(code "${D[@]}" -c "$JAR" -X POST -H 'Content-Type: application/json' -d "{\"password\":\"$PW\"}" $B/api/auth/login)"
  head -c 2097152 /dev/urandom >"$WORK/p.bin"
  UP=$(curl -s -m 60 "${D[@]}" -b "$JAR" -F "file=@$WORK/p.bin;filename=stack.bin" $B/api/upload)
  ID=$(node -e "try{console.log(JSON.parse(process.argv[1]).files?.[0]?.id??'')}catch{console.log('')}" "$UP")
  check "upload accepted"         yes "$([ -n "$ID" ] && echo yes || echo no)"
  curl -s -m 60 "${D[@]}" -b "$JAR" -o "$WORK/back.bin" "$B/api/files/$ID/download" 2>/dev/null || true
  check "download byte-identical" yes "$(cmp -s "$WORK/p.bin" "$WORK/back.bin" && echo yes || echo no)"
  check "written as uid 1000"     1000 "$(stat -c %u "$WORK/files/stack.bin" 2>/dev/null || echo missing)"
  # ffmpeg/heif must exist in the image, or video streaming and HEIC photos break silently later.
  check "ffmpeg in image"         ok "$(compose -p pocket-test exec -T pocket-drive sh -c 'ffmpeg -version >/dev/null 2>&1 && echo ok' 2>/dev/null || echo missing)"
  check "heif decoder in image"   ok "$(compose -p pocket-test exec -T pocket-drive sh -c 'command -v heif-dec >/dev/null && echo ok' 2>/dev/null || echo missing)"
  # Proxy-header trust, the check that matters most in container mode: cloudflared reaches nginx from a
  # bridge IP, not loopback, so a trusted-proxy CIDR that says 127.0.0.1 would silently drop the Secure
  # flag from session cookies and make every client look like one IP to the login rate limiter.
  # Use the password login, not the Google start route: it sets its session cookie with the same
  # `secure: req.secure` logic but needs no OAuth credentials, which a throwaway stack does not have.
  # (The Google route 404s when unconfigured, so it would "pass" without ever setting a cookie.)
  sec() { curl -s -o /dev/null -D - -m 20 "${D[@]}" -X POST -H 'Content-Type: application/json' \
            -d "{\"password\":\"$PW\"}" "$@" "$B/api/auth/login" \
          | grep -i '^set-cookie: cd_session' | grep -qi '; secure' && echo secure || echo insecure; }
  check "https from the tunnel honoured"  secure   "$(sec -H 'X-Forwarded-Proto: https')"
  check "plain http stays insecure"       insecure "$(sec)"

  # The two cloudflared configs must not drift apart.
  d=$(diff <(grep -vE '^#|^$' cloudflared/config.yml | sed 's#http://127.0.0.1:80#ORIGIN#; s#/etc/cloudflared/<TUNNEL_ID>.json#CREDS#; s#127.0.0.1:20241#METRICS#') \
           <(grep -vE '^#|^$' cloudflared/config.docker.yml | sed 's#http://nginx:80#ORIGIN#; s#/etc/cloudflared/tunnel.json#CREDS#; s#0.0.0.0:20241#METRICS#') | wc -l)
  check "cloudflared configs in sync" 0 "$d"

  echo; echo "$pass passed, $fail failed"
  [ "$fail" = 0 ] || { echo "--- app logs:"; compose -p pocket-test logs --tail 30 pocket-drive; }
  [ "$fail" = 0 ]
  ;;

up)
  have_docker || { echo "docker is not installed or not running"; exit 1; }
  for f in "$SECRETS/pocket-drive.env" "$SECRETS/tunnel.json" "$SECRETS/cloudflared.yml"; do
    [ -f "$f" ] || { echo "missing $f — run: bash scripts/stack.sh prepare"; exit 1; }
  done
  if host_running; then
    echo "== stopping the host services first (single writer on the database)"
    sudo systemctl disable --now $HOST_SERVICES
  fi
  APP_ENV_FILE=$SECRETS/pocket-drive.env TUNNEL_CREDENTIALS=$SECRETS/tunnel.json \
    TUNNEL_CONFIG=$SECRETS/cloudflared.yml compose up -d --build
  echo "== waiting for the stack"
  for i in $(seq 60); do [ "$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H 'Host: drive.bingisainath.com' http://127.0.0.1/api/health)" = 200 ] && break; sleep 2; done
  compose ps

  # Local health is not enough: it passes even when the tunnel is dead, which is exactly how a
  # broken credentials mount once left the site returning 530 while this script reported success.
  echo "== verifying the tunnel is actually carrying traffic"
  ok=0
  for i in $(seq 30); do
    conns=$(compose logs cloudflared 2>/dev/null | grep -c "Registered tunnel connection" || true)
    code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' https://drive.bingisainath.com/api/health || true)
    if [ "${conns:-0}" -gt 0 ] && [ "$code" = 200 ]; then
      echo "  $conns tunnel connections, drive.bingisainath.com returns 200"; ok=1; break
    fi
    sleep 4
  done
  if [ "$ok" != 1 ]; then
    echo "  THE PUBLIC SITE IS NOT SERVING (last code: ${code:-none}, connections: ${conns:-0})"
    echo "  recent tunnel logs:"; compose logs --tail 15 cloudflared | sed "s/^/    /"
    echo "  roll back with: bash scripts/stack.sh down"
    exit 1
  fi
  ;;

down)
  compose down
  echo "== handing back to the host services"
  sudo systemctl enable --now $HOST_SERVICES
  sleep 3; for s in $HOST_SERVICES; do printf '  %-13s %s\n' "$s" "$(systemctl is-active "$s")"; done
  ;;

status)
  echo "== host services"; for s in $HOST_SERVICES; do printf '  %-13s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo n/a)"; done
  echo "== containers"; have_docker && compose ps 2>/dev/null || echo "  docker not available"
  ;;

*) sed -n '2,14p' "$0"; exit 1 ;;
esac
