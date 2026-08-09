#!/usr/bin/env bash
#
# Right-size pm.max_children across the FPM pools. RUN ON hetzner.
#
#   ./tune-fpm-pools.sh --dry-run   # show every change, touch nothing
#   ./tune-fpm-pools.sh             # apply, validate, reload pool by pool
#   ./tune-fpm-pools.sh --revert    # restore the most recent backup set
#
# WHY. sum(pm.max_children) was 111 against 3819 MB RAM + 2047 MB swap. At the
# measured median worker RSS (50-57 MB) the theoretical worst case reached
# 5994-6327 MB -- over budget, and health-check.sh started warning on
# 2026-08-09. Exceeding RAM alone just means swapping; exceeding RAM+swap means
# the OOM killer picks a victim by RSS, which here is mysqld. That takes all 17
# sites down at once rather than the one site that caused it.
#
# The worst case is reachable: Apache MaxRequestWorkers is 150, so nothing in
# the stack caps concurrency below 111.
#
# SIZING. Yesterday's request counts, which are not close:
#
#     ayatalquran.com   243,691      <- 15x the next one
#     singlefunction     16,326
#     menamaps.com       11,144      <- takes orders
#     skinosis            7,985
#     hirement            7,819
#     dotaim.com          6,135
#     lebanese.tech       5,573
#     videotizer          3,713
#     ...everything else under 3,500
#
# 243,691/day is 2.8 req/s average. At a 100 ms PHP response that is well under
# one concurrent worker; 8 covers a 20x burst. The long tail runs at 0.04-0.19
# req/s, where 8 workers was never load-derived -- it is just the number the
# provisioning template happened to carry. 4 covers a 100x burst there.
#
# The three www.conf pools are the packaged defaults. 8.3's is NOT dead:
# /etc/apache2/conf-enabled/php-fpm-default.conf routes any .php that no
# per-vhost FilesMatch claims to /run/php/php8.3-fpm.sock -- that is what the
# "Primary script unknown" scanner noise has been hitting. It keeps its 5.
# Nothing references the 7.4 or 8.5 defaults, so they drop to 2 rather than
# being disabled, which stays reversible and keeps a fallback available.
#
# Result: 63 children x ~54 MB = ~3400 MB, 58% of RAM+swap. That leaves the
# median room to drift to ~93 MB before the check warns again.

set -euo pipefail

MODE="${1:-}"
POOL_DIR_GLOB='/etc/php/*/fpm/pool.d'
BAK_ROOT=/var/backups/php-fpm

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# pool basename -> new max_children. Anything not listed is left alone, so a
# pool added later is untouched until someone decides its number deliberately.
declare -A TARGET=(
  [ayatalquran.com]=8
  [menamaps.com]=6
  [analytics.dotaim.com]=4
  [dotaim.com]=4
  [grand-emerald.com]=4
  [hirement.com]=4
  [lebanese.tech]=4
  [memories.mardini.net]=4
  [nidaldirani.com]=4
  [singlefunction.com]=4
  [skinosis.com]=4
  [videotizer.com]=4
)
# www.conf is per-PHP-version, so it is keyed separately below.
declare -A WWW_TARGET=(
  [7.4]=2
  [8.5]=2
  # 8.3 deliberately absent -- it is the live fallback pool, leave it at 5.
)

# --- revert ----------------------------------------------------------------

if [[ "${MODE}" == "--revert" ]]; then
  latest=$(sudo ls -1d "${BAK_ROOT}"/* 2>/dev/null | sort | tail -1 || true)
  [[ -n "${latest}" ]] || { echo "no backup sets under ${BAK_ROOT}" >&2; exit 1; }
  log "restoring from ${latest}"
  sudo find "${latest}" -name '*.conf' -print0 | while IFS= read -r -d '' f; do
    rel=${f#"${latest}/"}
    ver=${rel%%/*}
    base=${rel#*/}
    log "  restoring ${ver}/${base}"
    sudo cp "${f}" "/etc/php/${ver}/fpm/pool.d/${base}"
  done
  for svc in $(systemctl list-unit-files 'php*-fpm.service' --no-legend | awk '$2=="enabled"{print $1}'); do
    log "reloading ${svc}"
    sudo systemctl reload "${svc}"
  done
  log "reverted"
  exit 0
