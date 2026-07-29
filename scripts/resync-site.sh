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
shift 3

# The 4th positional is the wp-path, and two of its legal values start with
# "--" (--piwigo, --no-db). Treating everything "--"-prefixed as an option made
# `resync-site.sh ... --piwigo --sub x` fail with "unknown option: --piwigo"
# while still having read it into WP_PATH -- so the value was right and the
# parse was wrong.
WP_PATH="cms"
if [[ $# -gt 0 ]]; then
  case "$1" in
    --piwigo|--no-db) WP_PATH="$1"; shift ;;
    --*)              : ;;              # a real option; leave it for the loop
    *)                WP_PATH="$1"; shift ;;
  esac
fi

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
# --chmod forces the house permissions as files land, rather than inheriting
# Hostinger's. There PHP ran as the account owner, so 755/644 was writable by
# the web server; here Apache runs as www-data, so the group needs write or
# WordPress cannot create content/upgrade/<plugin> and every plugin update
# fails with "Could not create directory".
# Page caches are excluded, and must be.
#
# They are regenerated on demand, so copying Hostinger's is pointless. Worse,
# --delete tries to remove the ones generated HERE -- which the FPM pool
# created as www-data, so rsync (running as webmasterish) fails with
# "Permission denied", exits 23, and under `set -e` the whole resync aborts
# part-way: on singlefunction.com that left the maintenance freeze in place and
# the database never rebuilt.
CACHE_EXCLUDES=(
  --exclude='content/cache/'
  --exclude='wp-content/cache/'
  --exclude='content/uploads/cache/'
)

# sudo: files WordPress creates are owned www-data:www-data, and this script
# runs as webmasterish, which is neither the owner nor (by default) in that
# group -- so rsync cannot overwrite a plugin file the site updated itself and
# dies with "mkstemp ... Permission denied", exit 23. This is a local copy, no
# SSH involved, so sudo costs nothing. The normalisation step below puts
# ownership back afterwards.
sudo rsync -a --delete --exclude='*.bak-*' "${CACHE_EXCLUDES[@]}" \
  --chmod=D775,F664 --stats \
  "${BACKUP}/sites/${DOMAIN}/public_html/" "${DOCROOT}/" \
  | grep -E 'Number of (regular files transferred|deleted files)' | sed 's/^/    /'

# Strip the cutover maintenance freeze from the DESTINATION copy.
#
# The source is deliberately frozen during a cutover (503 + Retry-After, see
# docs/runbook-site-cutover.md), which means its .htaccess carries the freeze
# block -- and the sync above faithfully copies it here. Without this the new
# site comes up serving 503 to everyone the moment DNS moves, which looks
# exactly like a failed migration.
#
# Marker-delimited so the strip is exact rather than a guess at line numbers.
if [[ -f "${DOCROOT}/.htaccess" ]] && grep -q 'MIGRATION-FREEZE-START' "${DOCROOT}/.htaccess"; then
  log "       stripping maintenance freeze from destination .htaccess"
  sed -i '/### MIGRATION-FREEZE-START/,/### MIGRATION-FREEZE-END/d' "${DOCROOT}/.htaccess"
fi
rm -f "${DOCROOT}/maintenance.html"

# Neutralise Hostinger's PHP-FPM SetHandler.
#
# Some sites carry an ACTIVE
#   SetHandler "proxy:unix:/var/run/php/php8.3-fpm.sock|fcgi://localhost"
# in .htaccess (nidaldirani.com and shamsaldhaher.com; most others have it
# commented). Hostinger ran PHP that way. Hetzner uses mod_php and does NOT
# load proxy_fcgi, so Apache does not recognise the handler and falls back to
# serving the file as a STATIC DOCUMENT -- returning raw PHP source instead of
# executing it. Verified: wp-config.php was served as plain text.
#
# Left unfixed this is both a broken site and a source disclosure, and it would
# go live the moment DNS moves.
#
# Commenting it out matches what the other migrated sites already have. The
# real fix is deciding between mod_php and PHP-FPM for the whole box -- see
# inventory B6 -- at which point this can be revisited.
if [[ -f "${DOCROOT}/.htaccess" ]] \
   && grep -qE '^[[:space:]]*SetHandler[[:space:]]+"proxy:unix:' "${DOCROOT}/.htaccess"; then
  log "       neutralising Hostinger PHP-FPM SetHandler (no proxy_fcgi here)"
  sed -i -E 's|^([[:space:]]*)(SetHandler[[:space:]]+"proxy:unix:)|\1# migrated: no proxy_fcgi on this host\n\1#\2|' \
    "${DOCROOT}/.htaccess"
