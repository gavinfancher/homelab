#!/usr/bin/env bash
# Back up the whole Postgres server to Cloudflare R2, and keep only the newest 24 backups.
# Runs on postgres.ad.gavinf.com every 2 hours from /etc/cron.d/postgres-backup, or by hand any time:
#   sudo postgres-backup
#
# [1/5] Log in to Infisical as the postgres-backup machine identity and fetch the R2 keys.
# [2/5] pg_dumpall inside the `postgres` container (every database, plus the roles and their
#       passwords), streamed straight into gzip: only the compressed temp file ever touches disk.
# [3/5] Upload it as backup-YYYY-MM-DDTHH:MM:SSZ.sql.gz (ISO 8601, UTC).
# [4/5] Only once the upload worked: list the backups and delete the oldest until 24 are left.
# [5/5] Delete the temp file. (It's also deleted if any step fails, by the EXIT trap.)
#
# Any failure stops the script right there, so nothing is deleted unless the new backup uploaded.
# The only secret on this box is the identity's login, in /etc/postgres-backup.env (root only).
# The R2 keys live in Infisical (project homelab-postgres, env prod). See README.md.
set -euo pipefail

# One timestamped line per step, so the output reads the same in a terminal and in the cron log.
# BACKUP_T0 carries the start time across the re-run in step 1, so the timings include the login.
export BACKUP_T0="${BACKUP_T0:-$(date +%s)}"
SECONDS=$(( $(date +%s) - BACKUP_T0 ))
STEP=1 STEP_START=0
log()   { echo "$(date -u +%FT%TZ) $*"; }
began() { STEP=$1 STEP_START=$SECONDS; log "[$1/5] $2"; }
done_() { log "      ✓ $* ($((SECONDS - STEP_START))s)"; }
trap 'log "✗ failed at step ${STEP}/5 (exit $?). Old backups are only deleted after a good upload."' ERR

# [1/5] First pass, no R2 keys yet: log in, then run this same script again with the keys from
# Infisical in its environment. They only exist for this run, never on disk.
if [[ -z "${POSTGRES_BACKUP_FETCHED:-}" ]]; then
  export POSTGRES_BACKUP_FETCHED=1
  began 1 "fetching R2 keys from Infisical"
  # shellcheck disable=SC1091
  source /etc/postgres-backup.env   # INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET, INFISICAL_PROJECT_ID
  INFISICAL_TOKEN="$(infisical login --method=universal-auth \
    --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" --silent --plain)"
  exec infisical run --token="$INFISICAL_TOKEN" --projectId="$INFISICAL_PROJECT_ID" --env=prod --silent \
    -- "$0" "$@"
fi

: "${R2_BUCKET:?missing from Infisical}" "${R2_ENDPOINT:?missing from Infisical}" \
  "${R2_ACCESS_KEY_ID:?missing from Infisical}" "${R2_SECRET_ACCESS_KEY:?missing from Infisical}"
done_ "got the R2 keys"

# One run at a time: a manual run while cron's is going exits instead of overlapping.
exec 9>/run/postgres-backup.lock
flock -n 9 || { log "another backup is running, skipping"; exit 1; }

# rclone's "r2" remote, built from env vars so there's no rclone.conf to manage
# (-q on each rclone call hides its "config file not found" notice; errors still show).
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare
# The bare account URL, no /<bucket> on the end (see README, setup step 2).
export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
# The token can only touch objects in this bucket, so don't let rclone try to check or create it.
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

KEEP=24
PREFIX="backup-"
NAME="${PREFIX}$(date -u +%Y-%m-%dT%H:%M:%SZ).sql.gz"   # ISO 8601, UTC
DEST="r2:${R2_BUCKET}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

began 2 "dumping every database (pg_dumpall | gzip)"
docker exec postgres pg_dumpall -U postgres | gzip > "$TMP"
done_ "$(du -h "$TMP" | cut -f1) compressed"

began 3 "uploading ${NAME} to ${DEST}"
rclone -q copyto "$TMP" "${DEST}/${NAME}"
done_ "uploaded"

began 4 "pruning: keeping the newest ${KEEP}"
# The names sort oldest-first, so everything before the last $KEEP is old.
mapfile -t backups < <(rclone -q lsf "$DEST" --include "${PREFIX}*" | sort)
extra=$(( ${#backups[@]} > KEEP ? ${#backups[@]} - KEEP : 0 ))
for old in "${backups[@]:0:extra}"; do
  rclone -q deletefile "${DEST}/${old}"
  log "      deleted ${old}"
done
done_ "${#backups[@]} in bucket, deleted ${extra}, $(( ${#backups[@]} - extra )) left"

began 5 "removing the temp file"
rm -f "$TMP"
done_ "removed"

log "backup done in ${SECONDS}s"
