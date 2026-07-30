# Migration status

Updated 2026-07-30. Hetzner is `91.99.146.221`. Hostinger is `82.25.96.229`.

**All 15 sites are live on Hetzner.** menamaps.com cut over 2026-07-30; phases 1
and 2 are complete and the handback list in
`docs/handover-menamaps-migration.md` §10 is now with the menamaps project.

## Live on Hetzner — all static sites done

| Site | Group | Cert expires | Redirect | Hostinger copy |
|---|---|---|---|---|
| lamarkazia.com | `dotaim` | 2026-10-27 | 301 | still in place |
| mardini.net | `mardini` | 2026-10-27 | 301 | still in place |
| webmasterish.com | `webmasterish` | 2026-10-27 | 301 | still in place |
| nizonet.com | `dotaim` | 2026-10-27 | 301 | parking page, discarded |
| sasf-ksa.com | `dotaim` | 2026-10-27 | 301 | still in place |

All verified byte-identical to the Hostinger original before cutover, both apex
and `www` (except nizonet.com, whose content was rewritten by design).

### WordPress

| Site | Group | Database | Cert expires | Notes |
|---|---|---|---|---|
| videotizer.com | `dotaim` | `videotizer_website_wp` | 2026-10-27 | behind Cloudflare, `--no-redirect` |
| nidaldirani.com | `dotaim` | `nidaldirani_website_wp` | 2026-10-27 | behind Cloudflare; MX stays on Hostinger |
| skinosis.com | `dotaim` | `skinosis_skinosis_com_wp` | 2026-10-27 | direct DNS, no MX; first site built on the FPM stack |
| grand-emerald.com | `dotaim` | `grandemerald_website_wp` | 2026-10-27 | zone still on Hostinger nameservers; MX stays on Hostinger |
| hirement.com | `dotaim` | `hirement_website_wp` | 2026-10-27 | Cloudflare Full (strict); core+plugins updated post-migration |
| lebanese.tech | `dotaim` | `lebanesetech_website_wp` | 2026-10-27 | **PHP 7.4** — first non-default version |
| singlefunction.com | `webmasterish` | `singlefunction_website_wp` | 2026-10-27 | **PHP 7.4**, WP 6.4.8 |

Verify the whole estate any time with `scripts/audit-sites.sh` — it asks each
site which PHP actually serves it rather than trusting config, and exits
non-zero on any finding.

| memories.mardini.net | `mardini` (sub) | `mardini_memories_website_piwigo` | 2026-10-27 | **Piwigo**, not WordPress; 2.7 GB of photos |

| menamaps.com | `dotaim` | `menamaps_website_wp` | 2026-10-28 | **PHP 8.5**, WooCommerce + Stripe (HPOS); Cloudflare Full (strict); per-site FPM limits; system wp-cron |

## Remaining

Nothing. **15 of 15 sites are live on Hetzner.**

## menamaps.com — cutover record, 2026-07-30

The only site with per-site FPM limits and the only one with a system wp-cron
entry. Both are documented in `docs/handover-menamaps-migration.md` §2 and §3.

Counts matched exactly across the freeze, using the **HPOS** tables — this store
keeps orders in `wp_wc_orders`, not `wp_posts`, and the generic
`post_type = 'shop_order'` query returns 0 on both sides and compares as a pass:

| | pre-freeze source | post-cutover destination |
|---|---|---|
| `wp_wc_orders` | 15 (newest 2026-07-20 23:20:25) | 15 (same timestamp) |
| statuses | `wc-completed` 8, `wc-checkout-draft` 7 | identical |
| `wp_woocommerce_order_items` | 41 | 41 |
| `wp_wc_order_stats` | 15 | 15 |
| Action Scheduler pending | 15 | 15 |
| products / variations | 861 / 9,824 | 861 / 9,824 |
| attachments | 14,448 | 14,448 |
| `wp_posts` / `wp_options` | 25,339 / 3,082 | 25,339 / 3,082 |
| tables | 52 | 52 |

