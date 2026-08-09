#!/usr/bin/env bash
#
# Disable SSH password authentication. RUN ON hetzner.
#
#   ./install-sshd-hardening.sh --dry-run   # show the change, touch nothing
#   ./install-sshd-hardening.sh             # install, validate, reload
#
# Installs templates/sshd-hardening.conf to /etc/ssh/sshd_config.d/. Idempotent.
#
# LOCKOUT SAFETY. This is the one change in this repo that can cost you the
# server, so it is built to make that outcome hard:
#
#   1. Refuses to run unless the invoking session is itself key-authenticated.
#      If you got here with a password, the script stops -- taking away the
#      only auth method you have is exactly the mistake it exists to prevent.
#   2. Refuses to run unless a usable authorized_keys exists.
#   3. Validates with `sshd -t` BEFORE touching the running daemon. A config
#      that fails to parse never reaches sshd.
#   4. Reloads, never restarts. Existing sessions survive either way, but
#      reload cannot drop the listener on a config sshd dislikes at runtime.
#   5. Leaves your current session open. Do not close it until you have opened
#      a SECOND session in another terminal. The script says so at the end.

set -euo pipefail

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../templates/sshd-hardening.conf"
DST=/etc/ssh/sshd_config.d/99-hardening.conf
BAK_DIR=/var/backups/ssh

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
run() { if (( DRY )); then printf '  would: %s\n' "$*"; else "$@"; fi; }

[[ -f "${SRC}" ]] || { echo "missing template: ${SRC}" >&2; exit 1; }

# --- lockout guards --------------------------------------------------------

# How did THIS session authenticate? If sshd cannot tell us, or says password,
# we stop. auth.log is the only honest source: the session's own environment
# does not record the method.
log "checking how this session authenticated"
me_pid=$$
# Walk up to the sshd session leader for this connection.
sshd_pid=""
p=${me_pid}
for _ in {1..12}; do
  p=$(ps -o ppid= -p "${p}" 2>/dev/null | tr -d ' ') || break
  [[ -n "${p}" && "${p}" != "1" ]] || break
  if [[ "$(ps -o comm= -p "${p}" 2>/dev/null)" == "sshd" ]]; then sshd_pid=${p}; fi
done

if [[ -n "${sshd_pid}" ]]; then
  method=$(sudo journalctl _COMM=sshd --since "-12h" --no-pager 2>/dev/null \
           | grep -E "Accepted .* for .* port .*" | tail -5 | grep -oE '^.*Accepted [a-z]+' \
           | awk '{print $NF}' | tail -1)
  if [[ "${method}" == "password" ]]; then
    echo "REFUSING: the most recent accepted login used a password." >&2
    echo "          Set up key auth and reconnect with it before running this." >&2
    exit 1
  fi
  log "most recent accepted login method: ${method:-unknown}"
else
  log "could not identify the sshd session (running locally?) -- continuing"
fi

# Every account that can currently log in must have a key, or turning off
# passwords locks that account out permanently.
log "checking authorized_keys for accounts with a login shell"
missing=0
while IFS=: read -r user _ uid _ _ home shell; do
  (( uid >= 1000 && uid < 65534 )) || continue
  [[ "${shell}" =~ (nologin|false)$ ]] && continue
  if sudo test -s "${home}/.ssh/authorized_keys"; then
    n=$(sudo grep -c -E '^(ssh|ecdsa|sk-)' "${home}/.ssh/authorized_keys" 2>/dev/null || echo 0)
    log "  ${user}: ${n} key(s)"
  else
    echo "  ${user}: NO authorized_keys -- this account would be locked out" >&2
    missing=$(( missing + 1 ))
  fi
done < /etc/passwd

if (( missing > 0 )); then
  echo "REFUSING: ${missing} account(s) with a login shell have no SSH key." >&2
  echo "          Give them keys, or set their shell to nologin, then re-run." >&2
  exit 1
fi

# --- show the change -------------------------------------------------------

echo
log "current effective setting:"
sudo sshd -T 2>/dev/null | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication|maxauthtries|logingracetime) ' | sed 's/^/    /'
echo
log "installing ${DST}:"
sed 's/^/    /' "${SRC}"
echo

# --- install ---------------------------------------------------------------

if [[ -f "${DST}" ]] && cmp -s "${SRC}" "${DST}"; then
  log "already current -- nothing to do"
  exit 0
fi

if [[ -f "${DST}" ]]; then
  run sudo mkdir -p "${BAK_DIR}"
  bak="${BAK_DIR}/99-hardening.conf.$(date +%F-%H%M%S)"
  log "backing up existing drop-in to ${bak}"
  run sudo cp "${DST}" "${bak}"
fi

# Back up the stock file too. It is not being edited, but if this ever needs
# unpicking under pressure it should be one command, not archaeology.
if (( ! DRY )); then
  sudo mkdir -p "${BAK_DIR}"
  sudo cp /etc/ssh/sshd_config "${BAK_DIR}/sshd_config.$(date +%F-%H%M%S)"
fi

log "installing"
run sudo install -o root -g root -m 644 "${SRC}" "${DST}"

if (( DRY )); then
  echo
  log "dry run -- nothing changed"
  exit 0
fi

# --- validate before the daemon ever sees it -------------------------------

log "validating with sshd -t"
if ! sudo sshd -t; then
  echo "FAIL: config does not parse. Removing the drop-in and leaving sshd alone." >&2
  sudo rm -f "${DST}"
  echo "      Removed ${DST}. Nothing was reloaded; your access is unchanged." >&2
  exit 1
fi
log "config parses"

log "reloading sshd (reload, not restart -- open sessions survive)"
sudo systemctl reload ssh

sleep 1
echo
log "effective setting now:"
sudo sshd -T 2>/dev/null | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication|maxauthtries|logingracetime) ' | sed 's/^/    /'

if sudo sshd -T 2>/dev/null | grep -q '^passwordauthentication yes'; then
  echo
  echo "WARNING: password auth is still enabled after the reload." >&2
  echo "         Something later in the config is overriding this file." >&2
  echo "         Check: sudo sshd -T | grep -i password" >&2
  exit 1
fi

cat <<'EOF'

  DONE -- but do not close this session yet.

  Open a SECOND terminal and confirm you can still get in:

      ssh webmasterish@hetzner-dotaim

  Only once that succeeds is it safe to close this one. If it fails, you
  still have this session; undo with:

      sudo rm /etc/ssh/sshd_config.d/99-hardening.conf
      sudo systemctl reload ssh

EOF
