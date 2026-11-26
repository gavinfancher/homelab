# postgres

Shared Postgres instance for homelab apps (easydocs, homecloud, wishly).

- **Host:** `postgres.ad.gavinf.com` (user `ubuntu`)
- **Compose file on host:** `/home/ubuntu/prod/compose.yaml` (identical to `./compose.yaml` here)
- **Image:** `postgres:18.6`
- **Data:** named volume `prod_pgdata` → `/var/lib/postgresql` (`PGDATA=/var/lib/postgresql/18/docker`)
- **Port:** `5432` published on all interfaces
- **Backups:** every 2h to Cloudflare R2 (`pg_dumpall`, newest 24 kept), from cron on this host. See [backup/](backup/README.md)

```sh
ssh postgres.ad.gavinf.com
cd ~/prod && docker compose up -d
docker exec -it postgres psql -U postgres
```

> `compose.yaml.bak-20261022213827` on the host only differs in the old mount path
> (`/var/lib/postgresql-1/data`), changed on 2026-10-22 for the PG18 data layout.

## Container settings, and why

Two settings in `compose.yaml` exist only because Postgres runs in Docker (added 2026-11-26):

- **`shm_size: 256mb`.** Docker gives every container a 64MB `/dev/shm`. Postgres keeps its *dynamic*
  shared memory there: the scratch space parallel workers share during a parallel query or a parallel
  `create index`. When a big query needs more than 64MB of it, the query fails with
  `could not resize shared memory segment "/PostgreSQL.…" to … bytes: No space left on device`.
  Nothing today is that big, but it's a limit that doesn't exist outside Docker, and the error is
  confusing when it does show up. 256MB is a small slice of the VM's 15GB, and it's only used while
  such a query runs. (`shared_buffers`, the main cache, doesn't live in `/dev/shm` and isn't affected.)
  Check it: `docker exec postgres df -h /dev/shm`.
- **`stop_grace_period: 60s`.** `docker stop` (and `docker compose down`, a host reboot, an image
  upgrade) sends the image's stop signal, `SIGINT`. To Postgres that means a "fast" shutdown: disconnect
  every client, write a final checkpoint, exit cleanly. But Docker only waits 10 seconds by default, then
  sends `SIGKILL`. If the checkpoint is still writing, Postgres is killed mid-way and has to do crash
  recovery (replaying the WAL) on the next start: no data lost, but a slower start and a scarier log.
  60s gives the checkpoint time to finish; a clean stop still takes only a second or two.
  Check it: `docker inspect postgres --format '{{.Config.StopTimeout}}'` → `60`.

## Changing the compose file

Edit `compose.yaml` here, commit, then on the host:

```sh
scp compose.yaml ubuntu@postgres.ad.gavinf.com:~/prod/compose.yaml
ssh ubuntu@postgres.ad.gavinf.com 'cd ~/prod && docker compose up -d --wait'
```

`up -d` recreates the container when its settings changed. The data is on the volume, so nothing is
lost, but **every app loses its database for the few seconds of the restart**. Their pools reconnect on
their own. Do it when a reminder send isn't due (wishly sends from 9:00 Eastern).

## What a fresh `docker compose up` gives you

Only the `postgres` superuser and an empty `postgres` database. Nothing else on the
host alters initialization:

| Thing | State |
|---|---|
| `/docker-entrypoint-initdb.d` | empty, no init SQL mounted |
| `.env` in `~/prod` | none, so the `${POSTGRES_*:-default}` fallbacks apply (user/db `postgres`, password `password` unless set in the shell) |
| `postgresql.auto.conf` | empty, nothing set with `ALTER SYSTEM` |
| `postgresql.conf` | image defaults (`listen_addresses=*`, `max_connections=100`, `shared_buffers=128MB`, UTC) |
| `pg_hba.conf` | image default: local trusted, remote `scram-sha-256` from any IP |
| Per-role / per-db settings | none |
| Extensions | only `plpgsql` |
| Functions / triggers | none |

Every app role, database, and table was added after initialization, by hand or by the apps.

## Live structure (as of 2026-11-26)

### Roles

One role per app, owning its own database: the same pattern for every app.

| Role | Notes |
|---|---|
| `postgres` | superuser |
| `easydocs` | owns `easydocs` db |
| `homecloud` | owns `homecloud` db |
| `wishly` | owns `wishly` db, its `public` schema and tables (was `wishly_app` + `wishly_schema` until 2026-11-26, see wishly `infra/sql/migrate-one-role.sql`) |
| `nextup` | owns `nextup` db (2026-11-25) |