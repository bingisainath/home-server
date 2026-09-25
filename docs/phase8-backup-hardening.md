# Phase 8 — backups and hardening

## Backup

```bash
bash scripts/backup.sh          # run it now
bash scripts/verify-backup.sh   # prove the backup is real, recent and restorable
sudo systemctl enable --now pocket-backup.timer
systemctl list-timers pocket-backup.timer
```

Nightly at 03:30 (plus up to 15 minutes of jitter), to `/root/backup` on the phone over Tailscale/SSH.

### What makes it a backup rather than a copy

**The database is snapshotted, not copied.** Pocket Drive runs in WAL mode and writes continuously;
copying `cloud-drive.db` off disk can capture a torn state. The script uses SQLite's own online backup
API (via Python's stdlib — no extra packages) and then runs `PRAGMA integrity_check` on the result.

**Deletions stay recoverable.** `rsync --delete` alone would faithfully replicate an accidental
deletion within hours. Deleted files are moved to `deleted/<date>/` on the phone and kept for
`RETAIN_DELETED_DAYS`.

**Every run ships a manifest** — path, size, mtime and sha256 of every file — so a restore can be
*verified*, not assumed.

**The transfer is checked, not trusted.** The database's sha256 is compared on the phone after the
copy; a mismatch fails the run.

### How you learn it broke

The script exits non-zero on any failure, which systemd records, and it pings the Uptime Kuma push URL
**only** on success. Create a **Push** monitor in Uptime Kuma, set its heartbeat interval to ~26 hours,
and put its push URL in `.env` as `BACKUP_PUSH_URL`. A missing ping then raises the alert — which also
catches the case a reachability check would miss: the backup not running at all, because the machine was
off or the timer was disabled.

This is why there is no "phone SSH" monitor. Checking that SSH answers proves less than checking that a
backup actually completed.

### Restoring

```bash
# 1. stop the stack so nothing writes while you restore
bash scripts/stack.sh down && sudo systemctl stop pocket-drive

# 2. files
rsync -a -e "ssh -p <port> -i <key>" root@<phone>:/root/backup/files/ /srv/pocket/files/

# 3. the most recent database snapshot
scp -P <port> -i <key> root@<phone>:/root/backup/db/<newest>.db ~/cloud-storage/cloud-drive.db
rm -f ~/cloud-storage/cloud-drive.db-wal ~/cloud-storage/cloud-drive.db-shm   # stale beside a restored db

# 4. bring it back and check the scan reports no surprises
bash scripts/stack.sh up
```

`Index synced with disk` should report roughly `+0 ~0 -0`. A large negative number means files are
missing relative to the database — stop and re-check the file restore before letting anyone in.

A file deleted by accident and not yet expired is in `deleted/<date>/` on the phone, at its original path.

## Hardening — state on this machine

| Item | Status |
|---|---|
| Docker log rotation | done in Phase 6: json-file, 10 MB × 3 per container |
| Per-container resource limits | done in Phase 6: memory and CPU ceilings on every service |
| Pinned image versions | done in Phase 6: no `latest` anywhere |
| Secrets out of the repo and image layers | done: `secrets/` is git-ignored, mode 600, injected at runtime |
| Suspend on lid close | `sleep.target`, `suspend.target` and `hibernate.target` are **masked**, so the machine cannot suspend at all. `HandleLidSwitch=ignore` is set as well, so the intent is explicit and does not rely on masking alone |
| unattended-upgrades | already installed, enabled and running (security origins, daily) |

### Automatic reboots are deliberately off

Unattended-upgrades installs security updates but does not reboot, so a kernel update is downloaded and
unpacked yet not running until you reboot. Enabling `Unattended-Upgrade::Automatic-Reboot` would close
that gap at the cost of the drive vanishing mid-upload at 03:00 with no warning. On a single-user home
server an occasional deliberate `sudo reboot` is the better trade; the containers all restart by
themselves afterwards. Check whether one is pending with `ls /var/run/reboot-required`.
