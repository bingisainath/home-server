#!/bin/bash
# Phase 5: retire the phone's app and tunnel, keeping it reachable as a backup target.
#
# Run from the LAPTOP: bash scripts/decommission-phone.sh [--apply]
# Without --apply it only reports what it would change.
#
# What it does:
#   - refuses to touch anything unless the laptop is serving all three hostnames
#   - writes a runit `down` file for cloud-drive, deploy, cloudflared and portfolio, so they stay
#     stopped across reboots (`sv down` alone does NOT survive a restart)
#   - narrows the watchdog to the services that remain, so it stops probing dead ones
#   - leaves tailscaled and debian-sshd running: Phase 8 backups need both
#   - deletes NO data. /root/cloud-storage stays as a pre-cutover fallback copy.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
[ -f "$ROOT/.env" ] && . "$ROOT/.env"
PHONE_HOST=${PHONE_HOST:?set PHONE_HOST in .env}
PHONE_PORT=${PHONE_PORT:-22}
PHONE_USER=${PHONE_USER:-root}
PHONE_KEY=${PHONE_KEY:?set PHONE_KEY in .env}
SSH="ssh -p $PHONE_PORT -i $PHONE_KEY -o IdentitiesOnly=yes -o ConnectTimeout=10 $PHONE_USER@$PHONE_HOST"

APPLY=${1:-}
# The app, its auto-deploy, the tunnel and the static site all moved to the laptop.
# sshd/ssh-agent are broken leftovers: their service dirs have no `run` file, so runsv respawned
# them once a second, draining a phone that now has to stay awake for backups. (SSH in goes via
# debian-sshd on its own port, which stays up.)
RETIRE="cloud-drive deploy cloudflared portfolio sshd ssh-agent"
KEEP="tailscaled debian-sshd watchdog"

# --- safety gate: the laptop must be serving everything before the phone is retired ---
echo "== checking the laptop is serving all three hostnames"
for h in bingisainath.com www.bingisainath.com drive.bingisainath.com; do
  code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "https://$h/")
  [ "$code" = 200 ] || { echo "  $h returned $code — not decommissioning anything"; exit 1; }
  echo "  $h: $code"
done
# The dotfile rule exists only in this repo's nginx config, so a 403 proves the laptop is the origin.
probe=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "https://bingisainath.com/.git/config")
[ "$probe" = 403 ] || { echo "  origin probe returned $probe, expected 403 (laptop nginx) — aborting"; exit 1; }
echo "  origin probe: 403 (served by this laptop)"

echo; echo "== phone services now"
$SSH 'P=/data/data/com.termux/files/usr; SVDIR=$P/var/service $P/bin/sv status $P/var/service/* 2>/dev/null | sed "s#.*/service/##" | cut -c1-55' | sed 's/^/  /'

if [ "$APPLY" != "--apply" ]; then
  echo
  echo "DRY RUN. With --apply this would:"
  echo "  stop permanently (writes a 'down' file):"; for s in $RETIRE; do echo "    - $s"; done
  echo "  keep running:                            $KEEP"
  echo "  narrow the watchdog to tailscaled only"
  echo "  delete nothing"
  exit 0
fi

echo; echo "== retiring: $RETIRE"
$SSH "P=/data/data/com.termux/files/usr; export SVDIR=\$P/var/service
for s in $RETIRE; do
  # The 'down' file is what makes it stick: runsvdir consults it on every boot.
  touch \"\$SVDIR/\$s/down\"
  \$P/bin/sv down \"\$s\" >/dev/null 2>&1 || true
  echo \"  \$s: stopped and marked down-at-boot\"
done"

echo; echo "== narrowing the watchdog (it was probing services that are now gone)"
$SSH 'P=/data/data/com.termux/files/usr; RUN=$P/var/service/watchdog/run
if grep -q "^CHECKS=.*cloud-drive" "$RUN"; then
  cp -n "$RUN" "$RUN.pre-decommission"
  sed -i "s|^CHECKS=.*|CHECKS=\"\${CHECKS:-tailscaled=tailscale}\"|" "$RUN"
fi
# Report what the file actually says now, rather than assuming the edit worked.
if grep -q "^CHECKS=.*cloud-drive" "$RUN"; then
  echo "  FAILED: watchdog still probes retired services:"; grep -n "^CHECKS=" "$RUN" | sed "s/^/    /"; exit 1
fi
grep -n "^CHECKS=" "$RUN" | sed "s/^/  now: /"
SVDIR=$P/var/service $P/bin/sv restart watchdog >/dev/null 2>&1 || true'

echo; echo "== what is left running"
$SSH 'P=/data/data/com.termux/files/usr; SVDIR=$P/var/service $P/bin/sv status $P/var/service/* 2>/dev/null | sed "s#.*/service/##" | cut -c1-55' | sed 's/^/  /'

cat <<'MSG'

Done. The phone keeps tailscaled + debian-sshd so Phase 8 backups can reach it, and its copy of the
data is untouched at /root/cloud-storage.

To undo (e.g. to fall back to the phone):
  ssh <phone> 'P=/data/data/com.termux/files/usr; rm -f $P/var/service/{cloud-drive,cloudflared,portfolio,deploy}/down;
               SVDIR=$P/var/service $P/bin/sv up cloud-drive cloudflared portfolio'
  then repoint DNS at the phone's tunnel (see docs/phase4-cutover.md, Rollback).
MSG