fi

# ---------------------------------------------------------------------------
# 3. Re-apply the local DB naming
# ---------------------------------------------------------------------------
#
# MUST come after step 2. The synced master_config.php is Hostinger's, carrying
# the u918436082_* names -- step 2 overwrites whatever we set previously, so
# without this the site points at a database that does not exist here.

# The production config file is NOT consistently named. Across these sites it
# is master_config.php, main_config.php, live_config.php, or plain config.php
# as the generic fallback -- wp-config picks by $_SERVER['SERVER_NAME'] and each
# site was set up slightly differently. Hardcoding one name silently repoints
# nothing on the sites that use another, and the first symptom is a database
# connection error after cutover.
#
# So: find every file under .config/ that names the SOURCE database, and repoint
# all of them. Files that are not the active one are harmless to update.

SRC_DB=$(awk '/^database:/ {print $2}' "${BACKUP}/manifest/${DOMAIN}.txt" 2>/dev/null || true)

log "step 3/5 -- repointing config at ${DBNAME}"

# Piwigo has no wp-config and no .config directory -- its settings live in
# local/config/database.inc.php as a $conf array, so the WordPress repointer
# cannot touch it. Different file, same contract.
if [[ "${WP_PATH}" == "--piwigo" ]]; then
  PW_CONF="${DOCROOT}/local/config/database.inc.php"
  if [[ -f "${PW_CONF}" ]]; then
    log "       $(basename "${PW_CONF}") (piwigo)"
    php "${HERE}/set-piwigo-db.php" "${PW_CONF}" "${DBNAME}" | sed 's/^/         /'
  else
    log "       WARNING: ${PW_CONF} not found -- the site will not connect"
  fi
elif [[ -z "${SRC_DB}" || "${SRC_DB}" == "(none)" ]]; then
  log "       no source database recorded, skipping"
