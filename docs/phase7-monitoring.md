# Phase 7 — Uptime Kuma and Netdata

```bash
bash scripts/monitoring.sh up | down | status | logs
```

| | URL (tailnet only) | What it answers |
|---|---|---|
| Uptime Kuma | `http://<tailscale-ip>:3001` | "is the site up, and tell me when it is not" |
| Netdata | `http://<tailscale-ip>:19999` | "why is the machine behaving like that" |

## Two deliberate choices

**A separate compose project from the app.** If monitoring lived in `compose.yaml`, `stack.sh down`
would stop alerting at exactly the moment you are most likely to break something. They share nothing
but the host.

**No Docker socket for Netdata.** Netdata needs container names to label its cgroup metrics, and the
usual recipe mounts `/var/run/docker.sock:ro`. That `:ro` is misleading: it makes the *socket file*
read-only, not the API behind it, so anything holding it can still create privileged containers — root
on this host, on an internet-facing machine. A `docker-socket-proxy` sits in between with `CONTAINERS=1`
and `POST=0`, which is enough for names and nothing else. Verified working: charts are labelled
`home-server-pocket-drive-1` and friends rather than raw cgroup ids.

## Reachability

Both bind to `${BIND_ADDR}` (the Tailscale address), so they are reachable from your tailnet and from
nowhere else. They are not behind the Cloudflare tunnel and have no public DNS.

Compose reads `.env` from the *compose file's* directory, not the repo root, so `scripts/monitoring.sh`
passes `--env-file` explicitly. Without it `BIND_ADDR` was ignored and both dashboards bound to
`127.0.0.1` — reachable only from the machine itself, which looks fine locally and fails from anywhere else.

## First run

Uptime Kuma has no admin account until you create one in the browser. Open it on the tailnet address,
set a username and password, then add these monitors — all HTTP(s), 60 s interval:

| Name | URL | Why |
|---|---|---|
| Drive (public) | `https://drive.bingisainath.com/api/health` | the whole path: Cloudflare → tunnel → nginx → app |
| Portfolio (public) | `https://bingisainath.com/` | same path, static side |

Two monitors is the right number here. A local-only check of the app would tell you whether the app or
the tunnel broke, but with one person running one machine that is a detail you can get from
`docker compose logs` once you are already looking. And the backup target's reachability is better
covered by Phase 8 alerting when a backup actually fails, which tests the real thing rather than a
proxy for it.

Then add a notification channel under Settings → Notifications and attach it to each monitor. Email via
Gmail needs an app password; Telegram or ntfy avoid SMTP entirely. Send a test before trusting it.

## The limit of self-hosted monitoring

If this laptop loses power or its network, Uptime Kuma goes down with the thing it was watching and no
alert is sent. Local monitoring tells you *what* broke once you are looking; it cannot tell you *that*
something broke when the whole machine is gone. Close that gap with one external check against
`https://drive.bingisainath.com/api/health` from a free third-party monitor.

## Netdata and netdata.cloud

The dashboard shows a "Sign in" button for netdata.cloud, Netdata's hosted SaaS. It is not needed and
not used: the agent is deliberately unclaimed, so no metrics leave this machine, and everything on
`:19999` works without an account. If that page refuses to load, that is netdata.cloud's own edge
blocking the browser — nothing to do with this setup.

## Netdata notes

- `netdata.conf` here is a minimal override; netdata supplies its own defaults for everything else.
- The battery collector is disabled: this laptop exposes no `power_now`, so it logged an error every
  second. Proc modules are toggled in `[plugin:proc]` **by path** (`/sys/class/power_supply = no`), not
  with `enabled = no` in the module's own section — that section only holds the module's settings.
