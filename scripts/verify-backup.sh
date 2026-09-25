#!/bin/bash
# Check the backup on the phone is real, recent and complete. Run any time; changes nothing.
# Usage: bash scripts/verify-backup.sh [--deep]
#   --deep also re-hashes a sample of files on the phone and compares them to the manifest.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
[ -f "$ROOT/.env" ] && . "$ROOT/.env"
PHONE_HOST=${PHONE_HOST:?set PHONE_HOST in .env}; PHONE_PORT=${PHONE_PORT:-22}
PHONE_USER=${PHONE_USER:-root}; PHONE_KEY=${PHONE_KEY:?set PHONE_KEY in .env}
REMOTE_BACKUP=${REMOTE_BACKUP:-/root/backup}
MAX_AGE_HOURS=${BACKUP_MAX_AGE_HOURS:-36}
SSH="ssh -p $PHONE_PORT -i $PHONE_KEY -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes $PHONE_USER@$PHONE_HOST"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (expected $2, got $3)"; fail=$((fail+1)); fi; }

$SSH true || { echo "FAIL  cannot reach the phone"; exit 1; }

latest=$($SSH "ls -1t $REMOTE_BACKUP/db/*.db 2>/dev/null | head -1" || true)
check "a database snapshot exists" yes "$([ -n "$latest" ] && echo yes || echo no)"
[ -n "$latest" ] || exit 1

age_h=$(( ( $(date +%s) - $($SSH "stat -c %Y '$latest'") ) / 3600 ))
check "snapshot is under ${MAX_AGE_HOURS}h old" yes "$([ "$age_h" -lt "$MAX_AGE_HOURS" ] && echo yes || echo no)"
echo "      latest: $(basename "$latest"), ${age_h}h old"

# A database that will not open is not a backup. Copy it back and ask SQLite.
tmp=$(mktemp /tmp/verify-db-XXXXXX.db); trap 'rm -f "$tmp"' EXIT
$SSH "cat '$latest'" >"$tmp"
res=$(python3 - "$tmp" <<'PY'
import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1])
    ok = c.execute("PRAGMA integrity_check").fetchone()[0]
    n  = c.execute("SELECT count(*) FROM entries").fetchone()[0]
    u  = c.execute("SELECT count(*) FROM users").fetchone()[0]
    print(f"{ok}|{n}|{u}")
except Exception as e:
    print(f"error: {e}|0|0")
PY
)
check "restored database passes integrity_check" ok "${res%%|*}"
entries=$(echo "$res" | cut -d'|' -f2); users=$(echo "$res" | cut -d'|' -f3)
check "it contains entries" yes "$([ "${entries:-0}" -gt 0 ] && echo yes || echo no)"
echo "      $entries entries, $users users"

# Files on the phone should match the manifest taken at the same time.
man=$($SSH "ls -1t $REMOTE_BACKUP/manifest/*-manifest.tsv.gz 2>/dev/null | head -1" || true)
if [ -n "$man" ]; then
  want=$($SSH "zcat '$man' | wc -l")
  have=$($SSH "find $REMOTE_BACKUP/files -type f | wc -l")
  check "file count matches the manifest" "$want" "$have"
fi

if [ "${1:-}" = "--deep" ] && [ -n "$man" ]; then
  echo "== deep check: re-hashing 20 random files on the phone"
  sums=$($SSH "ls -1t $REMOTE_BACKUP/manifest/*-sha256.txt.gz | head -1")
  bad=$($SSH "cd $REMOTE_BACKUP/files && zcat '$sums' | shuf -n 20 | sha256sum -c --quiet 2>&1 | wc -l")
  check "sampled files match their checksums" 0 "$bad"
fi

echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
