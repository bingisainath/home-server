# Phase 4 — move the Cloudflare Tunnel to the laptop

Moves `bingisainath.com`, `www.bingisainath.com` and `drive.bingisainath.com` from the phone's tunnel to
a new tunnel on this laptop, with the phone left running the whole time as a one-command rollback.

## What is there now

| | Phone (live today) | Laptop (after this phase) |
|---|---|---|
| Tunnel | the phone's named tunnel | new tunnel, e.g. `home-server` |
| Transport | pinned `http2` (carrier blocks UDP 7844) | `auto` — prefers QUIC, falls back by itself |
| Routing | each hostname → its own local port (`:3000`, `:8000`) | every hostname → nginx `:80`, which routes by `Host` |
| Data | 410 files, 2.7 GB, 184 KB database | empty until the migration below |

The routing change is the point of the move: upload limits, caching, header trust and TLS behaviour end up
in one reviewed config instead of being spread across services.

## Order matters

Data first, then tunnel, then DNS. Cutting DNS over before migrating would show visitors an empty drive
and split new uploads away from the old ones.

---

## 1. Migrate the data (no downtime yet)

```bash
cd ~/github.com/home-server
bash scripts/migrate-from-phone.sh presync
```

Copies 3.0 GB while the phone keeps serving. Re-runnable — each run copies only what changed. Plug the USB
cable in for this; rsync sustained 8–9 MB/s over it for this mix of 410 files (the 26 MB/s measured earlier
was a single large file, without rsync's per-file overhead).

Verify the copy by comparing both ends rather than trusting the exit code:

```bash
ssh -p <port> -i <key> root@<phone> 'find /root/cloud-storage/files -type f -not -path "*/.cloud-drive-tmp/*" -printf "%s\n" | awk "{s+=\$1} END {print s}"'
find /srv/pocket/files -type f -not -path '*/.cloud-drive-tmp/*' -printf '%s\n' | awk '{s+=$1} END {print s}'
```

The totals should match, except for anything you uploaded to the laptop while testing.

## 2. Log in to Cloudflare and create the tunnel

One interactive step, in a browser, as your normal user:

```bash
cloudflared tunnel login          # pick the bingisainath.com zone
```

If `cloudflared` isn't installed yet, the next command installs it; run the login again afterwards.

```bash
sudo -E bash scripts/install-cloudflared.sh
```

Creates the tunnel, installs credentials and config into `/etc/cloudflared`, and starts it under a
dedicated unprivileged `cloudflared` account. **No hostname points at it yet** — the phone is still live.
Note the tunnel id it prints.

## 3. Prove it works on a spare hostname first

This is the step that makes the cutover boring. Put a marker on this laptop so there is no doubt which
machine answered:

```bash
echo "laptop-$(date -u +%FT%TZ)" | sudo tee /var/www/portfolio/origin-check.txt
cloudflared tunnel route dns home-server laptop-test.bingisainath.com
```

`route dns` creates a new proxied CNAME to the tunnel; it does not touch existing records.

Add the test hostname to the drive's `server_name` so nginx recognises it, then check it publicly:

```bash
sudo sed -i 's/server_name drive.bingisainath.com drive.test;/server_name drive.bingisainath.com drive.test laptop-test.bingisainath.com;/' /etc/nginx/conf.d/pocket.conf
sudo nginx -t && sudo systemctl reload nginx
bash scripts/test-tunnel.sh laptop-test.bingisainath.com
```

Expect all checks to pass, including `origin is this laptop`. If anything fails, stop here: nothing public
has changed yet.

## 4. Final migration (short downtime, phone app stopped)

On the phone, in **Termux** (not the Debian container):

```bash
sv down deploy           # FIRST: otherwise it redeploys and restarts the app behind your back
sv down cloud-drive
```

Then on the laptop:

```bash
bash scripts/migrate-from-phone.sh final
cd ~/github.com/pocket-drive && npm start
```

Leftover test uploads: any file you put on the laptop during Phases 1–3 is still in `/srv/pocket/files`, but
the incoming database knows nothing about it, so the scanner will index it as a new file in the drive root.
Delete those first if you do not want them (`ls -lt /srv/pocket/files | head`).

Check the startup line: `Index synced with disk` should be about `+0 ~0 -0`, or `+n` where n is the number of
leftover test files you chose to keep. A large negative number means
files are missing — re-run the file copy before letting anyone in. Then open <http://localhost:3000> and
confirm your real files and folders are there.

## 5. Cut the real hostnames over

```bash
cloudflared tunnel route dns --overwrite-dns home-server bingisainath.com
cloudflared tunnel route dns --overwrite-dns home-server www.bingisainath.com
cloudflared tunnel route dns --overwrite-dns home-server drive.bingisainath.com
```

`--overwrite-dns` is required: these CNAMEs already exist and point at the phone's tunnel. The records are
proxied, so the Cloudflare edge picks up the change in seconds.

```bash
bash scripts/test-tunnel.sh bingisainath.com
bash scripts/test-tunnel.sh drive.bingisainath.com
```

Then in a browser: sign in with Google on `https://drive.bingisainath.com` (this is the first time the real
OAuth redirect is exercised — `PUBLIC_ORIGINS` already lists this origin), open a photo, play a video, and
upload something large enough to be chunked (>16 MB).

## Rollback

Point the three records back at the phone's tunnel and restart its app:

```bash
# <OLD_TUNNEL> = the phone's tunnel, from: cloudflared tunnel list
cloudflared tunnel route dns --overwrite-dns <OLD_TUNNEL> bingisainath.com
cloudflared tunnel route dns --overwrite-dns <OLD_TUNNEL> www.bingisainath.com
cloudflared tunnel route dns --overwrite-dns <OLD_TUNNEL> drive.bingisainath.com
# on the phone, in Termux:
sv up cloud-drive
```

Anything uploaded to the laptop after cutover stays on the laptop; the phone's copy is whatever the last
migration captured. Roll back promptly, or expect to reconcile by hand.

## Afterwards

- Remove the test hostname and marker once you are happy: delete the `laptop-test` DNS record,
  the `origin-check.txt` file, and the `drive.test` / `portfolio.test` names from `nginx/pocket.conf`.
- Leave the phone's tunnel and app **stopped but installed** until Phase 5 decommissions them properly.
- The phone's `deploy` service must stay down: it would otherwise pull `main`, rebuild and restart a second
  live instance of the drive against its own copy of the data.
