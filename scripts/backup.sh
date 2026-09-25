#!/bin/bash
# Nightly backup of Pocket Drive to the phone, over Tailscale/SSH.
#
# A real second copy, not a mirror of convenience:
#   - the SQLite database is snapshotted through SQLite's own backup API, so it is consistent even
#     though the app is writing to it. Copying the .db file directly would risk a torn WAL.
#   - deleted files are moved aside on the phone instead of vanishing, so an accidental deletion
#     (or a bad sync) stays recoverable for RETAIN_DELETED_DAYS.
#   - a manifest of every file with size and sha256 goes with each run, so a restore can be verified
#     rather than assumed.
#
# Failure is loud: the script exits non-zero (systemd records it) and does NOT ping the Uptime Kuma
# push URL, so Kuma alerts when a backup silently stops happening — including when this machine is off.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
[ -f "$ROOT/.env" ] && . "$ROOT/.env"

PHONE_HOST=${PHONE_HOST:?set PHONE_HOST in .env}
PHONE_PORT=${PHONE_PORT:-22}
PHONE_USER=${PHONE_USER:-root}
PHONE_KEY=${PHONE_KEY:?set PHONE_KEY in .env}
REMOTE_BACKUP=${REMOTE_BACKUP:-/root/backup}
LOCAL_DATA=${DATA_DIR:-$HOME/cloud-storage}
LOCAL_FILES=${STORAGE_DIR:-/srv/pocket/files}
DB=$LOCAL_DATA/cloud-drive.db
RETAIN_SNAPSHOTS=${RETAIN_SNAPSHOTS:-14}
RETAIN_DELETED_DAYS=${RETAIN_DELETED_DAYS:-30}
MIN_FREE_GB=${BACKUP_MIN_FREE_GB:-10}
PUSH_URL=${BACKUP_PUSH_URL:-}

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DAY=$(date -u +%Y-%m-%d)
WORK=$(mktemp -d /tmp/pocket-backup-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

SSH="ssh -p $PHONE_PORT -i $PHONE_KEY -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes"
RSH="ssh -p $PHONE_PORT -i $PHONE_KEY -o IdentitiesOnly=yes -o BatchMode=yes"
REMOTE=$PHONE_USER@$PHONE_HOST
log() { printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"; }

log "backup $STAMP starting"

# --- the target has to be there and have room, before anything is written ---
$SSH "$REMOTE" true || { log "FAILED: cannot reach $REMOTE:$PHONE_PORT"; exit 1; }
free_gb=$($SSH "$REMOTE" "df -BG --output=avail $REMOTE_BACKUP 2>/dev/null | tail -1 | tr -dc 0-9" || true)
[ -z "$free_gb" ] && free_gb=$($SSH "$REMOTE" "mkdir -p $REMOTE_BACKUP && df -BG --output=avail $REMOTE_BACKUP | tail -1 | tr -dc 0-9")
if [ "${free_gb:-0}" -lt "$MIN_FREE_GB" ]; then
  log "FAILED: phone has ${free_gb}G free, need at least ${MIN_FREE_GB}G"; exit 1
fi
log "phone reachable, ${free_gb}G free"
$SSH "$REMOTE" "mkdir -p $REMOTE_BACKUP/{files,db,manifest,deleted}"

# --- consistent database snapshot, safe against the running app ---
# Python's stdlib sqlite3 exposes the same online backup API the app itself uses; no extra packages.
[ -f "$DB" ] || { log "FAILED: no database at $DB"; exit 1; }
python3 - "$DB" "$WORK/cloud-drive.db" <<'PY'
import sqlite3, sys
src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
with dst:
    src.backup(dst)
dst.execute("PRAGMA integrity_check").fetchone()[0] == "ok" or sys.exit("integrity check failed")
src.close(); dst.close()
PY
log "database snapshot: $(du -h "$WORK/cloud-drive.db" | cut -f1), integrity ok"

# --- manifest: what a restore should contain, and how to prove it did ---
( cd "$LOCAL_FILES" && find . -type f -not -path './.cloud-drive-tmp/*' -printf '%s\t%TY-%Tm-%TdT%TH:%TM:%TS\t%p\n' \
  | sort -k3 ) >"$WORK/manifest.tsv"
( cd "$LOCAL_FILES" && find . -type f -not -path './.cloud-drive-tmp/*' -print0 | sort -z | xargs -0 -r sha256sum ) >"$WORK/sha256.txt"
gzip -9 "$WORK/manifest.tsv" "$WORK/sha256.txt"
log "manifest: $(zcat "$WORK/manifest.tsv.gz" | wc -l) files"

# --- files. Deletions are moved aside rather than lost. ---
rsync -a --delete --partial \
  --backup --backup-dir="$REMOTE_BACKUP/deleted/$DAY" \
  --exclude '.cloud-drive-tmp/' \
  -e "$RSH" "$LOCAL_FILES/" "$REMOTE:$REMOTE_BACKUP/files/"
log "files synced"

rsync -a -e "$RSH" "$WORK/cloud-drive.db"   "$REMOTE:$REMOTE_BACKUP/db/$STAMP-cloud-drive.db"
rsync -a -e "$RSH" "$WORK/manifest.tsv.gz"  "$REMOTE:$REMOTE_BACKUP/manifest/$STAMP-manifest.tsv.gz"
rsync -a -e "$RSH" "$WORK/sha256.txt.gz"    "$REMOTE:$REMOTE_BACKUP/manifest/$STAMP-sha256.txt.gz"

# --- prove the database arrived intact, rather than trusting rsync's exit code ---
local_sum=$(sha256sum "$WORK/cloud-drive.db" | cut -d' ' -f1)
remote_sum=$($SSH "$REMOTE" "sha256sum $REMOTE_BACKUP/db/$STAMP-cloud-drive.db | cut -d' ' -f1")
[ "$local_sum" = "$remote_sum" ] || { log "FAILED: database checksum mismatch after transfer"; exit 1; }
log "database verified on the phone"

# --- retention ---
$SSH "$REMOTE" "
  ls -1t $REMOTE_BACKUP/db/*.db 2>/dev/null | tail -n +$((RETAIN_SNAPSHOTS + 1)) | xargs -r rm -f
  ls -1t $REMOTE_BACKUP/manifest/*-manifest.tsv.gz 2>/dev/null | tail -n +$((RETAIN_SNAPSHOTS + 1)) | xargs -r rm -f
  ls -1t $REMOTE_BACKUP/manifest/*-sha256.txt.gz 2>/dev/null | tail -n +$((RETAIN_SNAPSHOTS + 1)) | xargs -r rm -f
  find $REMOTE_BACKUP/deleted -maxdepth 1 -mindepth 1 -type d -mtime +$RETAIN_DELETED_DAYS -exec rm -rf {} + 2>/dev/null || true
"
used=$($SSH "$REMOTE" "du -sh $REMOTE_BACKUP 2>/dev/null | cut -f1")
log "done. backup on the phone is now $used ($RETAIN_SNAPSHOTS snapshots kept)"

# --- tell Uptime Kuma this run succeeded; its absence is what raises the alarm ---
if [ -n "$PUSH_URL" ]; then
  # Kuma shows its push URL with "?status=up&msg=OK&ping=" already appended, which is easy to paste
  # wholesale, so tolerate both that and a bare token URL rather than building a broken query string.
  case "$PUSH_URL" in *\?*) sep="&" ;; *) sep="?" ;; esac
  curl -fsS -m 20 "${PUSH_URL}${sep}status=up&msg=ok" >/dev/null \
    && log "pinged Uptime Kuma" || log "WARNING: could not ping Uptime Kuma"
fi
