# PHP versions on Hetzner

Three versions are installed because the sites need three. Ubuntu 24.04 ships
only 8.3; 7.4 and 8.5 come from the `ondrej/php` PPA.

| Version | Source | Used by |
|---|---|---|
| 7.4.33 | ondrej PPA | lebanese.tech, singlefunction.com |
| 8.3.6 | Ubuntu | everything else, and the CLI default |
| 8.5.8 | ondrej PPA | menamaps.com |

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

## CLI default

`php` on the command line stays **8.3**. wp-cli follows it, and every script in
this repo assumes it. If it ever reports 7.4 or 8.5, that is a regression:

```bash
php -v | head -1     # expect 8.3.x
```

Per-version binaries are always available as `php7.4`, `php8.3`, `php8.5`.

## Assigning a version to a site

Per-site FPM pools, set in the site's vhost. See `docs/runbook-fpm.md`.
