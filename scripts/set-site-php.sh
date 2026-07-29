#!/usr/bin/env bash
#
# Give a site its own PHP-FPM pool at a chosen version. RUN ON hetzner.
#
#   ./set-site-php.sh <group> <domain> <php-version> [--sub <parent>]
#
#   ./set-site-php.sh dotaim ayatalquran.com 8.3
#   ./set-site-php.sh dotaim lebanese.tech 7.4
#   ./set-site-php.sh dotaim menamaps.com 8.5
#
# Writes /etc/php/<ver>/fpm/pool.d/<domain>.conf and adds a matching
# SetHandler to the site's vhost.conf and vhost-ssl.conf.
#
# WHY per-site pools rather than one shared pool: these sites need three
# different PHP versions (7.4, 8.3, 8.5) because that is what they run on
# Hostinger today. mod_php can serve exactly one, so it cannot host this
# estate at all. A pool per site also means one site's PHP crashing or
# saturating cannot starve the others.
#
# The pools run as www-data, deliberately the SAME identity mod_php used.
# Per-site users would be better -- right now any compromised site can read
# every other site's database credentials -- but changing identity and file
# ownership at the same time as the SAPI would make a failed cutover much
# harder to diagnose. That is a separate, per-site change.
#
# pm=ondemand by default: idle sites hold no workers at all, which matters on
# a 3.7 GB box hosting a dozen-odd mostly-quiet sites. Override with PM=dynamic
# for a busy site.

set -euo pipefail

GROUP="${1:?usage: $0 <group> <domain> <php-version> [--sub <parent>]}"
DOMAIN="${2:?usage: $0 <group> <domain> <php-version> [--sub <parent>]}"
VER="${3:?usage: $0 <group> <domain> <php-version> [--sub <parent>]}"
shift 3

PARENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sub) PARENT="${2:?--sub needs a parent domain}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -d "/etc/php/${VER}/fpm" ]] || { echo "PHP ${VER} FPM not installed" >&2; exit 1; }

VHOSTS="${VHOSTS_ROOT:-/var/www/vhosts}"
if [[ -n "${PARENT}" ]]; then
  BASE="${VHOSTS}/${GROUP}/${PARENT}/subs/${DOMAIN}"
else
  BASE="${VHOSTS}/${GROUP}/${DOMAIN}"
fi
CONF="${BASE}/config"
DOCROOT="${BASE}/httpdocs"
POOL="/etc/php/${VER}/fpm/pool.d/${DOMAIN}.conf"
SOCK="/run/php/${DOMAIN}-${VER}.sock"

PM="${PM:-ondemand}"
MAX_CHILDREN="${MAX_CHILDREN:-8}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

[[ -d "${DOCROOT}" ]] || { echo "not provisioned: ${DOCROOT}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pool
# ---------------------------------------------------------------------------

log "writing pool ${POOL}"

if [[ "${PM}" == "dynamic" ]]; then
  PM_BLOCK="pm = dynamic
pm.max_children = ${MAX_CHILDREN}
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3"
else
  PM_BLOCK="pm = ondemand
pm.max_children = ${MAX_CHILDREN}
pm.process_idle_timeout = 60s"
fi

sudo tee "${POOL}" >/dev/null <<POOLCONF
; ${DOMAIN} -- PHP ${VER}
; Managed by server_ops/scripts/set-site-php.sh. Edits here are overwritten.

[${DOMAIN}]
user = www-data
group = www-data

listen = ${SOCK}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

${PM_BLOCK}
pm.max_requests = 500

; Each site gets its own error log, so a fatal is attributable to a site
; rather than lost in a shared file.
php_admin_value[error_log] = ${BASE}/logs/php-error.log
php_admin_flag[log_errors] = on

; open_basedir keeps this pool from reading another site's files even though
; every pool currently runs as www-data. It is not a substitute for per-site
; users, but it is the cheap half of the same protection.
php_admin_value[open_basedir] = ${DOCROOT}:/tmp:/usr/share/php:/var/lib/php/sessions
php_admin_value[upload_tmp_dir] = /tmp
php_admin_value[session.save_path] = /var/lib/php/sessions
POOLCONF

# ---------------------------------------------------------------------------
# Vhost wiring
# ---------------------------------------------------------------------------
#
# FilesMatch rather than a blanket SetHandler: a bare SetHandler on the whole
# vhost sends every request, including static files, through PHP.

# Marker-delimited, and edited with python rather than sed. The block contains
# `$`, `\` and `#`, every one of which is special to sed in a different way --
# the first attempt failed with "unterminated s command" and left the vhost
# untouched. Markers also make switching a site between PHP versions exact:
# the old block is removed by name, not by pattern-matching Apache syntax.

for f in "${CONF}/vhost.conf" "${CONF}/vhost-ssl.conf"; do
  [[ -f "${f}" ]] || continue
  sudo python3 - "${f}" "${SOCK}" <<'PYEDIT'
import re, sys
path, sock = sys.argv[1], sys.argv[2]
block = (
    "\t### PHP-HANDLER-START\n"
    "\t<FilesMatch \\.php$>\n"
    f'\t\tSetHandler "proxy:unix:{sock}|fcgi://localhost"\n'
    "\t</FilesMatch>\n"
    "\t### PHP-HANDLER-END\n"
)
s = open(path).read()
s = re.sub(r"[ \t]*### PHP-HANDLER-START.*?### PHP-HANDLER-END\n", "", s, flags=re.S)
if "</VirtualHost>" not in s:
    sys.exit(f"no </VirtualHost> in {path}")
s = s.replace("</VirtualHost>", block + "</VirtualHost>", 1)
open(path, "w").write(s)
PYEDIT
  log "wired $(basename "${f}")"
done

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

log "restarting php${VER}-fpm"
sudo systemctl restart "php${VER}-fpm"

if ! sudo systemctl is-active --quiet "php${VER}-fpm"; then
  echo "FAIL: php${VER}-fpm did not come back" >&2
  sudo systemctl status "php${VER}-fpm" --no-pager | tail -20
  exit 1
fi

log "testing apache config"
if ! sudo apache2ctl configtest 2>&1 | grep -q 'Syntax OK'; then
  sudo apache2ctl configtest
  echo "FAIL: apache config test failed -- not reloading" >&2
  exit 1
fi

sudo systemctl reload apache2
log "done -- ${DOMAIN} now on PHP ${VER} via ${SOCK}"
