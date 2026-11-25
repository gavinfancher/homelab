#!/usr/bin/env bash
# Install Caddy on the proxy VM, swapped for a build that includes the Cloudflare
# DNS plugin.
#
#   caddy/install-caddy.sh                     # ubuntu@10.0.4.61
#   PROXY=me@10.0.4.31 caddy/install-caddy.sh  # some other user/host
#
# Run from the Mac. Needs a Debian/Ubuntu VM you can ssh into with passwordless sudo
# (the default on Ubuntu cloud images).
#
# Stock Caddy has no DNS providers, so it can't do DNS-01. This installs the apt
# package anyway (for the systemd unit, the caddy user and the dirs), then puts a
# custom binary in front of it the way Caddy's docs describe: dpkg-divert moves the
# packaged binary aside so apt upgrades don't overwrite the custom one. Afterwards
# `caddy upgrade` updates it and keeps the plugin. Safe to run again.
set -euo pipefail

PROXY=${PROXY:-ubuntu@10.0.4.61}

ssh "$PROXY" sudo bash -s <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# 1. Caddy's apt repo and the package.
if ! dpkg -s caddy >/dev/null 2>&1; then
  apt-get update -q
  apt-get install -yq curl gpg debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key |
    gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    -o /etc/apt/sources.list.d/caddy-stable.list
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q
  apt-get install -yq caddy
fi

# 2. The custom build, from Caddy's build server, with caddy-dns/cloudflare compiled in.
if ! caddy list-modules 2>/dev/null | grep -q '^dns.providers.cloudflare$'; then
  arch=$(dpkg --print-architecture)
  curl -fsSL -o /usr/bin/caddy.custom \
    "https://caddyserver.com/api/download?os=linux&arch=$arch&p=github.com%2Fcaddy-dns%2Fcloudflare"
  chmod 755 /usr/bin/caddy.custom
  dpkg-divert --list /usr/bin/caddy | grep -q caddy.default ||
    dpkg-divert --divert /usr/bin/caddy.default --rename /usr/bin/caddy
  update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10
  update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.custom 50
  systemctl restart caddy
fi

caddy version
caddy list-modules | grep '^dns.providers.cloudflare$'
REMOTE

echo "Caddy is installed. Next: caddy/set-token.sh (you run it, it asks for the token)."
