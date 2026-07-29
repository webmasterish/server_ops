#!/usr/bin/env bash
#
# Audit every vhost on this server. RUN ON hetzner.
#
#   ./audit-sites.sh            # all sites
#   ./audit-sites.sh <domain>   # one site
#
# Read-only apart from a temporary probe file it writes and removes inside each
# docroot, which is the only honest way to learn which PHP actually serves a
# site. Config can look right while requests go somewhere else -- that is
# exactly how lebanese.tech ended up serving 7.4 over HTTP and 8.3 over HTTPS
# at the same moment.
#
# Checks, per site:
#   pool      the FPM pool that exists for it, and its PHP version
#   http/ssl  which pool socket each vhost actually points at -- these MUST
#             agree, and did not on two sites
#   serving   PHP version reported by the site itself, over HTTPS
#   cert      names covered and days remaining
#   status    HTTP and HTTPS response codes
#   src       whether wp-config.php is served as source (disclosure)
#   perms     docroot ownership, and wp-config.php held at 644
#
# Exits non-zero if anything is wrong, so it can gate a change.

set -uo pipefail

ONLY="${1:-}"
VHOSTS="${VHOSTS_ROOT:-/var/www/vhosts}"
MY_IP=$(curl -s -4 ifconfig.me)
PROBE="__audit_sapi.php"
PROBLEMS=0

