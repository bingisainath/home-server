# Phase 5 — retire the phone's app, keep it as a backup target

Run after Phase 4 is confirmed working: `bash scripts/decommission-phone.sh` (dry run), then `--apply`.

## Why a `down` file and not just `sv down`

`sv down` stops a runit service **until the next reboot**. The phone's services have no `down` marker
by default, so a restart would have brought the old drive and its Cloudflare tunnel back — a second
live instance writing to its own copy of the data, while DNS points at the laptop. The script writes
`$SVDIR/<service>/down`, which `runsvdir` consults on every boot, so the retirement sticks.

## What is retired

| Service | Why |
|---|---|
| `cloud-drive` | the app runs on the laptop now |
| `deploy` | CI-gated auto-deploy: would pull `main`, rebuild and restart the app on its own |
| `cloudflared` | the tunnel moved to the laptop |
| `portfolio` | the static site is served by the laptop's nginx |
| `sshd`, `ssh-agent` | broken leftovers — their service dirs have no `run` file, so runsv respawned them once a second |

## What stays, and why it matters

| Service | Why it must keep running |
|---|---|
| `tailscaled` | the laptop reaches the phone over the tailnet |
| `debian-sshd` | the rsync/ssh target for Phase 8 backups |
| `watchdog` | restarts tailscaled if it wedges — its original purpose |

The watchdog's `CHECKS` used to probe `cloud-drive`, `portfolio` and `cloudflared`. It skips services
that are deliberately down, so it was harmless, but it now checks only `tailscaled`. The original is
kept alongside as `run.pre-decommission`.

`termux-wake-lock` in the Termux:Boot script keeps the CPU awake so SSH stays reachable with the screen
off. Do not remove it, or backups will fail whenever the phone sleeps.

## Data

Nothing is deleted. `/root/cloud-storage` (3.0 GB) stays as a pre-cutover copy of everything. Keep it
until Phase 8 backups have run successfully at least once — at that point it is redundant, and the same
space becomes the backup destination.

## Rolling back to the phone

```bash
ssh -p <port> -i <key> root@<phone> \
  'P=/data/data/com.termux/files/usr; rm -f $P/var/service/{cloud-drive,cloudflared,portfolio}/down;
   SVDIR=$P/var/service $P/bin/sv up cloud-drive cloudflared portfolio'
```

Then repoint DNS at the phone's tunnel — see the Rollback section of `phase4-cutover.md`. Leave `deploy`
down unless you really want auto-deploy back; it is the thing most likely to resurrect a second writer.
Anything uploaded to the laptop since the cutover exists only on the laptop.
