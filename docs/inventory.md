# Infrastructure Inventory

Compiled 2026-07-28. Read-only audit; nothing was changed on either server.

Deadline reminder: by **2026-07-31** we need (a) complete verified backups
of everything on Hostinger and (b) DNS off Hostinger nameservers.
That is **3 days** from this audit.

---

## 1. Hostinger — account inventory

**Account:** `u918436082` on `de-fra-web1973.main-hosting.eu`
**Stack:** LiteSpeed + CloudLinux (PHP selector), MariaDB **11.8.8**
**PHP available:** alt-php 7.4 / 8.2 / 8.3 — CLI default is 8.3.30; observed
serving 8.2.30 and 8.3.30 depending on domain
**Total in `~/domains`:** **27 GB** across 17 sites
**Shared web IP:** `82.25.96.229` (some domains served from `179.61.189.x`,
`91.108.100.x`, `77.37.48.x` — all Hostinger)

Docroot pattern: `~/domains/<domain>/public_html`

### 1.1 Site table

| # | Domain | Type | App / version | Database | DB size | Disk | Live |
|---|--------|------|---------------|----------|---------|------|------|
| 1 | billing.shamsaldhaher.com | PHP app | **Laravel** (APP_ENV=production), 70 tables | `u918436082_billing` | 5.2 MB | 1.2 G | 200 |
| 2 | grand-emerald.com | WordPress | WP 7.0.2 | `u918436082_grandemerald` | 11 MB | 382 M | 200 |
| 3 | hirement.com | WordPress | WP 6.9.4 | `u918436082_hirement` | 13 MB | 1.2 G | 200 |
| 4 | lamarkazia.com | Static | plain HTML, `noindex` | — | — | 68 K | 200 |
| 5 | lebanese.tech | WordPress | WP 6.9.5 — **fatal error** | `u918436082_lebanesetech` | 13 MB | 1.7 G | 200 |
| 6 | mardini.net | Static | single placeholder page | — | — | 16 K | 200 |
| 7 | memories.mardini.net | PHP app | **Piwigo 16.3.0** gallery | `u918436082_m_memories` | 4.8 MB | 2.8 G | 200 (login) |
| 8 | menamaps.com | WordPress | WP 7.0.2 + **WooCommerce + Stripe** | `u918436082_menamaps` | 147 MB | **11 G** | 200 |
| 9 | nidaldirani.com | WordPress | WP 7.0.2 | `u918436082_nidaldirani` | 950 KB | 317 M | 200 |
| 10 | nizonet.com | Parked | Hostinger default page | — | — | 28 K | 200 |
| 11 | sasf-ksa.com | Static | HTML + orphaned `wp/` remnants | — | — | 18 M | 200 |
| 12 | shamsaldhaher.com | WordPress | WP 7.0.2 — serves `/coming-soon/` | `u918436082_shamsaldhaher` | 3 MB | 264 M | 200 |
| 13 | singlefunction.com | WordPress | **WP 6.4.8** (oldest) | `u918436082_singlefunction` | 16 MB | 185 M | 200 |
| 14 | skinosis.com | WordPress | WP 7.0.2 | `u918436082_skinosis` | 1 MB | 141 M | 200 |
| 15 | videotizer.com | WordPress | WP 7.0.2 | `u918436082_videotizer` | 9 MB | 1.7 G | 200 |
| 16 | webmasterish.com | Static | HTML + orphaned `wordpress/wp-content` | — | — | 12 M | 200 |
| 17 | ~~woo.lushlebanon.com~~ | WordPress | WP 7.0.2 + WooCommerce (prefix `wppd_`) | `u918436082_HcyjX` | 97 MB | 6.6 G | **NOT MIGRATING** |

**Totals as hosted:** 11 WordPress, 2 other PHP apps (Laravel, Piwigo),
3 static, 1 parked. ~320 MB of database, 27.5 GB of files.

**`woo.lushlebanon.com` is being deleted, not migrated** (decision 2026-07-28).
It is excluded from every figure and every phase below. Still back it up before
deletion — see §5 Phase 0.

**Scope to migrate:** 16 sites — 10 WordPress, 2 other PHP apps, 3 static,
1 parked. **~223 MB of database across 12 databases, 20.9 GB of files.**

### 1.2 Non-standard WordPress layout

Nine of the WP sites do **not** use a stock layout. They use:

