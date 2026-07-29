# Handover — migrating menamaps.com

For whoever picks this up inside the menamaps project, where the surrounding
context lives. This document covers only what `server_ops` knows: the state of
the copy on Hetzner, the tooling, and the things specific to this site that
will bite.

Everything here has already been proven on four other sites
(videotizer.com, nidaldirani.com and three static ones). menamaps is the last
and hardest.

---

## Current state

- **Backed up and verified.** `/var/www/backups/hostinger/synced/` on Hetzner
  holds 126,553 files (10 GB) and `u918436082_menamaps.sql.bz2` (52 tables,
  4.2 MB compressed). Restore-tested into MySQL 8.0.46 — clean.
- **Not provisioned, not migrated.** No vhost, no database, no DNS change.
- Still live on Hostinger, unfrozen.

## Why this one is different

| | menamaps.com | the others |
|---|---|---|
| Size | 10 GB, 126k files | ≤ 2.8 GB |
| Commerce | **WooCommerce + Stripe** | none |
| Writes | live orders | posts/comments at most |
| Tooling outside docroot | **yes** — `~/mm-scripts/` | none |
| DNS | Cloudflare, registrar Cloudflare | mixed |

The size is an inconvenience. The others are the actual problems.

## 1. Tooling that lives outside the docroot

`~/mm-scripts/` on Hostinger — `batch-create.php`, `batch-golive.php`,
`canonicalize-city-terms.php`, last modified 2026-07-26, so actively used. Plus
`~/menamaps_track1_desc_backup_20260630_213620.json`.

**A docroot-only migration silently loses these.** They are in the backup
already (`synced/home/`), but nothing places them on Hetzner or recreates
whatever invokes them. Decide where they belong and whether anything schedules
them.

## 2. Cron

Hostinger's cron is hPanel-only and could not be enumerated over SSH. The
owner's recollection is that none exist, and no filesystem evidence contradicts
that — but `mm-scripts/` is exactly the sort of thing a cron would drive, so
**check hPanel → Websites → menamaps.com → Advanced → Cron Jobs before the plan
lapses.** After that the information is gone.

WordPress's own scheduled events live in `wp_options` and travel with the dump;
only real system cron would be lost.

## 3. WooCommerce and Stripe — the part that needs a decision

An order placed between the final sync and DNS propagation lands in a database
about to be discarded. Unlike a comment, nobody can re-enter it from memory.

The cutover procedure (`docs/runbook-site-cutover.md`) solves this by freezing
the source first: a 503 means no order can be taken. What remains is:

- **How long may the shop be closed?** The freeze holds from the final resync
  until DNS has propagated. On other sites that was minutes; here the resync is
  larger, so budget for a delta sync of 10 GB (fast, since the bulk is already
  copied — only changes move).
- **Repoint Stripe webhooks** to the new host. Miss this and payments succeed
  while order status never updates — the worst failure mode, because it looks
  fine.
- **Check for orders mid-flow** at freeze time.
- **Test checkout end to end** before lifting the freeze.

## 4. PHP version

WP 7.0.2, requires PHP ≥ 7.4. Hetzner serves 8.3, Hostinger 8.2–8.3, so it
migrates onto what it already runs. Note the local dev machine is on **PHP 8.5**,
which is why sites can show fatals locally that do not occur in production —
do not treat a local error as a migration blocker without checking which PHP
produced it.

Active plugins at time of audit: `kadence-blocks`, `woocommerce`,
`facebook-for-woocommerce`, `woocommerce-gateway-stripe`.

## 5. Mechanics

Same tooling as every other site. From `~/server_ops/scripts/` on Hetzner:

```bash
./provision-site.sh dotaim menamaps.com \
  --content /var/www/backups/hostinger/synced/sites/menamaps.com/public_html/ \
  --no-redirect

sudo mysql --defaults-file=/etc/mysql/debian.cnf \
  -e "CREATE DATABASE menamaps_website_wp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;"

# freeze the source first -- see the runbook
./resync-site.sh dotaim menamaps.com menamaps_website_wp cms

# only after DNS points here
./enable-site-ssl.sh dotaim menamaps.com --proxied --no-redirect
```

`resync-site.sh` handles, automatically, four things that each broke a previous
site:

1. Repoints **every** `.config/*.php` naming the source database — the
   production file is `live_config.php` here, not `master_config.php`.
2. Strips the maintenance freeze from the destination `.htaccess`, which would
   otherwise make the new site serve 503 the moment DNS moves.
3. Rewrites Hostinger absolute paths in `wp-config.php` and, serialization-safe,
   in the database.
4. Forces 775/664 ownership so WordPress can self-update, with `wp-config.php`
   held at 644.

## 6. Cloudflare — the ordering trap that took nidaldirani.com down

menamaps.com is Cloudflare-proxied. **If the zone is on Full (strict), the
certificate must exist on Hetzner BEFORE the origin is switched.** Otherwise
Cloudflare cannot validate the origin, and every request returns 526 — the site
is down, not degraded.

Two safe orders:

- Leave the zone on **Flexible** during cutover, issue the certificate, then
  move to Full (strict); or
- **Grey-cloud** (DNS-only) the record, issue the certificate, then re-proxy.

If it happens anyway, it is recoverable: Cloudflare still proxies plain HTTP to
the origin over HTTP even in strict mode, so `enable-site-ssl.sh --proxied`
can still complete over HTTP-01.

## 7. Verification worth doing beyond the script's

The resync verifies post/option counts and newest timestamp. For a shop, also:

```sql
SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';
SELECT MAX(post_date) FROM wp_posts WHERE post_type = 'shop_order';
SELECT COUNT(*) FROM wp_woocommerce_order_items;
```

Compare source and destination. Then place a test order end to end.

## 8. Rollback

A record back to `82.25.96.229`, **and lift the maintenance freeze on
Hostinger** — easy to forget, and forgetting means rolling back to a 503.

Once the shop has taken an order on Hetzner, rollback is no longer clean: that
order exists only on Hetzner. Decide early how long the rollback window stays
open, and stop treating it as free after the first order.
