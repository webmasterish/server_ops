# Piwigo — memories.mardini.net

Docroot: `/var/www/vhosts/mardini/mardini.net/subs/memories.mardini.net/httpdocs`.
Private gallery: `/` 302s to `identification.php`, which is expected.
Theme: Bootstrap Darkroom (`themes/bootstrap_darkroom`).

## Version history on hetzner

| Date | Core | Theme | How |
|---|---|---|---|
| 2026-07 (migration) | 16.3.0 | — | migrated from Hostinger |
| 2026-11-05 | 16.4.0 | Bootstrap Darkroom 16.e | owner, from the dashboard |

## Dashboard updates print `touch(): Utime failed` — harmless

Every dashboard update (core or extension) logs a burst of

```
PHP Warning:  touch(): Utime failed: Operation not permitted in .../admin/include/pclzip.lib.php on line 3857
```

to `logs/php-error.log`, and the dashboard shows them as error notices.
pclzip writes each file, then tries to set its mtime to the archive's. Files
are owned by `webmasterish` and group-writable by `www-data`: PHP can write
the content but only the owner may set an explicit mtime. Content is written;
only timestamps are off. Not worth changing ownership to silence it.

## Verifying an update

Done 2026-11-05 — core and theme both matched upstream byte-for-byte.

1. Version: `grep PHPWG_VERSION include/constants.php`.
2. Core: download the same release from
   `https://piwigo.org/download/dlcounter.php?code=<version>` locally, md5 every
   file (excluding `_data local galleries upload` and third-party themes), and
   compare with md5s of the same paths on the server. Mind filenames with
   spaces (`themes/default/icon/piwigo.org-icon 1.svg`). Expected difference:
   `install/obsolete.list` is missing on the server — the updater deletes it
   after processing it.
3. Theme: `themes/bootstrap_darkroom/pem_metadata.txt` names the upstream git
   revision; compare against that GitHub archive. Expected differences:
   `pem_metadata.txt` added and the version stamped in `themeconf.inc.php`.
4. DB: highest `install/db/NNN-database.php` should equal
   `MAX(id)` of the `upgrade` table (181 at 16.4.0). Read DB credentials from
   `local/config/database.inc.php` inside a PHP script — never print them.
5. HTTP, via `--resolve memories.mardini.net:443:127.0.0.1`: `/` 302,
   `/identification.php` 200 with no PHP warnings in the body.
6. `_data/logs/log_<date>_*.txt` — Piwigo's own log; only DEBUG/INFO is normal.

## Known gap

Password-reset mail does not send — no site on the server can send mail.
See `site-mail.md`.
