# home-server

Configuration for a small always-on home server that hosts a self-hosted cloud drive
([Pocket Drive](https://github.com/bingisainath/pocket-drive)) and a portfolio site
([sainathPortfolio](https://github.com/bingisainath/sainathPortfolio)). It replaces a setup that ran
on a rooted phone under Termux with a proper Linux box, built and verified step by step.

## Architecture (target)

```
                 Internet
                    │  Cloudflare Tunnel (outbound only, no open ports)
                    ▼
   ┌────────────────────────────────────── laptop (Ubuntu) ──────────────────────┐
   │  nginx  ── bingisainath.com        → static portfolio                         │
   │         └─ drive.bingisainath.com  → Pocket Drive (Node/Express, SQLite)      │
   │                                          │ files: local SSD   DB: local disk  │
   │  Uptime Kuma (checks + alerts)   Netdata (metrics)                            │
   │  nightly backup: DB snapshot + manifest ──rsync/ssh──▶ phone (over Tailscale) │
   └───────────────────────────────────────────────────────────────────────────────┘
```

Everything runs in Docker Compose with pinned image versions, log rotation and resource limits; secrets
live in a git-ignored `.env`.

## Status

| Phase | What | State |
|---|---|---|
| 1 | Pocket Drive + portfolio running locally | done |
| 2 | Storage: phone joined the pool (mergerfs+SSHFS) | built, tested, **dropped**: see [decision 001](docs/decisions/001-phone-as-backup-only.md) |
| 3 | nginx routing for both sites | **done** — 12/12 routing checks, 13/13 full-stack proxy checks |
| 4 | Cloudflare Tunnel moves to the laptop | **done** — data migrated, tunnel live, all three hostnames cut over |
| 5 | Decommission the phone's live app (keep it as backup target) | **done** — services retired across reboots, phone kept reachable |
| 6 | docker-compose stack | **done** — stack live, 15/15 checks, host services stood down |
| 7 | Uptime Kuma + Netdata | **done** — tailnet-only, Telegram alerts, backup push monitor wired |
| 8 | Backup job, no-suspend, unattended-upgrades, log/resource limits | **done** — nightly backup verified restorable; timer + logind drop-in need installing |

## Layout

- `nginx/pocket.conf`: host routing, upload limits, streaming, and trusted-proxy header handling
- `scripts/install-nginx.sh`: installs nginx and the config
- `scripts/test-routing.sh`: 12 black-box routing checks against the running nginx
- `scripts/test-proxy-e2e.sh`: full-stack check — starts a throwaway app + nginx using the real proxy
  directives and drives a real session through them (login, 3 MB upload, byte-identical download,
  range request, delete, logout). Refuses to run if the throwaway instance resolves storage outside its temp dir.
- `cloudflared/`: tunnel config and a hardened systemd unit (runs as its own unprivileged account)
- `compose.yaml` + `scripts/stack.sh`: the containerised stack and its prepare/test/up/down driver
- `scripts/backup.sh` + `scripts/verify-backup.sh`: nightly backup to the phone, and proof it restores
- `systemd/pocket-backup.{service,timer}`, `systemd/logind-no-suspend.conf`: schedule and no-sleep
- `docs/phase8-backup-hardening.md`: what makes it a backup rather than a copy, and how to restore
- `monitoring/` + `scripts/monitoring.sh`: Uptime Kuma and Netdata, separate from the app's lifecycle
- `docs/phase7-monitoring.md`: why the Docker socket is proxied, and what self-hosted monitoring cannot tell you
- `docs/phase6-docker.md`: what runs where, and the trusted-proxy trap containerising introduces
- `systemd/pocket-drive.service`: runs the drive as a service (restart on failure, survives reboot)
- `docs/phase5-decommission.md`: retiring the phone's services so they stay retired across reboots
- `scripts/decommission-phone.sh`: does that, with a safety gate that checks the laptop is serving first
- `docs/phase4-cutover.md`: the tunnel move — migrate data, prove it on a spare hostname, then switch DNS
- `scripts/migrate-from-phone.sh`: two-stage data move (`presync` live, `final` with the phone stopped)
- `scripts/install-cloudflared.sh`, `scripts/test-tunnel.sh`: install the tunnel, verify a hostname publicly
- `docs/decisions/`: short records of what was chosen and why, including measurements
- `experiments/mergerfs-sshfs-pool/`: the abandoned pool, with the failure tests that ruled it out
- `.env.example`: every setting the stack needs, with placeholders

## Notes on nginx config

- `X-Forwarded-Proto` and `CF-Connecting-IP` are trusted only from loopback (where the tunnel connects),
  so LAN clients can't spoof them; the app gets one clean `X-Forwarded-For` for per-IP login rate limiting.
- Buffering is off for uploads and downloads so multi-GB files and HLS video stream through.
- Unknown `Host` headers get `444`.

## Verification

Run after any change to `nginx/pocket.conf`:

```bash
sudo bash scripts/install-nginx.sh     # apply config
bash scripts/test-routing.sh           # 12 checks against the live nginx
bash scripts/test-proxy-e2e.sh         # 13 checks, isolated throwaway stack
```

The app's own suites (in the Pocket Drive repo) back these up: 81 backend tests, and a Puppeteer
browser suite whose 10 functional steps (login, upload, folders, image/PDF/text preview, delete,
search, dark mode) pass against the built frontend.

## Known limitations

- **Rejected upload chunks can return 502 instead of 401.** With request buffering off, nginx streams a chunk to the
  app; if the app rejects it (e.g. expired session) without reading the body and closes the connection while nginx is
  still writing, nginx reports `502` (`writev() failed (32: Broken pipe)`). Measured at ~7% for 20 MB bodies to a
  rejecting endpoint, 0% for 16 MB. Turning buffering *on* made it worse (up to ~37%), so it stays off. Valid chunks
  are unaffected. The proper fix is in the app (drain the body before responding).
- **Puppeteer e2e: the touch-swipe step fails on Chrome 154.** The final step
  ("swipe between photos without triggering the browser's back gesture") times out deterministically
  across runs, while the 10 functional steps before it pass and the run reports no console errors, CSP
  violations or failed requests. The test is deliberately ordered last because emulated touch gestures
  destabilise the tab, and it was written against Chrome 152. Not exercised by CI (which runs backend
  tests and the web build only) and not affected by anything in this repo, but unconfirmed either way:
  it is a real gesture-handler regression or a Chrome-version artifact.
