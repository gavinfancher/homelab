# iperf3

Command-line network speed tests between my devices and the homelab, run from the terminal. There are iperf3 servers in two
places: on the Proxmox host itself, and in a pod on each k8s worker. Testing both shows where any slowdown comes from.

```
Mac ──► pve NIC ──► pve host                                      iperf3 -c 10.0.4.10   the baseline
Mac ──► pve NIC ──► bridge ──► k8s VM ──► pod network ──► pod     iperf3 -c 10.0.4.22   k8s-w2
                                                                  iperf3 -c 10.0.4.23   k8s-w3
```

- **pve (10.0.4.10)** measures the physical link, plus Wi-Fi or the switch on your side. Anything running on pve, or in
  a VM on it, gets at most this.
- **a k8s worker (10.0.4.22 / .23)** measures the path k8s apps are actually reached by: the same link, then the
  VM's virtual NIC, then flannel into a pod. If it's well under the pve number, the loss is inside the homelab, not
  on the network.
- It doesn't go through Caddy or Traefik. iperf3 isn't HTTP, so it can't. For the path a web UI takes, use the
  browser test at `speed.ui.gavinf.com` (`../speedtest/`).
- It doesn't test the internet connection.

| | where | what |
|---|---|---|
| pve server | `iperf3` Debian package on the host, systemd unit `iperf3.service` | enabled at boot, runs as user `iperf3`, `--server --interval 0` |
| k8s servers | `iperf3.yaml`: namespace `iperf3`, a DaemonSet (one pod per worker), image `mlabbe/iperf3:3.19.1-r1` | each pod published on its node's IP via `hostPort` 5201, TCP and UDP |
| client | your Mac: `brew install iperf3` | |

Not on `k8s-cp`: its `CriticalAddonsOnly` taint keeps app pods off it, and no app runs there to test.

## setup

**pve** (already done; it was there by 2026-11-26):

```sh
ssh root@pve.ad.gavinf.com
apt install iperf3              # "start Iperf3 as a daemon automatically?" → Yes
systemctl status iperf3         # active (running)
```

**k8s** (from this repo, applied by hand like the speedtest, not Argo CD):

```sh
kubectl apply -f iperf3/iperf3.yaml
kubectl -n iperf3 get pods -o wide        # one Running on k8s-w2, one on k8s-w3
```

**Mac:**

```sh
brew install iperf3
```

## running tests

```sh
iperf3 -c 10.0.4.10            # Mac → pve: your upload, 10 seconds
iperf3 -c 10.0.4.10 -R         # pve → Mac: your download (-R reverses the direction)
iperf3 -c 10.0.4.10 -P 4       # 4 parallel streams: fills a fast link one stream can't
iperf3 -c 10.0.4.10 -u -b 0    # UDP, unlimited rate: shows jitter and packet loss
iperf3 -c 10.0.4.10 -t 30      # run 30 seconds instead of 10
```

Swap in `10.0.4.22` or `10.0.4.23` for a k8s worker. A quick full comparison, both directions:

```sh
for h in 10.0.4.10 10.0.4.22 10.0.4.23; do
  echo "== $h";
  iperf3 -c $h    | grep receiver
  iperf3 -c $h -R | grep receiver
done
```

**Between k8s nodes** (pod to pod, no Mac involved: the path when one app's pod calls another on a different node):

```sh
kubectl -n iperf3 get pods -o wide                          # note the pods' IPs (10.42.x.x)
kubectl -n iperf3 exec <pod on k8s-w2> -- iperf3 -c <IP of the pod on k8s-w3>
```

## reading the results

The line that matters is the `receiver` one at the bottom: the average over the whole test.

```
[ ID] Interval           Transfer     Bitrate         Retr
[  5]   0.00-10.00  sec  1.09 GBytes   939 Mbits/sec    0             sender
[  5]   0.00-10.01  sec  1.09 GBytes   936 Mbits/sec                  receiver
```

- **~940 Mbits/sec** is a full 1 Gbps link. That's the ceiling for wired tests; packet overhead takes the rest.
- **Retr** (retransmits) near 0 is healthy. Hundreds mean packets are being dropped somewhere.
- **pve vs a worker**: within a few percent is normal. Much lower on the worker points at the VM's NIC settings
  (should be virtio) or the pod network.
- **On Wi-Fi** you're mostly measuring the Wi-Fi. Do one test wired for a baseline before blaming the homelab.
- **Over Tailscale** (away from home) you're measuring the tunnel and your internet connection, not the LAN.
- **UDP** (`-u`): look at `Jitter` and `Lost/Total` on the receiver line. Loss of a fraction of a percent is fine.

## good to know

- **No authentication.** Anyone who can reach 5201 can run a test. Fine on the LAN and tailnet; never forward 5201
  on the router.
- **One test at a time per server.** A second client gets `the server is busy running a test` until the first ends.
- **No CPU limit on the pods, on purpose:** a limit would throttle the test, and you'd be measuring the limit.
- Remove the k8s servers: `kubectl delete -f iperf3/iperf3.yaml`. Stop the pve one: `systemctl disable --now iperf3`.
