#!/usr/bin/env bash
#
# Obtain a certificate and enable the HTTPS vhost for a site. RUN ON hetzner.
#
#   ./enable-site-ssl.sh <group> <domain> [--sub <parent>] [--no-www] [--no-redirect] [--proxied]
#
# --proxied: the domain sits behind Cloudflare, so its A record points at the
# proxy and never at this server. Origin is proven with a token round-trip
# through the public hostname instead of an IP comparison.
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

GROUP="${1:?usage: $0 <group> <domain> [--sub <parent>] [--no-www] [--no-redirect]}"
DOMAIN="${2:?usage: $0 <group> <domain> [--sub <parent>] [--no-www] [--no-redirect]}"
shift 2

PARENT=""
WANT_WWW=1
REDIRECT=1
PROXIED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sub)         PARENT="${2:?--sub needs a parent domain}"; shift 2 ;;
    --no-www)      WANT_WWW=0; shift ;;
    --no-redirect) REDIRECT=0; shift ;;
    --proxied)     PROXIED=1; shift ;;
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

if [[ ${PROXIED} -eq 1 ]]; then
  # Behind Cloudflare the A record resolves to Cloudflare, never to this box,
  # so comparing IPs can only ever fail. Prove origin the honest way instead:
  # put a probe value in the docroot, fetch it through the public hostname, and see
  # whether it comes back. That tests the whole path -- if it round-trips, the
  # ACME challenge will reach us too, which is the thing we actually care about.
  PROBE_VALUE="origin-check-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  PROBE_DIR="${DOCROOT}/.well-known/acme-challenge"
  # sudo, and re-chown: a manual probe run with sudo leaves this directory
  # owned by root, after which this script cannot write its own probe and dies
  # with "Permission denied" having done nothing.
  sudo mkdir -p "${PROBE_DIR}"
  sudo chown -R webmasterish:www-data "${DOCROOT}/.well-known"
  sudo chmod -R 775 "${DOCROOT}/.well-known"
  printf '%s' "${PROBE_VALUE}" > "${PROBE_DIR}/${PROBE_VALUE}"

  log "verifying this server is the origin for ${DOMAIN}"
  GOT=$(curl -sS -m 20 "http://${DOMAIN}/.well-known/acme-challenge/${PROBE_VALUE}" 2>/dev/null || true)
  rm -f "${PROBE_DIR}/${PROBE_VALUE}"

  if [[ "${GOT}" != "${PROBE_VALUE}" ]]; then
    cat >&2 <<MSG

REFUSING: ${DOMAIN} does not reach this server.

A probe value written into this docroot was not returned when fetched over the
public hostname, so the ACME challenge would not reach us either. Check that
the proxy's origin points here and that it is not serving a cached page.
MSG
    exit 1
  fi
  log "origin confirmed"

elif [[ "${RESOLVED}" != "${MY_IP}" ]]; then
  cat >&2 <<MSG

REFUSING: ${DOMAIN} does not resolve to this server yet.
  expected ${MY_IP}, got ${RESOLVED:-nothing}

Point the A record here first and wait for the TTL to lapse. Running certbot
now would fail validation and burn one of 5 hourly attempts for this hostname.

If this domain is behind Cloudflare, the A record resolves to Cloudflare by
design and never to this server -- re-run with --proxied.
MSG
  exit 1
fi

NAMES=(-d "${DOMAIN}")
if [[ ${WANT_WWW} -eq 1 ]]; then
  WWW_RESOLVED=$(dig +short A "www.${DOMAIN}" | tail -1)
  # Proxied: both names resolve to the proxy, so a match against MY_IP is
  # impossible. Include www as long as it resolves at all.
  if [[ ${PROXIED} -eq 1 && -n "${WWW_RESOLVED}" ]] || [[ "${WWW_RESOLVED}" == "${MY_IP}" ]]; then
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

# --expand matters when the name list has GROWN since the last run. That
# happens routinely here: if www points somewhere else at cutover time the
# guard above correctly excludes it, and the certificate is issued for the apex
# alone. Once www is repointed and this is re-run, --keep-until-expiring on its
# own decides the existing certificate is still valid and keeps it -- so www is
# never added, silently, and the vhost ends up with no ServerAlias either.
# --expand tells certbot to reissue when the requested names differ.
sudo certbot certonly --webroot -w "${DOCROOT}" \
  "${NAMES[@]}" \
  --cert-name "${DOMAIN}" \
  --non-interactive --agree-tos --email accounts@dotaim.com \
  --expand --keep-until-expiring

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

log "verifying https before adding the redirect"
sleep 2

# Check the ORIGIN directly, not the public URL. Through a proxy this test is
# measuring the proxy: hirement.com returned 403 here purely because
# Cloudflare bot-blocked a bare curl user-agent, so the script reported
# failure on a cutover that had actually succeeded. What this step needs to
# know is whether THIS server serves the site over TLS.
MY_IP="${MY_IP:-$(curl -s -4 ifconfig.me)}"
code=$(curl -sS -o /dev/null -w '%{http_code}' \
  --resolve "${DOMAIN}:443:${MY_IP}" "https://${DOMAIN}/" || echo 000)
log "origin https://${DOMAIN}/ -> ${code}"

if [[ "${code}" != "200" ]]; then
  echo "FAIL: origin is not serving HTTPS; leaving HTTP alone so the site stays up" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# HTTP -> HTTPS redirect
# ---------------------------------------------------------------------------
#
# Only now, and only after HTTPS is confirmed working above. Pointing the HTTP
# vhost at an HTTPS vhost that is broken would take the site off the air
# entirely rather than merely leaving it unencrypted.

if [[ ${REDIRECT} -eq 1 ]]; then
  log "enabling HTTP -> HTTPS redirect"
  "$(dirname "${BASH_SOURCE[0]}")/provision-site.sh" "${GROUP}" "${DOMAIN}" \
    ${PARENT:+--sub "${PARENT}"} >/dev/null

  http_code=$(curl -sS -o /dev/null -w '%{http_code}' "http://${DOMAIN}/" || echo 000)
  log "http://${DOMAIN}/ -> ${http_code} (expect 301)"
else
  log "redirect skipped (--no-redirect)"
fi

echo
sudo certbot certificates --cert-name "${DOMAIN}" 2>/dev/null \
  | grep -E 'Certificate Name|Domains|Expiry' || true
