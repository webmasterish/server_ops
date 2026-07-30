#!/usr/bin/env bash
#
# Dump every application database to /var/www/backups/db as .sql.bz2.
#
# RUN ON hetzner, as root.  sudo ./dump-databases.sh [--dry-run]
#
# This is tier 1 of the backup design (docs/runbook-backups.md): a local,
# human-grabbable copy that needs no tooling to restore. restic-backup.sh runs
# it first, then snapshots the results offsite -- so this script never talks to
# R2 and is useful on its own.
#
# Format is .sql.bz2 to match what the rest of the repo already consumes:
# verify-hostinger-backup.sh and sanitize-mariadb-dump.sh both expect it.
#
# Credentials come from /etc/mysql/debian.cnf, the packaged maintenance
# account -- the same source verify-hostinger-backup.sh uses. Nothing is read
# from any site's wp-config.php, because this dumps server-side rather than
# per-site, and nothing is ever printed.
#
# Idempotent: re-running on the same day overwrites that day's dump.

set -euo pipefail

DEST="${DB_BACKUP_DIR:-/var/www/backups/db}"
DEFAULTS="${MYSQL_DEFAULTS:-/etc/mysql/debian.cnf}"

# Matomo is ~1.0 GB of the ~1.3 GB total and rewrites its archive tables every
# day, so each dump is entirely new data that dedups against nothing -- daily
# it would account for most of the repo's ongoing growth. Weekly by decision
# (2026-07-30): it is analytics, and a week of loss is tolerable there in a way
# it is not for an order or an invoice.
#
# On the six non-dump days the previous dump stays on disk untouched, so every
# restic snapshot still contains a Matomo dump -- just one up to six days old.
# Because it is byte-identical it dedups perfectly and costs nothing.
WEEKLY_DBS="${WEEKLY_DBS:-dotaim_analytics_matomo}"
WEEKLY_DAY="${WEEKLY_DAY:-7}"          # ISO day of week; 7 = Sunday

KEEP_DAILY="${KEEP_DAILY:-7}"          # generations kept per daily database
KEEP_WEEKLY="${KEEP_WEEKLY:-2}"        # generations kept per weekly database

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

[[ ${EUID} -eq 0 ]] || { echo "must run as root -- needs ${DEFAULTS}" >&2; exit 1; }
[[ -r "${DEFAULTS}" ]] || { echo "cannot read ${DEFAULTS}" >&2; exit 1; }

TODAY="$(date +%F)"
DOW="$(date +%u)"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

mkdir -p "${DEST}"
chmod 750 "${DEST}"

# ---------------------------------------------------------------------------
# Which databases
# ---------------------------------------------------------------------------
# _verify_* are the throwaways verify-hostinger-backup.sh creates and drops. If
# a verify run was interrupted one can survive, and dumping it would be noise.
mapfile -t DBS < <(mysql --defaults-file="${DEFAULTS}" -N -B -e "
  SELECT schema_name FROM information_schema.schemata
  WHERE schema_name NOT IN ('information_schema','performance_schema','mysql','sys')
    AND schema_name NOT LIKE '\_verify\_%'
  ORDER BY schema_name;")

[[ ${#DBS[@]} -gt 0 ]] || { echo "no databases found -- refusing to continue" >&2; exit 1; }

log "${#DBS[@]} databases; today is day ${DOW} (weekly day is ${WEEKLY_DAY})"

# ---------------------------------------------------------------------------
# Prune -- keeps the N newest dumps of ONE database
# ---------------------------------------------------------------------------
# Deliberately narrow: it only ever globs "<db>_*.sql.bz2" inside ${DEST}, so it
# cannot touch a file it did not create. Filenames embed an ISO date, so a
# lexical sort is a chronological sort.
prune_db() {
  local db="$1" keep="$2"
  local -a found=()

  shopt -s nullglob
  found=( "${DEST}/${db}_"*.sql.bz2 )
  shopt -u nullglob

  [[ ${#found[@]} -le ${keep} ]] && return 0

  mapfile -t found < <(printf '%s\n' "${found[@]}" | sort -r)

  local i
  for (( i = keep; i < ${#found[@]}; i++ )); do
    if [[ ${DRY_RUN} -eq 1 ]]; then
      log "  would remove $(basename "${found[i]}")"
    else
      log "  pruning $(basename "${found[i]}")"
      rm -f -- "${found[i]}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Dump
# ---------------------------------------------------------------------------
FAILED=()

for db in "${DBS[@]}"; do
  keep="${KEEP_DAILY}"

  if [[ " ${WEEKLY_DBS} " == *" ${db} "* ]]; then
    keep="${KEEP_WEEKLY}"
    if [[ "${DOW}" != "${WEEKLY_DAY}" ]]; then
      log "${db}: weekly-only, not today -- leaving previous dump in place"
      prune_db "${db}" "${keep}"
      continue
    fi
  fi

  out="${DEST}/${db}_${TODAY}.sql.bz2"
  tmp="${out}.partial"

  if [[ ${DRY_RUN} -eq 1 ]]; then
    log "${db}: would dump to $(basename "${out}")"
    prune_db "${db}" "${keep}"
    continue
  fi

  log "${db}: dumping"

  # Written to .partial and moved into place only once it has been checked, so
  # a snapshot taken mid-dump never sees a truncated file that looks valid.
  # .partial is excluded from restic as a second line of defence.
  #
  # pipefail matters: without it a failed mysqldump still produces a valid,
  # empty bz2 and this would report success.
  if ! mysqldump --defaults-file="${DEFAULTS}" \
        --single-transaction --quick \
        --routines --events --triggers \
        --no-tablespaces \
        --default-character-set=utf8mb4 \
        "${db}" | bzip2 -9 > "${tmp}"; then
    log "${db}: FAILED -- dump did not complete"
    rm -f -- "${tmp}"
    FAILED+=("${db}")
    continue
  fi

  tables=$(bzcat "${tmp}" | grep -c '^CREATE TABLE' || true)
  if [[ "${tables}" -lt 1 ]]; then
    log "${db}: FAILED -- dump contains no CREATE TABLE statements"
    rm -f -- "${tmp}"
    FAILED+=("${db}")
    continue
  fi

  mv -f -- "${tmp}" "${out}"
  chmod 640 "${out}"
  log "${db}: ok -- ${tables} tables, $(du -h "${out}" | cut -f1)"

  prune_db "${db}" "${keep}"
done

# ---------------------------------------------------------------------------

echo
log "local dump store: $(du -sh "${DEST}" | cut -f1) in ${DEST}"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  log "FAILED: ${FAILED[*]}"
  exit 1
fi

log "all dumps ok"
