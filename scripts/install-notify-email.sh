#!/usr/bin/env bash
#
# Wire the health check to email. RUN ON hetzner.
#
#   ./install-notify-email.sh          # install msmtp, config skeleton, hook
#   ./install-notify-email.sh --test   # send a test email through the hook
#
# Sends to dev@dotaim.com via Google Workspace, which is where dotaim.com mail
# already lives (MX = aspmx.l.google.com, SPF = include:_spf.google.com,
# confirmed 2026-08-09).
#
# WHY A RELAY AND NOT DIRECT DELIVERY. The VPS could in principle hand mail
# straight to aspmx.l.google.com with no credentials at all -- that is how
# ordinary internet mail works. Do not. A Hetzner IP with no matching PTR, no
# SPF authorisation for dotaim.com and no DKIM signature is the exact profile
# of a spam source: Google will silently spam-folder it or reject outright.
# The one thing an alert channel must never do is fail quietly, so the mail
# goes out authenticated, through Google, as a legitimate dotaim.com sender.
#
# CREDENTIALS. /etc/msmtprc holds an app password and is deliberately NOT
# written by this script -- same rule as /etc/restic/restic.env. The script
# installs a skeleton with placeholders; you fill in the two lines yourself,
# in your own terminal, so the secret never passes through a transcript.

set -euo pipefail

MODE="${1:-}"
DIR=/etc/health-check
DST="${DIR}/notify"
MSMTPRC=/etc/msmtprc
TO="${HEALTH_MAIL_TO:-dev@dotaim.com}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# --- test mode -------------------------------------------------------------

if [[ "${MODE}" == "--test" ]]; then
  sudo test -x "${DST}" || { echo "no hook at ${DST} -- run without --test first" >&2; exit 1; }

  if sudo grep -qE '^(user|password)[[:space:]]+(YOUR-|APP-PASSWORD)' "${MSMTPRC}" 2>/dev/null; then
    echo "REFUSING: ${MSMTPRC} still contains placeholders." >&2
    echo "          Fill in the 'user' and 'password' lines first -- see below." >&2
    exit 1
  fi

  log "sending a test email to ${TO}"
  if printf 'health-check TEST on %s at %s\n\nThis is a test. Nothing is wrong.\n' \
       "$(hostname -s)" "$(date -Is)" | sudo "${DST}" TEST; then
    log "msmtp accepted the message -- check ${TO}"
    log "if nothing arrives, read the log: sudo tail -20 /var/log/msmtp.log"
  else
    echo "FAIL: msmtp rejected the message. Read: sudo tail -20 /var/log/msmtp.log" >&2
    exit 1
  fi
  exit 0
fi

# --- install msmtp ---------------------------------------------------------

# msmtp, not postfix. postfix is a full MTA with a listening daemon, a queue
# and a spool to maintain; msmtp is a ~200 KB sendmail-shaped pipe that opens
# one authenticated SMTP connection and exits. For "send one email when a
# check fails" the daemon is pure attack surface and pure maintenance.
if ! command -v msmtp >/dev/null 2>&1; then
  log "installing msmtp"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq msmtp >/dev/null
  log "installed msmtp $(msmtp --version | head -1 | awk '{print $3}')"
else
  log "msmtp already installed"
fi

# --- config skeleton -------------------------------------------------------

if [[ -f "${MSMTPRC}" ]]; then
  log "${MSMTPRC} exists -- leaving it alone"
else
  log "writing ${MSMTPRC} skeleton (placeholders, no secret)"
  sudo install -m 600 -o root -g root /dev/null "${MSMTPRC}"
  sudo tee "${MSMTPRC}" >/dev/null <<'EOF'
# /etc/msmtprc -- 0600 root. Holds an app password. Never commit, never print.
#
# Fill in the two lines marked BELOW, then:
#   sudo chmod 600 /etc/msmtprc
#   ~/server_ops/scripts/install-notify-email.sh --test

defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        dotaim
host           smtp.gmail.com
port           587