else
  mapfile -t CONFIG_FILES < <(grep -rl "${SRC_DB}" "${DOCROOT}/.config/" 2>/dev/null || true)
  if [[ ${#CONFIG_FILES[@]} -eq 0 ]]; then
    log "       WARNING: no config file under .config/ references ${SRC_DB}"
    log "       the site will not connect -- check the config layout by hand"
  fi
  for cf in "${CONFIG_FILES[@]}"; do
    log "       $(basename "${cf}")"
    php "${HERE}/set-site-db.php" "${cf}" "${DBNAME}" | sed 's/^/         /'
  done
fi

# ---------------------------------------------------------------------------
# 3b. Rewrite absolute paths left over from Hostinger
# ---------------------------------------------------------------------------
#
# Some plugins bake the filesystem path into wp-config.php or the database.
# WP Super Cache is the one seen here: it writes WPCACHEHOME into wp-config,
# then on every admin page load notices the path is wrong, tries to correct it,
# and fails because wp-config is deliberately not writable by www-data --
# surfacing as "Could not update wp-config.php! WPCACHEHOME must be set".
#
# This has to run on every resync, not once: step 2 re-copies wp-config.php
# from the source and reinstates the old path each time.

OLD_PATH="${SRC_DOCROOT_PREFIX:-/home/u918436082/domains}/${DOMAIN}/public_html"

if grep -q "${OLD_PATH}" "${DOCROOT}/wp-config.php" 2>/dev/null; then
  log "       rewriting stale source paths in wp-config.php"
  cp "${DOCROOT}/wp-config.php" "${DOCROOT}/wp-config.php.bak-$(date +%F-%H%M%S)"
  sed -i "s#${OLD_PATH}#${DOCROOT}#g" "${DOCROOT}/wp-config.php"
fi

# ---------------------------------------------------------------------------
# 3c. Normalise ownership and permissions
# ---------------------------------------------------------------------------
#
# LAST, after every file has been written. `sed -i` and `php` above recreate
# files and hand them the caller's default group, so normalising earlier leaves
# exactly the files this script touched owned wrongly -- wp-config.php ended up
# webmasterish:webmasterish that way, which is the file WordPress most needs to
# read.
#
# 775/664 with group www-data matches dotaim.com and ayatalquran.com, the two
# WordPress sites already working on this box.

log "       normalising ownership and permissions"
sudo chown -R webmasterish:www-data "${DOCROOT}"
sudo find "${DOCROOT}" -type d -exec chmod 775 {} +
sudo find "${DOCROOT}" -type f -exec chmod 664 {} +
# wp-config.php is deliberately NOT group-writable, unlike the rest of the
# tree. It holds the database credentials, and nothing in normal operation
# needs to rewrite it -- WP Super Cache tries, but only because it found a
# stale WPCACHEHOME, which step 3b has already corrected. Leaving it 664 would
# let any compromised plugin rewrite the file WordPress loads first on every
# request.
if [[ -f "${DOCROOT}/wp-config.php" ]]; then
  sudo chmod 644 "${DOCROOT}/wp-config.php"
fi

# ---------------------------------------------------------------------------
# 4. Rebuild the database
# ---------------------------------------------------------------------------

DUMP=$(ls -t "${BACKUP}"/db/*.sql.bz2 2>/dev/null \
  | xargs -I{} sh -c 'bzcat {} | head -40 | grep -ql "Database: " && echo {}' 2>/dev/null | head -1 || true)
DUMP="${DUMP:-$(ls -t "${BACKUP}"/db/*.sql.bz2 | head -1)}"

# Prefer the dump whose name matches the source database for this site.
# SRC_DB was resolved in step 3.
[[ -n "${SRC_DB}" && -f "${BACKUP}/db/${SRC_DB}.sql.bz2" ]] && DUMP="${BACKUP}/db/${SRC_DB}.sql.bz2"

log "step 4/5 -- rebuilding ${DBNAME} from $(basename "${DUMP}")"

"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${DBNAME}\`;
                  CREATE DATABASE \`${DBNAME}\`
                  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;"

bzcat "${DUMP}" | "${HERE}/sanitize-mariadb-dump.sh" | "${MYSQL[@]}" "${DBNAME}"

# Same stale paths, but inside the database -- and often inside PHP-serialized
# arrays, where the string length is stored alongside the value. A sed would
# change the text and leave the length wrong, quietly corrupting the option.
# wp search-replace understands serialization and fixes both.
if [[ "${WP_PATH}" != "--no-db" && "${WP_PATH}" != "--piwigo" ]]; then
  hits=$(cd "${DOCROOT}" && SERVER_NAME="${DOMAIN}" wp search-replace \
    "${OLD_PATH}" "${DOCROOT}" --all-tables --precise --dry-run \
    --path="${WP_PATH}" --skip-themes --skip-plugins --format=count 2>/dev/null | tail -1 || echo 0)
  if [[ "${hits:-0}" -gt 0 ]]; then
    log "       rewriting ${hits} stale source path(s) in the database"
    (cd "${DOCROOT}" && SERVER_NAME="${DOMAIN}" wp search-replace \
      "${OLD_PATH}" "${DOCROOT}" --all-tables --precise \
      --path="${WP_PATH}" --skip-themes --skip-plugins --quiet 2>/dev/null) || true
  fi
fi

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
