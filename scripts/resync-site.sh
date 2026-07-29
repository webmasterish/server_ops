#!/usr/bin/env bash
#
# Re-sync a already-provisioned site from Hostinger: latest files AND latest
# database. RUN ON hetzner.
#
#   ./resync-site.sh <group> <domain> <db-name> [wp-path] [--sub <parent>]
#
#   ./resync-site.sh dotaim videotizer.com videotizer_website_wp cms
#
# Run this immediately before flipping DNS. A site provisioned days earlier is
# serving a snapshot: videotizer.com had drifted by one post and one option
# within 18 hours, with a post modified 16 minutes before the check. Cutting
# over on stale data loses whatever changed in between, silently.
#
# DESTRUCTIVE on the Hetzner side, by design: the target database is dropped
# and rebuilt from the source, because a plain re-import leaves behind rows and
# tables that were deleted at the source. The site is briefly down during the
# import -- which is why this belongs BEFORE the DNS switch, not after.
#
# Nothing is written to Hostinger.
#
# Idempotent. Safe to run repeatedly; each run just re-narrows the gap.

set -euo pipefail

GROUP="${1:?usage: $0 <group> <domain> <db-name> [wp-path] [--sub <parent>]}"
DOMAIN="${2:?usage: $0 <group> <domain> <db-name> [wp-path] [--sub <parent>]}"
DBNAME="${3:?usage: $0 <group> <domain> <db-name> [wp-path] [--sub <parent>]}"
WP_PATH="${4:-cms}"
shift 3; [[ $# -gt 0 && "$1" != --* ]] && shift || true

PARENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sub) PARENT="${2:?--sub needs a parent domain}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SET="${BACKUP_SET:-synced}"
BACKUP="${BACKUP_ROOT:-/var/www/backups/hostinger}/${SET}"
VHOSTS="${VHOSTS_ROOT:-/var/www/vhosts}"

if [[ -n "${PARENT}" ]]; then
  BASE="${VHOSTS}/${GROUP}/${PARENT}/subs/${DOMAIN}"
else
  BASE="${VHOSTS}/${GROUP}/${DOMAIN}"
fi
DOCROOT="${BASE}/httpdocs"
CONFIG="${DOCROOT}/.config/master_config.php"

MYSQL=(sudo mysql --defaults-file=/etc/mysql/debian.cnf)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

[[ -d "${DOCROOT}" ]] || { echo "not provisioned: ${DOCROOT}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Refresh the backup set from Hostinger (delta files + fresh dump)
# ---------------------------------------------------------------------------

log "step 1/5 -- refreshing backup set from Hostinger"
BACKUP_SET="${SET}" "${HERE}/backup-hostinger-site.sh" "${DOMAIN}" "${WP_PATH}" \
  | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 2. Push files into the live docroot
# ---------------------------------------------------------------------------

log "step 2/5 -- syncing files into ${DOCROOT}"

# --delete so files removed at the source are removed here too. The .bak-*
# exclusion protects the config backups this script and set-site-db.php leave
# behind -- they do not exist at the source, so --delete would eat them.
rsync -a --delete --exclude='*.bak-*' --stats \
  "${BACKUP}/sites/${DOMAIN}/public_html/" "${DOCROOT}/" \
  | grep -E 'Number of (regular files transferred|deleted files)' | sed 's/^/    /'

sudo chown -R webmasterish:www-data "${DOCROOT}"

# ---------------------------------------------------------------------------
# 3. Re-apply the local DB naming
# ---------------------------------------------------------------------------
#
# MUST come after step 2. The synced master_config.php is Hostinger's, carrying
# the u918436082_* names -- step 2 overwrites whatever we set previously, so
# without this the site points at a database that does not exist here.

if [[ -f "${CONFIG}" ]]; then
  log "step 3/5 -- repointing config at ${DBNAME}"
  php "${HERE}/set-site-db.php" "${CONFIG}" "${DBNAME}" | sed 's/^/    /'
else
  log "step 3/5 -- no master_config.php, skipping"
fi

# ---------------------------------------------------------------------------
# 4. Rebuild the database
# ---------------------------------------------------------------------------

DUMP=$(ls -t "${BACKUP}"/db/*.sql.bz2 2>/dev/null \
  | xargs -I{} sh -c 'bzcat {} | head -40 | grep -ql "Database: " && echo {}' 2>/dev/null | head -1 || true)
DUMP="${DUMP:-$(ls -t "${BACKUP}"/db/*.sql.bz2 | head -1)}"

# Prefer the dump whose name matches the source database for this site.
SRC_DB=$(grep -oP '(?<=^database:\s{4})\S+' "${BACKUP}/manifest/${DOMAIN}.txt" 2>/dev/null || true)
[[ -n "${SRC_DB}" && -f "${BACKUP}/db/${SRC_DB}.sql.bz2" ]] && DUMP="${BACKUP}/db/${SRC_DB}.sql.bz2"

log "step 4/5 -- rebuilding ${DBNAME} from $(basename "${DUMP}")"

"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${DBNAME}\`;
                  CREATE DATABASE \`${DBNAME}\`
                  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;"

bzcat "${DUMP}" | "${HERE}/sanitize-mariadb-dump.sh" | "${MYSQL[@]}" "${DBNAME}"

# ---------------------------------------------------------------------------
# 5. Verify against the source
# ---------------------------------------------------------------------------

log "step 5/5 -- verifying against source"

# One simple query per metric, inline.
#
# The obvious version -- a single multi-subquery SELECT, or the same sent over
# a heredoc -- comes back EMPTY when run from inside a script, while working
# perfectly when typed by hand. An unquoted heredoc is processed by the local
# shell before it ever reaches the remote, and the result is a query the remote
# silently fails on. `read` then turns that into blank fields and a spurious
# DRIFT: a verification step reporting a problem that does not exist is worse
# than no verification. Simple queries are proven to survive the trip.
# `sed '/^$/d'`, not a bare `tail -1`: wp db query prints the value and THEN a
# blank line, so tail -1 returns the blank every time. That is what produced
# the empty source column and the false DRIFT warning.
src_q() {
  ssh -n -o BatchMode=yes hostinger \
    "cd domains/${DOMAIN}/public_html && SERVER_NAME=${DOMAIN} wp db query \"$1\" --skip-column-names --path=${WP_PATH} --skip-themes --skip-plugins" \
    2>/dev/null | sed '/^[[:space:]]*$/d' | tail -1
}

s_posts=$(src_q "SELECT COUNT(*) FROM wp_posts;")
s_opts=$(src_q "SELECT COUNT(*) FROM wp_options;")
s_newest=$(src_q "SELECT COALESCE(MAX(post_modified),'-') FROM wp_posts;")

dst_q() { "${MYSQL[@]}" -N -e "$1" | tail -1; }

d_posts=$(dst_q "SELECT COUNT(*) FROM \`${DBNAME}\`.wp_posts;")
d_opts=$(dst_q "SELECT COUNT(*) FROM \`${DBNAME}\`.wp_options;")
d_newest=$(dst_q "SELECT COALESCE(MAX(post_modified),'-') FROM \`${DBNAME}\`.wp_posts;")

if [[ -z "${s_posts}" ]]; then
  echo "    WARNING: could not read source counts -- verification inconclusive" >&2
fi

printf '    %-10s %-12s %-12s\n' '' source destination
printf '    %-10s %-12s %-12s %s\n' posts   "${s_posts}"  "${d_posts}"  "$([[ "${s_posts}" == "${d_posts}" ]] && echo OK || echo DRIFT)"
printf '    %-10s %-12s %-12s %s\n' options "${s_opts}"   "${d_opts}"   "$([[ "${s_opts}" == "${d_opts}" ]] && echo OK || echo DRIFT)"
printf '    %-10s %-12s %-12s\n'    newest  "${s_newest}" "${d_newest}"

if [[ "${s_posts}" != "${d_posts}" || "${s_opts}" != "${d_opts}" ]]; then
  echo
  echo "WARNING: counts differ. The source changed during the sync (normal on a"
  echo "live site) or something failed. Re-run to narrow the gap, and do the"
  echo "final run in a quiet window or with the source in maintenance mode."
fi

log "done -- verify over HTTP before switching DNS:"
echo "    curl -sI --resolve ${DOMAIN}:80:$(curl -s -4 ifconfig.me) http://${DOMAIN}/"
