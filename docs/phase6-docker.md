# Phase 6 — the stack in containers

Same four pieces as Phases 1–4 (app, nginx, tunnel, data), packaged so the whole thing can be rebuilt
from the two repos plus a secrets directory.

## The rule that matters

**The host systemd services and the containers must never run at the same time.** Both open the same
SQLite database, and a second writer corrupts the first one's view of it. `scripts/stack.sh up` stops
and disables `pocket-drive`, `nginx` and `cloudflared` before starting containers; `down` reverses it.
Nothing else in this repo enforces that, so do not start containers with a bare `docker compose up`.

## What runs where

| Container | Image | Notes |
|---|---|---|
| `pocket-drive` | built from `pocket-drive/Dockerfile` | runs as uid 1000 so bind-mounted files keep their owner |
| `nginx` | `nginx:1.29.3-bookworm` | published on `127.0.0.1:80` only — the tunnel is the way in |
| `cloudflared` | `cloudflare/cloudflared:2026.9.3` | same tunnel id as the host setup, origin is `http://nginx:80` |

Every image is pinned. `latest` would mean a `docker compose pull` could change the runtime under a
working system with no record of what changed.

## Data and secrets

Bind mounts, not named volumes, so the data stays where Phases 1–5 put it and the host tooling
(backups, `du`, an ordinary `ls`) keeps working:

- `/srv/pocket/files` → `/files`
- `~/cloud-storage` → `/data` (SQLite, thumbnails, HLS streams)
- `/var/www/portfolio` → `/var/www/portfolio` (read-only)

`scripts/stack.sh prepare` collects secrets from the working host setup into `./secrets/` (git-ignored,
mode 600): the app's settings minus anything describing host paths or ports, the tunnel credentials, and
a cloudflared config rendered with the real tunnel id. Nothing secret is baked into an image layer.

## One nginx config, two ways of running it

`nginx/pocket.conf.template` is the single source of truth. `${DRIVE_UPSTREAM}` is the only difference:
`127.0.0.1:3000` on the host, `pocket-drive:3000` in compose. `NGINX_ENVSUBST_FILTER=DRIVE_` restricts
substitution to `DRIVE_*`, so nginx's own `$host`, `$scheme` and `$remote_addr` are left alone — without
it, an environment variable named `host` would silently rewrite the config.

`TRUST_PROXY` is `1` in compose rather than the host's `loopback`: nginx reaches the app from a container
IP, not 127.0.0.1, so "trust one proxy hop" is the equivalent setting.

## Usage

```bash
bash scripts/stack.sh prepare   # once, and again whenever the app's .env or the tunnel changes
bash scripts/stack.sh test      # throwaway stack on port 8099, temp data, no tunnel
bash scripts/stack.sh up        # stops host services, starts containers
bash scripts/stack.sh status
bash scripts/stack.sh down      # back to the host services
```

`test` builds the image and drives a real session through the containerised nginx: login, a 2 MB upload,
a byte-identical download, dotfiles blocked, unknown hosts dropped, files written as uid 1000, and
`ffmpeg`/`heif-dec` actually present in the image. It also diffs the two cloudflared configs so they
cannot drift apart.

## The trusted-proxy trap

The Phase 3 config trusted `X-Forwarded-Proto` and `CF-Connecting-IP` only from `127.0.0.1`, which is
right on the host: cloudflared sits beside nginx on loopback. In compose, cloudflared is a separate
container and reaches nginx across the bridge, so loopback never matches and two things break **silently**:

- session cookies lose their `Secure` flag
- `CF-Connecting-IP` is ignored, so every visitor looks like one address to the login rate limiter

Neither shows up as an error; the site just works, less safely. The trusted source is therefore a CIDR
(`${DRIVE_TRUSTED_PROXY}`) evaluated with `geo`, which understands ranges where `map` does not, and the
compose network's subnet is pinned so the value is knowable rather than whatever Docker's pool assigns.
`scripts/stack.sh test` asserts both directions so it cannot regress.

## Notes from building it

- The first version of that cookie test probed `/api/auth/google/start`, which 404s when OAuth is not
  configured — as it is not in a throwaway stack. It therefore never set a cookie, so one check failed
  for the wrong reason and its companion *passed* for the wrong reason. Both now use the password login,
  which sets the same cookie through the same code path with no OAuth needed.
- `cloudflared`'s image runs as uid 65532, which cannot read a 0600 credentials file owned by uid 1000.
  The container therefore runs as `1000:1000` rather than loosening permissions on a credential. This
  is invisible to `stack.sh test`, which deliberately runs no tunnel, so `stack.sh up` now verifies that
  cloudflared registered connections *and* that the public hostname returns 200 — local health alone
  passed happily while Cloudflare was serving 530.
- Ubuntu's `docker.io` has no `buildx`, so builds use the classic builder (`DOCKER_BUILDKIT=0`).
- nginx is pinned to `1.28.3-trixie`, the same version as the host's nginx, so host mode and container
  mode run identical code. (`1.29` exists only on trixie; there is no `1.29.3-bookworm`.)
- Debian bookworm ships libheif 1.15, whose binary is `heif-convert`; `heif-dec` arrived in 1.18. The
  image symlinks whichever exists to `heif-dec`, since the app calls it with arguments both accept, and
  the build fails if neither works — better than losing HEIC thumbnails silently at runtime.
