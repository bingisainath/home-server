#!/bin/bash
# Copy the live Pocket Drive data from the phone to this laptop.
#
# Two stages, on purpose:
#   presync  — bulk copy while the phone keeps serving traffic. Safe, repeatable, no downtime.
#   final    — run with the phone's app STOPPED: copies what changed since, plus a consistent
#              database snapshot taken through SQLite's backup API (safe against a live writer).
#
# Nothing is deleted on the phone. The laptop's own data dirs are backed up before the first write.
# Usage:  bash scripts/migrate-from-phone.sh presync
#         bash scripts/migrate-from-phone.sh final
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Machine-specific values (phone address, key, paths) live in the git-ignored .env; see .env.example.
# shellcheck disable=SC1091
[ -f "$ROOT/.env" ] && . "$ROOT/.env"

STAGE=${1:-}
case "$STAGE" in presync|final) ;; *) echo "usage: $0 presync|final"; exit 1 ;; esac

PHONE_HOST=${PHONE_HOST:?set PHONE_HOST in .env - the phone Tailscale IP}
PHONE_PORT=${PHONE_PORT:-22}
PHONE_USER=${PHONE_USER:-root}
PHONE_KEY=${PHONE_KEY:?set PHONE_KEY in .env - ssh key for the phone}
REMOTE_DATA=${REMOTE_DATA:-/root/cloud-storage}
REMOTE_REPO=${REMOTE_REPO:-/root/cloud-drive}

LOCAL_DATA=${LOCAL_DATA:-$HOME/cloud-storage}      # DATA_DIR: db, thumbs, streams
LOCAL_FILES=${LOCAL_FILES:-/srv/pocket/files}      # STORAGE_DIR: the files themselves

SSH="ssh -p $PHONE_PORT -i $PHONE_KEY -o IdentitiesOnly=yes -o ConnectTimeout=10"
RSYNC_RSH="ssh -p $PHONE_PORT -i $PHONE_KEY -o IdentitiesOnly=yes"
REMOTE="$PHONE_USER@$PHONE_HOST"

say() { printf '\n=== %s\n' "$*"; }

$SSH "$REMOTE" true || { echo "cannot reach the phone at $REMOTE:$PHONE_PORT"; exit 1; }

# --- both ends need rsync; the phone's Debian container does not ship with it ---
command -v rsync >/dev/null || { echo "rsync is not installed on this laptop: sudo apt install rsync"; exit 1; }
$SSH "$REMOTE" 'command -v rsync >/dev/null' || {
  echo "rsync is not installed on the phone. Install it there:"
  echo "  $SSH $REMOTE 'apt-get update && apt-get install -y rsync'"
  exit 1
}

# --- is the phone's app still running? presync wants it up, final wants it down ---
running=$($SSH "$REMOTE" 'curl -s -o /dev/null -m 5 -w "%{http_code}" http://127.0.0.1:3000/api/health' || echo 000)
if [ "$STAGE" = final ] && [ "$running" = 200 ]; then
  cat <<'MSG'
The phone's Pocket Drive is still answering on :3000.
Stop it first, so the final copy is a still picture rather than a moving one:

  ssh -p <port> -i <key> root@<phone>   # then, in Termux (not proot):
  sv down deploy           # FIRST: otherwise it redeploys and restarts the app behind your back
  sv down cloud-drive

Then rerun: bash scripts/migrate-from-phone.sh final
MSG
  exit 1
fi
if [ "$STAGE" = presync ] && [ "$running" != 200 ]; then
  echo "note: the phone's app is not answering; presync still works."
fi

# --- one-time safety copy of whatever this laptop already has ---
if [ -f "$LOCAL_DATA/cloud-drive.db" ] && [ ! -f "$LOCAL_DATA/cloud-drive.db.pre-migration" ]; then
  say "keeping a copy of this laptop's existing database"
  cp -p "$LOCAL_DATA/cloud-drive.db" "$LOCAL_DATA/cloud-drive.db.pre-migration"
fi

mkdir -p "$LOCAL_DATA" "$LOCAL_FILES"

# --- files: the bulk of it. --partial so an interrupted run resumes instead of restarting. ---
say "copying files ($STAGE)"
rsync -a --info=progress2 --partial --human-readable \
  --exclude '.cloud-drive-tmp/' \
  -e "$RSYNC_RSH" "$REMOTE:$REMOTE_DATA/files/" "$LOCAL_FILES/"

# --- thumbnails and streams: regenerable, but copying saves hours of CPU after cutover ---
say "copying thumbnails and streaming versions"
rsync -a --info=progress2 --partial -e "$RSYNC_RSH" "$REMOTE:$REMOTE_DATA/thumbs/" "$LOCAL_DATA/thumbs/" || true
rsync -a --info=progress2 --partial -e "$RSYNC_RSH" "$REMOTE:$REMOTE_DATA/streams/" "$LOCAL_DATA/streams/" || true

if [ "$STAGE" = presync ]; then
  cat <<MSG

Presync done. Files are on this laptop; the phone is still live and still the source of truth.
Re-run presync as often as you like — each run only copies what changed.

Next, when you are ready for the switch:
  1. stop the phone's deploy and cloud-drive services (this script tells you how if you forget)
  2. bash scripts/migrate-from-phone.sh final
MSG
  exit 0
fi

# --- final: consistent database snapshot, taken on the phone via SQLite's backup API ---
say "taking a consistent database snapshot on the phone"
$SSH "$REMOTE" "cd $REMOTE_REPO/backend && node -e \"
  const Database = require('better-sqlite3');
  new Database(process.argv[1])
    .backup(process.argv[2])
    .then(() => { console.log('snapshot ok'); process.exit(0); },
          (e) => { console.error(e.message); process.exit(1); });
\" $REMOTE_DATA/cloud-drive.db /tmp/cloud-drive-migrate.db"

say "copying the database snapshot"
rsync -a --info=progress2 -e "$RSYNC_RSH" "$REMOTE:/tmp/cloud-drive-migrate.db" "$LOCAL_DATA/cloud-drive.db.incoming"

# Only swap it in once the copy is complete, so an interrupted transfer can't leave a half database.
mv -f "$LOCAL_DATA/cloud-drive.db.incoming" "$LOCAL_DATA/cloud-drive.db"
# A stale -wal/-shm beside a restored database would confuse SQLite: the snapshot already has everything.
rm -f "$LOCAL_DATA/cloud-drive.db-wal" "$LOCAL_DATA/cloud-drive.db-shm"
$SSH "$REMOTE" 'rm -f /tmp/cloud-drive-migrate.db'

say "what arrived"
echo "files:  $(find "$LOCAL_FILES" -type f -not -path '*/.cloud-drive-tmp/*' | wc -l) files, $(du -sh "$LOCAL_FILES" | cut -f1)"
echo "db:     $(du -h "$LOCAL_DATA/cloud-drive.db" | cut -f1)"
echo "thumbs: $(du -sh "$LOCAL_DATA/thumbs" 2>/dev/null | cut -f1 || echo none)"

cat <<MSG

Final migration done. Now start the drive on this laptop and check it:

  cd ~/github.com/pocket-drive && npm start

The startup line "Index synced with disk" should report roughly 0 added and 0 removed: the database and
the files agree. A large negative number means files are missing — stop and re-run the file rsync
before letting anyone use it.
MSG