```
public_html/
├── cms/        <- WordPress core (WP_SITEURL is /cms)
├── content/    <- wp-content (plugins, themes, uploads)
├── .config/    <- environment-keyed config: config.php, master_config.php,
│                  main_config.php, live_config.php, api_keys.php
└── wp-config.php  <- loader; picks a .config file by $_SERVER['SERVER_NAME']
```

Consequences for migration:

- `wp-cli` must be run with `--path=cms` **and** `SERVER_NAME=<domain>` set,
  otherwise the config falls through to a root/default branch and fails with
  `Access denied for user 'root'@'localhost'`.
- `.config/api_keys.php` exists on hirement.com, skinosis.com and
  videotizer.com. These hold third-party API credentials that are **not** in
  the database and **not** reconstructible. They must be carried across
  deliberately. (Not read as part of this audit.)
- Sites using this layout: grand-emerald, hirement, lebanese.tech, menamaps,
  nidaldirani, shamsaldhaher, singlefunction, skinosis, videotizer — i.e.
  **every WordPress site being migrated**. `woo.lushlebanon.com` was the one
  stock-layout install, and it is not migrating, so the provisioning tooling
  only ever has to handle the `cms/content` layout.

### 1.3 Cron jobs — NOT ENUMERABLE

`crontab` is not available over SSH on this plan; scheduled tasks are stored
in hPanel only. **This is an open gap — cron jobs must be read out of hPanel
manually before the plan lapses.**

Indirect evidence that scheduled tasks exist: `~/mm-scripts/` contains
`batch-create.php`, `batch-golive.php`, `canonicalize-city-terms.php`
(menamaps.com tooling, last modified 2026-07-26 — actively used).

### 1.4 Mailboxes — NOT ENUMERABLE (and deferred)

No `~/mail` or `~/Maildir` on the filesystem; Hostinger mail runs on separate
infrastructure and is managed in hPanel. Mailbox lists, aliases and forwarders
would have to be exported from hPanel manually.

**Not needed before the deadline.** Mail is a separate subscription from the
hosting plan and keeps working until it expires on its own; the account is
staying open. Revisit when the mail subscription nears expiry.

MX records are the only usable proxy from here — see §2.3.

### 1.5 Other account contents

- `~/.dbdumps/` — **empty**. No local database dumps exist.
- `~/domains/*/backups/` — present on 10 domains but all appear to be
  Hostinger-managed stubs, not usable archives.
- `~/error_log` (92 KB) plus per-domain `error_log` on grand-emerald,
  menamaps, nidaldirani, shamsaldhaher.
- `~/.api_token` — a Hostinger API token. Not read. Could be used to query
  the Hostinger API for the cron data SSH cannot reach — needs your go-ahead
  first, since that means sending a credential to their API.

---

## 2. DNS, mail and registrars

### 2.1 Full DNS table

| Domain | Nameservers | MX (mail) | Registrar |
|--------|-------------|-----------|-----------|
| billing.shamsaldhaher.com | **Hostinger** (dns-parking) | **Hostinger** | (in shamsaldhaher.com zone) |
| grand-emerald.com | **Hostinger** (dns-parking) | **Hostinger** | GoDaddy |
| hirement.com | Cloudflare | Google Workspace | GoDaddy |
| lamarkazia.com | GoDaddy | Google Workspace | GoDaddy |
| lebanese.tech | GoDaddy | Google Workspace | GoDaddy |
| mardini.net | GoDaddy | GoDaddy (secureserver) | GoDaddy |
| memories.mardini.net | (mardini.net zone) | — | (subdomain) |
| menamaps.com | Cloudflare | Google Workspace | **Cloudflare** |
| nidaldirani.com | Cloudflare | **Hostinger** | GoDaddy |
| nizonet.com | **Hostinger** (dns-parking) | **Hostinger** | **HOSTINGER** |
| sasf-ksa.com | GoDaddy | Google Workspace | GoDaddy |
| shamsaldhaher.com | **Hostinger** (dns-parking) | **Hostinger** | **HOSTINGER** |
| singlefunction.com | GoDaddy | Google Workspace | GoDaddy |
| skinosis.com | GoDaddy | **none** | GoDaddy |
| videotizer.com | Cloudflare | Google Workspace | GoDaddy |
| webmasterish.com | GoDaddy | GoDaddy (secureserver) | GoDaddy |
| woo.lushlebanon.com | (lushlebanon.com zone → Cloudflare) | Zoho (parent) | SafeNames (parent) |

