# postgres backups to R2

Every 2 hours, and whenever you run it by hand, `postgres.ad.gavinf.com` dumps the whole server and
uploads it to Cloudflare R2. The newest 24 are kept, and each run deletes anything older after its own
upload succeeds.

```
cron (every 2h, root)  or  sudo postgres-backup
   └─ postgres-backup.sh
        ├─ infisical login (machine identity postgres-backup) ──► R2 keys from project homelab-postgres, env prod
        ├─ docker exec postgres pg_dumpall | gzip       every database, plus roles and their passwords
        ├─ rclone copyto ──► r2:postgres-backups/backup-YYYY-MM-DDTHH:MM:SSZ.sql.gz   (UTC)
        └─ rclone deletefile on all but the newest 24
```

- **Why on the DB host, not a k8s CronJob:** nothing to package. The host already has `pg_dumpall` (inside the
  container, connecting over the local socket as `postgres`), so no backup role, no network path from the
  cluster, no image to pick. The copy still leaves the box, which is the point.
- **Why `pg_dumpall`:** one file brings back the whole server, roles included. It's plain SQL, so you can
  read it, or grep one database out of it.
- **Why Infisical:** the R2 keys live in one place you can rotate, never on this box's disk. The only secret here
  is the identity's login, and that identity can read one project holding nothing but the R2 keys. Revoke its
  client secret in Infisical and this box can read nothing.
- **Nothing is deleted unless the new backup uploaded.** If login, dump or upload fails, the script stops first.
- **One run at a time.** A manual run while cron's is going says so and exits.
- **Manual backups count toward the 24.** Each one pushes the oldest out, like a scheduled one.
- The dump holds password hashes. The bucket stays private, and the R2 token can only touch this bucket.

## files

| file | goes to (on the DB host) |
|---|---|
| `postgres-backup.sh` | `/usr/local/bin/postgres-backup` (root, 0755) |
| `postgres-backup.cron` | `/etc/cron.d/postgres-backup` (root, 0644) |
| `postgres-backup.env.example` | `/etc/postgres-backup.env`, filled in (root, 0600) |

## setup

1. **R2** (Cloudflare dashboard → R2 Object Storage):
   - create bucket `postgres-backups`
   - Manage API tokens → Create API token: permission **Object Read & Write**, applied to `postgres-backups`
     only. Keep the page open: the secret is shown once. You need the access key id, the secret access key, and
     the S3 endpoint (`https://<account id>.r2.cloudflarestorage.com`).

