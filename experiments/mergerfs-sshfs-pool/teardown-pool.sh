#!/bin/bash
# Option B teardown: remove the mergerfs pool + SSHFS mount, keep the laptop files as a plain folder.
# Run as: sudo bash teardown-pool.sh      (stop the Pocket Drive app first)
set -euo pipefail
USER_=${SUDO_USER:?run with sudo}
ENV=/home/$USER_/github.com/pocket-drive/backend/.env

if ss -ltn | grep -q '127.0.0.1:3000 '; then
  echo "Pocket Drive is still running on :3000. Stop it (Ctrl-C in its terminal) and rerun."; exit 1
fi
[ -d /srv/pocket/local ] || { echo "/srv/pocket/local missing; nothing to promote"; exit 1; }
[ ! -e /srv/pocket/files ] || { echo "/srv/pocket/files already exists; refusing to overwrite"; exit 1; }

systemctl disable --now pocket-pool.service pixel-sshfs.service 2>/dev/null || true
umount -l /srv/pocket/pool  2>/dev/null || true
umount -l /srv/pocket/pixel 2>/dev/null || true
rm -f /etc/systemd/system/pocket-pool.service /etc/systemd/system/pixel-sshfs.service
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

mv /srv/pocket/local /srv/pocket/files
rmdir /srv/pocket/pool /srv/pocket/pixel      # fails (kept) if anything is still inside

cp -p "$ENV" "$ENV.bak-before-pool-removal"
sudo -u "$USER_" sed -i 's#^STORAGE_DIR=.*#STORAGE_DIR=/srv/pocket/files#' "$ENV"
echo "STORAGE_DIR now: $(grep '^STORAGE_DIR=' "$ENV")"
echo "files:"; ls -A /srv/pocket/files
findmnt -n -o TARGET,FSTYPE | grep -E 'pocket' || echo "no pocket mounts remain"