### 2.2 FLAGGED — zones on Hostinger nameservers

Three zones must move to Cloudflare before 2026-07-31:

1. **shamsaldhaher.com** (also carries `billing.shamsaldhaher.com`)
2. **grand-emerald.com**
3. **nizonet.com**

All three use `ns1.dns-parking.com` / `ns2.dns-parking.com`, which is
Hostinger's nameserver service. If the plan lapses these zones stop resolving
and the sites go dark regardless of where the files live.

### 2.3 FLAGGED — live Hostinger mailboxes

Five domains have MX pointing at `mx1.hostinger.com` / `mx2.hostinger.com`:

1. **shamsaldhaher.com**
2. **billing.shamsaldhaher.com**
3. **grand-emerald.com**
4. **nizonet.com**
5. **nidaldirani.com** ← *DNS is already on Cloudflare, but mail is still
   Hostinger's.* Easy to miss — the zone looks "done" while the mailboxes are
   not.

**Status as of 2026-07-28: deferred, not a deadline item.** The Hostinger
account itself is staying open — what lapses is the hosting plan, which is not
being renewed. Mailboxes are a separate subscription and keep working until
they expire on their own, independent of hosting. So mail does not need to be
resolved before the plan lapses, and it does **not** gate the DNS work.

What still holds: mail is not in a hosting backup, and it does break if MX is
changed. So when the zones move to Cloudflare, **carry the existing Hostinger
MX records across unchanged**. Moving the zone is safe; changing MX is not.
Revisit mailbox migration when the mail subscription approaches expiry.

`skinosis.com` has **no MX at all** — worth confirming that is intentional.

### 2.4 FLAGGED — domains registered through Hostinger

- **nizonet.com**
- **shamsaldhaher.com**

**Status as of 2026-07-28: not a deadline item.** Registration is a separate
product from the hosting plan, and the Hostinger account is staying open — only
the hosting plan is lapsing. These domains can continue to be registered at
Hostinger indefinitely. No transfer is required.

The only thing to keep an eye on is the **domain** expiry dates, which are
independent of the plan expiry. Worth confirming they are on auto-renew, since
a lapsed registration is unrecoverable in a way a lapsed hosting plan is not.

---

## 3. Hetzner — current state

**Host:** `hetzner-dotaim`, Hetzner CPX21, Ubuntu **24.04.3 LTS**
**Uptime:** 333 days
**Access:** SSH key, passwordless sudo available

### 3.1 Capacity

| Resource | Value |
|----------|-------|
| Disk | 75 G total, 26 G used, **47 G available** (36%) |
| RAM | 3.7 G total, 1.8 G used, **1.9 G available** |
| Swap | **none configured** |

Top memory consumers: mysqld 18.8%, redis 5.6%, apache2 workers ~1.7% each.

### 3.2 Stack — two remaining gaps vs CLAUDE.md

| Component | Documented | **Actual** |
|-----------|-----------|------------|
| Web server | Apache | **Apache 2.4.58** — matches (CLAUDE.md corrected 2026-07-28) |
| PHP handler | PHP-FPM, one pool per site | **mod_php** (`php_module` loaded; `proxy_fcgi` is **not**) |
| Docroot | `/var/www/<domain>/httpdocs` | `/var/www/vhosts/<group>/<domain>/httpdocs` |

`php8.3-fpm.service` is running but Apache is not wired to it — there is no
`proxy_fcgi` module, and only the stock `www.conf` pool exists
(`pm = dynamic`, `pm.max_children = 5`). The "one PHP-FPM pool per site"
convention is currently aspirational, not implemented.

Also installed/running: MySQL **8.0.46** (not MariaDB), Redis, Docker
(**no containers running**), fail2ban, certbot, wp-cli 2.12.0.
PHP **8.3.6 only** — no 8.2 or 7.4.

### 3.3 Existing vhosts

Layout is `/var/www/vhosts/dotaim/<domain>/{httpdocs,logs,config,subs}`, with
Apache configs symlinked out of each site's own `config/` directory into
`sites-enabled` — a clean, per-site pattern worth keeping.

| Vhost | Docroot | Database | DB size |
|-------|---------|----------|---------|
| dotaim.com (+www) | `/var/www/vhosts/dotaim/dotaim.com/httpdocs` | `dotaim_website_wp` | 1.4 MB |
| ayatalquran.com | `/var/www/vhosts/dotaim/ayatalquran.com/httpdocs` | `ayatalquran_website_wp` | 42.9 MB |
| analytics.dotaim.com | `.../dotaim.com/subs/analytics.dotaim.com/httpdocs` | `dotaim_analytics_matomo` | **1023.6 MB** |

