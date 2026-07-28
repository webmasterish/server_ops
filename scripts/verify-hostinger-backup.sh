#!/usr/bin/env bash
#
# Verify a Hostinger backup set. RUN ON hetzner.
#
#   ./verify-hostinger-backup.sh [yyyy-mm-dd]
#
# "Verified backups" is the actual 2026-07-31 commitment, and an unverified
# copy does not count. This checks the part that can silently be wrong: whether
# each dump actually restores into the destination engine.
#
# For every dump it:
#   - reports the collations present (the MariaDB 11.x uca1400 family is the
#     one that would need rewriting for MySQL 8.0 -- see inventory B5)
#   - imports into a throwaway database
#   - compares tables created against CREATE TABLE statements in the dump
#   - drops the throwaway
#
# The throwaway databases are named _verify_* and are created and dropped by
# this script. It touches nothing else -- no production database is read or
# written.
#
# File-level verification already happened at capture time: backup-hostinger-
# site.sh compares source and destination file counts and refuses to write a
# manifest unless they match.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATE="${1:-$(date +%F)}"
DEST="${BACKUP_ROOT:-/var/www/backups/hostinger}/${DATE}"
MYSQL=(sudo mysql --defaults-file=/etc/mysql/debian.cnf)

[[ -d "${DEST}/db" ]] || { echo "no such backup set: ${DEST}"; exit 1; }

printf '%-34s %6s %6s  %-28s %s\n' DATABASE TABLES IMPORT COLLATIONS RESULT
printf '%s\n' "--------------------------------------------------------------------------------------------"

FAILED=0

for f in "${DEST}"/db/*.sql.bz2; do
  [[ -e "${f}" ]] || continue
  name=$(basename "${f}" .sql.bz2)
  tmp="_verify_${name:0:50}"

  expected=$(bzcat "${f}" | grep -c '^CREATE TABLE')
  collations=$(bzcat "${f}" | grep -oE 'COLLATE=[a-z0-9_]+' | sort -u \
    | sed 's/COLLATE=//' | paste -sd, - )
  [[ -z "${collations}" ]] && collations="(none declared)"

  "${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${tmp}\`; CREATE DATABASE \`${tmp}\`;" 2>/dev/null

  # Restores go through the sanitiser, because that is how they will happen for
  # real. Verifying the raw dump would test something we never intend to do.
  if bzcat "${f}" | "${HERE}/sanitize-mariadb-dump.sh" | "${MYSQL[@]}" "${tmp}" 2>/tmp/verify_err_$$; then
    imported=$("${MYSQL[@]}" -N -e \
      "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${tmp}';")
    if [[ "${imported}" == "${expected}" ]]; then
      result="OK"
    else
      result="MISMATCH"
      FAILED=$((FAILED + 1))
    fi
  else
    imported="-"
    result="IMPORT FAILED: $(head -1 /tmp/verify_err_$$)"
    FAILED=$((FAILED + 1))
  fi
  rm -f /tmp/verify_err_$$

  # uca1400 is the MariaDB 11.x collation family MySQL 8.0 does not know.
  case "${collations}" in
    *uca1400*) result="${result} (via sanitiser)" ;;
  esac

  printf '%-34s %6s %6s  %-28s %s\n' "${name}" "${expected}" "${imported}" "${collations}" "${result}"

  "${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${tmp}\`;" 2>/dev/null
done

echo
if [[ ${FAILED} -eq 0 ]]; then
  echo "All dumps restore cleanly into $("${MYSQL[@]}" -N -e 'SELECT VERSION();')"
else
  echo "${FAILED} problem(s) found -- see above"
fi

echo
echo "File-level results (from capture-time manifests):"
for m in "${DEST}"/manifest/*.txt; do
  d=$(basename "${m}" .txt)
  got=$(awk '/^files:/ {print $2}' "${m}")
  src=$(awk -F'reported ' '/^files:/ {print $2}' "${m}" | tr -d ')')
  if [[ "${got}" == "${src}" ]]; then mark="OK"; else mark="MISMATCH"; FAILED=$((FAILED+1)); fi
  printf '  %-28s %10s files  %s\n' "${d}" "${got}" "${mark}"
done

exit $(( FAILED > 0 ))
