# menamaps.com — migration plan and handover

**Single source of truth for the last Hostinger site.** Written from `server_ops`,
revised 2026-07-30 with the menamaps project's own findings so there is one
document rather than two.

`docs/runbook-site-cutover.md` still owns the generic mechanics. This document
owns everything specific to this site, and where it differs from the runbook, this
wins.

The session prompt that starts this work lives in
`__/sessions/session_2026-07-30.md` → *Pick up from here*, not here.

## STATUS: phases 1 and 2 are COMPLETE — cut over 2026-07-30, live on Hetzner

Everything below the ownership table is the plan as written beforehand, kept for
its reasoning. What actually happened, and what is still owed:

- **Live on Hetzner** on PHP 8.5.8, `menamaps_website_wp`, certificate valid to
  2026-10-28, Cloudflare Full (strict), system wp-cron installed.
- **All HPOS counts matched the pre-freeze baseline exactly** — orders,
  order_items, order_stats, Action Scheduler pending, products, variations,
  attachments, 52 tables. Figures in `migration/status.md`.
- **The Hostinger source is still frozen** (503 + `Retry-After`), deliberately,
  and stays that way. Rolling back means reverting DNS *and* lifting the freeze.
- **One thing went wrong: the apex was left orange-clouded** when the A record
  was repointed, so Full (strict) gave 526 on every HTTPS request until the
  certificate existed — about seven minutes of visible downtime. See
  `migration/status.md` for the recovery and the lesson. §4 below was right and
  was not followed; it is not a step to skip on the next Full (strict) zone.
- **Still owed: §10, the handback list**, which is the menamaps project's. Item
  4 — end-to-end checkout test, and confirming the unchanged Stripe webhook is
  delivering — is the one that matters most, and the freeze on Hostinger should
  stay up until it passes.
- **One item for the menamaps project to judge, not a fault:** `siteurl` is
  `http://menamaps.com/cms`, carried across unchanged from Hostinger. It works
  because Cloudflare terminates TLS and rewrites at the edge, exactly as before.
  Flagged rather than changed — site config belongs to that repo.

### The five FPM limits are NOT hand-edited into the pool

They live in `templates/fpm-limits/menamaps.com.conf` and `set-site-php.sh`
appends them on every run. §2 below says to add them to the pool by hand; that
was changed during the cutover, because the script rewrites the pool from its
template each time and the pool header says edits are overwritten. Hand-editing
would have worked until the next `set-site-php.sh` run and then silently
reverted to a 128M `memory_limit`. Verified in effect over HTTP after
provisioning, by asking PHP rather than by reading the config:
`fpm-fcgi|8.5.8|mem=1024M|upl=128M|post=128M|exec=300|vars=5000|svg=yes`.

---

## Current state

- **Backed up and verified.** `/var/www/backups/hostinger/synced/` on Hetzner
  holds 126,553 files (10 GB) and `u918436082_menamaps.sql.bz2` (52 tables,
  4.2 MB compressed). Restore-tested into MySQL 8.0.46 — clean.
- **A third copy exists.** The menamaps project ran a full `pull content` on
  2026-07-30, so the database and uploads also sit on the owner's local machine,
  independent of both hosts. Relevant while the backup set is still Hetzner-only
  with no offsite push.
- **Not provisioned, not migrated.** No vhost, no database, no DNS change.
- Still live on Hostinger, unfrozen.
- **The freeze is authorised** (owner, 2026-07-30). It remains the minimal,
  sentinel-marked, reversible exception to Hostinger being read-only; it is not
  standing permission for anything else.

## Ownership

| Phase | Owner | What |
|---|---|---|
| 1 — pre-freeze checks | **server_ops** | order and Action Scheduler counts, in-flight order check |
| 2 — cutover | **server_ops** | provision, freeze, resync, verify, DNS, TLS, wp-cron |
| 3 — handback | menamaps project | sync config, `push theme`, live checkout test, storefront and CLI checks |

No back-and-forth mid-cutover. Phases 1 and 2 run to completion here, then the
handback list at the end goes to the menamaps project.

## Why this one is different

| | menamaps.com | the others |
|---|---|---|
| Size | 10 GB, 126k files | ≤ 2.8 GB |
| Commerce | **WooCommerce + Stripe** | none |
| Writes | live orders | posts/comments at most |
| PHP | **8.5** | 7.4 or 8.3 |
| DNS | Cloudflare, registrar Cloudflare, **Full (strict)** | mixed |

The size is an inconvenience. The rest is the actual work.

---

## 1. PHP 8.5 — and why that is not the rejected "parity with local"

