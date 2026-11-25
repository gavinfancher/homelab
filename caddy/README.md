## https for the non-k8s web UIs (`*.ui.gavinf.com`) with caddy + let's encrypt

> **status:** migrating. the Caddyfile now serves both `*.ui.gavinf.com` (new) and `*.ad.gavinf.com`
> (old, `pve-ui.ad.gavinf.com`), sharing one `tls` snippet; that's migration step 1. the DC01 zone,
> tailscale route and cleanup are a click-by-click checklist in ad-at-home `docs/ui-zone-https-gui.md`.

proxmox (and anything else with a web UI that isn't in k8s) gets a real, browser-trusted cert at a
name like `pve.ui.gavinf.com`, instead of `https://10.0.4.10:8006` and a self-signed warning.

one small VM runs caddy. it holds a single `*.ui.gavinf.com` wildcard from let's encrypt and reverse
proxies each name to its backend. k8s apps stay where they are: `*.k8s.ad.gavinf.com` is served by
traefik with cert-manager's cert (homek8s `docs/tls.md`).

### the idea: hosts and web UIs live in two different zones

| zone | what's in it | who owns the records |
|---|---|---|
| `ad.gavinf.com` | machines: AD's own records, hosts you ssh / rdp / psql to | DC01, AD, DHCP dynamic updates |
| `ui.gavinf.com` | web pages only. a single `*` A record pointing at caddy | DC01, static, no dynamic updates |

so `pve.ad.gavinf.com` is the host (ssh), and `pve.ui.gavinf.com` is its web UI. same short name,
and the zone says which one you mean. no `-ui` suffixes, and no CNAME per service.

### how it fits together

```
browser ── pve.ui.gavinf.com? ──► DC01 DNS, zone ui.gavinf.com: * A 10.0.4.61
   │
   └── https ──► caddy (VM "proxy", 10.0.4.61)  cert: *.ui.gavinf.com
                   ├─ pve.ui.gavinf.com    ──► https://10.0.4.10:8006 (self-signed, not verified)
                   ├─ proxy.ui.gavinf.com  ──► "ok" (tls smoke test)
                   └─ anything else        ──► connection closed

caddy ──(cloudflare api token)──► TXT _acme-challenge.ui.gavinf.com in cloudflare ──► let's encrypt checks it
```

- **why a separate zone and not more names in `ad.gavinf.com`:** a wildcard in `ad.gavinf.com` would
  sit next to AD's SRV / `_msdcs` / DC records and answer for any name AD didn't register. a zone that
  only holds web UIs can safely have a wildcard, and then the Caddyfile is the only list of services.
- **why `-DynamicUpdate None` on it:** nothing (DHCP clients, domain members) can register itself
  into the zone and fight the wildcard. devices keep registering their real hostnames in `ad.gavinf.com`.
- **why dns-01:** nothing here is reachable from the internet, and wildcards require it anyway. same
  reasoning as the k8s cert.
- **why its own token:** a separate cloudflare token from cert-manager's, so either can be revoked alone.
  it's scoped to the whole `gavinf.com` zone, so it already covers `_acme-challenge.ui.gavinf.com`.
- **the split dns gotcha, again:** DC01 is authoritative for `ui.gavinf.com` and never sees the public
  TXT record. `resolvers 1.1.1.1 8.8.8.8` in the Caddyfile makes caddy's propagation check ask public dns
  instead. without it, it waits forever (cert-manager did exactly this). it only affects the acme check;
  caddy still resolves backends through DC01 like everything else.
- **other `gavinf.com` names are unaffected:** DC01 is only authoritative for `ad.` and `ui.`; the
  public site and everything else still resolve through its forwarders.
- **why not the k8s ingress:** that would mean Service + EndpointSlice yaml per VM, and proxmox's UI
  would go down whenever the control plane reboots (ingress points at k8s-cp). the hypervisor's UI
  shouldn't depend on a cluster running on it.
- **why not a public record in cloudflare** (`*.ui.gavinf.com -> 10.0.4.61`, DNS only): it would skip
  the zone, the tailscale route and the `resolvers` gotcha, but it publishes an internal IP, and some
  routers' DNS rebinding protection drops public answers that point at private IPs. DC01 already does
  internal DNS, so it owns this too.

### naming

caddy only handles web traffic (80/443). ssh, postgres, rdp, smb never touch it, so `ad.gavinf.com`
records stay exactly as they are.

| kind of thing | `ad.gavinf.com` | `ui.gavinf.com` |
|---|---|---|
| no web UI | `postgres` A -> its IP | nothing |
| web UI only | its own hostname, if it registers one (`kvm01`) | `kvm` (covered by the wildcard) |
| host + web UI | `pve` A -> its IP | `pve` (covered by the wildcard) |

- always one level under `ui.gavinf.com` (`pve`, not `ui.pve`), so the one wildcard covers every
  name. a deeper name would need its own cert, and every cert's names show up in public certificate
  transparency logs; the wildcard only shows `*.ui.gavinf.com`.
- the backend in the Caddyfile must not be a `ui.gavinf.com` name, or caddy connects to itself. by IP
  is simplest, and keeps working when DC01 is down (DC01 is a VM on pve). the backend's `ad.gavinf.com`
  name (`kvm01.ad.gavinf.com:80`) is fine too, for things whose IP might move.

### files

| file | what |
|---|---|
| `Caddyfile` | the wildcard site, one `@name` / `handle` pair per service |
| `systemd/caddy.service.d/cloudflare.conf` | drop-in: `EnvironmentFile=/etc/caddy/cloudflare.env`, so caddy gets `CF_API_TOKEN` |
| `install-caddy.sh` | apt caddy, then swaps in a build with `caddy-dns/cloudflare` (dpkg-divert, so apt won't undo it) |
| `set-token.sh` | **run by me, not an agent.** hidden prompt, writes the token to `/etc/caddy/cloudflare.env` (root, 0600) |
| `deploy.sh` | pushes Caddyfile + drop-in, `caddy validate`, then reloads |

all three run from the mac over ssh, as `ubuntu@10.0.4.61` by default. a different user or IP:
`PROXY=me@10.0.4.31 caddy/deploy.sh`.

### steps

1. **the VM (by hand).** what it needs:
   - debian or ubuntu (ubuntu cloud image is fine). 1 vCPU, 1 GB RAM, 8 GB disk is plenty
   - a fixed IP, 10.0.4.61: static in the VM, or a DHCP reservation by MAC. if static, keep the DHCP
     server from leasing it (DC01: `Add-DhcpServerv4ExclusionRange -ScopeId 10.0.4.0 -StartRange 10.0.4.61 -EndRange 10.0.4.61`,
     or the equivalent in UniFi if UniFi is still handing out leases)
   - DNS = DC01 (10.0.4.200), so it resolves `ad.gavinf.com` names like everything else
   - my ssh key for the login user, and passwordless sudo (ubuntu cloud images do both)
   - start at boot (`--onboot 1`), since every UI behind it depends on it

   check: `ssh ubuntu@10.0.4.61 sudo true` works with no prompt.

2. **caddy.** `caddy/install-caddy.sh`. ends by printing `dns.providers.cloudflare`.

3. **cloudflare token.** my profile -> api tokens -> create token -> "edit zone DNS" template,
   zone resources = include / specific zone / `gavinf.com`. put it in the password manager, then:
   ```sh
   caddy/set-token.sh
   ```

4. **config.** optional: uncomment `acme_ca` (staging) in the Caddyfile for the first run. caddy also
   falls back to staging on its own after a failure, so this matters less than it did for cert-manager.
   ```sh
   caddy/deploy.sh
   ssh ubuntu@10.0.4.61 sudo journalctl -u caddy -f     # wait for "certificate obtained successfully"
   ```
   if staging was on, comment `acme_ca` back out and deploy again.

5. **check tls before touching DNS.** `--resolve` pins the name to the proxy's IP, so this works
   with no DNS records yet. no `-k`, so curl verifies like a browser does:
   ```sh
   curl -sS --resolve proxy.ui.gavinf.com:443:10.0.4.61 -w ' %{http_code} verify=%{ssl_verify_result}\n' https://proxy.ui.gavinf.com
   # ok 200 verify=0
   ```

6. **DNS (by hand, on DC01).** a new zone with one wildcard record. this is the only DNS change, ever:
   new UIs are covered by the wildcard.
   ```powershell
   Add-DnsServerPrimaryZone     -Name ui.gavinf.com -ReplicationScope Forest -DynamicUpdate None
   Add-DnsServerResourceRecordA -ZoneName ui.gavinf.com -Name "*" -IPv4Address 10.0.4.61
   ```
   check from DC01: `Resolve-DnsName anything.ui.gavinf.com` -> 10.0.4.61.

7. **tailscale split DNS.** admin console -> DNS -> nameservers -> add nameserver 10.0.4.200,
   restricted to domain `ui.gavinf.com` (next to the existing `ad.gavinf.com` route). LAN clients need
   nothing: DHCP already hands them DC01.

8. **test end to end** from the mac:
   ```sh
   curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' https://pve.ui.gavinf.com
   # 200 verify=0
   ```
   then open https://pve.ui.gavinf.com and try a VM console (noVNC uses websockets; caddy proxies them).

### adding a service

one change: a `@name` / `handle` pair in the Caddyfile, then `caddy/deploy.sh`. the wildcard record
already sends every `ui.gavinf.com` name to caddy, and the wildcard cert already covers it. a name
with no `handle` gets its connection closed.

example: pgAdmin for the existing postgres box. `postgres.ad.gavinf.com` stays exactly as it is, so
`psql` and ssh keep going direct. the UI is `postgres.ui.gavinf.com`:

```caddy
@postgres host postgres.ui.gavinf.com
handle @postgres {
    reverse_proxy 10.0.4.X:5050    # pgAdmin's IP and port
}
```

self-signed https backends also need `transport http { tls_insecure_skip_verify }`, like pve. then:

```sh
caddy/deploy.sh
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' https://postgres.ui.gavinf.com
```

caddy only carries web traffic, so its cert never covers `psql`, ssh or rdp. those keep whatever TLS
they have on their own.

### migration from `ad.gavinf.com`

what's live now: `*.ad.gavinf.com` site in the Caddyfile, `proxy` A + `pve-ui` CNAME in `ad.gavinf.com`.

1. Caddyfile: pull the `tls` block into a snippet, add a `*.ui.gavinf.com` site next to the existing
   one (`proxy` smoke test, `pve`, catch-all `abort`), both importing the snippet. deploy, wait for the
   second cert, check with `--resolve` (step 5).
2. DC01 zone + wildcard (step 6), tailscale route (step 7), test (step 8).
3. update bookmarks / links to `*.ui.gavinf.com`.
4. remove the old pieces: the `*.ad.gavinf.com` site from the Caddyfile, and the `pve-ui` CNAME and
   `proxy` A from `ad.gavinf.com` (the VM keeps its own hostname record if it registers one). caddy
   stops renewing the old cert on its own.

### good to know

- caddy renews ~30 days before expiry, by itself. check the cert it's serving:
  `echo | openssl s_client -connect 10.0.4.61:443 -servername pve.ui.gavinf.com 2>/dev/null | openssl x509 -noout -issuer -dates`
- certs and the acme account live in `/var/lib/caddy/.local/share/caddy` on the VM. rebuilding the VM
  just means a new cert on first start.
- upgrading caddy: `ssh ubuntu@10.0.4.61 sudo caddy upgrade` (re-downloads with the same plugins), then
  `sudo systemctl restart caddy`. `apt upgrade` updates the diverted stock binary, which isn't the one in use.
- rotating the token: make the new one, `caddy/set-token.sh`, then revoke the old one in cloudflare.
- the proxy is now a single point of failure for these UIs. proxmox is still at `https://10.0.4.10:8006`
  if the VM is down.
- stuck cert: `sudo journalctl -u caddy` on the VM. "timed out waiting for record to fully propagate"
  means the `resolvers` line is missing; a 403 / "invalid request headers" from cloudflare means the
  token is wrong or can't edit the `gavinf.com` zone.
