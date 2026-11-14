## https for the non-k8s web UIs (`*.ad.gavinf.com`) with caddy + let's encrypt

proxmox (and anything else with a web UI that isn't in k8s) gets a real, browser-trusted cert at a
name like `pve-ui.ad.gavinf.com`, instead of `https://10.0.4.10:8006` and a self-signed warning.

one small VM runs caddy. it holds a single `*.ad.gavinf.com` wildcard from let's encrypt and reverse
proxies each name to its backend. k8s apps stay where they are: `*.k8s.ad.gavinf.com` is a different
name (a wildcard only covers one level), served by traefik with cert-manager's cert (homek8s `docs/tls.md`).

### how it fits together

```
browser ── pve-ui.ad.gavinf.com? ──► DC01 DNS: CNAME pve-ui -> proxy.ad.gavinf.com -> A 10.0.4.30
   │
   └── https ──► caddy (VM "proxy", 10.0.4.30)  cert: *.ad.gavinf.com
                   ├─ pve-ui.ad.gavinf.com ──► https://10.0.4.10:8006 (self-signed, not verified)
                   ├─ proxy.ad.gavinf.com  ──► "ok" (tls smoke test)
                   └─ anything else        ──► connection closed

caddy ──(cloudflare api token)──► TXT _acme-challenge.ad.gavinf.com in cloudflare ──► let's encrypt checks it
```

- **why dns-01:** nothing here is reachable from the internet, and wildcards require it anyway. same
  reasoning as the k8s cert.
- **why its own token:** a separate cloudflare token from cert-manager's, so either can be revoked alone.
- **the split dns gotcha, again:** the VM resolves through DC01, which owns `ad.gavinf.com` and never
  sees the public TXT record. `resolvers 1.1.1.1 8.8.8.8` in the Caddyfile makes caddy's propagation
  check ask public dns instead. without it, it waits forever (cert-manager did exactly this). it only
  affects the acme check; caddy still resolves backends through DC01 like everything else.
- **why not the k8s ingress:** that would mean Service + EndpointSlice yaml per VM, and proxmox's UI
  would go down whenever the control plane reboots (ingress points at k8s-cp). the hypervisor's UI
  shouldn't depend on a cluster running on it.

### naming

caddy only handles web traffic (80/443). ssh, postgres, rdp, smb never touch it, so most DNS records
stay exactly as they are. a name has one answer for every protocol, though, so a host you both ssh to
and browse to needs two names:

| kind of thing | DNS on DC01 | example |
|---|---|---|
| no web UI | `host` A -> its IP (unchanged) | `postgres.ad.gavinf.com` |
| web UI only | `name` CNAME -> `proxy` | `kvm.ad.gavinf.com` |
| host + web UI | `host` A -> its IP, plus `host-ui` CNAME -> `proxy` | `pve` (ssh) + `pve-ui` (browser) |

- always one level under `ad.gavinf.com` (`pve-ui`, not `ui.pve`), so the one wildcard covers every
  name. a deeper name would need its own cert, and every cert's names show up in public certificate
  transparency logs; the wildcard only shows `*.ad.gavinf.com`.
- the backend in the Caddyfile must not be a name that points back at the proxy, or caddy connects
  to itself. by IP is simplest, and keeps working when DC01 is down (DC01 is a VM on pve). a backend's
  own A record (`kvm01.ad.gavinf.com:80`) is fine too, for things whose IP might move.
- a web-UI-only device that registers its own hostname in DNS (DHCP dynamic updates) would fight the
  CNAME, so give the device itself a different hostname (`kvm01`).

### files

| file | what |
|---|---|
| `Caddyfile` | the wildcard site, one `@name` / `handle` pair per service |
| `systemd/caddy.service.d/cloudflare.conf` | drop-in: `EnvironmentFile=/etc/caddy/cloudflare.env`, so caddy gets `CF_API_TOKEN` |
| `install-caddy.sh` | apt caddy, then swaps in a build with `caddy-dns/cloudflare` (dpkg-divert, so apt won't undo it) |
| `set-token.sh` | **run by me, not an agent.** hidden prompt, writes the token to `/etc/caddy/cloudflare.env` (root, 0600) |
| `deploy.sh` | pushes Caddyfile + drop-in, `caddy validate`, then reloads |

all three run from the mac over ssh, as `ubuntu@10.0.4.30` by default. a different user or IP:
`PROXY=me@10.0.4.31 caddy/deploy.sh`.

### steps

1. **the VM (by hand).** what it needs:
   - debian or ubuntu (ubuntu cloud image is fine). 1 vCPU, 1 GB RAM, 8 GB disk is plenty
   - a fixed IP, 10.0.4.30: static in the VM, or a DHCP reservation by MAC. if static, keep the DHCP
     server from leasing it (DC01: `Add-DhcpServerv4ExclusionRange -ScopeId 10.0.4.0 -StartRange 10.0.4.30 -EndRange 10.0.4.30`,
     or the equivalent in UniFi if UniFi is still handing out leases)
   - DNS = DC01 (10.0.4.200), so it resolves `ad.gavinf.com` names like everything else
   - my ssh key for the login user, and passwordless sudo (ubuntu cloud images do both)
   - start at boot (`--onboot 1`), since every UI behind it depends on it

   check: `ssh ubuntu@10.0.4.30 sudo true` works with no prompt.

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
   ssh ubuntu@10.0.4.30 sudo journalctl -u caddy -f     # wait for "certificate obtained successfully"
   ```
   if staging was on, comment `acme_ca` back out and deploy again.

5. **check tls before touching DNS.** `--resolve` pins the name to the proxy's IP, so this works
   with no DNS records yet. no `-k`, so curl verifies like a browser does:
   ```sh
   curl -sS --resolve proxy.ad.gavinf.com:443:10.0.4.30 -w ' %{http_code} verify=%{ssl_verify_result}\n' https://proxy.ad.gavinf.com
   # ok 200 verify=0
   ```

6. **DNS (by hand, on DC01).** one A record for the proxy, a CNAME per UI. `pve`'s own record, if it
   has one, stays as it is:
   ```powershell
   Add-DnsServerResourceRecordA     -ZoneName ad.gavinf.com -Name proxy  -IPv4Address 10.0.4.30
   Add-DnsServerResourceRecordCName -ZoneName ad.gavinf.com -Name pve-ui -HostNameAlias proxy.ad.gavinf.com
   ```
   **don't** add a `*` record to `ad.gavinf.com`: the zone holds AD's own records, and per-name CNAMEs
   keep it explicit.

7. **test end to end** from the mac (tailscale sends `ad.gavinf.com` lookups to DC01):
   ```sh
   curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' https://pve-ui.ad.gavinf.com
   # 200 verify=0
   ```
   then open https://pve-ui.ad.gavinf.com and try a VM console (noVNC uses websockets; caddy proxies them).

### adding a service

a UI behind caddy takes two changes, one in each place, and each does a different half:

- **DC01 (DNS):** where the name goes. the CNAME sends the browser to the proxy.
- **the Caddyfile:** what caddy does when that name arrives. the `@name` / `handle` pair says which
  backend and port to proxy to.

both are needed. DNS only: the request reaches caddy, nothing matches, and it closes the connection.
Caddyfile only: nothing ever sends the browser to caddy.

example: pgAdmin for the existing postgres box. `postgres` (A -> the postgres VM) stays exactly as it
is, so `psql` and ssh keep going direct. the UI gets a new name, `postgres-ui`:

1. the Caddyfile, named per the table above (`<host>-ui` if you also ssh to it, a plain name like `kvm`
   if it's UI only):
   ```caddy
   @postgres-ui host postgres-ui.ad.gavinf.com
   handle @postgres-ui {
       reverse_proxy 10.0.4.X:5050    # pgAdmin's IP and port
   }
   ```
   self-signed https backends also need `transport http { tls_insecure_skip_verify }`, like pve.
2. `caddy/deploy.sh`. no new cert: the wildcard already covers it.
3. on DC01, a CNAME to the proxy's *name* (a CNAME always points at a name; `proxy`'s A record is
   the one place that holds 10.0.4.30):
   ```powershell
   Add-DnsServerResourceRecordCName -ZoneName ad.gavinf.com -Name postgres-ui -HostNameAlias proxy.ad.gavinf.com
   ```
4. `curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' https://postgres-ui.ad.gavinf.com`

caddy only carries web traffic, so its cert never covers `psql`, ssh or rdp. those keep whatever TLS
they have on their own.

### good to know

- caddy renews ~30 days before expiry, by itself. check the cert it's serving:
  `echo | openssl s_client -connect 10.0.4.30:443 -servername pve-ui.ad.gavinf.com 2>/dev/null | openssl x509 -noout -issuer -dates`
- certs and the acme account live in `/var/lib/caddy/.local/share/caddy` on the VM. rebuilding the VM
  just means a new cert on first start.
- upgrading caddy: `ssh ubuntu@10.0.4.30 sudo caddy upgrade` (re-downloads with the same plugins), then
  `sudo systemctl restart caddy`. `apt upgrade` updates the diverted stock binary, which isn't the one in use.
- rotating the token: make the new one, `caddy/set-token.sh`, then revoke the old one in cloudflare.
- the proxy is now a single point of failure for these UIs. proxmox is still at `https://10.0.4.10:8006`
  if the VM is down.
- stuck cert: `sudo journalctl -u caddy` on the VM. "timed out waiting for record to fully propagate"
  means the `resolvers` line is missing; a 403 / "invalid request headers" from cloudflare means the
  token is wrong or can't edit the `gavinf.com` zone.
