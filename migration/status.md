# Migration status

Updated 2026-07-29. Hetzner is `91.99.146.221`. Hostinger is `82.25.96.229`.

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

All WordPress sites run PHP 8.3 via per-site FPM pools. See `docs/runbook-fpm.md`.

**Note on database names:** they do not all follow `<project>_website_wp`.
skinosis.com is `skinosis_skinosis_com_wp`, and its local layout is
`httpdocs/skinosis.com/wp/` rather than `httpdocs/website/wp/`. Check the local
config per site rather than extrapolating the convention.

videotizer.com was cut over using the full procedure in
`docs/runbook-site-cutover.md`: frozen at source, resynced, verified, then DNS.
Post/option counts and newest timestamp matched the frozen source exactly.

**The Hostinger copy is still frozen (503) and should stay that way** — see
rollback in the runbook, which requires lifting it.

**Next: the remaining eight WordPress sites.**

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
3. The backup set has been pushed to S3, so a copy exists somewhere that is
   neither Hostinger nor the production box.

Point 3 is currently false for everything. Until the S3 push happens, Hostinger
*is* the second copy.

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
