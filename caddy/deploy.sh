#!/usr/bin/env bash
# Push the Caddyfile and the systemd drop-in to the proxy VM, check the config, and reload.
#
#   caddy/deploy.sh                     # ubuntu@10.0.4.30
#   PROXY=me@10.0.4.31 caddy/deploy.sh
#
# Run from the Mac after any Caddyfile change. A Caddyfile that fails `caddy validate`
# is never swapped in, so the running config is left alone. A reload is graceful (no
# dropped connections); a restart only happens when the drop-in changed, since
# systemd only reads environment at start.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
PROXY=${PROXY:-ubuntu@10.0.4.30}

ssh "$PROXY" sudo test -s /etc/caddy/cloudflare.env ||
  { echo "no token on the proxy yet; run caddy/set-token.sh first" >&2; exit 1; }

# 1. Copy both files in under .new names.
ssh "$PROXY" sudo sh -c "'cat > /etc/caddy/Caddyfile.new'" < "$here/Caddyfile"
ssh "$PROXY" sudo sh -c \
  "'mkdir -p /etc/systemd/system/caddy.service.d && cat > /etc/systemd/system/caddy.service.d/cloudflare.conf.new'" \
  < "$here/systemd/caddy.service.d/cloudflare.conf"

# 2. Validate, swap in, then reload or restart.
ssh "$PROXY" sudo bash -s <<'REMOTE'
set -euo pipefail
cd /etc/caddy
caddy validate --adapter caddyfile --config Caddyfile.new --envfile cloudflare.env
mv Caddyfile.new Caddyfile

d=/etc/systemd/system/caddy.service.d/cloudflare.conf
restart=no
if ! cmp -s "$d.new" "$d"; then restart=yes; fi
mv "$d.new" "$d"
systemctl daemon-reload
systemctl is-active -q caddy || restart=yes

if [ "$restart" = yes ]; then systemctl restart caddy; else systemctl reload caddy; fi
echo "caddy: $(systemctl is-active caddy) ($([ "$restart" = yes ] && echo restarted || echo reloaded))"
REMOTE

echo "Watch the cert: ssh $PROXY sudo journalctl -u caddy -f"
