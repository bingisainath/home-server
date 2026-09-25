#!/bin/bash
# Install cloudflared and stand up a NEW tunnel for this laptop. Run as: sudo -E bash scripts/install-cloudflared.sh
#
# Deliberately does NOT touch the live hostnames. It creates a separate tunnel beside the phone's one,
# so the phone keeps serving bingisainath.com until you run the cutover yourself. Rollback stays trivial.
#
# Needs a Cloudflare login first (as your normal user, not root):
#     cloudflared tunnel login
# which drops ~/.cloudflared/cert.pem. Re-running this script is safe.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TUNNEL_NAME=${TUNNEL_NAME:-home-server}
USER_=${SUDO_USER:?run with sudo}
CERT=/home/$USER_/.cloudflared/cert.pem

# --- cloudflared from Cloudflare's own apt repo, so it updates with the system ---
if ! command -v cloudflared >/dev/null; then
  echo "== installing cloudflared"
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    >/etc/apt/sources.list.d/cloudflared.list
  apt-get update -qq
  apt-get install -y cloudflared
fi
cloudflared --version

[ -f "$CERT" ] || { echo "No Cloudflare login found at $CERT. Run (as $USER_, not root):  cloudflared tunnel login"; exit 1; }

# --- a dedicated unprivileged account to run the tunnel ---
id -u cloudflared >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin cloudflared
install -d -o root -g cloudflared -m 0750 /etc/cloudflared

# --- create the tunnel (idempotent: reuse it if it already exists) ---
# `cloudflared tunnel list` prints columns: ID  NAME  CREATED  CONNECTIONS.
# Parsed with awk rather than node: node lives in the user's nvm dir and isn't on root's PATH.
tunnel_id() { sudo -u "$USER_" cloudflared tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$2==n {print $1; exit}'; }
ID=$(tunnel_id || true)
if [ -z "$ID" ]; then
  echo "== creating tunnel '$TUNNEL_NAME'"
  sudo -u "$USER_" cloudflared tunnel create "$TUNNEL_NAME"
  ID=$(tunnel_id || true)
fi
[ -n "$ID" ] || { echo "could not determine the tunnel id"; exit 1; }
echo "== tunnel: $TUNNEL_NAME  id: $ID"

# --- credentials + config into /etc/cloudflared, readable only by the service account ---
install -o root -g cloudflared -m 0640 "/home/$USER_/.cloudflared/$ID.json" "/etc/cloudflared/$ID.json"
sed "s/<TUNNEL_ID>/$ID/g" "$ROOT/cloudflared/config.yml" >/etc/cloudflared/config.yml
chown root:cloudflared /etc/cloudflared/config.yml
chmod 0640 /etc/cloudflared/config.yml
cloudflared --config /etc/cloudflared/config.yml tunnel ingress validate

install -m 0644 "$ROOT/cloudflared/cloudflared.service" /etc/systemd/system/cloudflared.service
systemctl daemon-reload
systemctl enable --now cloudflared
sleep 5
systemctl is-active cloudflared

cat <<MSG

cloudflared is running and connected to Cloudflare, but NO public hostname points at it yet:
bingisainath.com and drive.bingisainath.com are still served by the phone.

Tunnel id: $ID

Next: docs/phase4-cutover.md — test on a spare hostname first, then cut the real ones over.
MSG
