# pve

Small fixes for the Proxmox host (`pve`, 10.0.4.10), run from the Mac over ssh as root.

## `no-subscription-nag.sh`: no more "No valid subscription" pop-up

```sh
pve/no-subscription-nag.sh           # install + apply (restarts pveproxy; hard-refresh the browser after)
pve/no-subscription-nag.sh --check   # patched? hook installed? changes nothing
pve/no-subscription-nag.sh --undo    # reinstall the stock file, remove the hook
```

**What it changes:** one line in `/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js`. The UI's
`checked_command` asks the server for the subscription status and shows the pop-up when it isn't `active`; the
pop-up's OK then runs the action you clicked. The script makes that test `false`, so the UI takes its normal
branch and runs the action straight away.

- **Not** the usual "delete the pop-up" one-liner: those also stop actions that go through the same check from
  running (Updates → Refresh is one).
- **Only that one spot.** The Repositories page uses the same test to advise on update sources; it's left alone
  so it doesn't claim a subscription the host doesn't have.
- **Survives updates.** A Proxmox update replaces the file, so the script installs
  `/usr/local/sbin/pve-no-subscription-nag` and an apt hook (`/etc/apt/apt.conf.d/99-no-subscription-nag`) that
  re-runs it after every package install. If a future version changes the code, the hook prints a warning and
  patches nothing; it never fails an `apt` run. `--check` then shows "patched: no".
- **Backups:** the stock file is kept as `proxmoxlib.js.orig-<toolkit version>` next to it.
- **Repos untouched.** The host already uses `pve-no-subscription` with the enterprise repos disabled, so `apt`
  works without a subscription; this only affects the pop-up.

Tested on Proxmox VE 9.3.1 (proxmox-widget-toolkit 5.2.23).
