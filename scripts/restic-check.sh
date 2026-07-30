#!/usr/bin/env bash
#
# Verify the offsite repository. RUN ON hetzner, as root.
#
#   sudo ./restic-check.sh              # structure + 5% of pack data
#   sudo ./restic-check.sh --full       # structure + every byte (slow, egress)
#
# Normally invoked by restic-check.timer, Sundays 05:00 UTC.
#
# "Verified backups" was the actual commitment, and a repository that has never
# been read back is not verified. `restic check` walks the index and confirms
# every blob a snapshot references exists; --read-data-subset additionally
# downloads a sample and checks it against its hash, which is what catches
# silent corruption at the storage end.
#
# 5% weekly means the whole repository is covered roughly every five months,
# with no single week costing much egress. On R2 egress is free, so the ceiling
# here is time rather than money.

set -euo pipefail

ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/restic.env}"
SUBSET="${CHECK_SUBSET:-5%}"

[[ ${EUID} -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
  [[ -r "${ENV_FILE}" ]] || { echo "no ${ENV_FILE} and RESTIC_REPOSITORY unset" >&2; exit 1; }
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

restic unlock >/dev/null 2>&1 || true

if [[ "${1:-}" == "--full" ]]; then
  log "checking repository (reading ALL data)"
  restic check --read-data
else
  log "checking repository (reading ${SUBSET} of data)"
  restic check --read-data-subset="${SUBSET}"
fi

echo
log "repository statistics"
restic stats --mode raw-data || true

echo
log "check passed"
