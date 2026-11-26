# speedtest

i want to have a speedtest at speed.ui.gavinf.com

**https://speed.ui.gavinf.com**: an [OpenSpeedTest](https://openspeedtest.com) page on homek8s. Open it on a
laptop or phone (on the LAN or over Tailscale) and it measures download, upload, ping and jitter between that
device and the homelab, entirely in the browser. It doesn't test the internet connection, and it keeps no history.

| | |
|---|---|
| Manifest | `speedtest.yaml`: Namespace, Deployment (1 replica), Service, Ingress, plus an upload-only Ingress with a Traefik buffering Middleware |
| Image | `openspeedtest/latest:v2.0.8` (static nginx), pinned |
| Reached at | `speed.ui.gavinf.com`, internal only (DC01 `ui.gavinf.com` zone → Caddy → Traefik, `*.ui` wildcard cert) |
| Managed by | hand, not Argo CD: it won't change |

```sh
kubectl apply -f speedtest/speedtest.yaml      # deploy (or update after editing)
kubectl -n speedtest get pods                  # 1/1 Running
kubectl delete -f speedtest/speedtest.yaml     # remove everything
```

## Reading the results

The test runs through the same path as every homelab web UI: device → Caddy (10.0.4.61) → Traefik → the
speedtest pod on a worker. So it measures the real path a homelab web app is reached by, including those
hops, and a wired LAN result can come in a little under the raw link speed. Over Tailscale it measures the tunnel.

## Why uploads are buffered

The first version showed uploads of ~19,500 Mbps next to a believable ~940 Mbps download. The page's upload test
POSTs to a static file; the image's nginx answers that immediately with `200 OK` (it maps the 405 to 200)
without reading the body. Connected directly, the browser keeps sending regardless; through Traefik, the early
`200` goes straight back, Traefik stops reading, and the browser's timer stops after a fraction of the data.

Fix: a Traefik `buffering` Middleware on `/upload` only (its own Ingress). Traefik now receives each upload in
full before forwarding it, so the timer covers the real device → cluster transfer. Downloads aren't buffered.
Uploads are held in Traefik's memory (up to 40 MB each), never on disk, so the disk isn't what gets measured.

## Hardening

Runs as the image's non-root `nginx` user (101) with a read-only root filesystem and no capabilities; nginx
only writes to two small in-memory volumes (`/tmp`, `/var/cache/nginx`). No CPU limit on purpose: throttling
would show up as a slow network.
