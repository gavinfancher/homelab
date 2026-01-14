#!/usr/bin/env bash

curl -fsSL https://tailscale.com/install.sh | sh

sudo tailscale set --operator="$USER"

# Use env vars if set, otherwise prompt
if [[ -z "$TS_HOSTNAME" ]]; then
  read -p "enter host nickname: " TS_HOSTNAME
fi

if [[ -z "$TS_KEY" ]]; then
  read -p "enter linux setup key: " TS_KEY
fi

sudo tailscale up \
  --reset \
  --authkey="$TS_KEY" \
  --hostname="$TS_HOSTNAME"

sudo tailscale set --auto-update=true

echo "tailscale is up authenticated and your configuration is set"
