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
| 5 | lebanese.tech | WordPress | WP 6.9.5 — healthy (wp-cli caveat, B9) | `u918436082_lebanesetech` | 13 MB | 1.7 G | 200 |
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
| 17 | ~~woo.lushlebanon.com~~ | WordPress | WP 7.0.2 + WooCommerce (prefix `wppd_`) | `u918436082_HcyjX` | 97 MB | 6.6 G | **DELETE — no backup** |

**Totals as hosted:** 11 WordPress, 2 other PHP apps (Laravel, Piwigo),
3 static, 1 parked. ~320 MB of database, 27.5 GB of files.

### Scope decisions (2026-07-28)

| Site | Disposition |
|---|---|
| `woo.lushlebanon.com` | **Delete from hPanel. Do not back up.** The store moved to Shopify; the copy has no value and was only kept as a reference. Its Hostinger backup has never completed successfully in past attempts, so trying again would burn deadline time for nothing. |
| `shamsaldhaher.com` | **Back up. Probably not migrating** — pending final call. |
| `billing.shamsaldhaher.com` | **Back up. Probably not migrating** — pending final call. |
| `menamaps.com` | **Back up now. Migrate later, from its own project** — see §1.6. |
| everything else | Back up and migrate. |

"Not migrating" still means "back up" — the deadline commitment is complete
verified backups of everything on Hostinger. `woo.lushlebanon.com` is the sole
exception, by explicit decision.

**Backup scope (the 2026-07-31 commitment):** 16 sites, **20.9 GB of files**,
**~223 MB across 12 databases**.

**Migration scope:** ~19.4 GB once shamsaldhaher.com and billing are excluded —
and only **~8.4 GB of it is near-term**, since menamaps.com (11 G) is deferred
to its own project.

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

### 1.5 Payload composition — compression will not help much

Measured across the 20.9 GB backup scope (woo.lushlebanon excluded):

| Class | Size |
|---|---|
| Already-compressed media (jpg/png/gif/webp/mp4/pdf/zip/gz/woff) | **15.85 GB** |
| Everything else (code, HTML, CSS, JS, SQL) | **2.19 GB** |

Only ~12% of the payload is compressible. A `tar.gz` of the whole thing lands
around **16-17 GB**, not the 8-10 GB one might assume. Plan space against the
raw figure, not a hoped-for compression ratio.

### 1.6 menamaps.com tooling in the account root

There are loose files and scripts in `~` belonging to menamaps.com, outside any
docroot — they will **not** be caught by a `~/domains` backup:

- `~/mm-scripts/` — `batch-create.php`, `batch-golive.php`,
  `canonicalize-city-terms.php` (modified 2026-07-26, actively used)
- `~/menamaps_track1_desc_backup_20260630_213620.json` (84 KB)

**Include `~` root files in the backup**, then leave them alone. menamaps.com
migrates later from its own project, where the surrounding context lives.
Do not try to reconstruct that context here.

### 1.7 Other account contents

- `~/.dbdumps/` — **empty**. No local database dumps exist.
- `~/domains/*/backups/` — present on 10 domains but all appear to be
  Hostinger-managed stubs, not usable archives.
- `~/error_log` (92 KB) plus per-domain `error_log` on grand-emerald,
  menamaps, nidaldirani, shamsaldhaher.
- `~/.api_token` — a Hostinger API token. Not read, and **not needed**: it is
  a general Hostinger API token, not cron-related.

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

### 3.3b Target vhost grouping (decided 2026-07-28)

Migrated sites slot into the existing `/var/www/vhosts/<group>/` pattern under
three groups:

```
/var/www/vhosts/
├── mardini/
│   └── mardini.net/
│       ├── httpdocs/
│       └── subs/
│           └── memories.mardini.net/
├── webmasterish/
│   ├── singlefunction.com/
│   └── webmasterish.com/
└── dotaim/
    ├── dotaim.com/                 (existing)
    │   └── subs/analytics.dotaim.com/
    ├── ayatalquran.com/            (existing)
    ├── grand-emerald.com/
    ├── hirement.com/
    ├── lamarkazia.com/
    ├── lebanese.tech/
    ├── nidaldirani.com/
    ├── nizonet.com/
    ├── sasf-ksa.com/
    ├── skinosis.com/
    ├── videotizer.com/
    └── menamaps.com/               (later, own project)
```

Note `memories.mardini.net` becomes a **sub** of `mardini.net` rather than a
top-level vhost, matching how `analytics.dotaim.com` already sits under
`dotaim.com`. Each site keeps its own `httpdocs/`, `logs/`, `config/` and
(where relevant) `subs/`, with the Apache config symlinked out of `config/`
into `sites-enabled` — the pattern already in use.

Undecided pending the migrate/don't-migrate call: `shamsaldhaher.com` and
`billing.shamsaldhaher.com` (would presumably be their own `shamsaldhaher`
group if they land at all).

