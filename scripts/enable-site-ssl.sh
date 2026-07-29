#!/usr/bin/env bash
#
# Obtain a certificate and enable the HTTPS vhost for a site. RUN ON hetzner.
#
#   ./enable-site-ssl.sh <group> <domain> [--sub <parent>] [--no-www]
#
# Run this ONLY after DNS for the domain already points at this server.
# certbot's HTTP-01 challenge is answered by this machine, so if the name still
# resolves to Hostinger the validation fails. Let's Encrypt rate-limits failed
# validations (5 per account per hostname per hour), so a premature run is not
# free -- hence the resolution guard below, which refuses rather than trying.
#
# Uses `certonly --webroot` rather than `--apache`: certbot's Apache plugin
# rewrites the vhost in place, which would drift from the layout every other
# site here follows. This keeps vhost-ssl.conf ours, in the site's own config/
# directory, symlinked into sites-enabled like the rest.
#
# Idempotent: re-running renews/reuses the certificate and rewrites the vhost.

set -euo pipefail

GROUP="${1:?usage: $0 <group> <domain> [--sub <parent>] [--no-www]}"
DOMAIN="${2:?usage: $0 <group> <domain> [--sub <parent>] [--no-www]}"
shift 2

PARENT=""
WANT_WWW=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sub)    PARENT="${2:?--sub needs a parent domain}"; shift 2 ;;
    --no-www) WANT_WWW=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

VHOSTS="${VHOSTS_ROOT:-/var/www/vhosts}"
if [[ -n "${PARENT}" ]]; then
  BASE="${VHOSTS}/${GROUP}/${PARENT}/subs/${DOMAIN}"
  WANT_WWW=0            # subdomains do not get a www.<sub> name
else
  BASE="${VHOSTS}/${GROUP}/${DOMAIN}"
fi

DOCROOT="${BASE}/httpdocs"
LOGS="${BASE}/logs"
CONF="${BASE}/config"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

[[ -d "${DOCROOT}" ]] || { echo "not provisioned yet: ${DOCROOT}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Guard: does the name actually point here?
# ---------------------------------------------------------------------------

MY_IP=$(curl -s -4 ifconfig.me)
RESOLVED=$(dig +short A "${DOMAIN}" | tail -1)

log "this server: ${MY_IP}   ${DOMAIN} resolves to: ${RESOLVED:-<nothing>}"

if [[ "${RESOLVED}" != "${MY_IP}" ]]; then
  cat >&2 <<MSG

REFUSING: ${DOMAIN} does not resolve to this server yet.
  expected ${MY_IP}, got ${RESOLVED:-nothing}

Point the A record here first and wait for the TTL to lapse. Running certbot
now would fail validation and burn one of 5 hourly attempts for this hostname.
MSG
  exit 1
fi

NAMES=(-d "${DOMAIN}")
if [[ ${WANT_WWW} -eq 1 ]]; then
  WWW_RESOLVED=$(dig +short A "www.${DOMAIN}" | tail -1)
  if [[ "${WWW_RESOLVED}" == "${MY_IP}" ]]; then
    NAMES+=(-d "www.${DOMAIN}")
    log "including www.${DOMAIN}"
  else
    log "skipping www.${DOMAIN} (resolves to ${WWW_RESOLVED:-nothing}, not here)"
  fi
fi

# ---------------------------------------------------------------------------
# Certificate
# ---------------------------------------------------------------------------

log "requesting certificate"
sudo certbot certonly --webroot -w "${DOCROOT}" \
  "${NAMES[@]}" \
  --cert-name "${DOMAIN}" \
  --non-interactive --agree-tos --email accounts@dotaim.com \
  --keep-until-expiring

LIVE="/etc/letsencrypt/live/${DOMAIN}"
sudo test -f "${LIVE}/fullchain.pem" || { echo "no certificate at ${LIVE}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# HTTPS vhost
# ---------------------------------------------------------------------------

log "writing ${CONF}/vhost-ssl.conf"

ALIAS_LINE=""
[[ ${WANT_WWW} -eq 1 && " ${NAMES[*]} " == *"www.${DOMAIN}"* ]] \
  && ALIAS_LINE="		ServerAlias www.${DOMAIN}"

cat > "${CONF}/vhost-ssl.conf" <<EOF
<IfModule mod_ssl.c>
	<VirtualHost *:443>
		ServerName ${DOMAIN}
${ALIAS_LINE}
		ServerAdmin webmaster@${DOMAIN}

		DocumentRoot ${DOCROOT}
		<Directory />
			Options FollowSymLinks
			AllowOverride None
		</Directory>
		<Directory ${DOCROOT}>
			Options Indexes FollowSymLinks MultiViews
			AllowOverride All
			Require all granted
		</Directory>

		# Possible values include: debug, info, notice, warn, error, crit,
		# alert, emerg.
		LogLevel warn
		ErrorLog ${LOGS}/error.log
		CustomLog ${LOGS}/access.log combined

		Protocols h2 http/1.1

		SSLCertificateFile ${LIVE}/fullchain.pem
		SSLCertificateKeyFile ${LIVE}/privkey.pem
		Include /etc/letsencrypt/options-ssl-apache.conf
	</VirtualHost>
</IfModule>
EOF

LINK="/etc/apache2/sites-enabled/${DOMAIN}-ssl.conf"
if [[ ! -L "${LINK}" ]]; then
  log "linking ${LINK}"
  sudo ln -s "${CONF}/vhost-ssl.conf" "${LINK}"
fi

log "testing apache config"
if ! sudo apache2ctl configtest 2>&1 | grep -q 'Syntax OK'; then
  sudo apache2ctl configtest
  echo "FAIL: apache config test failed -- not reloading" >&2
  exit 1
fi

log "reloading apache"
sudo systemctl reload apache2

log "verifying"
sleep 2
code=$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN}/" || echo 000)
log "https://${DOMAIN}/ -> ${code}"

echo
sudo certbot certificates --cert-name "${DOMAIN}" 2>/dev/null \
  | grep -E 'Certificate Name|Domains|Expiry' || true
echo
echo "NOTE: HTTP-to-HTTPS redirect is NOT enabled. dotaim.com has it commented"
echo "out deliberately (Cloudflare handles it there). Decide per site."
