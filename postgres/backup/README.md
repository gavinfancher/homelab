# postgres backups to R2

Every 2 hours, `postgres.ad.gavinf.com` dumps the whole server and uploads it to Cloudflare R2. The newest
24 are kept (2 days), and each run deletes anything older after its own upload succeeds.

```
cron (every 2h, root) ── postgres-backup.sh
   ├─ docker exec postgres pg_dumpall | gzip      every database, plus roles and their passwords
   ├─ rclone copyto ──► r2:postgres-backups/postgres.ad.gavinf.com-backup-YYYY-MM-DD-HH-MM.sql.gz   (UTC)
   └─ rclone deletefile on all but the newest 24
```

- **Why on the DB host, not a k8s CronJob:** nothing to package. The host already has `pg_dumpall` (inside the
  container, connecting over the local socket as `postgres`), so no backup role, no network path from the
  cluster, no image to pick. The copy still leaves the box, which is the point.
- **Why `pg_dumpall`:** one file brings back the whole server, roles included. It's plain SQL, so you can
  read it, or grep one database out of it.
- **Nothing is deleted unless the new backup uploaded.** If the dump or upload fails, the script stops first.
- The dump holds password hashes. The bucket stays private, and the token can only touch this bucket.

## files

| file | goes to (on the DB host) |
|---|---|
| `postgres-backup.sh` | `/usr/local/bin/postgres-backup` (root, 0755) |
| `postgres-backup.cron` | `/etc/cron.d/postgres-backup` (root, 0644) |
| `postgres-backup.env.example` | `/etc/postgres-backup.env`, filled in (root, 0600) |

## setup

1. **R2** (Cloudflare dashboard → R2):
   - create bucket `postgres-backups`
   - Manage API tokens → create token: **Object Read & Write**, applied to `postgres-backups` only.
     Copy the access key id, secret, and the S3 endpoint (`https://<account id>.r2.cloudflarestorage.com`)
     into your password manager.

2. **rclone on the host.** It needs a version with the Cloudflare provider (1.59+); apt's can be older.
   ```sh
   ssh ubuntu@postgres.ad.gavinf.com
   curl -fsSL https://rclone.org/install.sh | sudo bash
   rclone version
   ```

3. **Copy the files over** (from this folder, on your Mac):
   ```sh
   scp postgres-backup.sh postgres-backup.cron postgres-backup.env.example ubuntu@postgres.ad.gavinf.com:/tmp/
   ssh ubuntu@postgres.ad.gavinf.com
   sudo install -o root -g root -m 0755 /tmp/postgres-backup.sh   /usr/local/bin/postgres-backup
   sudo install -o root -g root -m 0644 /tmp/postgres-backup.cron /etc/cron.d/postgres-backup
   sudo install -o root -g root -m 0600 /tmp/postgres-backup.env.example /etc/postgres-backup.env
   sudo nano /etc/postgres-backup.env      # fill in the endpoint and keys
   rm /tmp/postgres-backup*
   ```

4. **Run it once by hand** and check it landed:
   ```sh
   sudo /usr/local/bin/postgres-backup
   sudo bash -c 'set -a; . /etc/postgres-backup.env; rclone lsl r2:postgres-backups'
   ```
   From then on cron runs it at 00:00, 02:00, ... (host time). Its log is `/var/log/postgres-backup.log`.

## checking on it

```sh
tail /var/log/postgres-backup.log                                          # one "uploaded" line every 2h
sudo bash -c 'set -a; . /etc/postgres-backup.env; rclone lsf r2:postgres-backups | sort | tail -3'
```

Nothing alerts if it stops. The newest name in the bucket is the check: it should be under 2 hours old.

## restoring

Onto a fresh, empty server (a new `docker compose up` of `../compose.yaml`):

```sh
sudo bash -c 'set -a; . /etc/postgres-backup.env; rclone copyto r2:postgres-backups/<name>.sql.gz /tmp/restore.sql.gz'
gunzip -c /tmp/restore.sql.gz | docker exec -i postgres psql -U postgres -d postgres
```

It recreates every role and database. Expect one harmless error, `role "postgres" already exists`.
To restore one database only, the dump is plain SQL: each database starts at a `\connect <name>` line.
