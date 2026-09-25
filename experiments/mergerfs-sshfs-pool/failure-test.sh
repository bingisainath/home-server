#!/bin/bash
# Failure test for the phone branch. Run as: sudo PHONE=<tailscale ip> bash failure-test.sh
# Simulates (1) the ssh process dying and (2) the phone becoming unreachable for ~75s,
# sampling every 2s. BAD = pool mounted but the phone-branch canary file is missing
# (that is what would make the app's scanner drop index rows).
# Only touches: a canary file on the phone branch, and a temporary nft rule. Both are removed on exit.
set -u
PHONE=${PHONE:?set PHONE=<phone tailscale ip>}
PIXEL=/srv/pocket/pixel
POOL=/srv/pocket/pool
CANARY=failure-test-canary.txt
LOG=${LOG:-/tmp/pocket-failure-test.log}
USER_=${SUDO_USER:?run with sudo}
: >"$LOG"

cleanup() {
  nft delete table inet pocket_ftest 2>/dev/null
  sudo -u "$USER_" rm -f "$PIXEL/$CANARY" 2>/dev/null
  echo "cleanup done" | tee -a "$LOG"
}
trap cleanup EXIT

sample() { # label
  local s p m c
  s=$(systemctl is-active pixel-sshfs); p=$(systemctl is-active pocket-pool)
  m=no; timeout 3 findmnt -n "$POOL" >/dev/null 2>&1 && m=yes
  c=no; [ "$m" = yes ] && timeout 4 test -f "$POOL/$CANARY" && c=yes
  local flag=ok
  [ "$m" = yes ] && [ "$c" = no ] && flag=BAD
  printf '%s %-10s sshfs=%-11s pool=%-11s mounted=%-3s canary=%-3s %s\n' "$(date +%T)" "$1" "$s" "$p" "$m" "$c" "$flag" | tee -a "$LOG"
}

watch_until_recovered() { # label max_seconds
  local i
  for ((i = 0; i < $2; i += 2)); do
    sample "$1"
    if [ "$(systemctl is-active pocket-pool)" = active ] && timeout 4 test -f "$POOL/$CANARY"; then return 0; fi
    sleep 2
  done
  return 1
}

sudo -u "$USER_" sh -c "echo canary > '$PIXEL/$CANARY'" || { echo "cannot write canary to phone branch"; exit 1; }
sample baseline; sleep 2; sample baseline

echo "== TEST 1: kill the ssh process (link crash)" | tee -a "$LOG"
pkill -KILL -f "ssh -x -a.*root@$PHONE" || echo "no ssh process found" | tee -a "$LOG"
watch_until_recovered crash 90 && echo "TEST 1: recovered" | tee -a "$LOG" || echo "TEST 1: NOT recovered in 90s" | tee -a "$LOG"

sleep 5
echo "== TEST 2: phone unreachable for ~75s (traffic to $PHONE dropped)" | tee -a "$LOG"
nft add table inet pocket_ftest
nft add chain inet pocket_ftest out '{ type filter hook output priority 0; }'
nft add rule inet pocket_ftest out ip daddr "$PHONE" drop
for ((i = 0; i < 75; i += 3)); do sample blocked; sleep 3; done
nft delete table inet pocket_ftest
echo "== link restored, waiting for recovery" | tee -a "$LOG"
watch_until_recovered restored 120 && echo "TEST 2: recovered" | tee -a "$LOG" || echo "TEST 2: NOT recovered in 120s" | tee -a "$LOG"

echo "== SUMMARY" | tee -a "$LOG"
echo "BAD samples: $(grep -c ' BAD$' "$LOG")" | tee -a "$LOG"