No order was in `wc-pending`, `wc-on-hold` or `wc-processing`, and the newest
was ten days old, so the freeze could not land between a payment and its
webhook. `wc-checkout-draft` rows are abandoned carts, not payments in flight.

Verified after cutover: pretty permalinks under Apache (this site was on
LiteSpeed, so `AllowOverride All` had to be in effect), `/lebanon/` 301ing to
`/product-category/locations/lebanon/` **with the query string carried across**,
`/llms.txt`, `/wp-sitemap.xml`, and `content/uploads/menamaps-maps/` and
`content/uploads/wc-logs/` writable by the pool user by actual write test rather
than by reading permission bits.

### The 526: the record was left orange-clouded through the cutover

The plan called for grey-clouding the apex before repointing it, because the
zone runs **Full (strict)**. The A record was moved while still proxied, so
Cloudflare could not validate an origin that had no certificate yet and every
HTTPS request returned **526** until the certificate was issued. The site was
visibly down for roughly seven minutes.

It was recoverable for the reason the runbook gives: Cloudflare still proxies
plain HTTP to the origin even in strict mode, and **Cloudflare exempts
`/.well-known/acme-challenge/` from Always Use HTTPS** — verified with a probe
before spending a validation attempt, rather than assumed. `enable-site-ssl.sh
--proxied --no-redirect` then completed over HTTP-01 and the 526 cleared on the
Apache reload.

Because the record never left orange, the zone ended in its target state with no
re-proxy step. `ssl_verify:0` on both apex and `www`, so Full (strict) is
satisfied.

**Lesson: grey-cloud is not interchangeable with Flexible on a Full (strict)
zone.** On a Flexible zone, repointing early is survivable. Here it is a visible
outage, and the only reason it was a short one is that the ACME carve-out
exists.

## memories.mardini.net: photos return 403 unless logged in

That is correct, not a fault. Its `.htaccess` carries a deliberate rule:

```
RewriteCond %{HTTP_COOKIE} !pwg_id
RewriteRule ^(upload|_data)/.*\.(jpg|jpeg|png|webp|avif|gif|mp4|pdf)$ - [F,L]
```

Direct photo access is denied without a Piwigo session cookie — privacy
protection for a family gallery. Verified the rule carried across byte-identical
to the source, and that it keys on the cookie: 403 without, 200 with.

## Closed 2026-07-30/31

- **Offsite backups are live.** Not S3 — Cloudflare R2, in the existing DotAim
  account, bucket `hetzner-dotaim-backups`, via restic. Nightly at 03:27 UTC,
  weekly verification Sundays. First run and a full `check --read-data` both
  passed. See `docs/runbook-backups.md`. This closes the last hard-deadline item.
- **shamsaldhaher.com and billing.shamsaldhaher.com are archived.** The client
  is not keeping either running, so both were captured and verified rather than
  migrated: 7,754 and 71,291 files, dumps restore cleanly into MySQL 8.0.
- **Three zones on Hostinger nameservers — closed by owner decision**
  (2026-07-31). grand-emerald.com and nizonet.com do not depend on Hostinger
  for hosting, and shamsaldhaher.com's client appears to be renewing the
  domain. Not tracked further.

## Still open (not blockers)

- **All FPM pools run as www-data**, so any compromised site can still read
  every other site's database credentials. See `docs/runbook-fpm.md`.
- **Hostinger freezes remain in place** on every migrated site, deliberately.
  Rolling any of them back means reverting DNS *and* lifting the freeze.

Every site runs a per-site FPM pool. See `docs/runbook-fpm.md`. Three PHP
versions are in use — **8.3** for most, **7.4** for lebanese.tech and
singlefunction.com, **8.5** for menamaps.com — which is why mod_php could not
host this estate at all.