**Provision on 8.5.** `set-site-php.sh` already uses `menamaps.com 8.5` as its
worked example.

This session's decision log rejected *"make the server identical to local"* on
the grounds that local runs 8.5 and would reproduce local's fatals in production.
That reasoning does not apply here, and the same log's other decision is the one
that governs: **migrate each site at the PHP version it already runs.**

For this site those coincide. The web tier on Hostinger **is 8.5** — CloudLinux
alt-php, set in hPanel, `/opt/alt/php85/` present. It is not an upgrade to match
local; it is the version production already serves, and 8.3 would be a
*downgrade* away from what the code has been running against for months.

The trap that hid this: `php -v` over SSH on Hostinger reports **8.3.30**, which
is only the account's default CLI, not what serves HTTP. An earlier draft of this
document concluded 8.3 from exactly that reading. `migration/status.md` had it
right all along.

Hetzner is ready — verified 2026-07-30:

- **PHP 8.5.8 FPM installed, active, enabled.**
- imagick (with a **working SVG delegate** — `Imagick::queryFormats("SVG")`
  returns SVG, and the ImageMagick policy does not block it), gd, mysqli,
  mysqlnd, zip, curl, mbstring, intl, xml, exif, soap, bcmath all present.
- This will be the first site on the 8.5 pool; only `www.conf` exists there today.

The SVG delegate matters: this site renders street-map art and rasterises SVG in
process. Without it, map downloads and the marketing zip lose their raster output.

### WP-CLI runs under 8.3 by default

`wp --info` on Hetzner reports `/usr/bin/php8.3`. This site's operational
procedure is CLI-first (batch product creation, scoped pricing applies), so pin
the interpreter:

```bash
SERVER_NAME=menamaps.com /usr/bin/php8.5 /usr/local/bin/wp \
  --path=/var/www/vhosts/dotaim/menamaps.com/httpdocs/cms <command>
```

**`SERVER_NAME` is mandatory.** `wp-config.php` selects its config file from it,
and the CLI guard defaults to `localhost`, which matches no config on a
production box — WP-CLI then boots with no database credentials and queries
**silently do nothing**: no error, no "Query OK". Bracket any mutation with a
`SELECT` before and after so you can see rows actually change.

## 2. FPM limits — the real blocker

Hostinger's limits are not stock, and this site depends on that. Set these in the
pool at provisioning time:

```apache
php_admin_value[memory_limit] = 1024M
php_admin_value[upload_max_filesize] = 128M
php_admin_value[post_max_size] = 128M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_vars] = 5000
```

| | Hostinger (live) | Hetzner default | What breaks at the default |
|---|---|---|---|
| `memory_limit` | 2048M | **128M** | the Printify client's product list is multi-MB even slimmed, and nearly OOMed at 256M locally. Apply-all and Refresh-templates die |
| `upload_max_filesize` | 2048M | **2M** | the public story form clamps its cap to `wp_max_upload_size()`, so a 10 MB photo limit silently becomes 2 MB |
| `post_max_size` | 2048M | **8M** | multi-photo story submissions |
| `max_execution_time` | 0 | **30** | Printify v2 shipping payloads take 30–86s; the HTTP client allows 180s. wp-admin Fetch & preview dies at 30 |
| `max_input_vars` | — | 1000 | WooCommerce variation screens across 861 products post large forms |

1024M is chosen against 3.7 GB of RAM with ~1.6 GB currently available: enough
for the catalogue work, not enough for one runaway request to take the box down.

CLI is already unlimited on both hosts (`memory_limit=-1`,
`max_execution_time=0`), so the CLI-first procedure is unaffected either way.

## 3. No system wp-cron exists

`/etc/cron.d` holds only certbot, e2scrub, php sessions and sysstat, and there is
no root crontab. Every site migrated so far is brochure-ware where page-load cron
suffices. This one is a store with Action Scheduler, WooCommerce scheduled tasks,
and pending actions that travel with the dump.

Add, as `www-data`:

```cron
* * * * * SERVER_NAME=menamaps.com /usr/bin/php8.5 /usr/local/bin/wp \
  --path=/var/www/vhosts/dotaim/menamaps.com/httpdocs/cms cron event run --due-now --quiet
```

Leave WordPress's page-load cron enabled as well. Disabling it means editing
`wp-config.php`, which is a menamaps-repo change, not a server one.

## 4. Cloudflare — grey-cloud, never Flexible

The runbook offers Flexible or grey-cloud as equivalent safe orders. **For this
zone they are not.** It runs **Full (strict)** with Always Use HTTPS and
Automatic HTTPS Rewrites both on, and the site's own documentation records that
Flexible causes infinite redirect loops with this install.

