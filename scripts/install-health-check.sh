#!/usr/bin/env bash
#
# Install the daily health check. RUN ON hetzner.
#
#   ./install-health-check.sh           # install units, enable timer
#   ./install-health-check.sh --dry-run # show what would change, touch nothing
#
# Installs templates/systemd/health-check.{service,timer} and enables the
# timer. Runs the check once first: a monitor that has never been observed to
# pass is not a monitor, it is an untested script that will page you at 06:30.
#
# Idempotent. Backs up any existing unit before overwriting.
#
# The notify hook at /etc/health-check/notify is NOT installed here -- it is
# the one part that needs a credential or a URL. See
# docs/runbook-health-checks.md for the two shapes it can take.

set -euo pipefail

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${HERE}/../templates/systemd"
DST_DIR=/etc/systemd/system
BAK_DIR=/var/backups/systemd
SCRIPT="${HERE}/health-check.sh"

UNITS=(
  health-check.service health-check.timer
  review-reminder.service review-reminder.timer
)
TIMERS=(health-check.timer review-reminder.timer)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
run() { if (( DRY )); then printf '  would: %s\n' "$*"; else "$@"; fi; }

# --- preflight -------------------------------------------------------------

for u in "${UNITS[@]}"; do
  [[ -f "${SRC_DIR}/${u}" ]] || { echo "missing template: ${SRC_DIR}/${u}" >&2; exit 1; }
done

[[ -x "${SCRIPT}" ]] || {
  log "making ${SCRIPT} executable"
  run chmod +x "${SCRIPT}"
}

# The unit hardcodes an absolute ExecStart. If this checkout lives somewhere
# else the timer would fail nightly with status=203/EXEC, which is a confusing
# way to learn about a path mismatch.
EXPECTED=/home/webmasterish/server_ops/scripts/health-check.sh
if [[ "${SCRIPT}" != "${EXPECTED}" ]]; then
  echo "FAIL: this checkout is at ${SCRIPT}" >&2
  echo "      but health-check.service runs ${EXPECTED}" >&2
  echo "      install from the server checkout, or edit the unit's ExecStart" >&2
  exit 1
fi

# The freshness check reads the repository. Without this the check installs
# fine and then reports FAIL every morning for a reason that has nothing to do
# with the health of the machine.
#
# `sudo test`, not `[[ -r ]]`: the env file is 0600 root and this script runs
# as webmasterish, so a plain readability test always says no and blocks an
# install that would have worked perfectly. The check that matters is whether
# *root* can read it, because root is who the service runs as.
sudo test -r /etc/restic/restic.env || {
  echo "FAIL: /etc/restic/restic.env not readable by root -- see docs/runbook-backups.md" >&2
  exit 1
}

# --- prove it works before scheduling it -----------------------------------

log "running the check once (report mode) before installing"
echo
set +e
sudo "${SCRIPT}" --report
rc=$?
set -e
echo

case ${rc} in
  0) log "check passed clean" ;;
  2) log "check reported warnings (exit 2) -- installing anyway, that is a real result" ;;
  1) log "check reported failures (exit 1) -- installing anyway, that is a real result" ;;
  *) echo "FAIL: check exited ${rc}, which is not a verdict it is supposed to produce" >&2
     echo "      fix the script before scheduling it" >&2
     exit 1 ;;
esac

# --- install ---------------------------------------------------------------

for u in "${UNITS[@]}"; do
  if [[ -f "${DST_DIR}/${u}" ]]; then
    if cmp -s "${SRC_DIR}/${u}" "${DST_DIR}/${u}"; then
      log "${u} already current"
      continue
    fi
    run sudo mkdir -p "${BAK_DIR}"
    bak="${BAK_DIR}/${u}.$(date +%F-%H%M%S)"
    log "backing up existing ${u} to ${bak}"
    run sudo cp "${DST_DIR}/${u}" "${bak}"
  fi
  log "installing ${u}"
  run sudo install -o root -g root -m 644 "${SRC_DIR}/${u}" "${DST_DIR}/${u}"
done

log "reloading systemd"
run sudo systemctl daemon-reload

for t in "${TIMERS[@]}"; do
  log "enabling ${t}"
  run sudo systemctl enable --now "${t}"
done

if (( DRY )); then
  echo
  log "dry run -- nothing changed"
  exit 0
fi

echo
log "installed. next runs:"
systemctl list-timers "${TIMERS[@]}" --no-pager | sed -n '1,3p'
echo
log "read a run with:  journalctl -u health-check -n 40"
log "run by hand with: sudo ${SCRIPT} --report"

# `sudo test -x`, not `[[ -x ]]`: the hook is 0700 root and this script runs as
# webmasterish, so a plain test always reports it missing and prints a
# "nothing will tell you when it fails" warning at the exact moment a working
# channel is installed.
if ! sudo test -x /etc/health-check/notify; then
  echo
  log "NOTE: no notify hook at /etc/health-check/notify"
  log "      the check runs and logs, but nothing will tell you when it fails"
  log "      see docs/runbook-health-checks.md to wire one up"
fi