note() { PROBLEMS=$((PROBLEMS + 1)); printf '  !! %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Server level
# ---------------------------------------------------------------------------

echo "=============================================================="
echo "SERVER"
echo "=============================================================="

printf '  apache        %s\n' "$(systemctl is-active apache2)"
# sudo: without it apache2ctl cannot read the config and reports a permission
# error rather than a syntax verdict -- which this audit then reported as a
# FAILED configtest on a perfectly healthy server.
sudo apache2ctl configtest 2>&1 | grep -q 'Syntax OK' \
  && printf '  configtest    Syntax OK\n' || note "apache configtest FAILED"

printf '  mpm           %s\n' "$(apache2ctl -M 2>/dev/null | grep -oE 'mpm_[a-z]+')"
if apache2ctl -M 2>/dev/null | grep -q php_module; then
  note "mod_php is loaded -- it should not be, all sites use FPM"
fi

for v in 7.4 8.3 8.5; do
  st=$(systemctl is-active "php${v}-fpm" 2>/dev/null)
  printf '  php%-5s fpm   %s\n' "${v}" "${st}"
  [[ "${st}" == "active" ]] || note "php${v}-fpm is ${st}"
done

# The catch-all must sort first, or unknown SNI falls through to a real site.
first=$(ls /etc/apache2/sites-enabled/ | head -1)
printf '  first vhost   %s\n' "${first}"
[[ "${first}" == "000-catchall-ssl.conf" ]] \
  || note "catch-all is not first in sites-enabled -- unknown SNI will hit a real site"

code=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' \
  --resolve "unmatched.invalid:443:127.0.0.1" https://unmatched.invalid/ 2>/dev/null)
printf '  unknown SNI   %s\n' "${code}"
[[ "${code}" == "404" ]] || note "unknown SNI returned ${code}, expected 404"

printf '  disk          %s\n' "$(df -h / | awk 'NR==2 {print $4" free ("$5" used)"}')"
printf '  memory        %s\n' "$(free -m | awk '/^Mem/ {print $7" MB available of "$2" MB"}')"
printf '  swap          %s\n' "$(free -m | awk '/^Swap/ {print $3" MB of "$2" MB used"}')"
printf '  certbot timer %s\n' "$(systemctl is-active certbot.timer 2>/dev/null)"
printf '  logrotate     %s\n' "$(systemctl is-active logrotate.timer 2>/dev/null)"

# ---------------------------------------------------------------------------
# Per site
# ---------------------------------------------------------------------------

echo
echo "=============================================================="
echo "SITES"
echo "=============================================================="

for conf in "${VHOSTS}"/*/*/config "${VHOSTS}"/*/*/subs/*/config; do
  [[ -d "${conf}" ]] || continue
  base=$(dirname "${conf}")
  domain=$(basename "${base}")
  [[ -n "${ONLY}" && "${domain}" != "${ONLY}" ]] && continue
  docroot="${base}/httpdocs"

  echo
  echo "--- ${domain}"

  # --- pool and handler agreement -----------------------------------------
  pool_ver=""
  for v in 7.4 8.3 8.5; do
    [[ -f "/etc/php/${v}/fpm/pool.d/${domain}.conf" ]] && pool_ver="${v}"
  done

  http_sock=$(grep -oE 'run/php/[^|"]+' "${conf}/vhost.conf" 2>/dev/null | head -1)
  ssl_sock=$(grep -oE 'run/php/[^|"]+' "${conf}/vhost-ssl.conf" 2>/dev/null | head -1)

  printf '  pool          %s\n' "${pool_ver:-none (uses global fallback)}"
  printf '  http vhost    %s\n' "${http_sock:-none}"
  printf '  ssl  vhost    %s\n' "${ssl_sock:-none}"

  if [[ -f "${conf}/vhost-ssl.conf" && "${http_sock}" != "${ssl_sock}" ]]; then
    note "${domain}: http and ssl vhosts point at different pools"
  fi
  if [[ -n "${pool_ver}" && -n "${http_sock}" && -S "/${http_sock}" ]]; then
    :
  elif [[ -n "${http_sock}" ]]; then
    note "${domain}: socket /${http_sock} does not exist"
  fi

  # --- what actually serves ------------------------------------------------
  # The served root is not always <base>/httpdocs. analytics.dotaim.com points
  # at httpdocs/matomo, so a probe written to httpdocs is never reachable and
  # the audit reported "File not found" as if the site were broken. Read the
  # actual DocumentRoot out of the vhost, ignoring commented-out ones.
  real_root=$(grep -hE '^[[:space:]]*DocumentRoot[[:space:]]' \
    "${conf}/vhost-ssl.conf" "${conf}/vhost.conf" 2>/dev/null \
    | head -1 | awk '{print $2}')
  [[ -n "${real_root}" ]] && docroot="${real_root}"
  printf '  docroot       %s\n' "${docroot}"

  # A provisioned-but-not-yet-cut-over site has no certificate, so an HTTPS
  # request hits the catch-all and returns ITS 404 page -- which the probe then
  # reports as the site's PHP version. Probe over HTTP in that case, and treat
  # the missing certificate as a pre-cutover state rather than a fault.
  HAS_TLS=0
  sudo test -f "/etc/letsencrypt/live/${domain}/fullchain.pem" && HAS_TLS=1

  serving="n/a"
  if [[ -d "${docroot}" ]]; then
    printf '<?php echo php_sapi_name()."|".PHP_VERSION;' \
      | sudo tee "${docroot}/${PROBE}" >/dev/null 2>&1
    sudo chown webmasterish:www-data "${docroot}/${PROBE}" 2>/dev/null
    if [[ ${HAS_TLS} -eq 1 ]]; then
      serving=$(curl -sk -m 15 --resolve "${domain}:443:${MY_IP}" \
        "https://${domain}/${PROBE}" 2>/dev/null | head -c 40)
    else
      serving=$(curl -s -m 15 --resolve "${domain}:80:${MY_IP}" \
        "http://${domain}/${PROBE}" 2>/dev/null | head -c 40)
    fi
    sudo rm -f "${docroot}/${PROBE}"
  fi
  printf '  serving       %s\n' "${serving:-<no response>}"

  if [[ -n "${pool_ver}" && "${serving}" != *"|${pool_ver}."* && "${serving}" != "n/a" ]]; then
    note "${domain}: pool says ${pool_ver} but the site reports '${serving}'"
  fi

  # --- certificate ---------------------------------------------------------
  live="/etc/letsencrypt/live/${domain}"
  if sudo test -f "${live}/fullchain.pem"; then
    names=$(sudo openssl x509 -in "${live}/fullchain.pem" -noout -text 2>/dev/null \
      | grep -A1 'Subject Alternative Name' | tail -1 | sed 's/ *DNS://g' | tr -d ' ')
    endep=$(sudo openssl x509 -in "${live}/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
    days=$(( ( $(date -d "${endep}" +%s) - $(date +%s) ) / 86400 ))
    printf '  cert          %s (%s days)\n' "${names}" "${days}"
    [[ "${days}" -lt 21 ]] && note "${domain}: certificate expires in ${days} days"
  else
    printf '  cert          NONE (not cut over yet)\n'
  fi

  # --- responses -----------------------------------------------------------
  hs=$(curl -sk -o /dev/null -m 15 --resolve "${domain}:443:${MY_IP}" \
    -w '%{http_code}' "https://${domain}/" 2>/dev/null)
  hp=$(curl -s -o /dev/null -m 15 --resolve "${domain}:80:${MY_IP}" \
    -w '%{http_code}' "http://${domain}/" 2>/dev/null)
  printf '  origin        http:%s https:%s\n' "${hp}" "${hs}"
  if [[ ${HAS_TLS} -eq 1 ]]; then
    # 2xx or 3xx. A redirect is a legitimate answer -- memories.mardini.net is
    # a private Piwigo gallery that 302s to its login page. What matters is
    # ruling out 4xx/5xx: a broken vhost, missing handler, or dead pool.
    [[ "${hs}" =~ ^[23][0-9][0-9]$ ]] || note "${domain}: origin HTTPS returned ${hs}"
  else
    # No certificate yet, so HTTPS legitimately lands on the catch-all.
    # 302 is fine too: Piwigo redirects / to identification.php for a private
    # gallery, which is correct behaviour, not a fault.
    [[ "${hp}" =~ ^(200|301|302|303|307)$ ]] || note "${domain}: origin HTTP returned ${hp}"
  fi

  # --- source disclosure ---------------------------------------------------
  if [[ -f "${docroot}/wp-config.php" ]]; then
    if curl -sk -m 15 --resolve "${domain}:443:${MY_IP}" \
        "https://${domain}/wp-config.php" 2>/dev/null | head -c 80 | grep -q '<?php'; then
      note "${domain}: wp-config.php IS SERVED AS SOURCE"
    else
      printf '  src leak      no\n'
    fi
    mode=$(stat -c '%a' "${docroot}/wp-config.php")
    printf '  wp-config     %s\n' "${mode}"
    [[ "${mode}" == "644" ]] || note "${domain}: wp-config.php is ${mode}, expected 644"
  fi

  # --- leftovers -----------------------------------------------------------
  if [[ -f "${docroot}/.htaccess" ]] && grep -q 'MIGRATION-FREEZE' "${docroot}/.htaccess" 2>/dev/null; then
    note "${domain}: maintenance freeze block leaked into the destination"
  fi
done

echo
echo "=============================================================="
if [[ ${PROBLEMS} -eq 0 ]]; then
  echo "RESULT: no problems found"
else
  echo "RESULT: ${PROBLEMS} problem(s) -- see !! lines above"
fi
echo "=============================================================="
exit $(( PROBLEMS > 0 ))