fi

DRY=0
[[ "${MODE}" == "--dry-run" ]] && DRY=1

# --- plan ------------------------------------------------------------------

STAMP=$(date +%F-%H%M%S)
BAK_DIR="${BAK_ROOT}/${STAMP}"
changes=0
before=0
after=0

declare -a PLAN=()

for dir in ${POOL_DIR_GLOB}; do
  ver=$(printf '%s' "${dir}" | sed 's|/etc/php/||;s|/fpm/pool.d||')
  for f in "${dir}"/*.conf; do
    [[ -e "${f}" ]] || continue
    base=$(basename "${f}" .conf)
    cur=$(grep -oP '^pm\.max_children\s*=\s*\K\d+' "${f}" 2>/dev/null || echo "")
    [[ -n "${cur}" ]] || continue
    before=$(( before + cur ))

    if [[ "${base}" == "www" ]]; then
      want=${WWW_TARGET[${ver}]:-${cur}}
    else
      want=${TARGET[${base}]:-${cur}}
    fi

    after=$(( after + want ))
    if [[ "${cur}" != "${want}" ]]; then
      changes=$(( changes + 1 ))
      PLAN+=("${ver}|${f}|${base}|${cur}|${want}")
      printf '  %-6s %-24s %3s -> %-3s\n' "${ver}" "${base}" "${cur}" "${want}"
    else
      printf '  %-6s %-24s %3s     (unchanged)\n' "${ver}" "${base}" "${cur}"
    fi
  done
done

echo
total_mb=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
swap_mb=$(( $(awk '/^SwapTotal:/{print $2}' /proc/meminfo) / 1024 ))
budget=$(( total_mb + swap_mb ))
med=$(ps -eo rss,comm 2>/dev/null | awk '/php-fpm/{print $1}' | sort -n \
      | awk '{a[NR]=$1} END {if (NR) printf "%d", a[int(NR/2)+1]/1024; else print 50}')

log "sum(max_children): ${before} -> ${after}"
log "at ${med} MB median worker: $(( before * med )) MB -> $(( after * med )) MB of ${budget} MB RAM+swap"
log "${changes} pool(s) to change"

if (( changes == 0 )); then
  log "nothing to do"
  exit 0
fi

if (( DRY )); then
  echo
  log "dry run -- nothing changed"
  exit 0
fi

# --- apply -----------------------------------------------------------------

log "backing up to ${BAK_DIR}"
sudo mkdir -p "${BAK_DIR}"

for entry in "${PLAN[@]}"; do
  IFS='|' read -r ver f base cur want <<< "${entry}"
  sudo mkdir -p "${BAK_DIR}/${ver}"
  sudo cp "${f}" "${BAK_DIR}/${ver}/$(basename "${f}")"
done

for entry in "${PLAN[@]}"; do
  IFS='|' read -r ver f base cur want <<< "${entry}"
  log "  ${ver}/${base}: ${cur} -> ${want}"
  # Anchored, and only the max_children line. A loose s/8/4/ would rewrite
  # max_requests, idle timeouts and anything else numeric in the file.
  sudo sed -i -E "s|^(pm\.max_children\s*=\s*)[0-9]+|\1${want}|" "${f}"

  # Dynamic pools carry three more numbers that FPM validates against
  # max_children, and it refuses to start if any exceeds it:
  #   "pm.min_spare_servers(1) and pm.max_spare_servers(3) cannot be greater
  #    than pm.max_children(2)"
  # Lowering max_children alone therefore writes a config that passes a
  # careless eye and then fails at the next reload -- which, if nobody
  # validates, is discovered at the next reboot when the pool does not come
  # back. Found the hard way on 2026-08-09 with the 7.4 and 8.5 www pools.
  # ondemand pools ignore these entirely, so this is a no-op there.
  if grep -qE '^pm\s*=\s*dynamic' "${f}"; then
    max_spare=$(grep -oP '^pm\.max_spare_servers\s*=\s*\K\d+' "${f}" 2>/dev/null || echo "")
    min_spare=$(grep -oP '^pm\.min_spare_servers\s*=\s*\K\d+' "${f}" 2>/dev/null || echo "")
    start=$(grep -oP '^pm\.start_servers\s*=\s*\K\d+' "${f}" 2>/dev/null || echo "")

    if [[ -n "${max_spare}" ]] && (( max_spare > want )); then
      log "    clamping max_spare_servers ${max_spare} -> ${want}"
      sudo sed -i -E "s|^(pm\.max_spare_servers\s*=\s*)[0-9]+|\1${want}|" "${f}"
      max_spare=${want}
    fi
    if [[ -n "${min_spare}" && -n "${max_spare}" ]] && (( min_spare > max_spare )); then
      log "    clamping min_spare_servers ${min_spare} -> ${max_spare}"
      sudo sed -i -E "s|^(pm\.min_spare_servers\s*=\s*)[0-9]+|\1${max_spare}|" "${f}"
      min_spare=${max_spare}
    fi
    if [[ -n "${start}" ]] && (( start > want )); then
      log "    clamping start_servers ${start} -> ${min_spare:-1}"
      sudo sed -i -E "s|^(pm\.start_servers\s*=\s*)[0-9]+|\1${min_spare:-1}|" "${f}"
    fi
  fi
done

# --- validate BEFORE reloading --------------------------------------------

# `set +e` for the whole validation block, and no pipelines feeding a command
# whose exit status matters.
#
# php-fpm -t exits 78 (EX_CONFIG) on a bad config. Under `set -e` with
# `pipefail` that non-zero status aborted the script instantly -- skipping the
# revert below and leaving a config on disk that the running services had not
# yet read. Sites kept serving from memory while the next reload or reboot was
# primed to fail. Observed 2026-08-09; the whole point of validating before
# reloading was defeated by the error handling around the validation.
fail=0
set +e
declare -a VALIDATION_OUT=()
for dir in ${POOL_DIR_GLOB}; do
  ver=$(printf '%s' "${dir}" | sed 's|/etc/php/||;s|/fpm/pool.d||')
  bin="/usr/sbin/php-fpm${ver}"
  [[ -x "${bin}" ]] || continue
  out=$(sudo "${bin}" -t 2>&1)
  if grep -q 'test is successful' <<< "${out}"; then
    log "php${ver}-fpm config test: OK"
  else
    echo "FAIL: php${ver}-fpm config test failed:" >&2
    tail -5 <<< "${out}" >&2
    VALIDATION_OUT+=("${ver}: ${out}")
    fail=1
  fi
done
set -e

if (( fail )); then
  echo "REVERTING -- no service was reloaded, sites are unaffected" >&2
  for entry in "${PLAN[@]}"; do
    IFS='|' read -r ver f base cur want <<< "${entry}"
    sudo cp "${BAK_DIR}/${ver}/$(basename "${f}")" "${f}"
  done
  exit 1
fi

# --- reload ----------------------------------------------------------------

# One service at a time, checking each before moving on. reload re-reads the
# pool config without dropping the listening sockets, so in-flight requests
# finish and no site sees a connection refused.
for svc in $(systemctl list-unit-files 'php*-fpm.service' --no-legend | awk '$2=="enabled"{print $1}'); do
  log "reloading ${svc}"
  sudo systemctl reload "${svc}"
  sleep 1
  if systemctl is-active --quiet "${svc}"; then
    log "  ${svc} active"
  else
    echo "FAIL: ${svc} is not active after reload" >&2
    echo "      revert with: $0 --revert" >&2
    exit 1
  fi
done

echo
log "done. backup set: ${BAK_DIR}"
log "revert with: $0 --revert"
