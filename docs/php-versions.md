# PHP versions on Hetzner

Three versions are installed because the sites need three. Ubuntu 24.04 ships
only 8.3; 7.4 and 8.5 come from the `ondrej/php` PPA.

| Version | Source | Used by |
|---|---|---|
| 7.4.33 (`-31`) | ondrej PPA | lebanese.tech, singlefunction.com |
| 8.3.6 (`0ubuntu0.24.04.13`) | Ubuntu | everything else, and the CLI default |
| 8.5.12 | ondrej PPA | menamaps.com (as of 2026-09-26) |

Versions as of 2026-10-21, after the PHP2Shell patch (see "Security patches"
below).

Local dev runs **8.5.7**, which is why sites can throw fatals locally that do
not occur in production. A local error is not evidence of a migration problem
until you have checked which PHP produced it.

## The pin — do not remove it

`/etc/apt/preferences.d/99-ondrej-php-pin` restricts the PPA to supplying
`php7.4*`, `php8.5*` and `php-common`, at priority 600. Everything else from it
sits at 100, below Ubuntu's 500.

Without this, ondrej's `php8.3` (8.3.32) would replace Ubuntu's (8.3.6) on the
next `apt upgrade` — silently changing the PHP under ayatalquran.com, the
highest-traffic site, with no deployment and no obvious cause. Verified after
pinning: `apt-cache policy php8.3-fpm` still resolves to `8.3.6-0ubuntu0.24.04.10`.

`php-common` is the one shared package that had to be allowed through: Ubuntu's
2:93 explicitly `Breaks` ondrej's `php7.4-common`, so 7.4 cannot install
without it. The upgrade was simulated first and touches neither php8.3 nor
apache.

## The seven removed `php-*` packages

Installing 7.4 removed `php-apcu`, `php-imagick`, `php-imap`, `php-mcrypt`,
`php-memcache`, `php-redis` and `php-xmlrpc`. These are **metapackages** —
`php-redis` is 13 KB and owns no files beyond `/usr` and `/usr/share`; the real
module is `/usr/lib/php/20230831/redis.so`, shipped by `php8.3-redis`, which
was not touched. Verified `redis` still loads under 8.3 afterwards, which
matters because dotaim.com and ayatalquran.com use it as their object cache.

**Never run `apt autoremove` blind.** Because those metapackages are gone,
apt now marks `php8.3-apcu`, `-igbinary`, `-imagick`, `-memcache`, `-redis` and
`-xmlrpc` (plus `libxmlrpc-epi0t64`) as "no longer required". Autoremove would
take out the redis module two sites use as their object cache. Before ever
autoremoving, `apt-mark manual` the modules the 8.3 sites actually load.

## Security patches — the PPA branches are not automatic

`unattended-upgrades` follows the Ubuntu archive only, so it patches 8.3 and
**never** 7.4 or 8.5. A PHP security advisory therefore always needs a manual
step for the two PPA branches.

Worked through on 2026-10-21 for CVE-2026-109618/109619 ("PHP2Shell", critical
unauthenticated RCE, exploited in the wild on disclosure day):

```bash
# on hetzner — refresh lists, confirm the PPA candidate actually moved
sudo apt update 2>&1 | grep -iE "ondrej|^W:|^E:|^Err"
apt-cache policy php7.4-fpm php8.5-fpm php8.3-fpm | grep -E "^php|Installed|Candidate"

# patch all three branches; -y because `!` shells have no tty for the prompt
sudo apt install -y -o Acquire::Retries=10 --only-upgrade "php7.4-*" "php8.3-*" "php8.5-*"

# verify by PACKAGE version and changelog, not php -v
dpkg -l | grep -E "^ii\s+php(7\.4|8\.3|8\.5)-(fpm|common) "
zcat /usr/share/doc/php7.4-common/changelog.Debian.gz | grep -m1 -n CVE-XXXX
systemctl show -p ActiveEnterTimestamp --value php7.4-fpm php8.3-fpm php8.5-fpm
```

Three things that went wrong that day and will again:

- **`php -v` lies on 8.3.** Ubuntu backports fixes without changing the
  upstream number, so it reads 8.3.6 before and after. Only the package
  revision (`…24.04.12` → `…24.04.13`) shows the fix.
- **The PPA buckles on advisory day.** The first `apt update` silently kept a
  9-day-old PPA list (the fetch failed and apt carried on), so `--only-upgrade`
  found nothing. The install then hit `503 Service Unavailable` on 2 of 35
  debs and aborted having installed nothing. Re-running with
  `Acquire::Retries=10` fetched only the missing two. Always check the
  Candidate line before concluding there is no fix.
- **7.4 is EOL upstream.** Its fix exists only because the PPA maintainer
  backports. Confirm the CVE is named in the changelog, every time. The real fix
  is moving lebanese.tech and singlefunction.com to 8.3.

## CLI default

`php` on the command line stays **8.3**. wp-cli follows it, and every script in
this repo assumes it. If it ever reports 7.4 or 8.5, that is a regression:

```bash
php -v | head -1     # expect 8.3.x
```

Per-version binaries are always available as `php7.4`, `php8.3`, `php8.5`.

## Assigning a version to a site

Per-site FPM pools, set in the site's vhost. See `docs/runbook-fpm.md`.
