#!/bin/bash
set -e

while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  echo "Waiting for apt lock to be released..."
  sleep 5
done

sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get autoremove -y
sudo apt-get install -y \
  curl \
  btop \
  neovim \
  tmux \
  avahi-daemon

echo "basics installed successfully"
