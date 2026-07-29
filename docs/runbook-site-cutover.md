# Runbook — cutting a site over from Hostinger to Hetzner

For WordPress and other dynamic sites. Static sites are simpler: they have no
database and no write path, so steps 3 and 6 collapse into "re-run the sync".

**The problem this exists to solve.** A site provisioned on Monday and switched
on Wednesday serves Monday's data. Measured on videotizer.com: within 18 hours
it had drifted by one post and one option, with a post modified 16 minutes
before the check. Cut over on that and the change is gone — no error, no
warning, just missing content that someone will notice weeks later.

So the rule is: **provisioning and cutover are separate events, and the sync
happens at cutover, not at provisioning.**

---

## Before the day

1. **Lower the DNS TTL** on the record you will change, to 300s, at least a
   full old-TTL ahead. GoDaddy zones here default to 600s, so an hour is
   plenty. This is what makes the rollback fast.
2. **Provision the site** — `provision-site.sh`, deploy content, import the
   database, repoint the config. Verify over `--resolve` (see step 5). Do this
   whenever is convenient; it does not have to be near the cutover.
3. **Know where mail points.** Check the MX before touching anything. If mail
   is on Hostinger, changing the A record is fine but the MX must be carried
   across unchanged. Migrating mail is a separate job.

## Cutover

### 1. Freeze writes at the source

Not "pick a quiet window" — actually stop writes. A quiet window is a hope; a
freeze is a guarantee. Until the source can no longer accept a write, there is
a period where a comment, order or edit lands in a database that is about to be
thrown away.

Put the Hostinger site into maintenance: `templates/maintenance.htaccess`,
prepended to the site's existing `public_html/.htaccess`. It returns **503 with
Retry-After**, not 200 and not a redirect — a 200 saying "we're down" tells
search engines that *is* the page now, which is how a listings site gets
deindexed.

**A maintenance page only on Hetzner does not work here.** Hostinger keeps
serving until DNS moves, and during propagation some visitors still reach it
and can still write. The freeze has to be at the source.

**This means writing to Hostinger**, which `.claude/CLAUDE.md` otherwise holds
read-only. It is a deliberate, minimal, reversible exception for the cutover
itself. Get explicit agreement before the first one; do not treat this runbook
as standing permission.

Applying it, in `domains/<domain>/public_html/`:

```bash
# 1. upload maintenance.html (a plain holding page) and the freeze block
# 2. back up the original, then prepend
cp .htaccess .htaccess.bak-$(date +%F)
cat block.txt .htaccess.bak-$(date +%F) > .htaccess && rm block.txt
```

Then confirm it took, including a deep URL and the login page — a freeze that
only covers the homepage is not a freeze. **Check twice, a few seconds apart:**
LiteSpeed serves cached pages for a moment after the `.htaccess` write, so the
first check can show 200 on a freeze that is actually working. Both
lebanese.tech and singlefunction.com looked unfrozen on the first pass.

```bash
curl -sI https://<domain>/            # 503 + retry-after
curl -so /dev/null -w '%{http_code}\n' https://<domain>/listings/
curl -so /dev/null -w '%{http_code}\n' https://<domain>/cms/wp-login.php
```

The freeze blocks HTTP only. `rsync` and `mysqldump` run over SSH and are
unaffected, which is exactly what the next step needs.

**The freeze block must never reach Hetzner.** The sync copies `.htaccess`
faithfully, so without care the new site comes up serving 503 to everyone the
moment DNS moves — indistinguishable from a failed migration. `resync-site.sh`
strips it, which is why the block carries `### MIGRATION-FREEZE-START` /
`### MIGRATION-FREEZE-END` sentinels: the strip is exact rather than a guess at
line numbers. If you ever apply a freeze by hand, keep those markers.

### 2. Final sync

```bash
~/server_ops/scripts/resync-site.sh <group> <domain> <db-name> [wp-path]
# e.g.
~/server_ops/scripts/resync-site.sh dotaim videotizer.com videotizer_website_wp cms
```

This refreshes files from Hostinger, pushes them into the live docroot,
re-applies the local DB naming, rebuilds the database from a fresh dump, and
verifies row counts against the source.

Two things it does that are easy to forget by hand:

- **Re-applies `set-site-db.php` after the file sync.** The synced
  `master_config.php` is Hostinger's and carries the `u918436082_*` names. Sync
  without re-applying and the site points at a database that does not exist
  here.
- **Drops and recreates the database** rather than importing over it. A plain
  re-import leaves rows and tables that were deleted at the source.

### 3. Read the verification

```
           source       destination
posts      2779         2779         OK
options    176          176          OK
newest     2026-07-29 14:18:56 2026-07-29 14:18:56
```

