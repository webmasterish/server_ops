#!/usr/bin/env bash
#
# Machine-level health check. RUN ON hetzner, as root.
#
#   sudo ./health-check.sh           # terse: only WARN/FAIL lines, then a verdict
#   sudo ./health-check.sh --report  # every check, including the OK ones
#
# Normally invoked by health-check.timer at 06:30 UTC and never read by a
# human: silence means healthy. See docs/runbook-health-checks.md.
#
# Scope is deliberately the *machine* -- backups, capacity, services, certs.
# Per-site correctness (which FPM pool actually serves a vhost, whether
# wp-config.php is exposed) belongs to audit-sites.sh and is not duplicated
# here. That one writes a probe file into every docroot and takes ~30s of HTTP
# requests against production, which is fine monthly and wrong daily.
#
# Exit codes, because the notify hook and systemd both key off them:
#   0  everything OK
#   2  at least one WARN  -- degraded, look this week
#   1  at least one FAIL  -- something is broken now
#
# WARN and FAIL are different claims and are kept apart on purpose. A disk at
# 82% and a backup that has not run in three days should not produce the same
# alert, or the alert stops meaning anything and gets filtered.

set -uo pipefail

ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/restic.env}"
NOTIFY="${HEALTH_NOTIFY:-/etc/health-check/notify}"

REPORT=0
[[ "${1:-}" == "--report" ]] && REPORT=1

