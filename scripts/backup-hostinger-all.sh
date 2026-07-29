#!/usr/bin/env bash
#
# Back up every in-scope Hostinger site, largest first.
#
# RUN THIS ON hetzner.  ./backup-hostinger-all.sh
#
# Largest first is deliberate: menamaps.com alone is over half the payload, so
# starting it first means the long pole runs while everything else finishes
# around it, and a failure surfaces early rather than four hours in.
#
# Idempotent -- re-running re-syncs deltas only. Safe to re-run after a failure;
# completed sites cost seconds the second time.
#
# Deliberately NOT in scope (docs/inventory.md section 1.1):
#   woo.lushlebanon.com        moved to Shopify, backup has no value
#   shamsaldhaher.com          migrate/keep decision still open
#   billing.shamsaldhaher.com  migrate/keep decision still open
#
# Those three are excluded by decision, not oversight. If the deadline
# commitment is meant to cover everything on the account, the latter two still
# need a run before the plan lapses.

set -uo pipefail

SET="${BACKUP_SET:-synced}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONE="${HERE}/backup-hostinger-site.sh"
DEST="${BACKUP_ROOT:-/var/www/backups/hostinger}/${SET}"
LOG="${DEST}/run.log"

# domain <TAB> db-mode   (a wp subpath, --piwigo, or --no-db)
SITES=$(cat <<'LIST'
menamaps.com	cms
memories.mardini.net	--piwigo
lebanese.tech	cms
videotizer.com	cms
hirement.com	cms
grand-emerald.com	cms
nidaldirani.com	cms
singlefunction.com	cms
skinosis.com	cms
sasf-ksa.com	--no-db
webmasterish.com	--no-db
lamarkazia.com	--no-db
nizonet.com	--no-db
mardini.net	--no-db
LIST
)

mkdir -p "${DEST}"
exec > >(tee -a "${LOG}") 2>&1

echo "=============================================================="
echo "Hostinger backup run -- ${SET}"
echo "started $(date -Is)"
echo "=============================================================="

FAILED=()
OK=()

# Read the site list on fd 3, not stdin. ssh inside the loop body reads stdin
# greedily and will swallow the remaining lines -- the first run of this script
# backed up menamaps.com and then silently skipped the other 13 sites.
while IFS=$'\t' read -r domain mode <&3; do
  [[ -z "${domain}" ]] && continue
  echo
  echo "-------------------------------------------------------------"
  echo ">>> ${domain} (${mode})"
  echo "-------------------------------------------------------------"
  if BACKUP_SET="${SET}" "${ONE}" "${domain}" "${mode}"; then
    OK+=("${domain}")
  else
    echo "*** FAILED: ${domain}"
    FAILED+=("${domain}")
  fi
done 3<<< "${SITES}"

# ---------------------------------------------------------------------------
# Account-root files -- menamaps tooling that lives outside any docroot and
# would be missed by a domains-only sync. See inventory section 1.6.
# ---------------------------------------------------------------------------

echo
echo ">>> account root files"
mkdir -p "${DEST}/home"
rsync -a --stats -e "ssh -o BatchMode=yes" \
  --include='mm-scripts/***' \
  --include='*.json' \
  --exclude='*' \
  hostinger:./ "${DEST}/home/" && OK+=("~ root files") || FAILED+=("~ root files")

# ---------------------------------------------------------------------------

echo
echo "=============================================================="
echo "finished $(date -Is)"
echo "ok:     ${#OK[@]}  -- ${OK[*]}"
echo "failed: ${#FAILED[@]} -- ${FAILED[*]:-none}"
echo "total on disk: $(du -sh "${DEST}" | cut -f1)"
echo "=============================================================="

[[ ${#FAILED[@]} -eq 0 ]]