Plus `000-default.conf`. Matomo's database is by far the largest thing on the
box and is growing.

### 3.4 TLS

certbot manages three certificates, all valid to **2026-09-24** (58 days):
`analytics.dotaim.com`, `ayatalquran.com`, `dotaim.com`.
`/etc/cron.d/certbot` is present, so renewal is automated.

### 3.5 Backups — FLAGGED

- `/var/www/backups/do-dotaim/` — 1.3 G, covering `dotaim.com` and
  `ayatalquran.com`. **Last written 2025-08-29 — roughly 11 months stale.**
- **No backup cron job exists.** `crontab -l` is empty for both root and
  `webmasterish`; `/etc/cron.d` contains only certbot, e2scrub_all, php,
  sysstat.
- The only current backup is the Hetzner provider snapshot, daily with 7-day
  retention.

So there is no working file/database backup routine on the destination server,
and nothing offsite beyond a 7-day provider snapshot window.

---

## 4. Blockers and risks

Ordered by how much they threaten the 2026-07-31 deadline.

### B1 — No backup exists yet, and there are 3 days left  *(critical)*

**20.9 GB** of files plus **~223 MB** of databases to preserve, and no dump has
been taken (`~/.dbdumps` is empty). The deadline commitment is *complete
verified backups*, and none of that work has started. Pulling ~21 GB over SSH
is the long pole — `menamaps.com` alone is 11 G, over half the volume. This
needs to start immediately and run in parallel with everything else.

Note `woo.lushlebanon.com` still needs backing up (6.6 G + 97 MB) even though
it is being deleted — take the copy before deleting, then set it aside. If that
backup is taken separately and first, deleting it on Hostinger also frees 6.6 G
of source-side headroom for the rest of the work.

### B2 — Backup destination is tight but workable  *(medium — was critical)*

Dropping `woo.lushlebanon.com` takes the payload from 27.5 G to **20.9 G**,
which changes this from a hard blocker to a sequencing constraint.

Hetzner has **47 G free** (75 G total, 26 G used). Two scenarios:

| Plan | Added | Result |
|---|---|---|
| Sites live on Hetzner, archive stored **elsewhere** | ~21 G | ~26 G free (65% used) — **viable** |
| Archive staged **and** unpacked on Hetzner | ~42 G | ~5 G free (93% used) — **not viable** |

So: the archive must not live on Hetzner. Put it on local `/media/data2` or
object storage, and stream each site onto Hetzner as it migrates rather than
landing the whole archive there first. With that constraint respected, no
volume expansion is needed.

### B3 — Cron jobs cannot be read over SSH  *(critical)*

`crontab` is hPanel-only, so part of "complete verified backups" is **not**
obtainable by the tooling in this repo — someone has to export the cron jobs
from the Hostinger control panel by hand, or we authorise use of the account's
API token. `~/mm-scripts/` (modified 2026-07-26) is evidence that live
scheduled tasks exist. This is the one Phase 0 step that cannot be scripted or
retried after the plan lapses.

Mailboxes are likewise hPanel-only, but are **no longer urgent** — see §2.3.
They outlive the hosting plan.

### B4 — Hostinger-registered domains  *(resolved — no action)*

`nizonet.com` and `shamsaldhaher.com` are registered through Hostinger, but the
account is staying open and only the hosting plan is lapsing. Registration is
unaffected; no transfer needed. Only ordinary domain-expiry hygiene applies
(§2.4).

### B5 — MariaDB 11.8.8 → MySQL 8.0.46  *(high)*

Source and destination are different database engines, and the source is
several major versions ahead. MariaDB 11.x emits `uca1400` collations and
MariaDB-specific syntax in dumps that MySQL 8.0 will reject. Every dump needs
a sanitising pass and a verified test import — assume this, do not discover it
mid-cutover. Database defaults are `utf8mb4` / `utf8mb4_unicode_ci`, which is
fine; per-table collations are the risk.

### B6 — No provisioning tooling exists yet  *(high)*

**Resolved: Apache stays.** The nginx reference in CLAUDE.md was an error and
has been corrected — Apache is the deliberate choice, matching the local dev
environment. Hetzner's existing per-site pattern (Apache configs symlinked out
of each site's own `config/` directory into `sites-enabled`) is sound and
should be the template.

