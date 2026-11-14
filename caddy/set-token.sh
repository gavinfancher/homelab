#!/usr/bin/env bash
# Store the Cloudflare API token on the proxy VM, in /etc/caddy/cloudflare.env (root, 0600).
#
#   caddy/set-token.sh                     # ubuntu@10.0.4.30
#   PROXY=me@10.0.4.31 caddy/set-token.sh
#
# Run this yourself, not through an agent: it reads the token with a hidden prompt,
# so it never lands in shell history, a command line, or a transcript. It goes to
# the VM over ssh's stdin. Also the way to rotate it.
#
# The token: Cloudflare -> My Profile -> API Tokens -> Create Token -> "Edit zone DNS",
# Zone Resources = Include / Specific zone / gavinf.com. Its own token, not
# cert-manager's, so either can be revoked alone.
set -euo pipefail

PROXY=${PROXY:-ubuntu@10.0.4.30}

read -rsp "Cloudflare API token: " token; echo
[ -n "$token" ] || { echo "empty token" >&2; exit 1; }

printf 'CF_API_TOKEN=%s\n' "$token" |
  ssh "$PROXY" sudo sh -c \
    "'umask 077; cat > /etc/caddy/cloudflare.env; chown root:root /etc/caddy/cloudflare.env'"
unset token

# Env vars are only read at start, so a running Caddy needs a restart to see a new token.
ssh "$PROXY" sudo sh -c \
  "'test -f /etc/systemd/system/caddy.service.d/cloudflare.conf && systemctl restart caddy || true'"

echo "Token stored. Next: caddy/deploy.sh"
