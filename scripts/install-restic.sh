#!/usr/bin/env bash
#
# Install the offsite backup stack. RUN ON hetzner.
#
#   sudo ./install-restic.sh            # install + validate, timers left OFF
#   sudo ./install-restic.sh --enable   # ...and start the timers
#
# Installs restic, the exclude list and the systemd units, then checks that the
# repository is reachable. It does NOT create /etc/restic/restic.env -- that
# holds the R2 credentials and you write it yourself, on the server, so the
# keys never pass through anyone else's hands. See docs/runbook-backups.md.
#
# Idempotent, and safe to re-run after editing the template or the excludes.
# Without --enable nothing is scheduled, so a first run cannot surprise you.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="${HERE}/../templates"
ENV_FILE=/etc/restic/restic.env
PASS_FILE=/root/.restic-pass

ENABLE=0
[[ "${1:-}" == "--enable" ]] && ENABLE=1

[[ ${EUID} -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Binary
# ---------------------------------------------------------------------------

if ! command -v restic >/dev/null; then
  log "installing restic from apt"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq restic
else
  log "restic already present"
fi
log "restic $(restic version | awk '{print $2}')"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

install -d -m 700 -o root -g root /etc/restic

# Backed up before overwriting, and NOT into /etc/restic -- logrotate taught us
# what happens when a backup file is left inside a directory something else
# globs. See the header of install-logrotate.sh.
if [[ -f /etc/restic/excludes.txt ]]; then
  install -d -m 700 /var/backups/restic
  cp /etc/restic/excludes.txt "/var/backups/restic/excludes.txt.$(date +%F-%H%M%S)"
fi
install -o root -g root -m 600 "${TPL}/restic-excludes.txt" /etc/restic/excludes.txt
log "installed /etc/restic/excludes.txt"

for unit in restic-backup.service restic-backup.timer \
            restic-check.service restic-check.timer; do
  install -o root -g root -m 644 "${TPL}/systemd/${unit}" "/etc/systemd/system/${unit}"
done
systemctl daemon-reload
log "installed 4 systemd units"

# ---------------------------------------------------------------------------
# Preconditions -- fail loudly here rather than at 03:15
# ---------------------------------------------------------------------------

[[ -r "${ENV_FILE}" ]] || fail "missing ${ENV_FILE} -- see docs/runbook-backups.md"

perms=$(stat -c '%a %U' "${ENV_FILE}")
[[ "${perms}" == "600 root" ]] || fail "${ENV_FILE} is '${perms}', must be '600 root'"

set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

[[ -n "${RESTIC_REPOSITORY:-}" ]] || fail "RESTIC_REPOSITORY not set in ${ENV_FILE}"
[[ -n "${RESTIC_PASSWORD_FILE:-}" ]] || fail "RESTIC_PASSWORD_FILE not set in ${ENV_FILE}"
[[ -r "${RESTIC_PASSWORD_FILE}" ]] || fail "cannot read ${RESTIC_PASSWORD_FILE}"

pperms=$(stat -c '%a %U' "${PASS_FILE}" 2>/dev/null || echo "missing")
[[ "${pperms}" == "600 root" ]] || fail "${PASS_FILE} is '${pperms}', must be '600 root'"

# Never echo the value -- only whether there is one.
[[ -s "${RESTIC_PASSWORD_FILE}" ]] || fail "${RESTIC_PASSWORD_FILE} is empty"
log "credentials present and correctly permissioned"

# ---------------------------------------------------------------------------
# Repository
# ---------------------------------------------------------------------------

if restic cat config >/dev/null 2>&1; then
  log "repository reachable and already initialised"
else
  log "repository not initialised -- running restic init"
  restic init
  log "initialised"
fi

# wc -l rather than grep -c: grep -c exits 1 on zero matches, so the `|| echo 0`
# fallback fired *in addition to* grep's own "0" and the count printed twice.
snap_count=$(restic snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l)
log "snapshots currently in repository: ${snap_count}"

# ---------------------------------------------------------------------------
# Dry run: confirm the excludes match what we think they match
# ---------------------------------------------------------------------------
# --dry-run walks the whole tree and reports what *would* be stored without
# writing anything. This is where a wrong exclude pattern surfaces, rather than
# in six months when someone needs a file that was never in the repository.

log "dry run (nothing is written)"
restic backup --dry-run --verbose \
  --one-file-system --exclude-caches \
  --exclude-file=/etc/restic/excludes.txt \
  --tag nightly \
  /var/www/vhosts /var/www/backups/db /var/www/backups/hostinger /etc 2>&1 | tail -5

# ---------------------------------------------------------------------------

if [[ ${ENABLE} -eq 1 ]]; then
  systemctl enable --now restic-backup.timer restic-check.timer
  log "timers enabled"
  systemctl list-timers 'restic-*' --no-pager | head -4
else
  log "installed but NOT scheduled -- re-run with --enable to start the timers"
fi

echo
log "run one now with:  sudo systemctl start restic-backup.service"
log "watch it with:     journalctl -fu restic-backup.service"