[[ ${EUID} -eq 0 ]] || { echo "must run as root -- reads restic creds and every site" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Thresholds
#
# Each of these is a number someone will want to argue with later, so they are
# in one block with the reasoning attached rather than buried in the checks.
# ---------------------------------------------------------------------------

# 36h, not 24h. The backup runs at 03:15 with up to 15m of RandomizedDelaySec,
# and the check runs at 06:30. A 24h window would false-alarm the first time a
# run took longer than usual; 36h still catches a single missed night.
SNAPSHOT_MAX_AGE_H=36

# restic-check.timer is weekly. 9 days allows one skipped week's worth of
# jitter (Persistent=true reruns after a reboot) without hiding a repo check
# that has genuinely stopped happening.
REPOCHECK_MAX_AGE_D=9

# Same 36h logic as the snapshot: logrotate.timer is daily at 00:00.
LOGROTATE_MAX_AGE_H=36

DISK_WARN=80
DISK_FAIL=90

# Percent of total RAM still available. Below 15% the box is one traffic spike
# from the OOM killer picking a victim, and it will pick mysqld.
MEM_AVAIL_WARN=15

# Swap in use is not itself a problem -- Linux will page out genuinely idle
# pages and leave them there for weeks. Half the swap file is the point where
# it stops being residue and starts being pressure.
SWAP_WARN=50

# 21 days. certbot.timer renews at 30 days remaining and runs twice daily, so
# anything still under 21 has failed to renew roughly 18 times and needs a
# human. Tighter than that and a single transient ACME failure pages you.
CERT_WARN_D=21
CERT_FAIL_D=10

# A pending reboot is normal for a day or two. A week means it has been
# forgotten, and the running kernel is missing whatever the update fixed.
REBOOT_WARN_D=7

# Services whose absence means the estate is down or unprotected. php*-fpm is
# globbed at check time because the set of installed PHP versions changes.
CORE_SERVICES=(apache2 mysql redis-server ufw fail2ban)

# ---------------------------------------------------------------------------
# Result plumbing
# ---------------------------------------------------------------------------

WARNS=0
FAILS=0
LINES=()

emit() { LINES+=("$1"); }

ok()   { emit "$(printf 'OK    %-22s %s' "$1" "$2")"; }
warn() { WARNS=$((WARNS + 1)); emit "$(printf 'WARN  %-22s %s' "$1" "$2")"; }
fail() { FAILS=$((FAILS + 1)); emit "$(printf 'FAIL  %-22s %s' "$1" "$2")"; }

# ---------------------------------------------------------------------------
# Backups
#
# This is the section the whole script exists for. The other checks describe a
# server that is having a bad day; these describe a server whose recovery plan
# has quietly stopped existing, which is only discovered when it is needed.
# ---------------------------------------------------------------------------

check_backup_freshness() {
  # THE check. A timer can be enabled, a service can exit 0, and the
  # repository can still not have received a snapshot for a week -- expired R2
  # credentials, a stale lock, a full disk during the dump. Every one of those
  # shows up here and nowhere else, because this asserts the outcome rather
  # than the mechanism.
  if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
    if [[ -r "${ENV_FILE}" ]]; then
      set -a
      # shellcheck disable=SC1090
      . "${ENV_FILE}"
      set +a
    else
      fail "backup/creds" "no ${ENV_FILE} and RESTIC_REPOSITORY unset"
      return
    fi
  fi

  local json age_h when
  # --latest 1 with the nightly tag: the hostinger-archive snapshot is a
  # permanent point-in-time record from 2026-07-30 and is deliberately never
  # renewed, so including it would make the repository look fresh forever.
  json=$(timeout 120 restic snapshots --tag nightly --latest 1 --json 2>/dev/null)

  if [[ -z "${json}" || "${json}" == "[]" ]]; then
    fail "backup/freshness" "cannot read snapshots from the repository"
    return
  fi

  when=$(python3 -c '
import sys, json, datetime
s = json.load(sys.stdin)
if not s:
    sys.exit(1)
print(s[-1]["time"])' <<< "${json}" 2>/dev/null)

  if [[ -z "${when}" ]]; then
    fail "backup/freshness" "no nightly snapshot found in the repository"
    return
  fi

  age_h=$(python3 -c '
import sys, datetime
t = datetime.datetime.fromisoformat(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc)
print(int((now - t).total_seconds() // 3600))' "${when}" 2>/dev/null)

  if [[ -z "${age_h}" ]]; then
    fail "backup/freshness" "could not parse snapshot timestamp: ${when}"
  elif (( age_h > SNAPSHOT_MAX_AGE_H * 2 )); then
    fail "backup/freshness" "newest snapshot is ${age_h}h old (limit ${SNAPSHOT_MAX_AGE_H}h)"
  elif (( age_h > SNAPSHOT_MAX_AGE_H )); then
    warn "backup/freshness" "newest snapshot is ${age_h}h old (limit ${SNAPSHOT_MAX_AGE_H}h)"
  else
    ok "backup/freshness" "newest nightly snapshot ${age_h}h old"
  fi
}

# Last run of a oneshot unit, as "<epoch> <success|failed>". Returns 1 if the
# unit has genuinely never run.
#
# Two sources, and the second one is not optional. systemd does NOT persist
# ExecMainStartTimestamp across a reboot: after a restart it reads empty for
# any oneshot that has not run since boot, and the naive reading of empty is
# "has never run". That would push two FAILs after every single reboot --
# observed on 2026-08-09, when the post-reboot check reported both restic
# units as never-run while the repository plainly held a 13h-old snapshot.
# A monitor that cries wolf on every restart is one you learn to ignore, so
# the false positive is a worse bug than the thing it would be reporting.
#
# The journal does persist here (/var/log/journal, boots recorded back to
# 2025-08), so it is the durable fallback. Order matters: systemctl is cheap
# and authoritative for the current boot; the journal is the record across
# boots.
unit_last_run() {
  local unit=$1 stamp epoch line
  stamp=$(systemctl show -p ExecMainStartTimestamp --value "${unit}" 2>/dev/null)
  if [[ -n "${stamp}" ]]; then
    epoch=$(date -d "${stamp}" +%s 2>/dev/null) || epoch=""
    if [[ -n "${epoch}" ]]; then
      printf '%s %s\n' "${epoch}" "$(systemctl show -p Result --value "${unit}" 2>/dev/null)"
      return 0
    fi
  fi

  # short-unix gives "<epoch>.<usec> host systemd[1]: <message>", so the epoch
  # is everything before the first dot.
  line=$(journalctl -u "${unit}" --no-pager -o short-unix 2>/dev/null \
         | grep -E '(Finished|Failed with result)' | tail -1)
  [[ -n "${line}" ]] || return 1

  if grep -q 'Failed with result' <<< "${line}"; then
    printf '%s %s\n' "${line%%.*}" "failed"
  else
    printf '%s %s\n' "${line%%.*}" "success"
  fi
}

check_unit_result() {
  # Distinguishes "ran and failed" from "has not run". Both are bad and they
  # need different fixes, so they get different messages.
  local unit=$1 label=$2 max_age_d=$3
  local info epoch result age_d

  if ! info=$(unit_last_run "${unit}"); then
    fail "${label}" "${unit} has never run"
    return
  fi

  epoch=${info%% *}
  result=${info##* }
  age_d=$(( ( $(date +%s) - epoch ) / 86400 ))

  if [[ "${result}" != "success" ]]; then
    fail "${label}" "${unit} last result: ${result:-unknown}"
  elif (( age_d > max_age_d )); then
    warn "${label}" "${unit} succeeded but ${age_d}d ago (limit ${max_age_d}d)"
  else
    ok "${label}" "${unit} succeeded ${age_d}d ago"
  fi
}

check_timers() {
  # A disabled timer is silent by construction: nothing fails, nothing runs.
  local t
  for t in restic-backup.timer restic-check.timer logrotate.timer certbot.timer; do
    if systemctl is-active --quiet "${t}"; then
      ok "timer/${t%.timer}" "active"
    else
      fail "timer/${t%.timer}" "NOT active"
    fi
  done
}

check_logrotate() {
  # Same cross-boot caveat as check_unit_result -- see unit_last_run.
  local info age_h
  if ! info=$(unit_last_run logrotate.service); then
    warn "logrotate/lastrun" "logrotate.service has no recorded run"
    return
  fi
  age_h=$(( ( $(date +%s) - ${info%% *} ) / 3600 ))
  if (( age_h > LOGROTATE_MAX_AGE_H )); then
    warn "logrotate/lastrun" "last rotated ${age_h}h ago (limit ${LOGROTATE_MAX_AGE_H}h)"
  else
    ok "logrotate/lastrun" "rotated ${age_h}h ago"
  fi
}

# ---------------------------------------------------------------------------
# Capacity
# ---------------------------------------------------------------------------

check_disk() {
  local pct avail
  pct=$(df --output=pcent / | tail -1 | tr -dc '0-9')
  avail=$(df -h --output=avail / | tail -1 | tr -d ' ')
  if (( pct >= DISK_FAIL )); then
    fail "disk/root" "${pct}% used, ${avail} free"
  elif (( pct >= DISK_WARN )); then
    warn "disk/root" "${pct}% used, ${avail} free"
  else
    ok "disk/root" "${pct}% used, ${avail} free"
  fi
}

check_memory() {
  local total avail pct
  total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  pct=$(( avail * 100 / total ))
  if (( pct < MEM_AVAIL_WARN )); then
    warn "mem/available" "${pct}% available ($(( avail / 1024 )) MB)"
  else
    ok "mem/available" "${pct}% available ($(( avail / 1024 )) MB)"
  fi
}

check_swap() {
  local total used pct
  total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
  used=$(( total - $(awk '/^SwapFree:/{print $2}' /proc/meminfo) ))
  if (( total == 0 )); then
    warn "swap" "no swap configured"
    return
  fi
  pct=$(( used * 100 / total ))
  if (( pct >= SWAP_WARN )); then
    warn "swap" "${pct}% used ($(( used / 1024 )) MB) -- check what is resident"
  else
    ok "swap" "${pct}% used ($(( used / 1024 )) MB)"
  fi
}

check_fpm_headroom() {
  # Sums pm.max_children across every pool and prices it at the observed
  # average RSS, then asks whether that worst case fits in RAM plus swap.
  #
  # RAM+swap rather than RAM alone, and that distinction is the whole check.
  # Exceeding RAM means the box swaps and gets slow, which is survivable and
  # self-correcting. Exceeding RAM+swap means the OOM killer has to choose,
  # and it chooses by RSS -- which on this machine is mysqld, taking every
  # site down at once rather than the one site that caused it.
  #
  # The worst case is reachable, which is why this warns rather than merely
  # reporting. Apache's MaxRequestWorkers is 150 and sum(max_children) is 111,
  # so 111 concurrent PHP requests is permitted by both layers -- nothing in
  # the configuration caps it below the number this check prices. `ondemand`
  # makes it unlikely (observed peak ~29 processes) but not impossible, and a
  # bot storm across several vhosts at once is exactly the shape that gets
  # there.
  #
  # MEDIAN, not mean. Measured 2026-08-09, per-process RSS ran min 15 /
  # median 52 / max 129 MB -- an 8x spread, because a WordPress request mid-
  # render and an idle worker are not the same animal. The mean chases
  # whatever is running at the instant of sampling: two runs four minutes
  # apart produced 38 MB and 48 MB, moving the verdict by 1.1 GB. A check
  # whose answer depends on when you asked it is not a check, and the first
  # spurious page is the one that teaches you to ignore the real one.
  local sum med_mb worst_mb total_mb swap_mb budget_mb n
  sum=$(grep -h '^pm.max_children' /etc/php/*/fpm/pool.d/*.conf 2>/dev/null \
        | awk -F= '{s+=$2} END {print s+0}')
  (( sum > 0 )) || { ok "fpm/headroom" "no pools found"; return; }

  # Sort by RSS and take the middle sample. Falls back to 50 MB if no worker
  # is running at all, which is normal on an idle box with ondemand pools --
  # and guessing there is better than dividing by zero.
  med_mb=$(ps -eo rss,comm 2>/dev/null \
    | awk '/php-fpm/{print $1}' | sort -n \
    | awk '{a[NR]=$1} END {if (NR) printf "%d", a[int(NR/2)+1]/1024; else print 50}')
  n=$(ps -eo comm 2>/dev/null | grep -c php-fpm || true)

  worst_mb=$(( sum * med_mb ))
  total_mb=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
  swap_mb=$(( $(awk '/^SwapTotal:/{print $2}' /proc/meminfo) / 1024 ))
  budget_mb=$(( total_mb + swap_mb ))

  if (( worst_mb > budget_mb )); then
    warn "fpm/headroom" "${sum} children x ${med_mb}MB median = ${worst_mb}MB exceeds ${budget_mb}MB RAM+swap"
  else
    ok "fpm/headroom" "${sum} children x ${med_mb}MB median = ${worst_mb}MB of ${budget_mb}MB RAM+swap (n=${n})"
  fi
}

# ---------------------------------------------------------------------------
# Services and configuration
# ---------------------------------------------------------------------------

check_services() {
  local s
  for s in "${CORE_SERVICES[@]}"; do
    if systemctl is-active --quiet "${s}"; then
      ok "svc/${s}" "active"
    else
      fail "svc/${s}" "NOT active"
    fi
  done

  # Globbed rather than listed: set-site-php.sh can introduce a new version at
  # any time, and a hardcoded list would silently stop covering it.
  local pool
  while IFS= read -r pool; do
    [[ -n "${pool}" ]] || continue
    if systemctl is-active --quiet "${pool}"; then
      ok "svc/${pool%.service}" "active"
    else
      fail "svc/${pool%.service}" "NOT active"
    fi
  done < <(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '$2=="enabled"{print $1}')
}

check_failed_units() {
  local n list
  n=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | grep -c . || true)
  if (( n > 0 )); then
    list=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd, -)
    fail "systemd/failed" "${n} failed unit(s): ${list}"
  else
    ok "systemd/failed" "none"
  fi
}

check_apache_config() {
  # Catches a vhost edited but not yet reloaded: the running Apache is fine,
  # so nothing looks wrong until the next restart takes every site down.
  if apache2ctl configtest >/dev/null 2>&1; then
    ok "apache/configtest" "syntax OK"
  else
    fail "apache/configtest" "$(apache2ctl configtest 2>&1 | tail -1)"
  fi
}

check_certs() {
  # Reads the certificate files directly instead of asking certbot. certbot
  # takes its own lock, and this runs while certbot.timer may be mid-renewal.
  local worst=9999 worst_name="" n=0 c name days
  for c in /etc/letsencrypt/live/*/cert.pem; do
    [[ -e "${c}" ]] || continue
    n=$(( n + 1 ))
    name=$(basename "$(dirname "${c}")")
    days=$(( ( $(date -d "$(openssl x509 -enddate -noout -in "${c}" 2>/dev/null | cut -d= -f2)" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    if (( days < worst )); then worst=${days}; worst_name=${name}; fi
  done

  if (( n == 0 )); then
    warn "certs" "no certificates found under /etc/letsencrypt/live"
  elif (( worst < CERT_FAIL_D )); then
    fail "certs" "${worst_name} expires in ${worst}d (${n} certs checked)"
  elif (( worst < CERT_WARN_D )); then
    warn "certs" "${worst_name} expires in ${worst}d (${n} certs checked)"
  else
    ok "certs" "${n} certs, soonest ${worst_name} in ${worst}d"
  fi
}

check_reboot() {
  # The flag file's mtime is not when the reboot became pending: every later
  # package that wants a reboot rewrites it. On 2026-09-25 a new kernel landed
  # on a reboot already 13 days overdue, the age reset to 0, and the next
  # morning's check reported OK. So remember when we first saw the flag, and
  # only forget it once the flag is gone. A timestamp older than the current
  # boot is from a pending reboot that has since happened, not this one.
  local since_file=/var/lib/health-check/reboot-pending-since
  if [[ ! -f /var/run/reboot-required ]]; then
    rm -f "${since_file}"
    ok "reboot" "not required"
    return
  fi
  local now boot since age_d pkgs
  now=$(date +%s)
  boot=$(( now - $(cut -d. -f1 /proc/uptime) ))
  since=$(cat "${since_file}" 2>/dev/null || true)
  if [[ ! "${since}" =~ ^[0-9]+$ ]] || (( since < boot )); then
    since=$(stat -c %Y /var/run/reboot-required)
    mkdir -p "${since_file%/*}"
    echo "${since}" > "${since_file}"
  fi
  age_d=$(( ( now - since ) / 86400 ))
  pkgs=$(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null | head -c 100)
  if (( age_d >= REBOOT_WARN_D )); then
    warn "reboot" "pending ${age_d}d: ${pkgs}"
  else
    ok "reboot" "pending ${age_d}d: ${pkgs}"
  fi
}

check_ssh_exposure() {
  # Cheap assertion that a hardening decision has not been undone by a package
  # upgrade dropping a new file into /etc/ssh/sshd_config.d/.
  local pw
  pw=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
  if [[ "${pw}" == "yes" ]]; then
    warn "ssh/passwordauth" "enabled -- keys are the only intended auth here"
  else
    ok "ssh/passwordauth" "disabled"
  fi
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

check_backup_freshness
check_unit_result restic-backup.service "backup/lastrun" 2
check_unit_result restic-check.service  "backup/repocheck" "${REPOCHECK_MAX_AGE_D}"
check_timers
check_logrotate
check_disk
check_memory
check_swap
check_fpm_headroom
check_services
check_failed_units
check_apache_config
check_certs
check_reboot
check_ssh_exposure

# ---------------------------------------------------------------------------
# Output
#
# Terse mode prints only what is wrong. That is what makes a daily unattended
# run readable: if the report is 30 green lines every morning, nobody reads the
# morning it is 29 green lines and one red one.
# ---------------------------------------------------------------------------

if (( FAILS > 0 )); then
  VERDICT="FAIL"; RC=1
elif (( WARNS > 0 )); then
  VERDICT="WARN"; RC=2
else
  VERDICT="OK"; RC=0
fi

OUT="health-check ${VERDICT} on $(hostname -s) at $(date -Is)"$'\n'

if (( REPORT == 1 )); then
  OUT+="$(printf '%s\n' "${LINES[@]}")"$'\n'
else
  # `|| true` because grep exits 1 when everything is OK and there is nothing
  # to print, which under a stricter shell would be read as a failed check.
  OUT+="$(printf '%s\n' "${LINES[@]}" | grep -Ev '^OK ' || true)"$'\n'
fi

OUT+="$(printf '%d checks, %d warn, %d fail' "${#LINES[@]}" "${WARNS}" "${FAILS}")"

printf '%s\n' "${OUT}"

# Hand off to whatever channel the owner configured. Optional by design: the
# check is useful without it (journalctl -u health-check), and requiring a
# credential before the thing will run at all is how monitoring ends up never
# getting installed.
if (( RC != 0 )) && [[ -x "${NOTIFY}" ]]; then
  printf '%s\n' "${OUT}" | "${NOTIFY}" "${VERDICT}" || true
fi

exit "${RC}"