### 3.4 TLS

certbot manages three certificates, all valid to **2026-09-24** (58 days):
`analytics.dotaim.com`, `ayatalquran.com`, `dotaim.com`.
`/etc/cron.d/certbot` is present, so renewal is automated.

### 3.5 Backups — FLAGGED

- `/var/www/backups/do-dotaim/` — 1.3 G, 7 files. **Cleared for deletion
  2026-07-28** — see the assessment below.
- **No backup cron job exists.** `crontab -l` is empty for both root and
  `webmasterish`; `/etc/cron.d` contains only certbot, e2scrub_all, php,
  sysstat.
- The only current backup is the Hetzner provider snapshot, daily with 7-day
  retention.

So there is no working file/database backup routine on the destination server,
and nothing offsite beyond a 7-day provider snapshot window.

#### `do-dotaim` deletion assessment

Contents — 7 files, the DigitalOcean-era import set:

```
dotaim.com/2025-08-28/     dotaim.com_2025-08-28.tar.gz              466 MB
                           dotaim_analytics_matomo_..._latest.sql     578 MB
                           dotaim_analytics_matomo_....sql.bz2        174 MB
                           dotaim_website_wp_....sql                  483 KB
                           dotaim_website_wp_....sql.bz2               53 KB
ayatalquran.com/2025-08-29/ ayatalquran.com_2025-08-29.tar.gz          43 MB
                            ayatalquran_website_wp_....sql             31 MB
```

**Verdict: safe to delete.** Reasoning:

- These are pre-migration snapshots of the DigitalOcean state. Both sites have
  been live on Hetzner for ~11 months since, all returning HTTP 200 with real
  content (`dotaim.com` 89 KB, `ayatalquran.com` 37 KB, `analytics` 189 KB).
  Anything missing from the migration would have surfaced long ago.
- The live databases exist and are healthy (§3.3).
- Nothing on the box references this path — no cron, no scripts.

Two honest caveats, neither blocking:

1. This is the **only** copy of the pre-migration DigitalOcean state. Once gone,
   rolling back to August 2025 is impossible. Given 11 months of successful
   production use, that is an acceptable trade.
2. It only frees **1.3 G**, which does not change the migration arithmetic (B2)
   either way. Delete it for tidiness, not for space.

Zero-risk alternative if there is any hesitation: delete only the uncompressed
`.sql` files that already have a `.bz2` twin — `dotaim_analytics_matomo_..._latest.sql`
(578 MB) and `dotaim_website_wp_....sql` (483 KB). That frees ~579 MB and loses
nothing at all, since the bz2 holds identical data.

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

**Resolved 2026-07-28: Hetzner has enough room. Back up there.**

Dropping `woo.lushlebanon.com` takes the payload from 27.5 G to **20.9 G**.
Deleting `/var/www/backups/do-dotaim` (§3.5) frees another 1.3 G, giving
**48.3 G free**.

Revised arithmetic — note that compression barely helps (§1.5: only ~12% of the
payload is compressible, so a full archive is ~16-17 G, not ~8 G):

| Scenario | Added | Free after |
|---|---|---|
| Archives only (~16-17 G) | 17 G | ~31 G — comfortable |
| Extracted sites only (~19 G migrating) | 19 G | ~29 G — comfortable |
| Archives **and** everything extracted at once | ~36 G | ~12 G — tight but survivable |

So the answer to both questions is yes: enough for the archives, and enough for
them extracted. The tight case only arises if every archive is kept alongside
every extraction simultaneously — avoid it by extracting site-by-site and
removing each archive once that site is verified.

**But a backup on the production box is not a backup.** Staging on Hetzner is
the right call for speed (server-to-server, avoiding the slow home link), and
then the archives should be pushed to DotAim's AWS S3 so a real offsite copy
exists. The S3 upload runs from Hetzner's datacenter link, not from home.

Local `/media/backups/from_remote_servers/hostinger/<yyyy-mm-dd>/` remains the
fallback if S3 is not convenient, accepting the slower transfer.

### B3 — Cron jobs cannot be read over SSH  *(medium — likely a non-issue)*

`crontab` is hPanel-only. In current hPanel, cron is **per-website**:
`hPanel → Websites → <site> → Advanced → Cron Jobs`. There is no account-wide
list, so a complete check means opening that page for each site.

The owner's recollection is that **no cron jobs exist** on this account, which
is consistent with what the filesystem shows. Treat this as a quick
confirmation rather than an export task — and it only needs doing for the
handful of sites plausibly running one (menamaps.com above all, given
`~/mm-scripts/`), not all 16.

Worth knowing: **WordPress's own scheduled events are stored in the database**
(`wp_options` → `cron`), so they travel with the dump automatically and need no
separate export. Only real system cron entries would be lost.

