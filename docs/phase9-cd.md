# Continuous deployment

```bash
sudo install -m 644 systemd/pocket-deploy.service systemd/pocket-deploy.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now pocket-deploy.timer
journalctl -u pocket-deploy -f          # watch it work
```

Every five minutes `scripts/deploy.sh` asks whether `origin/main` moved and whether **that exact commit**
passed CI. When nothing changed the run is one `git fetch` and an exit.

## Why pull-based

The laptop has no inbound ports — the Cloudflare tunnel is outbound-only — so GitHub cannot reach in to
push a deploy. Opening a port, or running a self-hosted runner with repo credentials, would undo the main
security property of the tunnel setup. Polling costs one API call and a fetch.

## What a deploy does

1. **CI gate.** A commit whose checks are pending, failed, or absent is not deployed. A failed commit is
   reported once, not every five minutes.
2. **Path filter.** Only `backend/`, `frontend/`, `package*.json`, `Dockerfile` and `.dockerignore`
   justify a rebuild. A docs commit fast-forwards and leaves the running container alone.
3. **Database snapshot** through SQLite's backup API, keeping the last five, before anything changes.
4. **Tag the running image `:previous`**, so a rollback does not depend on a rebuild succeeding.
5. **Build, restart, then check health twice** — locally, and through the public URL. The tunnel is a
   separate failure domain from the app: the container can be perfectly healthy while nothing reaches it.
6. **On any failure: roll back** the image *and* the commit, confirm the site recovered, write
   `paused` with the reason, and stop deploying until a human removes that file.

## What it will not do

**Infrastructure is not auto-deployed.** Changes to this repo — compose, nginx, the tunnel — take effect
only when you run them. They can take the site down in ways a health check cannot undo (a wrong nginx
upstream still passes a container health check), and they are rare enough to be worth doing deliberately.

**It will not deploy a dirty or detached working tree**, or anything not on `main`.

## Verified

| Behaviour | Result |
|---|---|
| Refuses to deploy while CI is running | `CI still running for 1aa3a52` |
| Docs-only commit syncs without rebuilding | image id unchanged across the run |
| Real code change deploys | rebuilt and healthy in 15 s, public URL 200 throughout |

The rollback path has **not** been exercised against a genuinely broken release. Until it has, treat it as
designed-but-unproven: read `paused` and `build.log` in `~/.local/state/pocket-deploy` if a deploy fails.

## When something goes wrong

```bash
cat  ~/.local/state/pocket-deploy/paused        # why it stopped
tail ~/.local/state/pocket-deploy/build.log     # if the build failed
cat  ~/.local/state/pocket-deploy/history.log   # what deployed, and when
rm   ~/.local/state/pocket-deploy/paused        # resume, once it is fixed
```
