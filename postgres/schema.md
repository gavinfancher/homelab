### Databases

All tables live in `public`.

#### `easydocs` (owner `easydocs`)

| Table | Columns | Keys / constraints |
|---|---|---|
| `items` | `owner` text, `pk` text, `sk` text, `data` jsonb default `'{}'` | PK `(owner, pk, sk)` |
| `uploads` | `name` text, `content_type` text, `size` int, `data` bytea null, `bucket` text null, `object_key` text null, `etag` text null, `status` text default `'ready'`, `owner` text, `created` / `modified` timestamptz default `now()` | PK `name`; unique `(bucket, object_key)`; `status in ('pending','ready')` |
| `users` | `name` text, `password_hash` text, `created` timestamptz default `now()` | PK `name` |
| `sessions` | `token_hash` text, `username` text, `expires` timestamptz | PK `token_hash` |

#### `homecloud` (owner `homecloud`)

| Table | Columns | Keys / constraints |
|---|---|---|
| `vms` | `name` text, `os` text, `cores` int, `memory_mb` int, `disk_gb` int, `vmid` int null, `state` text default `'creating'`, `step` text default `'create'`, `step_started` timestamptz default `now()`, `ip` text null, `error` text null, `created_at` timestamptz default `now()` | PK `name`; unique `vmid`; `os in ('ubuntu','windows')`; `state in ('creating','ready','failed','deleting')` |
| `vm_events` | `id` bigserial, `vm` text, `at` timestamptz default `now()`, `level` text default `'info'`, `message` text | PK `id`; FK `vm` → `vms(name)` on delete cascade; `level in ('info','warn','error')`; index `(vm, id)` |
| `sessions` | `token_hash` text, `expires` timestamptz | PK `token_hash` |

#### `wishly` (owner `wishly_schema`)

| Table | Columns | Keys / constraints |
|---|---|---|
| `users` | `id` bigint identity, `email` text, `password_hash` text, `timezone` text default `'UTC'`, `send_hour` int default `8`, `onboarded_at` timestamptz null, `created_at` timestamptz default `now()` | PK `id`; unique `email`; `send_hour` 0–23 |
| `sessions` | `token_hash` text, `user_id` bigint, `created_at` timestamptz default `now()`, `expires_at` timestamptz | PK `token_hash`; FK `user_id` → `users` on delete cascade; index `user_id` |
| `reminders` | `id` bigint identity, `user_id` bigint, `title` text, `month` int, `day` int, `days_before` int[], `created_at` timestamptz default `now()` | PK `id`; FK `user_id` → `users` on delete cascade; `month` 1–12, `day` 1–31; index `user_id` |
| `sends` | `reminder_id` bigint, `days_before` int, `occurrence_date` date, `sent_at` timestamptz default `now()` | PK `(reminder_id, days_before, occurrence_date)`; FK `reminder_id` → `reminders` on delete cascade |

## Rebuilding on a new DB

| App | Roles + DB | Tables |
|---|---|---|
| homecloud | `homecloud/infra/sql/roles.sql` | created by the backend on startup (`backend/app/db.py`, `CREATE TABLE IF NOT EXISTS`) |
| wishly | `wishly/infra/sql/roles.sql` (one `wishly` role, owns the db) | `wishly/infra/sql/schema.sql`, applied as `wishly` |
| easydocs | **no setup scripts found locally** | **unknown**. Take a `pg_dump --schema-only -d easydocs` from the live server before getting rid of it |

To make a fresh DB set itself up, those scripts could be mounted into
`/docker-entrypoint-initdb.d`. They only run when the volume is empty. They take
passwords as psql `:'vars'`, so they'd need a small wrapper script to pass them in.