What remains: the repo is **empty**. No `scripts/`, no `templates/`, no
runbooks. All provisioning tooling has to be written from scratch before the
first site moves.

Still open, and separate from the nginx question: Hetzner serves PHP via
**mod_php**, not PHP-FPM, so the "one PHP-FPM pool per site" convention in
CLAUDE.md is still unimplemented and there is currently no per-site process
isolation. Deferred for now — flagging it so it is a decision rather than an
oversight.

### B7 — One live WooCommerce store  *(high)*

With `woo.lushlebanon.com` dropped, **`menamaps.com` is the only remaining
store** — WooCommerce + Stripe gateway, carrying order and customer data and
taking live payments. It needs a maintenance window, a content freeze, a final
delta sync, and Stripe webhook endpoints repointed. It is also the largest site
(11 G) and has the `mm-scripts/` cron dependencies. Move it last.

### B8 — PHP version mismatch  *(medium)*

Hostinger serves both 8.2.30 and 8.3.30; Hetzner has **only 8.3**.
`singlefunction.com` runs WP 6.4.8, which predates PHP 8.3 support, and
`nizonet.com` was observed on 8.2 (it is a parked placeholder, so it does not
matter much). Either install PHP 8.2 alongside 8.3 on Hetzner, or update
`singlefunction.com` before moving it — the latter is probably cleaner now that
`woo.lushlebanon.com`, the other 8.2 site, is out of scope.

### B9 — lebanese.tech is broken  *(medium)*

Fatal error in `content/themes/curated_directory/includes/plugins/webmasterish/webmasterish.php:1307`
(`Uncaught TypeError: No resource supplied`). The site returns 200 publicly but
wp-cli only works with `--skip-themes --skip-plugins`. Migrating it will carry
the fault across; it needs fixing either before or after, but it should not be
allowed to block the backup.

### B10 — Hetzner has no swap and limited RAM  *(medium)*

3.7 G total with 1.9 G available, no swap, and Matomo's 1 GB database already
resident. Adding 16 sites including a WooCommerce store will cause memory
pressure. Add swap and revisit MySQL tuning before the bulk of the migration.

### B11 — `.config/api_keys.php` files  *(medium)*

hirement.com, skinosis.com and videotizer.com hold third-party API credentials
in files, outside the database. A database-plus-uploads migration will silently
drop them and the breakage will only show up later. Track them explicitly.

### B12 — Orphaned WordPress remnants  *(low)*

`sasf-ksa.com/public_html/wp/` (wp-content + wp-includes, no core) and
`webmasterish.com/public_html/wordpress/` (wp-content only) are leftovers from
removed installs. Both sites serve static HTML. Confirm they are dead before
copying ~18 MB of nothing — but do include them in the backup, since deciding
they are junk is easier with a copy in hand.

---

## 5. Proposed migration order

The two deadline items — backups and DNS — are **not** the migration and
should not wait for it. Run them first and in parallel.

### Phase 0 — Deadline work, start now (by 2026-07-31)

Nothing here requires deciding anything about Hetzner's stack.

1. **Export cron jobs from hPanel by hand.** Nothing else can enumerate them
   (B3). Do this first; it is the only step that cannot be scripted or retried
   after the plan lapses. Mailboxes are **not** needed now — they outlive the
   plan (§2.3).
2. **Back up `woo.lushlebanon.com` first, then delete it.** 6.6 G + 97 MB. It
   is not migrating, but it must not be lost. Doing it first frees 6.6 G on the
   source side and shrinks everything downstream.
3. **Start the file pull** — the remaining 16 sites, ~20.9 G, biggest first
   (`menamaps.com` 11 G, `memories.mardini.net` 2.8 G, `lebanese.tech` and
   `videotizer.com` 1.7 G each). Archive destination must **not** be Hetzner
   (B2). This runs for hours; kick it off early and let it work while other
   steps proceed.
4. **Dump the 12 databases** — wp-cli for the 10 WP sites (remembering
   `SERVER_NAME=<domain>` and `--path=cms`), artisan/mysqldump for
   `u918436082_billing`, mysqldump for `u918436082_m_memories`.
5. **Verify** — checksums on the archives, and a test import of each database
   into Hetzner's MySQL 8.0 under a throwaway name. This doubles as the B5
   MariaDB-compatibility test and tells us early how much dump-sanitising is
   needed. "Verified backups" is the actual commitment; an unverified copy does
   not count.
