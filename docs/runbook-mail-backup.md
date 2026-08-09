# Runbook — Hostinger mailbox backup and re-import

Companion to `scripts/backup-hostinger-mail.sh`.

## Why this exists

As of **2026-08-01** Hostinger blocked hPanel and webmail access for the
lapsed account, and quoted a new hosting subscription as the only way back in.
That is not being bought — the decision is to leave Hostinger entirely.

However `imap.hostinger.com:993` **still accepts logins**. Panel access and
mail-protocol access are separate products, and only the panel was cut. That
gap is the whole reason a backup is still possible, and there is no guarantee
it stays open. Do this now.

Separately, `mx1.hostinger.com` now answers `554 5.7.1 Relay access denied`
at RCPT for every one of our domains, which means **inbound mail is being
rejected, not queued**. Nothing new is arriving, so a single clean pull should
capture everything that will ever exist.

> This corrects `docs/inventory.md` §2.3, which recorded Hostinger's claim
> that mailboxes "keep working until they expire on their own". They did not.

## Where the backup lives

```
/media/backups/mail/hostinger/<email-address>/
```

`/media/backups` is chosen deliberately:

- 83 GB free, versus ~17 GB on `/media/data2` (95% full)
- outside the repo, so no chance of committing mail — the repo rule is
  "never commit database dumps or site archives", and this is the same class
- alongside the existing `gmail/` and `from_remote_servers/` backup trees

Override with `MAIL_BACKUP_ROOT=/some/other/path` if needed.

## Running it

```bash
sudo apt install isync          # provides mbsync (1.4.4 on this box)

# One address per line. '__' prefix is gitignored -- keep it local.
$EDITOR scripts/__mailboxes.txt

./scripts/backup-hostinger-mail.sh
```

The script prompts for each mailbox password separately, with hidden input.
Press Enter on a blank prompt to skip a mailbox.

**Credentials are never written to disk.** The password goes into an
environment variable visible only to this process tree, and the generated
mbsync config reaches it via `PassCmd "printenv MBSYNC_PASS"`. The config
itself is written to a `mktemp -d` directory at mode 700 and deleted on exit.
Nothing goes near the repo, and nothing goes near
`/media/data2/www/sites/DotAim.com/Hosting/` — that path stays out of scope.

Re-running is safe and cheap: `SyncState` means only deltas are fetched.

## Safety properties

The sync is deliberately one-directional and non-destructive:

| Setting | Effect |
|---|---|
| `Sync Pull` | only ever downloads; never uploads |
| `Expunge None` | never expunges on either side |
| `Remove None` | a folder vanishing upstream does not delete the local copy |
| `Create Near` | creates local folders only, never remote |

So this cannot damage the Hostinger side, and cannot lose local mail if a
later run hits a half-broken server.

## Verifying

```bash
# message count per mailbox
find /media/backups/mail/hostinger -type f \( -path '*/cur/*' -o -path '*/new/*' \) \
  | awk -F/ '{print $6}' | sort | uniq -c

du -sh /media/backups/mail/hostinger/*
```

Spot-check that a message is real, not a stub:

```bash
find /media/backups/mail/hostinger -path '*/INBOX/cur/*' -type f | head -1 | xargs head -20
```

You should see genuine `From:` / `Subject:` / `Date:` headers.

## Re-importing into a new provider

The output is **standard Maildir**, which is the portable format — this is
exactly why mbsync was chosen over a proprietary export. Three routes:

### 1. Push straight into the new mailbox (recommended)

`imapsync` can read a local Maildir as its source and write to any IMAP
server, so the backup uploads into a new provider unchanged:

```bash
sudo apt install imapsync
imapsync \
  --host1 localhost --user1 dummy \
  --host2 imap.newprovider.com --user2 info@grand-emerald.com \
  --folder /media/backups/mail/hostinger/info@grand-emerald.com
```

Check the flags against `imapsync --help` for the installed version — the
Maildir-source options have changed between releases.

### 2. Thunderbird

Install the *ImportExportTools NG* add-on, point it at a Maildir folder, then
drag the imported folders onto the new IMAP account. Slower, but visual, and
good for a single mailbox.

### 3. Keep as a cold archive

Maildir is plain files — one message per file, greppable, no database. If a
domain's mail does not need to live on, this directory *is* the archive. Fold
it into the restic/R2 offsite backup rather than re-hosting it.

## After the new provider is chosen

Moving off Hostinger mail means changing three DNS records per domain, all of
which currently still point at Hostinger:

- `MX` — `mx1/mx2.hostinger.com`
- `SPF` TXT — `include:_spf.mail.hostinger.com`
- `DKIM` — `hostingermail-a/b/c._domainkey` CNAMEs

Affected domains (`docs/inventory.md` §2.3): `shamsaldhaher.com`,
`billing.shamsaldhaher.com`, `grand-emerald.com`, `nizonet.com`,
`nidaldirani.com`.
