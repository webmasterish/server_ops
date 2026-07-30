#!/usr/bin/env bash
#
# Install the vhost logrotate rule. RUN ON hetzner.
#
#   ./install-logrotate.sh [--force-rotate]
#
# Installs templates/logrotate-vhosts.conf to /etc/logrotate.d/vhosts, after
# a debug run to confirm logrotate actually matches the files and is willing
# to act on them. Without --force-rotate it only installs; the first real
# rotation then happens on the next daily timer.
#
# --force-rotate additionally runs the rotation immediately. That is what
# reclaims the accumulated space. It COMPRESSES rather than discards -- the
# data survives as .log.1.gz and is pruned after 30 days by the normal cycle.
#
# Idempotent. Backs up any existing rule before overwriting.

set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force-rotate" ]] && FORCE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../templates/logrotate-vhosts.conf"
DST=/etc/logrotate.d/vhosts

# NOT alongside DST. logrotate reads *every* file in /etc/logrotate.d/ with no
# extension filter, so a .bak left in there is parsed as a second live rule
# covering the same globs. logrotate then reports "duplicate log entry",
# skips that file, and exits 1 -- which makes logrotate.service fail every
# night even though the rotations themselves succeeded. That is exactly what
# happened on 2026-07-29; the unit was in `failed` state until 2026-07-30.
BAK_DIR=/var/backups/logrotate

[[ -f "${SRC}" ]] || { echo "missing template: ${SRC}" >&2; exit 1; }

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# `|| true` on every find: the Matomo tmp directories are not readable by this
# user, so find exits non-zero even with stderr discarded, and pipefail would
# turn that into a silent abort before anything is installed.
log_gb() {
  { find /var/www/vhosts -name "$1" -printf '%s\n' 2>/dev/null || true; } \
    | awk '{s+=$1} END {printf "%.1f", s/1073741824}'
}

before=$(log_gb '*.log')
log "vhost logs currently: ${before} GB"

if [[ -f "${DST}" ]]; then
  sudo mkdir -p "${BAK_DIR}"
  bak="${BAK_DIR}/vhosts.$(date +%F-%H%M%S)"
  log "backing up existing rule to ${bak}"
  sudo cp "${DST}" "${bak}"
fi

# Sweep up any backup left in the config directory by an earlier version of
# this script, which wrote them next to DST. Moved rather than deleted, and
# only files matching the name this script itself generated.
while IFS= read -r stray; do
  [[ -n "${stray}" ]] || continue
  sudo mkdir -p "${BAK_DIR}"
  log "relocating stray config-dir backup: $(basename "${stray}")"
  sudo mv "${stray}" "${BAK_DIR}/$(basename "${stray}")"
done < <(sudo find /etc/logrotate.d -maxdepth 1 -name 'vhosts.bak-*' 2>/dev/null || true)

log "installing ${DST}"
sudo install -o root -g root -m 644 "${SRC}" "${DST}"

# Debug mode parses the config and reports what it *would* do, changing
# nothing. If the su/create lines are wrong this is where it surfaces, rather
# than silently skipping every file at 00:00.
log "validating (dry run)"

# Capture once into a variable rather than piping straight into grep -q.
# grep -q exits on first match, which SIGPIPEs logrotate, which under
# pipefail makes the whole pipeline non-zero -- reporting "matched no files"
# at the exact moment it matched one.
dryrun=$(sudo logrotate -d "${DST}" 2>&1 || true)
matched=$(grep -c 'considering log' <<< "${dryrun}" || true)

if [[ "${matched}" -lt 1 ]]; then
  echo "FAIL: logrotate matched no files -- check the globs" >&2
  tail -20 <<< "${dryrun}" >&2
  exit 1
fi

log "matches ${matched} log files"

# In debug mode logrotate marks files it has never seen as "last rotated now",
# so it always reports they do not need rotating. That is expected on a first
# run and says nothing about whether -f will work.

if [[ ${FORCE} -eq 1 ]]; then
  log "forcing immediate rotation (compress, not discard)"
  sudo logrotate -v -f "${DST}" 2>&1 | grep -E '^(rotating|compressing|removing)' | head -40

  after=$(log_gb '*.log')
  archived=$(log_gb '*.log.*')
  log "vhost logs now: ${after} GB live, ${archived} GB archived"
else
  log "installed only -- first rotation runs on the next daily timer"
  log "re-run with --force-rotate to reclaim space now"
fi

echo
df -h / | tail -1
