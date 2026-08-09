#!/usr/bin/env bash
#
# Push the periodic-review reminder. RUN ON hetzner, as root.
#
#   sudo ./review-reminder.sh          # send the reminder for today's date
#   sudo ./review-reminder.sh --print  # print it, send nothing
#
# Invoked by review-reminder.timer on the 1st of each month at 09:00 UTC.
# Goes out through the same /etc/health-check/notify hook as the health check,
# so it lands wherever alerts land and there is one channel to keep working.
#
# WHY THIS EXISTS AS A TIMER. The monthly and quarterly reviews in
# docs/runbook-health-checks.md are the two things in the whole regime with no
# automatic trigger -- the daily check runs itself, but "look at the trends"
# and "prove you can restore" only happen if someone remembers. A runbook
# nobody re-opens is a runbook that documents an intention. This is the part
# that makes the cadence real.
#
# It is deliberately NOT part of health-check.sh. A chore is not a fault:
# folding it in would mean the daily check goes non-OK for a reason that has
# nothing to do with the health of the machine, and once "WARN" can mean "it
# is the 1st" you have taught yourself to skim past WARN.

set -uo pipefail

NOTIFY="${HEALTH_NOTIFY:-/etc/health-check/notify}"
STATE=/var/lib/health-check
LAST_DRILL="${STATE}/last-restore-drill"

PRINT=0
[[ "${1:-}" == "--print" ]] && PRINT=1

# Handled first: recording a completed drill has nothing to do with composing
# a reminder, and doing it up here keeps that path from depending on any of
# the date arithmetic below.
if [[ "${1:-}" == "--drill-done" ]]; then
  install -d -m 755 "${STATE}"
  date +%F > "${LAST_DRILL}"
  echo "recorded restore drill: $(cat "${LAST_DRILL}")"
  exit 0
fi

month=$(date +%m)
month_name=$(date +%B)

# Quarters land on Jan/Apr/Jul/Oct. The restore drill is the one item that
# actually proves the backups are backups rather than an untested habit, so it
# gets called out rather than left to the runbook.
drill_due=0
case "${month}" in
  01|04|07|10) drill_due=1 ;;
esac

drill_note=""
if [[ -r "${LAST_DRILL}" ]]; then
  last=$(cat "${LAST_DRILL}" 2>/dev/null)
  last_epoch=$(date -d "${last}" +%s 2>/dev/null || echo 0)
  if (( last_epoch > 0 )); then
    days=$(( ( $(date +%s) - last_epoch ) / 86400 ))
    drill_note="last restore drill: ${last} (${days} days ago)"
    (( days > 100 )) && drill_due=1
  fi
else
  drill_note="last restore drill: NEVER RECORDED"
  drill_due=1
fi

{
  printf 'Monthly review due -- %s\n\n' "${month_name}"

  printf 'On hetzner:\n'
  printf '  sudo ~/server_ops/scripts/health-check.sh --report\n'
  printf '  ~/server_ops/scripts/audit-sites.sh\n\n'

  printf 'Then look at the things no threshold can judge:\n'
  printf '  - log volume vs the 30-day window\n'
  printf '  - traffic shape (bot share was 65%% on 2026-08-09)\n'
  printf '  - pending updates and reboots\n'
  printf '  - pool count vs fpm/headroom\n\n'

  if (( drill_due )); then
    printf 'QUARTERLY RESTORE DRILL IS DUE.\n'
    printf '%s\n\n' "${drill_note}"
    printf 'restic check proves the repository is intact. It does NOT prove\n'
    printf 'you can rebuild a site from it. Only the drill does:\n\n'
    printf '  sudo restic restore latest --target /tmp/drill \\\n'
    printf '    --include /var/www/vhosts/dotaim/skinosis.com/httpdocs\n'
    printf '  sudo diff -r /tmp/drill/var/www/vhosts/dotaim/skinosis.com/httpdocs \\\n'
    printf '               /var/www/vhosts/dotaim/skinosis.com/httpdocs\n'
    printf '  sudo rm -rf /tmp/drill\n\n'
    printf 'When it passes, record it:\n'
    printf '  sudo ~/server_ops/scripts/review-reminder.sh --drill-done\n\n'
  else
    printf '%s\n\n' "${drill_note}"
  fi

  printf 'Runbook: docs/runbook-health-checks.md\n'
} > /tmp/review-reminder.$$

if (( PRINT )); then
  cat /tmp/review-reminder.$$
  rm -f /tmp/review-reminder.$$
  exit 0
fi

if [[ -x "${NOTIFY}" ]]; then
  "${NOTIFY}" REVIEW < /tmp/review-reminder.$$ \
    && echo "reminder sent" \
    || echo "notify hook failed -- see the channel's log" >&2
else
  echo "no notify hook at ${NOTIFY} -- printing instead" >&2
  cat /tmp/review-reminder.$$
fi

rm -f /tmp/review-reminder.$$