`~/.api_token` is a general Hostinger API token, not cron-related — not needed.

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

### B9 — lebanese.tech: wp-cli needs `--skip-themes`  *(low)*

**Correction (2026-07-28): the site is not broken.** An earlier draft of this
document called it a fatal error; that was wrong. Verified: HTTP 200, 65 KB of
real page, correct `<title>`, no error text in the body.

What is true is narrower — under **wp-cli only**, the theme throws
`Uncaught TypeError: No resource supplied` at
`content/themes/curated_directory/includes/plugins/webmasterish/webmasterish.php:1307`.
The code path evidently expects a web-request context that CLI does not
provide. Web requests are unaffected.

Practical impact: any wp-cli command against this site needs
`--skip-themes --skip-plugins`. That is a one-flag workaround, not a defect to
fix before migrating.

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

1. **Delete `woo.lushlebanon.com` in hPanel** (owner). No backup. Removes 6.6 G
   from the source before anything else runs.
2. **Delete `/var/www/backups/do-dotaim`** on Hetzner (owner). Frees 1.3 G and
   brings free space to ~48.3 G. Cleared — see §3.5.
3. **Open a transfer path from Hetzner to Hostinger.** Server-to-server, so the
   20.9 G never crosses the slow home link. Use SSH agent forwarding
   (`ssh -A`) so no private key is ever stored on Hetzner.
4. **Pull all 16 sites plus `~` root files** (§1.6) into
   `/var/www/backups/hostinger/<yyyy-mm-dd>/`, biggest first (`menamaps.com`
   11 G, `memories.mardini.net` 2.8 G, `lebanese.tech` and `videotizer.com`
   1.7 G each). This is the long pole — start it early and let it run.
5. **Dump the 12 databases** — wp-cli for the 10 WP sites (remembering
   `SERVER_NAME=<domain>` and `--path=cms`, plus `--skip-themes --skip-plugins`
   for lebanese.tech), artisan/mysqldump for `u918436082_billing`, mysqldump
   for `u918436082_m_memories`.
6. **Verify** — checksums on the archives, file counts against the source, and
   a test import of each database into Hetzner's MySQL 8.0 under a throwaway
   name. This doubles as the B5 MariaDB-compatibility test and tells us early
   how much dump-sanitising is needed. "Verified backups" is the actual
   commitment; an unverified copy does not count.
7. **Push the archives to AWS S3** for a genuine offsite copy — a backup living
   only on the production box is not a backup.
8. **Move the zones to Cloudflare** — `grand-emerald.com`, `nizonet.com`, and
   `shamsaldhaher.com` (pending Q2). Pre-stage every record, lower TTLs first,
   and **carry the existing Hostinger MX records across unchanged** (§2.3) —
   moving the zone is safe, changing MX is not.
9. **Spot-check cron in hPanel** (owner) for menamaps.com and any site
   plausibly running one (B3). Expected to be empty.

No longer in Phase 0: mailbox IMAP pull and domain transfers, both deferred by
the 2026-07-28 decision that the Hostinger account stays open. Backing up
`woo.lushlebanon.com` is also gone, by explicit decision.

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

**Resolved 2026-07-28:**

- *Backup destination* → **Hetzner**, after deleting `do-dotaim`. Space is
  sufficient (B2). Push archives on to AWS S3 afterwards for a genuine offsite
  copy.
- *Hostinger API token* → not needed; it is not cron-related.
- *`skinosis.com` has no MX* → ignore. Dead project, client's responsibility,
  hosting kept as a favour.
- *`sasf-ksa.com/wp/` and `webmasterish.com/wordpress/`* → confirmed dead.
  Sweep both for media and other non-WordPress files first, keep anything
  found, discard the rest.

**Still open:**

1. **Do `shamsaldhaher.com` and `billing.shamsaldhaher.com` migrate?**
   Currently "probably not". Both get backed up regardless. Note the knock-on:
   `shamsaldhaher.com` is one of the three zones on Hostinger nameservers, so
   if it is not migrating, decide what it should point at — see Q2.
2. **Does the `shamsaldhaher.com` zone still need moving to Cloudflare?**
   It is on Hostinger's `dns-parking` nameservers. Those are tied to the domain
   registration (which continues) rather than the hosting plan, so the zone may
   keep resolving after the plan lapses — but it would resolve to a docroot
   that no longer exists. Recommendation: move it anyway. It is cheap and
   removes a dependency we would otherwise be guessing about.
3. **mod_php or PHP-FPM** on Hetzner (B6)? Currently mod_php, so no per-site
   isolation; CLAUDE.md still specifies one pool per site. Deferred by
   agreement — to discuss when provisioning work starts.
4. **AWS S3 details** — which bucket/profile for the offsite copy, and are
   credentials already available on Hetzner?