6. **Move the three zones to Cloudflare** — `shamsaldhaher.com`,
   `grand-emerald.com`, `nizonet.com`. Pre-stage every record, lower TTLs
   first, and **carry the existing Hostinger MX records across unchanged**
   (§2.3) — moving the zone is safe, changing MX is not.

No longer in Phase 0: mailbox IMAP pull and domain transfers, both deferred by
the 2026-07-28 decision that the Hostinger account stays open.

After Phase 0, the deadline is met and everything below can proceed calmly.

### Phase 1 — Prepare Hetzner

7. Write the provisioning scripts and Apache vhost templates the repo is
   supposed to hold (B6), modelled on the existing per-site `config/` +
   `sites-enabled` symlink pattern. Stack question is settled: **Apache**.
8. Add swap; review MySQL memory settings (B10).
9. Update `singlefunction.com` off WP 6.4.8, or add PHP 8.2 alongside 8.3 (B8).
10. **Set up a real backup job on Hetzner** (§3.5) — the existing one has been
    dead for 11 months, and it needs to work *before* it is the only copy of
    16 more sites.

### Phase 2 — Migrate, easiest first

Order chosen so the provisioning scripts get exercised on sites where a
mistake costs nothing, before they touch anything transactional.

11. **Static and parked** — `mardini.net`, `lamarkazia.com`, `nizonet.com`,
    `webmasterish.com`, `sasf-ksa.com`. No database. Proves out vhost, docroot
    and certbot.
12. **Small WordPress** — `nidaldirani.com` (950 KB), `skinosis.com` (1 MB),
    `shamsaldhaher.com` (3 MB, behind a coming-soon page so the blast radius
    is nil). Proves out the `cms/content` layout, the `.config` loader and the
    MariaDB→MySQL path on real data.
13. **Medium WordPress** — `videotizer.com`, `grand-emerald.com`,
    `hirement.com`, `singlefunction.com` (update WP 6.4.8 first, B8).
    Carry `.config/api_keys.php` for hirement, skinosis and videotizer (B11).
14. **Non-WordPress apps** — `memories.mardini.net` (Piwigo 16.3.0, 2.8 G of
    gallery files) and `billing.shamsaldhaher.com` (Laravel; needs `.env`,
    queue/scheduler review, storage symlink).
15. **lebanese.tech** — fix the theme fatal (B9) before or after the move, but
    do not let it hold up the queue.
16. **`menamaps.com` last** — the only remaining store (B7). Scheduled
    maintenance window, content freeze, final database delta sync, Stripe
    webhooks repointed, checkout tested end to end before DNS moves. It is
    also the largest site and has the `mm-scripts/` tooling and cron
    dependencies to re-create (§1.3).

### Phase 3 — Decommission

17. Confirm every site is served from Hetzner and correct.
18. Let the Hostinger plan run out its remaining term as a read-only fallback
    rather than cancelling early. The **account stays open** — domains and
    mailboxes continue there until they expire on their own.
19. Retain the verified backup archive independently of both servers, including
    the `woo.lushlebanon.com` copy.

---

## 6. Decisions taken (2026-07-28)

- **`woo.lushlebanon.com` is being deleted, not migrated.** Back it up first,
  then delete. Cuts the payload from 27.5 G to 20.9 G and removes one of the
  two WooCommerce stores from scope.
- **Apache stays on Hetzner**, matching local dev. The nginx reference in
  CLAUDE.md was an error and has been corrected.
- **The Hostinger account stays open.** Only the hosting plan lapses — it is
  not being renewed. Domains and mailboxes are separate subscriptions and keep
  working until they expire on their own. Neither is a 2026-07-31 item.

## 7. Open questions

1. **Where should the ~21 GB backup live?** (B2) Local `/media/data2` or object
   storage — Hetzner is ruled out by the space arithmetic.
2. **May I use `~/.api_token`** to query the Hostinger API for the cron data
   SSH cannot reach? That sends an account credential to Hostinger's API, so I
   have not touched it. The alternative is a manual hPanel export.
3. **mod_php or PHP-FPM** on Hetzner (B6)? Currently mod_php, so no per-site
   isolation; CLAUDE.md still specifies one pool per site.
4. **`skinosis.com` has no MX** — intentional?
5. **`sasf-ksa.com/wp/` and `webmasterish.com/wordpress/`** — confirmed dead?