1. Lower the TTL on the apex A record (grey-clouding gives it a real TTL).
2. Grey-cloud (DNS-only) the apex.
3. Switch the A record to `91.99.146.221`.
4. `enable-site-ssl.sh dotaim menamaps.com --proxied --no-redirect`.
5. Verify `ssl_verify:0` against the origin, per the runbook's post-cutover section.
6. Re-proxy, and confirm the zone is still on Full (strict).

**Do not touch MX** — mail is Google Workspace and menamaps.com is an alias of
dotaim.com. Leave the Brevo DKIM CNAMEs DNS-only, and leave SPF alone: it carries
two includes (`spf.brevo.com` and `_spf.google.com`) and both are needed.

## 5. What needs no work at all

**The domain is not changing**, so every integration keyed on the hostname
survives untouched:

- **Stripe webhook** — `https://menamaps.com/?wc-api=wc_stripe`. An earlier draft
  of this document called repointing it "the worst failure mode"; it simply does
  not apply. **Do not rotate the signing secret as a precaution** — that would
  break a working endpoint. Verify delivery after cutover instead.
- **Printify's WooCommerce store connection** (its REST key and order webhook),
  **Facebook CAPI**, **Matomo** site 13, **IndexNow**.
- **Brevo SMTP.** Credentials live in a database option and travel with the dump.
  Egress from Hetzner verified: **587 open**, 2525 open, 465 blocked. No DNS
  change — Brevo signs the mail and the origin IP is not in the mail path.

`exec`/`shell_exec` are disabled on Hostinger but not on Hetzner. Pure upside;
nothing depends on it. The site's map pipeline was written in pure PHP *because*
of that Hostinger restriction and keeps working as-is.

## 6. Resolved — previously open items

- **Cron jobs: there are none.** Confirmed by the owner from hPanel, 2026-07-30.
  This closes the gap in `docs/inventory.md` §1.3, which could not enumerate them
  over SSH. WordPress's own scheduled events live in `wp_options` and travel with
  the dump.
- **`~/mm-scripts/` is not at risk.** All three files — `batch-create.php`,
  `batch-golive.php`, `canonicalize-city-terms.php` — are **tracked in the
  menamaps repo** (`scripts/printify/`, `scripts/products/`) and are hand-run
  `wp eval-file` tools, not scheduled. `~/mm-scripts/` was scratch space for a
  CLI run. Nothing to place or recreate; deploy from git if wanted. Same for
  `~/menamaps_track1_desc_backup_20260630_213620.json` — a one-off backup
  artefact, already inside the synced set.

---

## 7. Phase 1 — pre-freeze checks

Read-only, over Hostinger's own WP-CLI, so no credentials are handled:

```bash
ssh u918436082@hostinger 'SERVER_NAME=menamaps.com \
  wp --path=domains/menamaps.com/public_html/cms db query "
    SELECT COUNT(*) orders, MAX(date_created_gmt) newest FROM wp_wc_orders;
    SELECT status, COUNT(*) FROM wp_wc_orders GROUP BY status;
    SELECT COUNT(*) FROM wp_woocommerce_order_items;
    SELECT COUNT(*) FROM wp_wc_order_stats;
    SELECT COUNT(*) pending_actions FROM wp_actionscheduler_actions WHERE status = \"pending\";
"'
```

Record the output — it is the comparison baseline for step 3 of the cutover. Then:

- Any order in `wc-pending`, `wc-on-hold` or `wc-processing` created in the last
  few hours is potentially mid-flow. Note it; the freeze must not land between a
  payment and its webhook.
- If anything looks in-flight, wait for it rather than reconciling afterwards.

## 8. Phase 2 — the cutover

Per `runbook-site-cutover.md`, with the deltas above:

```bash
./provision-site.sh dotaim menamaps.com \
  --content /var/www/backups/hostinger/synced/sites/menamaps.com/public_html/ \
  --no-redirect

./set-site-php.sh dotaim menamaps.com 8.5
# then add the five php_admin_value lines from §2 to the pool and reload FPM

sudo mysql --defaults-file=/etc/mysql/debian.cnf \
  -e "CREATE DATABASE menamaps_website_wp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;"

# --- freeze the source first, and check it twice a few seconds apart ---
./resync-site.sh dotaim menamaps.com menamaps_website_wp cms

# verify over --resolve (see §9), then DNS per §4, then:
./enable-site-ssl.sh dotaim menamaps.com --proxied --no-redirect
```

Then add the wp-cron entry from §3 before handing back.

Values:

