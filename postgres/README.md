# postgres

Shared Postgres instance for homelab apps (easydocs, homecloud, wishly).

- **Host:** `postgres.ad.gavinf.com` (user `ubuntu`)
- **Compose file on host:** `/home/ubuntu/prod/compose.yaml` (identical to `./compose.yaml` here)
- **Image:** `postgres:18.6`
- **Data:** named volume `prod_pgdata` → `/var/lib/postgresql` (`PGDATA=/var/lib/postgresql/18/docker`)
- **Port:** `5432` published on all interfaces
- **Backups:** every 2h to S3, kept 30 days, from a CronJob on homek8s. See [backup/](backup/README.md)

```sh
ssh postgres.ad.gavinf.com
cd ~/prod && docker compose up -d
docker exec -it postgres psql -U postgres
```

> `compose.yaml.bak-20261022213827` on the host only differs in the old mount path
> (`/var/lib/postgresql-1/data`), changed on 2026-10-22 for the PG18 data layout.

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

## Live structure (as of 2026-11-23)

### Roles

| Role | Notes |
|---|---|
| `postgres` | superuser |
| `easydocs` | owns `easydocs` db |
| `homecloud` | owns `homecloud` db |
| `wishly_schema` | owns `wishly` db and its `public` schema |
| `wishly_app` | `CONNECT` on `wishly`; table access via membership in `pg_read_all_data` + `pg_write_all_data` (no direct grants) |
