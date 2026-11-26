# homelab

The base layer of my homelab: the Proxmox host and the small pieces of infrastructure around it.

The rest lives in its own repos:

- [homecloud](https://github.com/gavinfancher/homecloud): a web page that provisions VMs on the Proxmox host
- [homek8s](https://github.com/gavinfancher/homek8s): the k3s cluster and its apps (served as `*.ui.gavinf.com` through Caddy)
- ad-at-home: DC01 and the `ad.gavinf.com` AD / DNS / DHCP

## Network

| Thing | Address |
|---|---|
| LAN | 10.0.4.0/24, gateway 10.0.4.1 (UniFi) |
| Proxmox (`pve`) | 10.0.4.10, also a Tailscale subnet router for the LAN |
| k8s control plane / workers | 10.0.4.20 / .22-.23 (k8s-w1 .21 retired) |
| proxy (Caddy VM) | 10.0.4.61 |
| DC01 (AD, DNS for `ad.gavinf.com`) | 10.0.4.200 |

## Layout

```
pve/      fixes for the Proxmox host itself (no-subscription pop-up)
caddy/    the front door for every web UI: *.ui.gavinf.com, Let's Encrypt wildcard, k8s apps handed to Traefik
speedtest/ speed.ui.gavinf.com, a browser speed test on homek8s (applied by hand)
iperf3/   command-line speed tests: a server on pve and one per k8s worker
```

| Name | Goes to | TLS from |
|---|---|---|
| `*.ad.gavinf.com` | hosts: AD, ssh, rdp, psql (DC01 zone) | each service's own |
| `*.ui.gavinf.com` | every web UI, through Caddy: `pve.ui`, and k8s apps (`nextup.ui`, `argocd.ui`, ...) handed to Traefik (DC01 zone, one `*` record) | Caddy, `*.ui.gavinf.com` ([caddy/](caddy/README.md)) |