menamaps.com is the only site with non-default FPM limits. They live in
`templates/fpm-limits/menamaps.com.conf` and are reapplied by `set-site-php.sh`
on every run; they are **not** hand-edited into the pool file, which the script
regenerates each time.

**Note on database names:** they do not all follow `<project>_website_wp`.
skinosis.com is `skinosis_skinosis_com_wp`, and its local layout is
`httpdocs/skinosis.com/wp/` rather than `httpdocs/website/wp/`. Check the local
config per site rather than extrapolating the convention.

videotizer.com was cut over using the full procedure in
`docs/runbook-site-cutover.md`: frozen at source, resynced, verified, then DNS.
Post/option counts and newest timestamp matched the frozen source exactly.

**The Hostinger copy is still frozen (503) and should stay that way** — see
rollback in the runbook, which requires lifting it.

**Next, in order:** per-site FPM users. Nothing else is outstanding — offsite
backups landed 2026-07-30 and the remaining zone moves were dropped by owner
decision.

## Do not delete from Hostinger yet

Nothing has been removed from Hostinger, deliberately. While the old copy
remains, rolling back any of these sites is a single A-record change. Deleting
it converts a two-minute rollback into a restore-from-backup.

Safe to delete only once **all** of these hold:

1. The site has been live on Hetzner long enough to trust — a few days, not
   hours, so anything cache-shaped or crawler-shaped has surfaced.
2. Mail for the domain does not touch Hostinger. Not an issue for the three
   live sites (GoDaddy/secureserver MX), but it **is** for nizonet.com, whose
   MX points at Hostinger.
3. The backup set exists somewhere that is neither Hostinger nor the production
   box.

**Point 3 became true on 2026-07-30.** The whole estate — every site, every
database, and the Hostinger-era archive — is in Cloudflare R2, verified by a
full `restic check --read-data`. Hostinger is no longer anyone's second copy,
so deletion there is now gated only on points 1 and 2.

The local copy of the Hostinger archive at `/var/www/backups/hostinger/synced`
was deleted 2026-07-31 once that was verified. It survives in R2 as snapshot
`4f4eb80f`, tagged `hostinger-archive`, which sits outside the nightly
retention policy and is therefore never pruned.

## nizonet.com — zone changes

Current zone is hosted on Hostinger nameservers (`ns1/ns2.dns-parking.com`).

Change:

| Record | Now | Change to |
|---|---|---|
| `@` | `ALIAS nizonet.com.cdn.hstgr.net.` | `A 91.99.146.221` |
| `www` | `CNAME www.nizonet.com.cdn.hstgr.net.` | `CNAME nizonet.com.` |
| `ftp` | `A 82.25.96.229` | delete — Hostinger-only, dead after the plan lapses |

Keep untouched — all mail, which stays with Hostinger for now:

- `MX` 5 `mx1.hostinger.com` / 10 `mx2.hostinger.com`
- `TXT` `v=spf1 include:_spf.mail.hostinger.com ~all`
- `_dmarc` `TXT`
- `hostingermail-{a,b,c}._domainkey` CNAMEs
- `autoconfig`, `autodiscover` CNAMEs

Note the `@` record changes type, ALIAS to A. Hostinger's ALIAS is a
CNAME-flattening record pointed at their CDN; it cannot be repointed at an
arbitrary IP, so it has to be replaced.

**This does not satisfy the DNS deadline item.** Editing records at Hostinger
leaves the *zone* on Hostinger nameservers. The 2026-07-31 commitment was DNS
off Hostinger nameservers entirely — that means moving the zone to Cloudflare.
Doing so would also let the `@` record be a normal A record and drop the CDN
ALIAS dependency. Worth doing for `grand-emerald.com` and `shamsaldhaher.com`
at the same time, since they are the other two.

## nizonet.com content

The migrated files were Hostinger's default parking page and were discarded. It
now serves a purpose-written minimal `index.html` in the same style as
mardini.net, with `noindex` since there is nothing to index.
