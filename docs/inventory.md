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
| `woo.lushlebanon.com` | **Leave in place, exclude from the backup.** The store moved to Shopify, so the copy has no value, and its Hostinger backup has never completed successfully in past attempts. Deleting it changes nothing operationally, so it stays until the migration is finished — the owner may yet decide to push a copy to S3. Excluded from all rsync and dump runs meanwhile. |
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

### 1.3 Cron jobs — CLOSED, there are none

**Resolved 2026-07-30.** The owner confirmed from hPanel that the account has
**no cron jobs at all**. Nothing to carry across, nothing to recreate.

`crontab` is not available over SSH on this plan and scheduled tasks are stored
in hPanel only, which is why this could not be answered from the shell and stood
open as long as it did.

The indirect evidence that suggested otherwise was misread: `~/mm-scripts/`
(`batch-create.php`, `batch-golive.php`, `canonicalize-city-terms.php`,
menamaps.com tooling, last modified 2026-07-26) are **hand-run `wp eval-file`
tools, not scheduled jobs**, and all three are tracked in the menamaps repo
under `scripts/printify/` and `scripts/products/`. `~/mm-scripts/` was scratch
space for a CLI run. Active use is not evidence of automation.

WordPress's own scheduled events live in `wp_options` and travel with the
database dump, so they were never at risk either. menamaps.com now has a
**system** wp-cron entry on Hetzner — see
`docs/handover-menamaps-migration.md` §3 — but that is a new addition for a
store with Action Scheduler, not a Hostinger job being reproduced.

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

### B5 — MariaDB 11.8.8 → MySQL 8.0.46  *(low — largely a non-issue)*

First, scope: MariaDB 11.8.8 is the database *server* for the entire Hostinger
shared account. All 12 databases run on it — every WordPress site, the Laravel
billing app and Piwigo alike. Hetzner runs MySQL 8.0.46, so **every dump
crosses engines**, not just Piwigo's.

**Earlier drafts of this document rated that "high" risk. That was overstated.**
Two pieces of evidence, one prior and one measured:

1. The owner has been pulling these dumps into a **local MySQL 8.4.10** almost
   daily for development work, for a long time, with no issues. MySQL 8.4 is
   *newer* and stricter than Hetzner's 8.0.46, so that experience transfers.
2. The `skinosis.com` trial (§4c) imported into Hetzner's MySQL 8.0.46 cleanly:
   13 tables, zero errors, and row counts matching the source exactly
   (141 posts / 175 options / 464 postmeta).

Why the theoretical concern did not materialise:

- These databases use **`utf8mb4_unicode_520_ci`**, which MySQL 8.0.46 supports
  (verified against `information_schema.COLLATIONS`). The problem collations are
  MariaDB 11.x's `uca1400` family, which only appear on tables *created* under
  MariaDB 11.x — these schemas predate that.
- The MariaDB markers in the dump (`/*M!999999`, `/*M!100616`) are **conditional
  comments**, designed to be ignored by non-MariaDB servers. MySQL skips them,
  which is exactly the intent.
- Every table is InnoDB. No storage-engine translation needed.

**And then the verify pass found one.** `u918436082_m_memories` — Piwigo —
uses **`utf8mb3_uca1400_ai_ci`** across all 34 tables, and MySQL 8.0.46 rejects
it outright: `ERROR 1273 (HY000) Unknown collation`. So the risk was real, just
far narrower than "high" implied: **1 database out of 9, and the only one not
created by WordPress.** Piwigo's schema was evidently created recently enough,
under MariaDB 11.x, to pick up its new default; the WordPress schemas all
predate that and carry `utf8mb4_unicode_520_ci`, which MySQL knows.

This is exactly why the trial site was not sufficient on its own — skinosis.com
was clean, and would have licensed a false conclusion about the other eight.

**Resolved** by `scripts/sanitize-mariadb-dump.sh`, a restore-time filter
mapping `*_uca1400_*` to the nearest collation MySQL has. Captured dumps stay
byte-faithful to the source; the rewrite happens visibly at restore. All 9
databases now restore cleanly into MySQL 8.0.46 — see §4d.

**Still open, deliberately:** Piwigo is on `utf8mb3`, deprecated since MySQL 8.0
and slated for removal. Converting it to `utf8mb4` changes index key lengths and
can overflow a table's key limit, so it is a migration decision to take and test
on purpose — not something a restore filter should do quietly.

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

## 4b. Backup method

### Transfer path

Hetzner reaches Hostinger directly on **port 65002** (verified:
`SSH-2.0-OpenSSH_9.9`). Port 22 is not used — an early test against it reported
"filtered" and was meaningless.

Auth follows the pattern already established for the DigitalOcean migration:
copy `~/.ssh/hostinger/dotaim/` from the local machine to Hetzner and add
`Include hostinger/dotaim/config` to Hetzner's `~/.ssh/config`. The bundled
config defines the `hostinger` alias with an absolute `IdentityFile` path under
`/home/webmasterish`, which is identical on Hetzner, so it works unchanged and
the CLAUDE.md "use the alias, never an inline host" rule keeps holding.

