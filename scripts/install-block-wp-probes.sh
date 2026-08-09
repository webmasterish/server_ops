#!/usr/bin/env bash
#
# Install the origin-side WordPress probe blocks. RUN ON hetzner.
#
#   ./install-block-wp-probes.sh --dry-run   # show the config, change nothing
#   ./install-block-wp-probes.sh             # install, verify, reload
#   ./install-block-wp-probes.sh --remove    # disable and reload
#
# Installs templates/block-wp-probes.conf. Idempotent.
#
# The safety property that matters: this denies POST to the ROOT wp-login.php
# while leaving /cms/wp-login.php -- the real login for all ten sites -- fully
# working. The script proves that with live requests AFTER reloading, and
# rolls back automatically if the real login path stops behaving.

set -euo pipefail

MODE="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../templates/block-wp-probes.conf"
DST=/etc/apache2/conf-available/block-wp-probes.conf
BAK_DIR=/var/backups/apache2

# A site that actually has WordPress at /cms, used for the live verification.
PROBE_HOST="${PROBE_HOST:-hirement.com}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# Always hit the origin directly. Going through Cloudflare would test the edge
# rule instead of this one, and would report success even if this file did
# nothing at all.
probe() {
  local method=$1 path=$2
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 -k \
    --resolve "${PROBE_HOST}:443:127.0.0.1" \
    -X "${method}" "https://${PROBE_HOST}${path}"
}

if [[ "${MODE}" == "--remove" ]]; then
  log "disabling"
  sudo a2disconf block-wp-probes >/dev/null 2>&1 || true
  sudo apache2ctl configtest
  sudo systemctl reload apache2
  log "removed and reloaded"
  exit 0
fi

[[ -f "${SRC}" ]] || { echo "missing template: ${SRC}" >&2; exit 1; }

# --- preflight: the assumption this whole config rests on -------------------

log "verifying no site serves WordPress from its document root"
root_wp=0
for d in /var/www/vhosts/*/*/httpdocs; do
  if [[ -f "${d}/wp-login.php" ]]; then
    echo "  !! ${d} has wp-login.php AT ROOT" >&2
    root_wp=$((root_wp + 1))
  fi
done
if (( root_wp > 0 )); then
  echo "REFUSING: ${root_wp} site(s) serve WordPress from the document root." >&2
  echo "          Blocking POST to /wp-login.php would lock them out of wp-admin." >&2
  exit 1
fi
log "  none -- all WordPress installs are in a subdirectory"

if (( ${#MODE} )) && [[ "${MODE}" == "--dry-run" ]]; then
  echo
  sed 's/^/    /' "${SRC}"
  echo
  log "dry run -- nothing changed"
  exit 0
fi

# --- baseline BEFORE changing anything -------------------------------------

log "baseline (direct to origin, bypassing Cloudflare):"
before_real=$(probe POST "/cms/wp-login.php")
before_root=$(probe POST "/wp-login.php")
log "  POST /cms/wp-login.php -> ${before_real}   (the real login: must keep working)"
log "  POST /wp-login.php     -> ${before_root}   (the bot target: should become 403)"

# --- install ---------------------------------------------------------------

if [[ -f "${DST}" ]] && cmp -s "${SRC}" "${DST}" \
   && [[ -L /etc/apache2/conf-enabled/block-wp-probes.conf ]]; then
  log "already current and enabled -- nothing to do"
  exit 0
fi

if [[ -f "${DST}" ]]; then
  sudo mkdir -p "${BAK_DIR}"
  bak="${BAK_DIR}/block-wp-probes.conf.$(date +%F-%H%M%S)"
  log "backing up existing config to ${bak}"
  sudo cp "${DST}" "${bak}"
fi

log "installing ${DST}"
sudo install -o root -g root -m 644 "${SRC}" "${DST}"
sudo a2enconf block-wp-probes >/dev/null

log "config test"
if ! sudo apache2ctl configtest 2>&1 | tail -1; then
  echo "FAIL: configtest failed -- disabling, Apache left as it was" >&2
  sudo a2disconf block-wp-probes >/dev/null || true
  exit 1
fi

log "reloading apache (graceful)"
sudo systemctl reload apache2
sleep 2

# --- verify with live requests ---------------------------------------------

after_real=$(probe POST "/cms/wp-login.php")
after_root=$(probe POST "/wp-login.php")
after_get=$(probe GET "/wp-login.php")

echo
log "after:"
log "  POST /cms/wp-login.php -> ${after_real}   (was ${before_real})"
log "  POST /wp-login.php     -> ${after_root}   (was ${before_root})"
log "  GET  /wp-login.php     -> ${after_get}    (should still redirect, not 403)"

fail=0

# The critical assertion. If the real login path changed behaviour at all,
# something matched more broadly than intended and admins are locked out.
if [[ "${after_real}" != "${before_real}" ]]; then
  echo "FAIL: the REAL login path changed from ${before_real} to ${after_real}" >&2
  fail=1
fi
if [[ "${after_real}" == "403" ]]; then
  echo "FAIL: /cms/wp-login.php is now forbidden -- this would lock out wp-admin" >&2
  fail=1
fi
if [[ "${after_root}" != "403" ]]; then
  echo "WARN: POST to root /wp-login.php returned ${after_root}, expected 403" >&2
fi

if (( fail )); then
  echo "ROLLING BACK" >&2
  sudo a2disconf block-wp-probes >/dev/null || true
  sudo apache2ctl configtest >/dev/null 2>&1 && sudo systemctl reload apache2
  echo "rolled back; re-verify: $(probe POST /cms/wp-login.php)" >&2
  exit 1
fi

echo
log "done -- root wp-login POST blocked, real login unaffected"
log "remove with: $0 --remove"
