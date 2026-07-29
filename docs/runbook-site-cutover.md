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

### 1. Pick a quiet window

The gap between the final sync and DNS propagation is a window where writes to
the old site are lost. For low-traffic sites this is minutes and usually
nothing. For anything taking orders or comments, see "Sites that take writes".

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

---

## Sites that take writes

`menamaps.com` (WooCommerce + Stripe) and anything with active comments or
form submissions need more than a quiet window, because an order placed
between the final sync and propagation lands in a database that is about to be
abandoned.

Options, in increasing order of effort:

1. **Accept the gap.** Fine for a site whose writes are cheap to lose or
   easy to re-enter. Not fine for orders.
2. **Maintenance mode at the source** during steps 2 to 6. Stops writes
   entirely. Visitors see a holding page for the duration — typically minutes.
3. **Re-sync after propagation.** Sync once, switch DNS, then sync only the
   tables that took writes once traffic has fully moved. Fiddly and
   table-specific; only worth it where downtime is unacceptable.

For menamaps.com specifically, also: repoint Stripe webhooks, and test checkout
end to end before considering it done.

---

## Rollback

Change the A record back to `82.25.96.229`. That is the whole procedure, and it
is why the Hostinger copy stays until the migration is finished.

The exception is a site that has taken writes on Hetzner since cutover — those
writes are not on Hostinger. Rolling back then means exporting from Hetzner
first. Another reason not to leave sites half-migrated for long.
