#!/usr/bin/env bash
#
# Create the directory structure and HTTP vhost for a site. RUN ON hetzner.
#
#   ./provision-site.sh <group> <domain> [--sub <parent-domain>] [--content <src>]
#
#   ./provision-site.sh webmasterish lamarkazia.com \
#       --content /var/www/backups/hostinger/synced/sites/lamarkazia.com/public_html/
#
#   ./provision-site.sh mardini memories.mardini.net --sub mardini.net
#
# Mirrors the layout already in use for dotaim.com and ayatalquran.com:
#
#   /var/www/vhosts/<group>/<domain>/
#   ├── httpdocs/   docroot, webmasterish:www-data
#   ├── logs/       per-site access.log and error.log
#   └── config/     vhost.conf and (later) vhost-ssl.conf, symlinked into
#                   /etc/apache2/sites-enabled/
#
# Subdomains nest under the parent, matching analytics.dotaim.com:
#   /var/www/vhosts/<group>/<parent>/subs/<domain>/
#
# HTTP ONLY. TLS is a separate step (enable-site-ssl.sh) because certbot's
# HTTP-01 challenge needs the domain already resolving to this server -- and
# enabling an SSL vhost that references a certificate which does not exist yet
# takes Apache down on the next reload, along with every site on it.
#
# Idempotent: safe to re-run. Existing directories and content are left alone;
# the vhost is rewritten from the template each time.

set -euo pipefail

GROUP="${1:?usage: $0 <group> <domain> [--sub <parent>] [--content <src>]}"
DOMAIN="${2:?usage: $0 <group> <domain> [--sub <parent>] [--content <src>]}"
shift 2

PARENT=""
CONTENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sub)     PARENT="${2:?--sub needs a parent domain}"; shift 2 ;;
    --content) CONTENT="${2:?--content needs a source path}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

VHOSTS="${VHOSTS_ROOT:-/var/www/vhosts}"
if [[ -n "${PARENT}" ]]; then
  BASE="${VHOSTS}/${GROUP}/${PARENT}/subs/${DOMAIN}"
  ALIASES=""
else
  BASE="${VHOSTS}/${GROUP}/${DOMAIN}"
  ALIASES="www.${DOMAIN}"
fi

DOCROOT="${BASE}/httpdocs"
LOGS="${BASE}/logs"
CONF="${BASE}/config"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

log "creating ${BASE}"
mkdir -p "${DOCROOT}" "${LOGS}" "${CONF}"

# httpdocs is group-writable by www-data so PHP can write uploads; logs the
# same, since Apache creates the log files as root but the directory must be
# traversable. Matches the existing sites.
sudo chown -R webmasterish:www-data "${DOCROOT}" "${LOGS}"
sudo chmod 775 "${DOCROOT}" "${LOGS}"

# ---------------------------------------------------------------------------
# Content
# ---------------------------------------------------------------------------

if [[ -n "${CONTENT}" ]]; then
  [[ -d "${CONTENT}" ]] || { echo "no such content dir: ${CONTENT}" >&2; exit 1; }
  log "deploying content from ${CONTENT}"
  # No --delete: this must never remove something already live in a docroot.
  rsync -a "${CONTENT%/}/" "${DOCROOT}/"
  sudo chown -R webmasterish:www-data "${DOCROOT}"
  log "content: $(find "${DOCROOT}" -type f | wc -l) files"
fi

# ---------------------------------------------------------------------------
# HTTP vhost
# ---------------------------------------------------------------------------

log "writing ${CONF}/vhost.conf"

SERVER_ALIAS_LINE=""
[[ -n "${ALIASES}" ]] && SERVER_ALIAS_LINE="	ServerAlias ${ALIASES}"

cat > "${CONF}/vhost.conf" <<EOF
<VirtualHost *:80>
	ServerName ${DOMAIN}
${SERVER_ALIAS_LINE}
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
</VirtualHost>
EOF

# ---------------------------------------------------------------------------
# Enable
# ---------------------------------------------------------------------------

LINK="/etc/apache2/sites-enabled/${DOMAIN}.conf"
if [[ ! -L "${LINK}" ]]; then
  log "linking ${LINK}"
  sudo ln -s "${CONF}/vhost.conf" "${LINK}"
fi

log "testing apache config"
if ! sudo apache2ctl configtest 2>&1 | grep -q 'Syntax OK'; then
  sudo apache2ctl configtest
  echo "FAIL: apache config test failed -- not reloading" >&2
  exit 1
fi

log "reloading apache"
sudo systemctl reload apache2

log "done"
echo
echo "  docroot : ${DOCROOT}"
echo "  vhost   : ${CONF}/vhost.conf -> ${LINK}"
echo "  logs    : ${LOGS}"
echo
echo "Verify before touching DNS (this server is $(curl -s -4 ifconfig.me)):"
echo "  curl -sI --resolve ${DOMAIN}:80:127.0.0.1 http://${DOMAIN}/"
echo
echo "Then point DNS here, and only then run:"
echo "  ./enable-site-ssl.sh ${GROUP} ${DOMAIN}${PARENT:+ --sub ${PARENT}}"
