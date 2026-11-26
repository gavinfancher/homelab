#!/usr/bin/env bash
# Back up the whole Postgres server to Cloudflare R2, and keep only the newest 24 backups.
# Runs on postgres.ad.gavinf.com every 2 hours from /etc/cron.d/postgres-backup. See README.md.
#
# 1. pg_dumpall inside the `postgres` container: every database, plus the roles and their passwords.
# 2. gzip it to a temp file, and upload it as postgres.ad.gavinf.com-backup-YYYY-MM-DD-HH-MM.sql.gz (UTC).
# 3. Only once the upload worked: delete the oldest backups until 24 are left.
#
# R2 credentials come from /etc/postgres-backup.env (root only, never in git).
set -euo pipefail

KEEP=24
PREFIX="postgres.ad.gavinf.com-backup-"
NAME="${PREFIX}$(date -u +%Y-%m-%d-%H-%M).sql.gz"

set -a
# shellcheck disable=SC1091
source /etc/postgres-backup.env   # R2_BUCKET and the RCLONE_CONFIG_R2_* settings
set +a
DEST="r2:${R2_BUCKET}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# pipefail: if pg_dumpall fails, the script stops here and nothing is uploaded or deleted.
docker exec postgres pg_dumpall -U postgres | gzip > "$TMP"
rclone copyto "$TMP" "${DEST}/${NAME}"
echo "$(date -u +%FT%TZ) uploaded ${NAME} ($(du -h "$TMP" | cut -f1))"

# The names sort oldest-first, so everything except the last $KEEP lines is old.
rclone lsf "$DEST" --include "${PREFIX}*" | sort | head -n -"$KEEP" | while read -r old; do
  rclone deletefile "${DEST}/${old}"
  echo "$(date -u +%FT%TZ) deleted ${old}"
done
