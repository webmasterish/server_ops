#!/usr/bin/env bash
#
# Back up one Hostinger site onto this server.
#
# RUN THIS ON hetzner, not locally -- it pulls server-to-server so the payload
# never crosses a home connection.
#
#   ./backup-hostinger-site.sh <domain> [wp-subpath|--no-db]
#
#   ./backup-hostinger-site.sh skinosis.com          # WP in public_html/cms
#   ./backup-hostinger-site.sh woo.example.com .     # WP at docroot
#   ./backup-hostinger-site.sh mardini.net --no-db   # static, no database
#
# Writes to /var/www/backups/hostinger/<date>/ :
#   sites/<domain>/         rsync'd tree
#   db/<dbname>.sql.bz2     streamed dump
#   manifest/<domain>.txt   counts, sizes, checksum
#
# Nothing is written to Hostinger. Files come over rsync rather than a tarball
# built on the source, and the dump is streamed to stdout and compressed on
# arrival -- Hostinger stays read-only, and its CloudLinux CPU limits stay out
# of the picture. See docs/inventory.md section 4b.
#
# Idempotent: re-running re-syncs files (delta only) and replaces the dump.
# Safe to re-run for the pre-cutover catch-up sync.

set -euo pipefail

DOMAIN="${1:?usage: $0 <domain> [wp-subpath|--no-db]}"
WP_PATH="${2:-cms}"

REMOTE="${REMOTE_ALIAS:-hostinger}"
DATE="${BACKUP_DATE:-$(date +%F)}"
DEST="${BACKUP_ROOT:-/var/www/backups/hostinger}/${DATE}"
SSH_OPTS=(-o BatchMode=yes)

SITE_DIR="${DEST}/sites/${DOMAIN}"
MANIFEST="${DEST}/manifest/${DOMAIN}.txt"

mkdir -p "${SITE_DIR}" "${DEST}/db" "${DEST}/manifest"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

log "syncing files for ${DOMAIN}"

# Hostinger's per-domain backups/ directories are its own managed stubs, not
# usable archives -- skipped by decision, 2026-07-28.
EXCLUDES=(--exclude='backups/')

# No -z: section 1.5 measured the payload as ~88% already-compressed media, so
# compression burns CPU for almost nothing.
#
# --delete removes content dropped at the source. --delete-excluded is the one
# that matters here: plain --delete *protects* excluded paths on the receiver,
# so a site synced before backups/ was excluded keeps its stale copy forever and
# the count check below fails with dest > source. Needed any time an exclusion
# is added after a sync already happened.
rsync -a --delete --delete-excluded --stats "${EXCLUDES[@]}" \
  -e "ssh ${SSH_OPTS[*]}" \
  "${REMOTE}:domains/${DOMAIN}/" "${SITE_DIR}/"

# The source count must apply the same exclusions, or the check below compares
# unlike things and fails on every site that has a backups/ directory.
SRC_COUNT=$(ssh -n "${SSH_OPTS[@]}" "${REMOTE}" \
  "find domains/${DOMAIN} -type f -not -path '*/backups/*' | wc -l")
DST_COUNT=$(find "${SITE_DIR}" -type f | wc -l)

log "files: source=${SRC_COUNT} dest=${DST_COUNT}"

if [[ "${SRC_COUNT}" != "${DST_COUNT}" ]]; then
  log "FAIL: file count mismatch"
  exit 1
fi

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

DB_NAME="(none)"
DB_FILE="(none)"

