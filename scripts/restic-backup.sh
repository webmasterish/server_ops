#!/usr/bin/env bash
#
# Nightly offsite backup. RUN ON hetzner, as root.
#
#   sudo ./restic-backup.sh            # dump databases, snapshot, prune
#   sudo ./restic-backup.sh --no-dump  # snapshot only (dumps already fresh)
#
# Tier 2 of docs/runbook-backups.md, and the only copy that survives losing the
# server. Normally invoked by restic-backup.timer at 03:15 UTC.
#
# Configuration lives in /etc/restic/restic.env (0600, root) and is NOT in this
# repo -- it holds the R2 credentials. See docs/runbook-backups.md for its
# shape. Under systemd it arrives via EnvironmentFile; run by hand, this script
# sources it.

set -euo pipefail

ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/restic.env}"
EXCLUDES="${RESTIC_EXCLUDES:-/etc/restic/excludes.txt}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DO_DUMP=1
[[ "${1:-}" == "--no-dump" ]] && DO_DUMP=0

[[ ${EUID} -eq 0 ]] || { echo "must run as root -- needs to read every site" >&2; exit 1; }

# What gets backed up.
#
# /etc is included whole rather than cherry-picked: it is a few MB, and the
# things that would hurt to lose are scattered through it -- the ondrej APT pin
# at preferences.d/99-ondrej-php-pin, every vhost, every FPM pool, the
# letsencrypt tree. Cherry-picking is how you discover in a restore that you
# forgot one. /etc/restic is excluded (see excludes.txt).
#
# /var/www/backups/hostinger was here until 2026-07-31, when the local copy of
# the Hostinger archive was deleted. It is NOT lost: snapshot 4f4eb80f, tagged
# hostinger-archive, holds it permanently and is outside the `forget --tag
# nightly` retention policy. See docs/runbook-backups.md.
PATHS=(
  /var/www/vhosts
  /var/www/backups/db
  /etc
)

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

# Only source the env file when the repository is not already configured, so
# systemd's EnvironmentFile wins and there is one source of truth per context.
if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
  [[ -r "${ENV_FILE}" ]] || {
    echo "no ${ENV_FILE} and RESTIC_REPOSITORY unset -- see docs/runbook-backups.md" >&2
    exit 1
  }
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

[[ -r "${EXCLUDES}" ]] || { echo "missing exclude file: ${EXCLUDES}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Databases first -- the snapshot is only as good as the dumps inside it
# ---------------------------------------------------------------------------

if [[ ${DO_DUMP} -eq 1 ]]; then
  log "dumping databases"
  "${HERE}/dump-databases.sh"
  echo
fi

# ---------------------------------------------------------------------------
# Snapshot
# ---------------------------------------------------------------------------

log "repository: ${RESTIC_REPOSITORY}"

# unlock first: an interrupted run (OOM, reboot mid-backup) leaves a stale lock
# that makes every subsequent run fail until someone notices. Stale locks are
# safe to remove; live ones are left alone by design.
restic unlock >/dev/null 2>&1 || true

log "snapshotting ${#PATHS[@]} paths"

# --one-file-system stops a stray bind mount from pulling in something huge.
# --exclude-caches honours CACHEDIR.TAG, which several PHP tools drop.
restic backup \
  --verbose \
  --one-file-system \
  --exclude-caches \
  --exclude-file="${EXCLUDES}" \
  --tag nightly \
  "${PATHS[@]}"

echo

# ---------------------------------------------------------------------------
# Retention -- the grandfather/father/son policy, expressed natively
# ---------------------------------------------------------------------------
# This is the same shape as the 2011 DigitalOcean script's daily/weekly/monthly
# rotation. The difference is that restic stores each generation as references
# to deduplicated blocks, so 20-odd generations cost roughly what one costs --
# where the old script's `cp` of the whole tree per generation would need
# ~120 GB on a disk with ~25 GB free.
#
# --keep-last 3 is a floor: it guarantees three snapshots survive even if the
# clock or the timer misbehaves and the date-based rules all match one day.
log "applying retention"

restic forget \
  --tag nightly \
  --keep-last 3 \
  --keep-daily 7 \
  --keep-weekly 5 \
  --keep-monthly 12 \
  --prune

echo
log "current snapshots"
restic snapshots --compact || true

echo
log "done"