`OK` on both counts and matching `newest` means the copy is current. A `DRIFT`
means either the source changed mid-sync (re-run; it is cheap) or something
failed. **Do not proceed on DRIFT** without understanding which.

If the source column is blank the check is inconclusive, not passing — the
script says so explicitly rather than showing a misleading `OK`.

### 4. Verify over HTTP, before DNS

```bash
curl -sI --resolve <domain>:80:91.99.146.221 http://<domain>/
curl -s   --resolve <domain>:80:91.99.146.221 http://<domain>/ | grep -i '<title>'
```

Compare against the live site. Check a content page, not just the homepage —
`/listings/`, a single post, anything with a database query behind it. Look for
`error establishing a database connection`, which is what a missed step 2 looks
like.

### 5. Switch DNS

Change the A record to **91.99.146.221**. Leave `www` alone if it is a CNAME to
the apex; it follows. **Do not touch MX.**

#### Cloudflare zones: certificate FIRST, on Full AND Full (strict)

Switching the origin before Hetzner holds a certificate for the hostname fails
in one of two ways, and **the milder-sounding setting has the worse failure**:

| Zone mode | What happens | How obvious |
|---|---|---|
| Full (strict) | Cloudflare cannot validate the origin: **526** on every request | obvious — the site is visibly down |
| **Full** | Cloudflare encrypts but does not validate, accepts whatever certificate is presented, and Apache answers unknown SNI with its default vhost | **silent — HTTP 200 serving a different site** |

nidaldirani.com hit the 526. hirement.com hit the silent one and spent several
minutes serving the **Matomo login page** under its own domain, with no error
anywhere; it was caught only by reading the page title rather than the status
code. The same class of failure has bitten this estate before on a previous
server, where the fallback vhost was 961.io.

A catch-all vhost now makes the second case fail loudly instead — see
`scripts/install-catchall-vhost.sh`. Unknown SNI gets a bare 404 from a
self-signed vhost rather than a real site. That is a safety net, **not** a
reason to skip the ordering below.

Either:

- leave the zone on **Flexible** through the cutover, issue the certificate
  (step 7), then move it to Full (strict); or
- **grey-cloud** the record (DNS-only), issue the certificate, then re-proxy.

If you hit it anyway it is recoverable, because Cloudflare still proxies plain
HTTP to the origin over HTTP even in strict mode — so `enable-site-ssl.sh
--proxied` completes over HTTP-01 and the 526 clears as soon as Apache reloads.
Confirm with a probe before assuming:

```bash
# on hetzner
mkdir -p <docroot>/.well-known/acme-challenge
echo PROBE-OK > <docroot>/.well-known/acme-challenge/probe-test
# from anywhere
curl -s http://<domain>/.well-known/acme-challenge/probe-test   # expect PROBE-OK
```

#### Why DNS goes here, after the resync, not before it

The tempting order is freeze, switch DNS, then resync. It gets the same
no-lost-writes guarantee, since the freeze is what provides that. But it makes
every visitor who lands on Hetzner during propagation see either the *stale*
site (resync not finished) or a *broken* one (database dropped mid-import).
Stale is the worse of the two: it looks fine, so nobody reports it.

Resyncing first means a visitor only ever sees one of two honest states — a
503 maintenance page on Hostinger, or the correct current site on Hetzner.

It also preserves step 4. Switch DNS first and you have committed before
verifying; the check becomes a formality you perform on a decision already
made. Resync first and step 4 is a real gate with a free rollback behind it.

The cost is that the maintenance page stays up for the duration of the resync
instead of just the propagation. On videotizer.com the resync takes about 90
seconds.

### 5b. If the guard says DNS has not propagated — check WHOSE resolver

`enable-site-ssl.sh` runs on Hetzner and uses **Hetzner's** resolver. That is
the only view that matters, and it can lag every other view by a full TTL.

This cost time twice. On skinosis.com the local machine's resolver was stale
while the world had the new record; on singlefunction.com **Hetzner's**
systemd-resolved kept re-caching the old address with a fresh 600s TTL while
both GoDaddy nameservers and every public resolver had the new one.

```bash
# what Hetzner sees -- the view that decides
ssh webmasterish@hetzner-dotaim 'dig +short <domain> A'
# authoritative, bypassing all caching
dig +short @ns47.domaincontrol.com <domain> A
```

If Hetzner disagrees with authoritative, flush rather than wait:

```bash
ssh webmasterish@hetzner-dotaim 'sudo resolvectl flush-caches'
```

### 6. Wait, then confirm it is actually being served from here

```bash
curl -sS -o /dev/null -w '%{remote_ip}\n' -L https://<domain>/
```

For a direct (non-proxied) domain this must print `91.99.146.221`.