if [[ "${WP_PATH}" != "--no-db" ]]; then
  log "resolving database name"

  if [[ "${WP_PATH}" == "--piwigo" ]]; then
    # Piwigo keeps its settings in local/config/database.inc.php as a $conf
    # array -- no wp-cli involved.
    DB_NAME=$(ssh -n "${SSH_OPTS[@]}" "${REMOTE}" \
      "cd domains/${DOMAIN}/public_html && php -r '\$conf=array(); include \"local/config/database.inc.php\"; echo \$conf[\"db_base\"];'" \
      | tr -d '[:space:]')
  else
    # The custom wp-config picks its config file by $_SERVER['SERVER_NAME'],
    # which is empty under CLI -- without it the config falls through to a root
    # branch and fails to connect. --skip-themes/--skip-plugins keeps a broken
    # theme (lebanese.tech) from taking wp-cli down with it.
    WP_CMD="cd domains/${DOMAIN}/public_html && SERVER_NAME=${DOMAIN} wp"
    WP_ARGS="--path=${WP_PATH} --skip-themes --skip-plugins"

    DB_NAME=$(ssh -n "${SSH_OPTS[@]}" "${REMOTE}" \
      "${WP_CMD} db query 'SELECT DATABASE();' --skip-column-names ${WP_ARGS}" \
      | tr -d '[:space:]')
  fi

  if [[ -z "${DB_NAME}" ]]; then
    log "FAIL: could not resolve database name"
    exit 1
  fi

  DB_FILE="${DEST}/db/${DB_NAME}.sql.bz2"
  log "dumping ${DB_NAME}"

  # NOT `wp db export`. Hostinger disables PHP's shell-exec functions
  # (passthru/exec/proc_open are undefined), and wp-cli's db export shells out
  # to mysqldump -- so it fails, silently, producing an empty file and exit 255.
  # Instead: let wp-cli load wp-config to resolve the credentials, hand them to
  # the remote shell, and run mysqldump there.
  #
  # The credentials never reach this machine, are never written to a file, and
  # never appear in output -- they exist only in the remote shell's environment
  # for the life of the dump. MYSQL_PWD keeps the password out of the remote
  # process list too. CLAUDE.md sanctions reading them at the moment they are
  # needed; this is that, and nothing more.
  #
  # pipefail matters: without it a failed dump still yields a valid-looking
  # (empty) bz2 and the script would report success.
  # Each resolver prints a set of `export` statements for the remote shell to
  # eval. Same contract, different source of truth.
  if [[ "${WP_PATH}" == "--piwigo" ]]; then
    CRED_EVAL="php -r '\$conf=array(); include \"local/config/database.inc.php\"; printf(\"export MYSQL_PWD=%s DBU=%s DBH=%s DBN=%s\", escapeshellarg(\$conf[\"db_password\"]), escapeshellarg(\$conf[\"db_user\"]), escapeshellarg(\$conf[\"db_host\"]), escapeshellarg(\$conf[\"db_base\"]));'"
  else
    CRED_EVAL="SERVER_NAME='${DOMAIN}' wp eval 'printf(\"export MYSQL_PWD=%s DBU=%s DBH=%s DBN=%s\", escapeshellarg(DB_PASSWORD), escapeshellarg(DB_USER), escapeshellarg(DB_HOST), escapeshellarg(DB_NAME));' --path='${WP_PATH}' --skip-themes --skip-plugins 2>/dev/null"
  fi

  set -o pipefail
  ssh "${SSH_OPTS[@]}" "${REMOTE}" 'bash -s' <<REMOTE_SCRIPT | bzip2 -9 > "${DB_FILE}"
set -euo pipefail
cd "domains/${DOMAIN}/public_html"
eval "\$(${CRED_EVAL})"
mysqldump --single-transaction --quick --default-character-set=utf8mb4 \\
  --host="\$DBH" --user="\$DBU" "\$DBN"
REMOTE_SCRIPT

  TABLES=$(bzcat "${DB_FILE}" | grep -c '^CREATE TABLE' || true)
  if [[ "${TABLES}" -lt 1 ]]; then
    log "FAIL: dump contains no CREATE TABLE statements"
    exit 1
  fi
  log "dump ok: ${TABLES} tables, $(du -h "${DB_FILE}" | cut -f1)"
fi

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

{
  echo "domain:      ${DOMAIN}"
  echo "captured:    $(date -Is)"
  echo "source:      ${REMOTE}:domains/${DOMAIN}/"
  echo "files:       ${DST_COUNT} (source reported ${SRC_COUNT})"
  echo "bytes:       $(du -sb "${SITE_DIR}" | cut -f1)"
  echo "database:    ${DB_NAME}"
  if [[ "${DB_FILE}" != "(none)" ]]; then
    echo "db_bytes:    $(stat -c%s "${DB_FILE}")"
    echo "db_sha256:   $(sha256sum "${DB_FILE}" | cut -d' ' -f1)"
  fi
} > "${MANIFEST}"

log "done -- manifest at ${MANIFEST}"
cat "${MANIFEST}"