# BELOW 1/2 -- the full Google Workspace address that will send the alerts.
# `from` must match `user`, or be an address that account is verified to send
# as, or Google rejects the message with "Sender address rejected".
user           YOUR-ADDRESS@dotaim.com
from           YOUR-ADDRESS@dotaim.com

# BELOW 2/2 -- a Google APP PASSWORD, not the account password.
# https://myaccount.google.com/apppasswords  (requires 2-Step Verification on)
# It is 16 characters; paste it with or without spaces, both work.
password       APP-PASSWORD-HERE

account default : dotaim
EOF
  sudo chmod 600 "${MSMTPRC}"
  sudo chown root:root "${MSMTPRC}"
fi

# msmtp writes its own log; keep it from growing without bound. Small file,
# but an unrotated log is how you find a 2 GB surprise three years later.
if [[ ! -f /etc/logrotate.d/msmtp ]]; then
  log "adding logrotate rule for /var/log/msmtp.log"
  sudo tee /etc/logrotate.d/msmtp >/dev/null <<'EOF'
/var/log/msmtp.log {
	monthly
	rotate 6
	missingok
	notifempty
	compress
	create 600 root root
}
EOF
fi

# --- notify hook -----------------------------------------------------------

log "installing ${DST}"
sudo install -d -m 700 -o root -g root "${DIR}"

sudo tee "${DST}" >/dev/null <<EOF
#!/bin/sh
# Health check notify hook -- sends the report by email via msmtp.
#
# Called by health-check.sh as:  notify <VERDICT>  with the report on stdin.
# GENERATED by scripts/install-notify-email.sh.

verdict="\$1"
to="${TO}"

# Refuse to attempt a send while the credentials are still placeholders.
#
# Without this the hook runs anyway and msmtp emits three lines of
# "authentication failed (method PLAIN)" into the journal on every non-OK
# check -- observed 2026-08-09. That is noise which looks like a broken mail
# system rather than what it is: setup not finished. One clear line is more
# useful than a stack of Google error codes, and exit 0 keeps a
# not-yet-configured channel from also marking the check as failed.
if grep -qE '^(user|from|password)[[:space:]]+(YOUR-|APP-PASSWORD)' /etc/msmtprc 2>/dev/null; then
  echo "notify: /etc/msmtprc still has placeholders -- alert NOT sent (verdict: \$verdict)" >&2
  exit 0
fi

# The verdict goes in the Subject because that is the only part you see on a
# phone lock screen. "[hetzner] health-check FAIL" is actionable at a glance;
# "Server notification" is not.
{
  printf 'To: %s\n' "\$to"
  printf 'Subject: [hetzner] health-check %s\n' "\$verdict"
  printf 'X-Priority: %s\n' "\$([ "\$verdict" = FAIL ] && echo 1 || echo 3)"
  printf 'Content-Type: text/plain; charset=utf-8\n'
  printf '\n'
  cat
  printf '\n--\nSent by health-check.sh on %s\n' "\$(hostname -f)"
  printf 'Runbook: docs/runbook-health-checks.md\n'
} | msmtp --read-recipients
EOF

sudo chmod 700 "${DST}"
sudo chown root:root "${DST}"

log "hook installed, sending to ${TO}"

# --- what is left for a human ----------------------------------------------

if sudo grep -qE '^(user|from|password)[[:space:]]+(YOUR-|APP-PASSWORD)' "${MSMTPRC}"; then
  cat <<EOF

  ONE THING LEFT, and it has to be you -- the password must not pass
  through a transcript.

    1. Create a Google App Password (needs 2-Step Verification enabled):
         https://myaccount.google.com/apppasswords
       Name it something like "hetzner alerts". Google shows it ONCE.

    2. On the server, edit three lines:
         sudo nano ${MSMTPRC}
       Replace YOUR-ADDRESS@dotaim.com on the 'user' and 'from' lines,
       and APP-PASSWORD-HERE on the 'password' line.

    3. Confirm permissions and send a test:
         sudo chmod 600 ${MSMTPRC}
         ~/server_ops/scripts/install-notify-email.sh --test

    4. Check ${TO}.

EOF
else
  log "msmtprc looks filled in -- test with: $0 --test"
fi