| | |
|---|---|
| group | `dotaim` |
| domain | `menamaps.com` |
| database | `menamaps_website_wp` (matches the local dev name) |
| wp-path | `cms` |
| docroot | `/var/www/vhosts/dotaim/menamaps.com/httpdocs` |
| source | `/var/www/backups/hostinger/synced/sites/menamaps.com/public_html/` |
| production config | `.config/live_config.php` — confirmed: `.config/` holds only `index.php` and `live_config.php`, so `resync-site.sh` has exactly one file to repoint |

`resync-site.sh` already handles the four things that each broke a previous site:
repointing `.config/*.php`, stripping the maintenance freeze from the
destination `.htaccess`, rewriting Hostinger absolute paths (file and
serialization-safe in the database), and forcing 775/664 with `wp-config.php`
held at 644.

## 9. Verification

**The generic order query does not work here — this store is HPOS.** Orders are
in `wp_wc_orders`, not `wp_posts`. The obvious query returns 0 on both sides and
compares as a pass:

```sql
-- WRONG for this site
SELECT COUNT(*) FROM wp_posts WHERE post_type = 'shop_order';
```

Use the phase-1 queries against the destination and compare to the recorded
baseline. For reference, the numbers from the owner's 2026-07-30 `pull content`
(pull-time, not freeze-time — phase 1 supersedes these):

```
wc_orders      15   (newest 2026-07-20 23:20:25)
order_items    41
order_stats    15
products      861
attachments 14448
as_pending     15
options      3260
```

Then over `--resolve`, before DNS, check more than the homepage. This site was
served by **LiteSpeed** and now runs under **Apache**, so `AllowOverride All`
must be in effect for its `.htaccess`:

- a product permalink (pretty permalinks);
- `/lebanon/` — a short country URL that 301s to the full archive and **must
  carry its query string across**, or campaign tracking breaks;
- `/llms.txt` and `/wp-sitemap.xml`;
- `content/uploads/menamaps-maps/` and `content/uploads/wc-logs/` writable by the
  pool user (`www-data`) — the map job and the public photo upload both write as
  the pool user, and both have broken on permissions before.

Watch for `error establishing a database connection`, which is what a missed
config repoint looks like.

## 10. Handback to the menamaps project

Hand these over rather than doing them here — they touch that repo's tracked
config and its live-deploy path:

1. Repoint `scripts/sync/config.sh`: SSH alias, database name and credentials,
   and `REMOTE_ROOT_RELATIVE`, which is `$HOME`-relative today and becomes an
   absolute path — so `_pull.sh` and `_push.sh` need reading, not just the variable.
2. Re-verify `push theme` first. It is the only deploy path to live.
3. One `pull db`, confirming the local dev restore still lands.
4. **Test checkout end to end before the freeze is lifted**, and confirm the
   unchanged Stripe webhook is delivering.
5. Check the Locations menu, and run one scoped pricing apply from the CLI to
   prove the operational path works under the new pool.

## 11. Rollback

1. A record back to `82.25.96.229`.
2. **Lift the maintenance freeze on Hostinger** — easy to forget precisely
   because the runbook says to leave it, and forgetting means rolling back to a 503.

Once the shop takes an order on Hetzner, rollback is no longer clean: that order
exists only there. Decide the window before starting, and stop treating rollback
as free after the first order.

---

## Appendix — verified 2026-07-30

**Hetzner:** PHP 8.5.8 FPM active/enabled, all required extensions incl. imagick
with SVG delegate; WP-CLI 2.12.0 (running 8.3 by default); MySQL 8.0.46; Brevo
SMTP 587 open, 2525 open, 465 blocked; **37 GB free of 75 GB**; RAM 3.7 GB with
~1.6 GB available.

Uploads are **9.8 GB** and get duplicated out of the 16 GB backup tree during
provisioning, so budget roughly 27 GB free afterwards. Not roomy — the offsite
push of the backup set is the thing that would relieve it.

**Hostinger:** web PHP 8.5 (alt-php, hPanel), default SSH CLI 8.3.30;
`memory_limit` 2048M, `upload_max_filesize` 2048M, `max_execution_time` 0;
`exec`/`shell_exec` disabled; uploads 9.8 GB; `.config/` = `index.php` +
`live_config.php`; **no cron jobs**.

**One incidental note, not a work item.** This site's recurring "the last job
didn't finish (fatal/timeout)" failures on Printify batch operations were
root-caused to the shared host killing Action Scheduler's async loopback under
resource limits. That cause does not exist on a VPS. The CLI-first procedure
stays as-is regardless; this is not a reason to revisit the deferred wp-admin
reliability work.
