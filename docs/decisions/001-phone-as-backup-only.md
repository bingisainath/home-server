# 001: The phone is a backup target, not part of the storage pool

Status: accepted (2026-09-24)

## Context
The target design pooled the laptop SSD (~428 GB free) with the phone's storage (~86 GB free) using
mergerfs over an SSHFS mount, so the drive would see one larger volume.

## What I built and measured
- SSHFS over Tailscale (direct USB tether path, ~8 ms) into a mergerfs pool. `category.create=ff`
  with `minfreespace`, so files land on the SSD first and spill to the phone only when the SSD is nearly full.
- Throughput through SSHFS: about 26 MB/s over the USB tether (SSH encryption on the phone is the limit).
- Failure tests (`experiments/mergerfs-sshfs-pool/failure-test*.{sh,py}`) that kill the ssh process and
  black-hole traffic to the phone while a canary file on the phone branch is polled:
  - Killing ssh: pool went down immediately, recovered ~13 s later on its own.
  - Silent link loss (packets dropped): every operation touching the pool hung for ~45 s (the dead-link
    detection time), then the whole pool, including laptop-only files, went offline until the phone returned.
  - A tight polling loop found a window of about 50 ms right after the link died in which the pool was
    still mounted and a directory listing succeeded **without** the phone's files.

## Why that matters
Pocket Drive's scanner treats the disk as the source of truth and removes index rows for files it can no
longer see. A listing that silently omits a branch can therefore delete metadata and share links for
files that still exist. It can't be prevented from the pool side; it needs an app change (refuse to drop
a large share of the index in one scan). Separately, the phone became a hard dependency for the drive's
availability while adding only ~20% capacity.

## Decision
Files live on the laptop SSD as a plain folder. The phone receives nightly backups over rsync/SSH
(DB snapshot + file manifest + files that fit). A missing phone fails a backup and raises an alert; it
never stalls the drive. The mergerfs/SSHFS units were removed; the experiment is kept under `experiments/`.

## Also learned
- Ubuntu's AppArmor profile for `fusermount3` blocks unprivileged FUSE mounts outside a few paths
  (e.g. `/srv`); mounting as root from systemd avoids loosening the profile.
- A sentinel file inside a directory the app manages (`.cloud-drive-tmp`) gets wiped by the app on startup,
  which silently broke the pool's start-up check. Check the mount type instead of a file.
- `sshfs -o reconnect` keeps the process alive after link loss, which defeats "stop the pool when the
  phone goes away". Dropping `reconnect` lets systemd own the restart.
