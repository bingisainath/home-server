#!/bin/bash
# Install nginx, publish the portfolio build, install the routing config. Run as: sudo bash scripts/install-nginx.sh
# PORTFOLIO_DIST: path to the portfolio's built dist/ (default: ~/github.com/sainathPortfolio/dist of the invoking user)
# Installs nginx, publishes the portfolio build, installs the routing config, validates, reloads.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIST=${PORTFOLIO_DIST:-/home/${SUDO_USER:?run with sudo}/github.com/sainathPortfolio/dist}

[ -f "$DIST/index.html" ] || { echo "no portfolio build at $DIST (run: npm run build in sainathPortfolio)"; exit 1; }

apt-get install -y nginx rsync gettext-base

install -d -o root -g root /var/www/portfolio
rsync -a --delete "$DIST"/ /var/www/portfolio/
chown -R root:root /var/www/portfolio

# Render the shared template for the host: the app runs on loopback here, not in a container.
DRIVE_UPSTREAM=${DRIVE_UPSTREAM:-127.0.0.1:3000} \
DRIVE_TRUSTED_PROXY=${DRIVE_TRUSTED_PROXY:-127.0.0.1/32} \
  envsubst '${DRIVE_UPSTREAM} ${DRIVE_TRUSTED_PROXY}' <"$ROOT/nginx/pocket.conf.template" >/etc/nginx/conf.d/pocket.conf
chmod 644 /etc/nginx/conf.d/pocket.conf
rm -f /etc/nginx/sites-enabled/default        # stock welcome site would otherwise catch port 80

nginx -t
systemctl enable nginx
systemctl reload nginx || systemctl restart nginx
echo "nginx is up: $(systemctl is-active nginx)"
