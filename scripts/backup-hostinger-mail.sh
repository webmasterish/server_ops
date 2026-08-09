#!/usr/bin/env bash
#
# Pull Hostinger mailboxes down to local Maildir over IMAP.
#
# RUN THIS LOCALLY (not on hetzner).  ./backup-hostinger-mail.sh
#
# Why this exists: as of 2026-08-01 Hostinger has blocked hPanel/webmail
# access, but imap.hostinger.com:993 still accepts logins. Panel access and
# mail-protocol access are separate products. That gap is the only way left to
# get this mail out, and it may close without warning -- treat this as urgent.
#
# Inbound mail to these domains appears to be REJECTED at the MX already
# ("554 Relay access denied" at RCPT), so what is in the mailboxes now is
# probably all there will ever be. Nothing new is arriving to miss.
#
# Read-only with respect to the server. Sync is Pull-only and both Expunge and
# Remove are None, so this never deletes or flags anything on Hostinger's side,
# and never deletes anything locally either. Re-running only fetches deltas.
#
# Output is Maildir, which imapsync / Thunderbird / offlineimap can all read
# directly -- see docs/runbooks/mail-backup.md for the import path.
#
# Credentials are NEVER written to disk. The password is read interactively
# into an environment variable that only this process and its children can
# see, and the generated mbsync config refers to it via PassCmd.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${MAIL_BACKUP_ROOT:-/media/backups/mail/hostinger}"
LIST="${MAILBOX_LIST:-${HERE}/__mailboxes.txt}"
HOST="${IMAP_HOST:-imap.hostinger.com}"
PORT="${IMAP_PORT:-993}"
LOG="${DEST}/run.log"

CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"

die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
log() { printf '%s  %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$*" | tee -a "$LOG"; }

command -v mbsync >/dev/null 2>&1 || die \
  "mbsync not found. Install with:  sudo apt install isync"

[ -r "$CA_BUNDLE" ] || die "CA bundle not found at $CA_BUNDLE"

if [ ! -r "$LIST" ]; then
  cat >&2 <<EOF

No mailbox list found at:
  $LIST

Create it with one email address per line. Blank lines and lines starting
with '#' are ignored. The '__' prefix is gitignored by this repo, so the
file stays local -- keep it that way, it is a list of live addresses.

Example:

  # grand-emerald.com
  info@grand-emerald.com
  admin@grand-emerald.com

  # nizonet.com
  info@nizonet.com

EOF
  exit 1
fi

mkdir -p "$DEST" || die "cannot create $DEST"
touch "$LOG" || die "cannot write $LOG"

# Space check. Mailboxes are usually small, but /media/data2 is nearly full
# and picking the wrong disk here would be an unpleasant surprise.
AVAIL_MB=$(df -Pm "$DEST" | awk 'NR==2 {print $4}')
log "destination $DEST (${AVAIL_MB} MB free)"
[ "${AVAIL_MB:-0}" -lt 500 ] && log "WARNING: under 500 MB free on destination"

mapfile -t BOXES < <(grep -vE '^\s*(#|$)' "$LIST" | tr -d '\r' | awk '{$1=$1};1')
[ "${#BOXES[@]}" -gt 0 ] || die "no mailboxes listed in $LIST"

log "=== run start: ${#BOXES[@]} mailbox(es) via ${HOST}:${PORT} ==="

CONF_DIR="$(mktemp -d)"
chmod 700 "$CONF_DIR"
trap 'rm -rf "$CONF_DIR"; unset MBSYNC_PASS' EXIT INT TERM

OK=0; FAIL=0

for BOX in "${BOXES[@]}"; do
  # Filesystem-safe directory name, but keep the address readable.
  SAFE="${BOX//\//_}"
  BOX_DIR="${DEST}/${SAFE}"
  CONF="${CONF_DIR}/${SAFE}.mbsyncrc"

  printf '\n---------------------------------------------------------------\n'
  printf 'Mailbox: %s\n' "$BOX"

  # Read the password straight into the environment. Never echoed, never
  # written to a file, cleared when this script exits.
  MBSYNC_PASS=""
  read -rsp "Password for ${BOX} (input hidden, blank to skip): " MBSYNC_PASS
  printf '\n'
  export MBSYNC_PASS

  if [ -z "$MBSYNC_PASS" ]; then
    log "SKIP  ${BOX} (no password entered)"
    continue
  fi

  mkdir -p "$BOX_DIR"

  # Far/Near is isync >= 1.4 vocabulary. On older isync these are Master/Slave.
  umask 077
  cat > "$CONF" <<EOF
IMAPAccount src
Host ${HOST}
Port ${PORT}
User ${BOX}
PassCmd "printenv MBSYNC_PASS"
TLSType IMAPS
CertificateFile ${CA_BUNDLE}
PipelineDepth 10

IMAPStore src-remote
Account src

MaildirStore src-local
Path ${BOX_DIR}/
Inbox ${BOX_DIR}/INBOX
SubFolders Verbatim

Channel backup
Far :src-remote:
Near :src-local:
Patterns *
Create Near
Remove None
Expunge None
Sync Pull
SyncState *
EOF

  log "START ${BOX} -> ${BOX_DIR}"
  if mbsync -c "$CONF" -V backup 2>&1 | tee -a "$LOG"; then
    COUNT=$(find "$BOX_DIR" -type f -path '*/cur/*' -o -type f -path '*/new/*' 2>/dev/null | wc -l)
    SIZE=$(du -sh "$BOX_DIR" 2>/dev/null | cut -f1)
    log "OK    ${BOX} -- ${COUNT} messages, ${SIZE}"
    OK=$((OK+1))
  else
    log "FAIL  ${BOX} -- see output above"
    FAIL=$((FAIL+1))
  fi

  unset MBSYNC_PASS
  rm -f "$CONF"
done

printf '\n===============================================================\n'
log "=== run done: ${OK} ok, ${FAIL} failed ==="
log "backups at: ${DEST}"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
