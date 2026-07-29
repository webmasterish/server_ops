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
itself — one file, prepended, removed afterwards. Get explicit agreement before
the first one; do not treat this runbook as standing permission.

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

### 6. Wait, then confirm it is actually being served from here

```bash
curl -sS -o /dev/null -w '%{remote_ip}\n' -L https://<domain>/
```

Must print `91.99.146.221`. Until it does, the certificate step will refuse.

### 7. Certificate and redirect

```bash
~/server_ops/scripts/enable-site-ssl.sh <group> <domain>
```

Refuses if DNS has not propagated, rather than burning one of five hourly
Let's Encrypt validation attempts. Add `--no-redirect` for Cloudflare-proxied
sites, which redirect at the edge already.

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
