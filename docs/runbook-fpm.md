# PHP-FPM on Hetzner

Apache runs **mpm_event + proxy_fcgi**. mod_php is gone. Each site has its own
FPM pool, and pools can run different PHP versions.

## Why

Not a preference — a requirement. These sites run three different PHP versions
on Hostinger (7.4, 8.3, 8.5), and **mod_php can serve exactly one**. It could
not host this estate at all.

The rest is upside:

- **Memory.** mod_php forces mpm_prefork, where every Apache worker carries a
  full PHP interpreter. Measured before: 22 workers, 1291 MB. After: 3 Apache
  processes at 50 MB plus FPM workers that exit when idle.
- **Blast radius.** One site saturating or crashing PHP no longer starves the
  others.
- **Attribution.** Each pool writes its own `logs/php-error.log`, so a fatal
  belongs to a site instead of vanishing into a shared file.

## Assigning a version

```bash
~/server_ops/scripts/set-site-php.sh <group> <domain> <version> [--sub <parent>]

# busy site: dynamic rather than ondemand
PM=dynamic MAX_CHILDREN=12 ~/server_ops/scripts/set-site-php.sh dotaim ayatalquran.com 8.3
```

Writes `/etc/php/<ver>/fpm/pool.d/<domain>.conf`, wires a marker-delimited
`<FilesMatch \.php$>` block into both vhost files, restarts that FPM service
and reloads Apache. Re-running with a different version moves the site cleanly
— the old block is removed by marker, not by pattern-matching Apache syntax.

## Verifying a site is really on the pool you think

Modes and sockets can look right while the request goes somewhere else. Ask
PHP directly:

```bash
# on hetzner
printf '<?php echo php_sapi_name()."|".PHP_VERSION;' | sudo tee <docroot>/__sapicheck.php
sudo chown webmasterish:www-data <docroot>/__sapicheck.php
# then
curl -s https://<domain>/__sapicheck.php     # expect fpm-fcgi|<version>
# and REMOVE IT
sudo rm <docroot>/__sapicheck.php
```

`apache2handler` means it is still on mod_php. `fpm-fcgi` with the wrong
version means the vhost points at another pool's socket.

## The source-disclosure trap

With mod_php gone, **a `.php` file in a vhost with no handler is served as
plain text.** Not a 500 — the source, including anything in it. This is
precisely how nidaldirani.com exposed `wp-config.php` before its stale
Hostinger `SetHandler` was neutralised.

Two defences, both in place:

1. `set-site-php.sh` gives every PHP site its own handler.
2. `/etc/apache2/conf-available/php-fpm-default.conf` is a server-wide fallback
   sending any unclaimed `.php` to the default 8.3 pool.

**Any new vhost must get one or the other before it serves a `.php` file.**

## Per-site limit overrides

A site needing non-default `php_admin_value` limits gets a file at
`templates/fpm-limits/<domain>.conf`. `set-site-php.sh` appends it verbatim to
the generated pool, last, so it wins over the defaults. No file means stock
limits, which is every site except **menamaps.com**.

**Do not hand-edit the pool file.** `set-site-php.sh` rewrites
`/etc/php/<ver>/fpm/pool.d/<domain>.conf` from its template on every run and the
pool header says so. A limit typed in there works until the next run of the
script and then silently reverts — for menamaps.com that would mean
`memory_limit` dropping from 1024M back to Debian's 128M, which surfaces as
Printify batch operations dying rather than as anything pointing at PHP config.
This is the same shape of bug as `provision-site.sh` destroying the PHP handler
block on rewrite, which left lebanese.tech serving two different PHP versions
over HTTP and HTTPS at the same moment.

Confirm limits are actually in effect by asking PHP over HTTP, not by reading
the pool file — same principle as the SAPI check above:

```php
<?php echo ini_get('memory_limit')."|".ini_get('max_execution_time');
```

## Pool sizing

`pm = ondemand` by default, `max_children = 8`, idle workers exit after 60s.
On a 3.7 GB box hosting a dozen mostly-quiet sites, idle sites should hold no
workers. Busy sites get `PM=dynamic` so a worker is always warm —
ayatalquran.com is the only one so far.

`open_basedir` confines each pool to its own docroot. Every pool still runs as
`www-data`, so this is the cheap half of isolation, not the whole thing — see
below.

## Still open: per-site users

All pools run as `www-data`, the same identity mod_php used. That means **any
compromised site can still read every other site's database credentials.**
Verified, not assumed.

Fixing it means a user per site plus a matching ownership change on each
docroot. It was deliberately left out of the SAPI migration: changing identity
and permissions at the same moment as the handler would have made a failed
cutover far harder to diagnose. It is a per-site change and can be done
gradually.

## Rollback

```bash
sudo a2dismod mpm_event
sudo a2enmod mpm_prefork php8.3
sudo systemctl restart apache2
```

**This is no longer a way back, as of 2026-07-30.** It was only ever valid while
every site ran 8.3. lebanese.tech and singlefunction.com are on 7.4 and
menamaps.com is on 8.5; mod_php can serve exactly one version, so reverting
would take those three off the air. Kept here as a record of what the escape
hatch was, not as a procedure to run.