Chosen over SSH agent forwarding for a concrete reason: **a forwarded agent dies
with the session that carried it.** A multi-hour unattended rsync needs
credentials that outlive any one login, so a key on the box is the right call
here, not merely the familiar one.

### Files: rsync the trees, do not tar on Hostinger

The DigitalOcean migration used tar.gz per site and sql.bz2 per database, built
on the source and then transferred. **Do not repeat that here.** Five reasons,
in rough order of weight:

1. **It writes nothing to Hostinger.** CLAUDE.md holds Hostinger read-only until
   the migration is verified. Building ~17 GB of tarballs there breaks that, and
   needs the free quota to hold them.
2. **CloudLinux resource limits.** Hostinger enforces per-account CPU/IO limits
   (LVE). Compressing 11 GB of menamaps JPEGs on a shared host invites
   throttling or an outright kill partway through.
3. **Compression is nearly worthless here** — §1.5 measured ~12% compressible.
   Burning constrained shared CPU for that is a bad trade.
4. **rsync resumes; tar does not.** A 11 GB archive that dies at 90% starts over.
5. **The delta re-sync before cutover is nearly free** with rsync and expensive
   with tar. Every site needs a final catch-up sync at go-live.

So: `rsync` the directory trees straight to Hetzner, then **build the archives on
Hetzner** from the synced trees for the S3 copy. Same artifacts as before, just
produced on the machine that can afford the work.

### Databases: stream, never stage on the source

Pipe each dump over SSH and compress on arrival, so nothing is written to
Hostinger's filesystem. `wp db export -` writes to stdout, which makes this
clean for the 10 WordPress sites; the Laravel and Piwigo databases use
`mysqldump` the same way.

### Layout on Hetzner

```
/var/www/backups/hostinger/<yyyy-mm-dd>/
├── sites/<domain>/          rsync'd trees -- the migration source
├── db/<dbname>.sql.bz2      streamed dumps
├── home/                    ~ root files (§1.6)
├── MANIFEST.txt             sizes, file counts, per-site checksums
└── archives/                built here, one at a time, uploaded to S3, deleted
```

Build archives one at a time rather than all at once — that keeps peak disk near
~19 GB of trees plus one archive, well inside the 48 GB free, instead of the
~36 GB the both-at-once case would need.

## 4c. Trial run — skinosis.com (2026-07-28)

Completed end to end before any bulk work. Result: **the method works**, with
one significant discovery.

| Check | Result |
|---|---|
| Files synced | 4868 / 4868 — exact match |
| Bytes | 112,188,403 |
| Delta re-sync | 1 file, 3 KB, ~1 s — confirms cheap pre-cutover catch-up |
| Database dump | 13 tables, 69 KB bz2 |
| Import into MySQL 8.0.46 | clean, no errors |
| Row counts source vs imported | 141 / 175 / 464 — exact match |

### The discovery: `wp db export` does not work on Hostinger

Hostinger disables PHP's shell-exec family — `passthru()`, and by extension
`exec`/`system`/`proc_open`, are **undefined**. wp-cli's `db export` shells out
to `mysqldump`, so it **fails silently**: no output, no stderr, exit 255, and an
empty file where the dump should be.

This is a nasty failure mode. Without the "does the dump contain any
`CREATE TABLE`?" guard in `backup-hostinger-site.sh`, it produces a
plausible-looking 14-byte `.sql.bz2` and reports success. **Any backup taken
with `wp db export` on this host is empty.** Worth checking if one was ever
relied on.

Working approach, now in the script: let wp-cli load `wp-config.php` to resolve
the credentials, hand them to the *remote shell*, and run `mysqldump` there —
shell-exec restrictions do not apply to a real shell. Credentials never reach
the local machine, are never written to a file, and never appear in output;
`MYSQL_PWD` keeps the password out of the remote process list. `wp db query`,
`wp db size` and `wp db tables` are unaffected — they go through PHP's mysqli,
not a subprocess.

## 4d. Backup run and verification — 2026-07-28 (COMPLETE)

`/var/www/backups/hostinger/2026-07-28/` — **16 GB**, 14 sites, 9 databases.
Hetzner sat at 56% disk when done.

Every site file-verified at capture (source vs destination file count, refusing
to write a manifest on mismatch), and every database restore-verified into
MySQL 8.0.46.

| Site | Files | Database | Tables | Restore |
|---|---|---|---|---|
| menamaps.com | 126,553 | `u918436082_menamaps` | 52 | OK |
| memories.mardini.net | 22,192 | `u918436082_m_memories` | 34 | OK *(via sanitiser)* |
| lebanese.tech | 15,507 | `u918436082_lebanesetech` | 12 | OK |
| videotizer.com | 12,340 | `u918436082_videotizer` | 13 | OK |
| hirement.com | 12,470 | `u918436082_hirement` | 12 | OK |
| grand-emerald.com | 8,098 | `u918436082_grandemerald` | 14 | OK |
| singlefunction.com | 6,069 | `u918436082_singlefunction` | 13 | OK |
| nidaldirani.com | 5,862 | `u918436082_nidaldirani` | 12 | OK |
| skinosis.com | 4,872 | `u918436082_skinosis` | 13 | OK |
| sasf-ksa.com | 141 | — | — | — |
| webmasterish.com | 348 | — | — | — |
| lamarkazia.com | 6 | — | — | — |
| nizonet.com | 2 | — | — | — |
| mardini.net | 2 | — | — | — |
| `~` root files | 4 | — | — | — |

