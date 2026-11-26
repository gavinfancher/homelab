#!/usr/bin/env bash
# Remove Proxmox's "No valid subscription" pop-up, and keep it removed across updates.
# Run from the Mac:   pve/no-subscription-nag.sh          (install + apply)
#                     pve/no-subscription-nag.sh --undo   (stock file back, hook removed)
#                     pve/no-subscription-nag.sh --check  (is it patched? changes nothing)
# Another host:       PVE=root@10.0.4.10 pve/no-subscription-nag.sh
#
# How: the web UI asks the server for the subscription status and, if it isn't "active", shows the pop-up;
# its OK button then runs the action you clicked (Updates > Refresh goes through the same check). Deleting the
# pop-up, as many one-liners do, also skips those actions. This instead makes the "is it active?" test false,
# so the UI takes its normal branch and runs the action directly.
#
# Proxmox updates overwrite the file, so an apt hook re-applies the patch after every package install. The hook
# never fails apt: if a future version changes the code, it only prints a warning. The apt repos are untouched
# (the host already uses pve-no-subscription).
set -euo pipefail

PVE=${PVE:-root@10.0.4.10}
mode=${1:-install}

case "$mode" in
  install|--check|--undo) ;;
  *) echo "usage: $0 [--check|--undo]" >&2; exit 2 ;;
esac

ssh "$PVE" MODE="$mode" bash -s <<'REMOTE'
set -euo pipefail
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
PATCHER=/usr/local/sbin/pve-no-subscription-nag
HOOK=/etc/apt/apt.conf.d/99-no-subscription-nag

if [ "$MODE" = "--undo" ]; then
  rm -f "$HOOK" "$PATCHER"
  apt-get install -y --reinstall -qq proxmox-widget-toolkit >/dev/null
  systemctl restart pveproxy
  grep -q "nag removed" "$JS" && { echo "still patched?" >&2; exit 1; }
  echo "undone: stock proxmoxlib.js reinstalled, apt hook removed. Hard-refresh the browser."
  exit 0
fi

if [ "$MODE" = "--check" ]; then
  echo "proxmox-widget-toolkit $(dpkg-query -W -f='${Version}' proxmox-widget-toolkit)"
  grep -q "nag removed" "$JS" && echo "patched: yes" || echo "patched: no"
  [ -f "$HOOK" ] && echo "apt hook: installed" || echo "apt hook: missing"
  exit 0
fi

# The patcher lives on the host, so the apt hook can run it without the Mac.
cat > "$PATCHER" <<'PATCH'
#!/bin/sh
# Installed by homelab pve/no-subscription-nag.sh. Safe to run any number of times.
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
TEST="res.data.status.toLowerCase() !== 'active'"
grep -q "nag removed" "$JS" && exit 0                     # already patched
if ! grep -qF "$TEST" "$JS"; then
  echo "pve-no-subscription-nag: subscription check not found in $JS; Proxmox changed it, nothing patched" >&2
  exit 0                                                  # never fail apt
fi
ver=$(dpkg-query -W -f='${Version}' proxmox-widget-toolkit 2>/dev/null || echo unknown)
cp -p "$JS" "$JS.orig-$ver"                               # the stock file, per toolkit version
# Only inside checked_command (from its start to its pop-up). The Repositories page uses the same test to
# advise on update sources; patching that one too would make it claim an active subscription.
sed -i "/checked_command: function/,/Ext.Msg.show/ s|res.data.status.toLowerCase() !== 'active'|false /* nag removed: homelab pve/no-subscription-nag.sh */|" "$JS"
grep -q "nag removed" "$JS" && echo "pve-no-subscription-nag: patched proxmoxlib.js ($ver)"
PATCH
chmod 0755 "$PATCHER"

# Re-apply after every apt/dpkg run (widget-toolkit updates replace the file).
cat > "$HOOK" <<HOOKEOF
// Installed by homelab pve/no-subscription-nag.sh: keep the subscription pop-up removed after updates.
DPkg::Post-Invoke { "$PATCHER || true"; };
HOOKEOF

"$PATCHER"
grep -q "nag removed" "$JS" || { echo "not patched (see the warning above)" >&2; exit 1; }
systemctl restart pveproxy   # serve the patched file now
echo "done: patched, apt hook installed. Hard-refresh the browser (Cmd+Shift+R) or log in again."
REMOTE