**For a Cloudflare-proxied domain it will print a Cloudflare address, and that
is correct** — the A record points at Cloudflare by design. A 200 alone proves
nothing here, because Cloudflare may still be reaching Hostinger, or serving
from cache. Check the origin actually saw the request:

```bash
curl -sS -o /dev/null "https://<domain>/?cachebust=$RANDOM"
tail -3 /var/www/vhosts/<group>/<domain>/logs/access.log
```

The request should appear, from a Cloudflare IP (`172.70.x`, `104.x`, `188.114.x`).

### 7. Certificate and redirect

```bash
# direct
~/server_ops/scripts/enable-site-ssl.sh <group> <domain>

# behind Cloudflare
~/server_ops/scripts/enable-site-ssl.sh <group> <domain> --proxied --no-redirect
```

Refuses if the site does not reach this server, rather than burning one of five
hourly Let's Encrypt validation attempts.

`--proxied` is required for Cloudflare domains. Without it the guard compares
the A record against this server's IP, which for a proxied domain can never
match, and it will refuse a perfectly good cutover. With it, the guard writes a
probe value into the docroot and fetches it over the public hostname instead —
proving the ACME challenge will arrive, which is the thing that actually
matters.

`--no-redirect` for proxied sites: Cloudflare redirects at the edge.

### 8. Leave Hostinger alone

Do not delete anything. While the old copy exists, rollback is one A record.
See `migration/status.md` for the conditions that have to hold first.

**Leave the maintenance freeze in place** once DNS has moved. The site is no
longer reachable by name, so the freeze costs nothing, and it stops anyone
reaching the old copy by IP or stale cache and writing to a database nobody is
watching any more.

---

## Sites that take writes

`menamaps.com` (WooCommerce + Stripe) is the hard case: an order placed in the
gap lands in a database about to be abandoned, and unlike a comment it is not
something anyone can re-enter from memory.

The freeze in step 1 already solves this — a 503 means no order can be taken.
What remains is choosing how long the shop is allowed to be closed, and:

- repoint Stripe webhooks to the new host
- test checkout end to end before lifting the freeze
- check for orders placed shortly before the freeze that are mid-flow

The alternative to a freeze — cut over hot and re-sync order tables afterwards
— is table-specific, fiddly, and gets auto-increment collisions wrong in ways
that are painful to unpick. Only worth it if the shop genuinely cannot close
for a few minutes.

---

## Rollback

1. Change the A record back to `82.25.96.229`.
2. **Lift the maintenance freeze on Hostinger**, or you have rolled back to a
   503. Easy to forget precisely because step 8 says to leave it.

That is the whole procedure, and it is why the Hostinger copy stays until the
migration is finished.

The exception is a site that has taken writes on Hetzner since cutover — those
writes are not on Hostinger. Rolling back then means exporting from Hetzner
first. Another reason not to leave sites half-migrated for long.

---

## After cutover: Cloudflare-proxied sites

A proxied site works the moment DNS moves, which hides a question worth
answering: **how is Cloudflare talking to the origin?**

If the site served HTTPS *before* a certificate existed on Hetzner — as
videotizer.com did — the zone is on **Flexible**. Flexible means:

```
visitor  --HTTPS-->  Cloudflare  --PLAIN HTTP-->  Hetzner
```

The visitor sees a padlock, so nothing looks wrong. But the Cloudflare-to-origin
leg crosses the public internet unencrypted, readable and modifiable in transit,
including session cookies and anything posted to wp-admin. Flexible also causes
redirect loops the moment the origin starts redirecting HTTP to HTTPS.

Once `enable-site-ssl.sh --proxied` has issued a certificate, the origin serves
valid TLS under SNI and the zone should be moved to **Full (strict)**:

- **Full** — Cloudflare connects over HTTPS but accepts any certificate,
  including self-signed. Encrypted, but does not prove it is talking to the
  right server.
- **Full (strict)** — Cloudflare connects over HTTPS *and* validates the
  certificate. This is the correct setting once a real certificate exists.

In the dashboard: pick the domain, then **SSL/TLS → Overview → Encryption mode
→ Full (strict)**. It is per-zone, so it has to be set for each proxied domain.

Verify the origin is ready before switching:

```bash
curl -sS -o /dev/null --resolve <domain>:443:91.99.146.221 \
  -w 'origin https %{http_code} ssl_verify:%{ssl_verify_result}\n' https://<domain>/
```

`ssl_verify:0` means Full (strict) will work. Anything else means it will not,
and switching would take the site down.

Leave `--no-redirect` in place for proxied sites either way: Cloudflare handles
the HTTP-to-HTTPS redirect at the edge, and an origin redirect underneath it is
redundant at best.
