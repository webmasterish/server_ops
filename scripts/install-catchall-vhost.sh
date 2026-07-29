#!/usr/bin/env bash
#
# Install the catch-all vhost so an unmatched HTTPS request cannot be answered
# with somebody else's site. RUN ON hetzner.
#
#   ./install-catchall-vhost.sh
#
# See templates/000-catchall-ssl.conf for why this exists. Short version: with
# no catch-all, Apache answers unknown SNI with the first vhost alphabetically,
# and hirement.com spent several minutes serving the Matomo login page with a
# 200 and no error anywhere.
#
# Idempotent.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../templates/000-catchall-ssl.conf"
DST=/etc/apache2/sites-available/000-catchall-ssl.conf

[[ -f "${SRC}" ]] || { echo "missing template: ${SRC}" >&2; exit 1; }

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# The snakeoil key is not always present even when the certificate is --
# regenerating both is harmless and makes this work on a fresh box.
if [[ ! -f /etc/ssl/private/ssl-cert-snakeoil.key ]]; then
  log "generating snakeoil certificate"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ssl-cert >/dev/null 2>&1 || true
  sudo make-ssl-cert generate-default-snakeoil --force-overwrite
fi

sudo test -f /etc/ssl/private/ssl-cert-snakeoil.key \
  || { echo "no snakeoil key -- cannot continue" >&2; exit 1; }

log "creating /var/www/catchall"
sudo mkdir -p /var/www/catchall
sudo chown root:root /var/www/catchall

log "installing ${DST}"
sudo install -o root -g root -m 644 "${SRC}" "${DST}"
sudo a2ensite 000-catchall-ssl >/dev/null 2>&1 || true

# a2ensite links as 000-catchall-ssl.conf, which sorts before every per-site
# vhost. That ordering IS the mechanism -- if it ever stops sorting first, the
# catch-all stops being the default and the bug returns silently.
FIRST=$(ls /etc/apache2/sites-enabled/ | head -1)
if [[ "${FIRST}" != "000-catchall-ssl.conf" ]]; then
  log "WARNING: first vhost is ${FIRST}, not the catch-all -- ordering is wrong"
fi

log "testing apache config"
if ! sudo apache2ctl configtest 2>&1 | grep -q 'Syntax OK'; then
  sudo apache2ctl configtest
  echo "FAIL: apache config test failed -- not reloading" >&2
  exit 1
fi

sudo systemctl reload apache2
log "reloaded"

# ---------------------------------------------------------------------------
# Prove it works, rather than assuming
# ---------------------------------------------------------------------------

echo
log "verifying: an unknown SNI must NOT return a real site"
BODY=$(curl -sk -m 15 --resolve "unmatched.invalid:443:127.0.0.1" \
  https://unmatched.invalid/ 2>/dev/null | head -c 400)
CODE=$(curl -sk -m 15 -o /dev/null -w '%{http_code}' \
  --resolve "unmatched.invalid:443:127.0.0.1" https://unmatched.invalid/ 2>/dev/null)

TITLE=$(grep -oiE '<title>[^<]*</title>' <<< "${BODY}" | head -1 || true)

echo "    status: ${CODE}"
echo "    title:  ${TITLE:-<none>}"

# Apache's own error document HAS a <title>, so "any title means a real site"
# is the wrong test -- it failed on a correct install. What actually matters is
# whether the response looks like one of the hosted applications.
if grep -qiE 'wp-content|wp-includes|matomo|piwik|<body[^>]*class=' <<< "${BODY}"; then
  echo "    FAIL -- still serving a real application: ${TITLE}" >&2
  exit 1
fi

if [[ "${CODE}" == "404" ]]; then
  echo "    OK -- unknown names get a 404 from the catch-all, not a real site"
else
  echo "    unexpected status ${CODE} -- check manually" >&2
  exit 1
fi
