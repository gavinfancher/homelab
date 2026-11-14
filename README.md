# homelab

The base layer of my homelab: the Proxmox host and the small pieces of infrastructure around it.

The rest lives in its own repos:

- [homecloud](https://github.com/gavinfancher/homecloud): a web page that provisions VMs on the Proxmox host
- [homek8s](https://github.com/gavinfancher/homek8s): the k3s cluster, its apps, and `*.k8s.ad.gavinf.com`
- ad-at-home: DC01 and the `ad.gavinf.com` AD / DNS / DHCP

## Network

| Thing | Address |
|---|---|
| LAN | 10.0.4.0/24, gateway 10.0.4.1 (UniFi) |
| Proxmox (`pve`) | 10.0.4.10, also a Tailscale subnet router for the LAN |
| k8s control plane / workers | 10.0.4.20 / .21-.23 |
| proxy (Caddy VM) | 10.0.4.30 |
| DC01 (AD, DNS for `ad.gavinf.com`) | 10.0.4.200 |

## Layout

```
caddy/    reverse proxy + Let's Encrypt wildcard for the non-k8s web UIs (*.ad.gavinf.com)
```

| Name | Goes to | TLS from |
|---|---|---|
| `pve-ui.ad.gavinf.com` | Proxmox UI, through Caddy | Caddy, `*.ad.gavinf.com` ([caddy/](caddy/README.md)) |
| `*.k8s.ad.gavinf.com` | Traefik on k8s-cp | cert-manager, `*.k8s.ad.gavinf.com` (homek8s) |
