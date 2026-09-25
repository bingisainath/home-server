#!/bin/bash
# Full-stack check of nginx/pocket.conf's proxy behaviour: starts a THROWAWAY Pocket Drive instance and a
# throwaway nginx (both unprivileged, high ports, temp dirs) that uses the same proxy directives as the real
# drive server block, then drives a real session through it: login, upload, download, byte-compare, delete.
#
# Touches nothing that is running: not the installed nginx, not the live app, not /srv/pocket, not any .env.
# Usage: bash scripts/test-proxy-e2e.sh        (needs node on PATH; no root)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${APP_ROOT:-$HOME/github.com/pocket-drive}
WORK=$(mktemp -d /tmp/pocket-proxy-e2e-XXXXXX)
APP_PORT=${APP_PORT:-39301}
NGX_PORT=${NGX_PORT:-39302}
PASSWORD='proxy-e2e-password'
JAR=$WORK/cookies.txt
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (expected $2, got $3)"; fail=$((fail+1)); fi; }

cleanup() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
  [ -f "$WORK/nginx.pid" ] && kill "$(cat "$WORK/nginx.pid")" 2>/dev/null
  sleep 0.3; rm -rf "$WORK"
}
trap cleanup EXIT

[ -f "$APP/frontend/dist/index.html" ] || { echo "frontend not built at $APP/frontend/dist"; exit 1; }

# --- throwaway app instance ---
mkdir -p "$WORK/data"
HASH=$(cd "$APP/backend" && node -e "import('./src/auth.js').then(m=>console.log(m.hashPassword(process.argv[1])))" "$PASSWORD")
env -i PATH="$PATH" HOME="$HOME" \
  DATA_DIR="$WORK/data" STORAGE_DIR="$WORK/data/files" PORT="$APP_PORT" HOST=127.0.0.1 PASSWORD_HASH="$HASH" \
  TRUST_PROXY=loopback OWNER_EMAIL=owner@example.com \
  node "$APP/backend/src/server.js" >"$WORK/app.log" 2>&1 &
APP_PID=$!

# --- throwaway nginx with the same proxy directives as nginx/pocket.conf ---
mkdir -p "$WORK/tmp" "$WORK/logs"
{
  echo "pid $WORK/nginx.pid; error_log $WORK/logs/error.log; daemon off;"
  echo "events {}"
  echo "http {"
  echo "  access_log off; client_body_temp_path $WORK/tmp/b; proxy_temp_path $WORK/tmp/p;"
  echo "  fastcgi_temp_path $WORK/tmp/f; uwsgi_temp_path $WORK/tmp/u; scgi_temp_path $WORK/tmp/s;"
  # prelude from the real config: the trusted-proxy maps and real_ip settings ($fwd_proto is defined there)
  awk '/^server \{/{exit} {print "  " $0}' "$ROOT/nginx/pocket.conf.template"
  echo "  server { listen 127.0.0.1:$NGX_PORT;"
  echo "    client_max_body_size 100m;"
  # the drive's proxy block, verbatim, first match only, upstream port substituted
  awk '/^    location \/ \{$/{f=1} f{print} f&&/^    \}$/{exit}' "$ROOT/nginx/pocket.conf.template" |
    sed "s#proxy_pass http://\${DRIVE_UPSTREAM};#proxy_pass http://127.0.0.1:$APP_PORT;#"
  echo "  }"
  echo "}"
} >"$WORK/nginx.conf"
/usr/sbin/nginx -t -p "$WORK" -c "$WORK/nginx.conf" >"$WORK/logs/conftest.log" 2>&1 || {
  echo "generated nginx config is invalid:"; cat "$WORK/logs/conftest.log"; exit 1; }
/usr/sbin/nginx -p "$WORK" -c "$WORK/nginx.conf" >>"$WORK/logs/start.log" 2>&1 &

# The app loads backend/.env itself, so confirm from its own startup banner that storage really is the
# throwaway dir. Without this, an inherited STORAGE_DIR would make the upload/delete steps hit real files.
for i in $(seq 40); do grep -q '  files:' "$WORK/app.log" && break; sleep 0.25; done
REAL_FILES=$(sed -n 's/^  files:  *//p' "$WORK/app.log" | head -1)
case "$REAL_FILES" in
  "$WORK"/*) ;;
  *) echo "ABORT: throwaway instance resolved storage to '$REAL_FILES', not inside $WORK"; exit 1 ;;
esac
echo "throwaway storage: $REAL_FILES"

B="http://127.0.0.1:$NGX_PORT"
code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@"; }
for i in $(seq 40); do [ "$(code "$B/api/health")" = 200 ] && break; sleep 0.5; done

check "health through proxy" 200 "$(code "$B/api/health")"
check "unauthenticated list rejected" 401 "$(code "$B/api/list")"
check "wrong password rejected" 401 "$(code -X POST -H 'Content-Type: application/json' -d '{"password":"nope"}' "$B/api/auth/login")"
check "login sets session" 204 "$(code -c "$JAR" -X POST -H 'Content-Type: application/json' -d "{\"password\":\"$PASSWORD\"}" "$B/api/auth/login")"
check "session cookie stored" yes "$(grep -q cd_session "$JAR" && echo yes || echo no)"
check "authenticated list" 200 "$(code -b "$JAR" "$B/api/list")"

# --- upload a real file through the proxy, then read it back and compare bytes ---
head -c 3145728 /dev/urandom >"$WORK/payload.bin"
UP=$(curl -s -m 60 -b "$JAR" -F "file=@$WORK/payload.bin;filename=proxy-e2e.bin" "$B/api/upload")
ID=$(node -e "try{console.log(JSON.parse(process.argv[1]).files?.[0]?.id ?? '')}catch{console.log('')}" "$UP")
check "upload returned an id" yes "$([ -n "$ID" ] && echo yes || echo no)"
curl -s -m 60 -b "$JAR" -o "$WORK/back.bin" "$B/api/files/$ID/download"
check "downloaded bytes identical" yes "$(cmp -s "$WORK/payload.bin" "$WORK/back.bin" && echo yes || echo no)"
check "file is on disk" yes "$([ -f "$WORK/data/files/proxy-e2e.bin" ] && echo yes || echo no)"

# --- streaming: a range request must work through the proxy (video seeking depends on it) ---
check "range request honoured" 206 "$(code -b "$JAR" -H 'Range: bytes=0-1023' "$B/api/files/$ID/raw")"

check "delete entry" 200 "$(code -b "$JAR" -X DELETE "$B/api/entries/$ID")"
check "logout" 204 "$(code -b "$JAR" -c "$JAR" -X POST "$B/api/auth/logout")"
check "session invalid after logout" 401 "$(code -b "$JAR" "$B/api/list")"

echo; echo "$pass passed, $fail failed"
[ "$fail" = 0 ] || { echo "--- app log:"; tail -20 "$WORK/app.log"; echo "--- nginx errors:"; tail -10 "$WORK/logs/error.log"; }
[ "$fail" = 0 ]