Re-run any time with `verify-hostinger-backup.sh 2026-07-28`.

### Two bugs the run exposed

Both produced *silent* wrong results, which is the kind worth recording.

1. **`ssh` inside a `while read` loop ate the site list.** The first batch run
   backed up menamaps.com, skipped the other 13, and exited 0 reporting
   "failed: 0". Only the `ok: 2` count betrayed it. `ssh` reads stdin greedily
   and consumed the remaining here-string lines. Fixed by feeding the list on
   fd 3 and adding `ssh -n` where stdin is not needed.

2. **`rsync --delete` protects excluded paths.** After `backups/` was excluded,
   sites already synced kept their stale copy, and the count check failed with
   *destination greater than source* — 4874 vs 4872 on skinosis.com. Plain
   `--delete` will not remove something an `--exclude` now covers; that needs
   `--delete-excluded`. Relevant any time an exclusion is added after a sync.

### Still outstanding

- **`shamsaldhaher.com` and `billing.shamsaldhaher.com` are not backed up** —
  excluded pending the migrate/keep decision. They remain the only gap against
  a literal reading of the 2026-07-31 commitment. Backing them up does not
  require the decision.
- **Not yet offsite.** The set lives only on Hetzner, i.e. on the production
  box. The S3 push (Phase 0 step 7) is what makes it a backup rather than a
  copy.

## 5. Proposed migration order

The two deadline items — backups and DNS — are **not** the migration and
should not wait for it. Run them first and in parallel.

### Phase 0 — Deadline work, start now (by 2026-07-31)

Nothing here requires deciding anything about Hetzner's stack.

1. ~~Delete `/var/www/backups/do-dotaim`~~ — **done 2026-07-28.** Free space on
   Hetzner is now **48 G**.
2. **Open the transfer path** — copy the `hostinger/dotaim` key bundle to
   Hetzner and add the `Include` line (§4b). Everything then runs from Hetzner.
3. **Single-site trial run — `skinosis.com`.** Do not start the bulk pull until
   this is reviewed and approved. Rationale for the choice: 141 MB so it is
   quick, but it exercises every feature that matters — the `cms/content`
   layout, the `SERVER_NAME`-keyed `.config` loader, a `.config/api_keys.php`
   file, WP 7.0.2, and a real MariaDB→MySQL import. And it is the dead client
   project, so the stakes are nil.
4. **Pull the remaining 15 sites plus `~` root files** (§1.6) into
   `/var/www/backups/hostinger/<yyyy-mm-dd>/sites/`, biggest first
   (`menamaps.com` 11 G, `memories.mardini.net` 2.8 G, `lebanese.tech` and
   `videotizer.com` 1.7 G each). Excludes `woo.lushlebanon.com`. This is the
   long pole — start it early and let it run unattended.
5. **Stream the 12 database dumps** (§4b) — wp-cli for the 10 WP sites
   (remembering `SERVER_NAME=<domain>` and `--path=cms`, plus
   `--skip-themes --skip-plugins` for lebanese.tech), `mysqldump` for
   `u918436082_billing` and `u918436082_m_memories`.
6. **Verify** — per-site checksums and file counts against the source, plus a
   test import of every database into Hetzner's MySQL 8.0 under a throwaway
   name. This doubles as the B5 MariaDB-compatibility test. "Verified backups"
   is the actual commitment; an unverified copy does not count.
7. **Archive and push to AWS S3** — built on Hetzner, one at a time, deleted
   after upload. A backup living only on the production box is not a backup.
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

## 6b. Security items found on Hetzner (2026-07-29)

### Matomo API token in an Apache vhost — ROTATE

`analytics.dotaim.com`'s `vhost-ssl.conf` carries a live Matomo API bearer token
inline in a `RewriteRule` that maps `/mcp-proxy`. Two problems:

1. It is a secret in a plaintext Apache config, readable by anything that
   inspects vhosts — which is routine work.
2. It was printed into a session transcript on 2026-07-29 while inspecting that
   vhost's DocumentRoot. **Treat it as disclosed and rotate it.**

Better homes for it: a Matomo-side config value, or an Apache `SetEnvIf` sourced
from a root-only file outside the vhost.

### All FPM pools share the www-data identity

Verified, not assumed: `www-data` can read every site's database credentials,
so a compromise in any one site exposes all of them. On Hostinger each site had
its own user; that isolation was lost in the move. `open_basedir` per pool is in
place as the cheap half. Per-site users are the fix — see `docs/runbook-fpm.md`.

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