2. **Infisical project** (app.infisical.com):
   - new project `homelab-postgres`. Only these keys go in it, in **Production**, at the root:

     | key | value |
     |---|---|
     | `R2_BUCKET` | `postgres-backups` |
     | `R2_ENDPOINT` | `https://<account id>.r2.cloudflarestorage.com`: the bare URL, **no `/postgres-backups` on the end** (the bucket's settings page shows it with one) |
     | `R2_ACCESS_KEY_ID` | from step 1 |
     | `R2_SECRET_ACCESS_KEY` | from step 1 |

   - copy the project id (project settings) for step 5.

3. **Machine identity** (Organization → Access Control → Identities → Create):
   - name `postgres-backup`, org role **No Access**
   - Authentication → **Universal Auth**. Optional: Client Secret Trusted IPs = your home's public IP
     (only if it doesn't change). Create a client secret, and copy the client id + secret (shown once).
   - in `homelab-postgres` → Access Control → Machine Identities → Add → `postgres-backup`, role **Viewer**.
   - free plan: 3 machine identities. This one plus `k8s-cluster` makes 2.

4. **Tools on the host:** rclone (1.59+ for the Cloudflare provider; apt's can be older) and the Infisical CLI.
   ```sh
   ssh ubuntu@postgres.ad.gavinf.com
   curl -fsSL https://rclone.org/install.sh | sudo bash
   curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | sudo -E bash   # if this 404s, use the command
   sudo apt-get update && sudo apt-get install -y infisical                         # on infisical.com/docs/cli
   rclone version && infisical --version
   ```

5. **Copy the files over** (from this folder, on your Mac):
   ```sh
   scp postgres-backup.sh postgres-backup.cron postgres-backup.env.example ubuntu@postgres.ad.gavinf.com:/tmp/
   ssh ubuntu@postgres.ad.gavinf.com
   sudo install -o root -g root -m 0755 /tmp/postgres-backup.sh   /usr/local/bin/postgres-backup
   sudo install -o root -g root -m 0644 /tmp/postgres-backup.cron /etc/cron.d/postgres-backup
   sudo install -o root -g root -m 0600 /tmp/postgres-backup.env.example /etc/postgres-backup.env
   sudo nano /etc/postgres-backup.env      # client id, client secret, project id
   rm /tmp/postgres-backup*
   ```

6. **Run it once by hand.** It should print one `uploaded ...` line; check the object in the R2 dashboard.
   ```sh
   sudo postgres-backup
   ```
   From then on cron also runs it at 00:00, 02:00, ... (host time). Its log is `/var/log/postgres-backup.log`.

## updating the script

Edit `postgres-backup.sh` here, commit, then put it on the host (from this folder, on your Mac):

```sh
scp postgres-backup.sh ubuntu@postgres.ad.gavinf.com:/tmp/
ssh ubuntu@postgres.ad.gavinf.com 'sudo install -o root -g root -m 0755 /tmp/postgres-backup.sh /usr/local/bin/postgres-backup && rm /tmp/postgres-backup.sh'
```

## a backup right now

```sh
ssh -t ubuntu@postgres.ad.gavinf.com sudo postgres-backup     # from your Mac
```

## checking on it

```sh
tail /var/log/postgres-backup.log     # one "uploaded" line every 2h
```

Or look at the bucket in the R2 dashboard. Nothing alerts if it stops: the newest name should be under 2 hours old.

## restoring

Onto a fresh, empty server (a new `docker compose up` of `../compose.yaml`). Download the backup from the R2
dashboard and copy it to the host, then:

```sh
gunzip -c backup-<when>.sql.gz | docker exec -i postgres psql -U postgres -d postgres
```

It recreates every role and database. Expect one harmless error, `role "postgres" already exists`.
To restore one database only, the dump is plain SQL: each database starts at a `\connect <name>` line.

## troubleshooting

What a good run prints:

```
2026-11-26T18:52:03Z [1/5] fetching R2 keys from Infisical
2026-11-26T18:52:04Z       ✓ got the R2 keys (1s)
2026-11-26T18:52:04Z INF Injecting 4 Infisical secrets into your application process
2026-11-26T18:52:04Z [2/5] dumping every database (pg_dumpall | gzip)
2026-11-26T18:52:04Z       ✓ 100K compressed (0s)
2026-11-26T18:52:04Z [3/5] uploading backup-2026-11-26T18:52:04Z.sql.gz to r2:postgres-backups
2026-11-26T18:52:05Z       ✓ uploaded (1s)
2026-11-26T18:52:05Z [4/5] pruning: keeping the newest 24
2026-11-26T18:52:05Z       ✓ 3 in bucket, deleted 0, 3 left (0s)
2026-11-26T18:52:05Z [5/5] removing the temp file
2026-11-26T18:52:05Z       ✓ removed (0s)
2026-11-26T18:52:05Z backup done in 2s
```

Once there are more than 24, step 4 also prints a `deleted <name>` line for each old one it removes.
A failure prints `✗ failed at step N/5` after the error, and nothing after that step runs.

| you see | cause | fix |
|---|---|---|
| `ERROR : error listing: directory not found` after `uploaded`, and the backup sits in a `postgres-backups/` folder inside the bucket | `R2_ENDPOINT` ends in `/postgres-backups` | set the bare URL in Infisical, and delete the stray folder in the R2 dashboard |
| `R2_... : missing from Infisical` | a key is missing, misnamed, or empty in `homelab-postgres` / Production | add it there, exactly as named in setup step 2 |
| infisical login fails (401 / invalid credentials) | wrong client id/secret in `/etc/postgres-backup.env`, the secret was revoked, or trusted IPs don't match | make a new client secret (see rotating) |
| `another backup is running, skipping` | a run was already going (cron and a manual run at once) | nothing; wait for it |
| `failed to wait for command termination: exit status N` | that's `infisical run` passing on the script's failure; the real error is the line above it | read the line above |
| `AccessDenied` from rclone | the R2 token doesn't cover `postgres-backups`, or lacks Object Read & Write | new R2 token, update the two keys in Infisical |

## rotating

- **R2 keys:** make a new R2 token, update the two keys in Infisical. Nothing to change on the host.
- **Identity secret:** create a new client secret in Infisical, put it in `/etc/postgres-backup.env`, then
  revoke the old one.

## setup record

| date | what |
|---|---|
| 2026-11-26 | R2 bucket `postgres-backups` and a bucket-scoped Object Read & Write token. Infisical project `homelab-postgres` (id `68a41a02-3fc1-4678-af69-c2ddc76c9ff7`) with the 4 R2 keys; machine identity `postgres-backup` (universal auth, Viewer on that project). rclone 1.76.0 and the Infisical CLI installed on the host; script, cron file and env file installed. |
| 2026-11-26 | First run uploaded (100K), but `R2_ENDPOINT` ended in `/postgres-backups`, so the object landed in a `postgres-backups/` folder and the cleanup listing failed. Endpoint fixed in Infisical and the stray folder deleted. Script now prints numbered progress steps. |
| 2026-11-26 | Backups renamed to `backup-YYYY-MM-DD-HH-MM.sql.gz` (dropped the host name; this bucket only holds this server). The one existing backup was renamed in R2 so pruning still counts it. |
| 2026-11-26 | Names changed to ISO 8601 UTC with seconds, `backup-YYYY-MM-DDTHH:MM:SSZ.sql.gz` (`T` between date and time, `Z` = UTC). The existing backups were renamed to match (seconds `00` where the old names had none). Colons are fine in R2 and on Linux; macOS Finder shows them as `/`, which is only cosmetic. |
