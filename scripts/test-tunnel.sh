#!/bin/bash
# Verify a hostname is served by THIS laptop through Cloudflare, end to end over the public internet.
# Usage: bash scripts/test-tunnel.sh <hostname>        e.g. laptop-test.bingisainath.com
#
# The trick for telling the two origins apart: this laptop runs nginx (which adds no version banner and
# serves the portfolio and drive from one port), the phone runs the app and a static server directly.
# A marker file served only from here removes all doubt.
set -u
HOST=${1:?usage: $0 <hostname>}
MARKER=/var/www/portfolio/origin-check.txt
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (expected $2, got $3)"; fail=$((fail+1)); fi; }
code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@"; }

echo "== $HOST via Cloudflare"
check "https reachable"        200 "$(code "https://$HOST/")"
check "http redirects to https 301/308" ok "$(c=$(code "http://$HOST/"); case $c in 301|308|200) echo ok;; *) echo "$c";; esac)"

# Served by Cloudflare at all?
srv=$(curl -sI -m 20 "https://$HOST/" | grep -i '^server:' | tr -d '\r' | awk '{print tolower($2)}')
check "served by cloudflare"   cloudflare "$srv"

# Is the origin THIS machine? Only true if the local marker comes back.
if [ -f "$MARKER" ]; then
  want=$(cat "$MARKER")
  got=$(curl -s -m 20 "https://$HOST/origin-check.txt" || true)
  check "origin is this laptop" "$want" "$got"
else
  echo "SKIP  origin marker not installed (see docs/phase4-cutover.md step 3)"
fi

# Drive-specific checks, only meaningful on the drive hostname.
case "$HOST" in
  drive.*)
    check "drive health"           200 "$(code "https://$HOST/api/health")"
    check "drive API needs auth"   401 "$(code "https://$HOST/api/list")"
    sec=$(curl -sI -m 20 "https://$HOST/api/auth/google/start?origin=https://$HOST" | grep -i '^set-cookie: cd_oauth' | grep -qi '; secure' && echo secure || echo insecure)
    check "cookies marked Secure over the tunnel" secure "$sec"
    ;;
esac

echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
