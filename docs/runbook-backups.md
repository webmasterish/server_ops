# Runbook — backups

How everything on `hetzner` is backed up, where it goes, and how to get it
back. Decided 2026-07-30.

## Design in one table

| tier | what | where | format | retention |
|---|---|---|---|---|
| 1 | databases | local `/var/www/backups/db/` | `.sql.bz2` | 7 generations (Matomo: 2) |
| 2 | **the real backup** — sites, dumps, `/etc` | Cloudflare R2, `hetzner-dotaim-backups` | restic (deduplicated, encrypted) | 7 daily / 5 weekly / 12 monthly |
| 3 | whole machine | Hetzner provider snapshots | provider image | 7 days |

Tier 1 is convenience: a dump you can grab and pipe into `mysql` with no
tooling. Tier 3 is fast whole-box rollback. **Tier 2 is the only one that
survives losing the server**, and it is the only one that is verified.

### Why the files are not tarballs

A tarball is one opaque blob: change a single file and all ~17 GB of it is new,
so on a disk with ~25 GB free you can afford exactly one generation. restic
stores file *content blocks*, so a snapshot of a mostly-unchanged tree costs
only what actually changed — which is what makes twenty-four retained
generations affordable at all. Tarring first would defeat precisely the
mechanism that makes the history possible.

Databases are the opposite case and stay `.sql.bz2`: a dump is one logical
artefact, it restores with no special tooling, and `verify-hostinger-backup.sh`
and `sanitize-mariadb-dump.sh` already consume that exact format.

### Why Matomo is weekly

Matomo is ~1.0 GB of the ~1.3 GB of database, and it rewrites its archive
tables daily, so every dump is new data that deduplicates against nothing. On
the other six days the previous dump stays on disk and is snapshotted
unchanged, so every snapshot still contains a Matomo dump — just one up to six
days old. It is analytics; a week of loss is tolerable there in a way it is
not for an order or an invoice.

---

## Where everything lives

On `hetzner`:

| what | path | notes |
|---|---|---|
| restic binary | `/usr/bin/restic` | 0.16.4, from apt |
| repository password | `/root/.restic-pass` | **0600 root.** Lose it and the backups are unrecoverable |
| R2 credentials + repo URL | `/etc/restic/restic.env` | 0600 root. **Not in this repo** |
| exclude list | `/etc/restic/excludes.txt` | from `templates/restic-excludes.txt` |
| local DB dumps | `/var/www/backups/db/` | tier 1 |
| Hostinger archive | `/var/www/backups/hostinger/synced/` | point-in-time; see below |
| scripts | `/home/webmasterish/server_ops/scripts/` | |
| systemd units | `/etc/systemd/system/restic-{backup,check}.{service,timer}` | |
| logs | journald | `journalctl -u restic-backup` |

Off-box: `s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/hetzner-dotaim-backups`

## Schedule

| when (UTC) | what |
|---|---|
| 03:15 nightly | `restic-backup.timer` → dump databases, snapshot, `forget --prune` |
| Sun 05:00 | `restic-check.timer` → `restic check --read-data-subset=5%` |

Both have `RandomizedDelaySec` and `Persistent=true`, so a reboot at the wrong
moment delays a run rather than skipping it. 03:15 is the measured traffic
trough and is clear of the 00:00 logrotate run.

## What is excluded, and why

See `/etc/restic/excludes.txt` for the annotated list. The one worth knowing:
**per-site Apache logs are not backed up.** They are ~59 MB/day of fresh
incompressible data that would dominate the repository's growth, and they
already have 30 days of on-box history via `/etc/logrotate.d/vhosts`. They are
operational data, not business data.

`/etc/restic/` is excluded so the credentials for the destination are never
stored inside the repository they unlock.

---

## First-time setup

### 1. Cloudflare (in the dashboard)

1. **R2 → Create bucket** — name `hetzner-dotaim-backups`, location hint **EU**
   (the server is in Germany).
2. Leave the bucket **private**. It needs no public access and no custom
   domain.
3. **R2 → Manage API Tokens → Create API Token**
   - Permission: **Object Read & Write**
   - Scope it to the `hetzner-dotaim-backups` bucket only, not "all buckets"
   - TTL: forever
4. Copy the **Access Key ID**, **Secret Access Key** and your **Account ID**.
   The secret is shown once.

Use **Standard** storage, not Infrequent Access. IA is $0.01/GB-month against
Standard's $0.015, but it adds per-GB retrieval charges and a 30-day minimum
storage duration — and `restic forget --prune` deletes objects continuously, so
the minimum-duration charges would eat the difference. At this size the saving
is a few cents a month.

### 2. On the server — do this yourself, in your own terminal

These two files hold secrets and are deliberately not created by any script in
this repo, so the keys never pass through a transcript.

```bash
# Repository password. Generate it, then SAVE A COPY in your credentials store
# BEFORE going further -- there is no recovery path without it.
sudo install -d -m 700 /etc/restic
sudo bash -c 'head -c 32 /dev/urandom | base64 > /root/.restic-pass'
sudo chmod 600 /root/.restic-pass
sudo cat /root/.restic-pass          # copy this into your password manager

# Repository config + R2 credentials.
sudo install -m 600 /dev/null /etc/restic/restic.env
sudo nano /etc/restic/restic.env
```

`/etc/restic/restic.env` should contain exactly:

```sh
RESTIC_REPOSITORY=s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/hetzner-dotaim-backups
RESTIC_PASSWORD_FILE=/root/.restic-pass
AWS_ACCESS_KEY_ID=<R2 access key id>
AWS_SECRET_ACCESS_KEY=<R2 secret access key>
```

> `AWS_*` is not a mistake — R2 speaks the S3 API, and restic's S3 backend
> reads those variable names whatever the provider.

### 3. Install and enable

```bash
cd ~/server_ops/scripts
sudo ./install-restic.sh                            # installs, validates, initialises; nothing scheduled
sudo systemctl start --no-block restic-backup.service   # first real run
journalctl -fu restic-backup.service                # Ctrl-C here is safe
sudo ./install-restic.sh --enable                   # once you are happy, start the timers
```

> **Use `--no-block`.** Plain `systemctl start` on a `Type=oneshot` unit blocks
> until the whole run finishes — several minutes for the first backup — and an
> SSH session sitting idle that long will often drop with
> `client_loop: send disconnect: Broken pipe`. That message is about your
> terminal, not the backup: systemd owns the process, so the run continues and
> completes regardless. `--no-block` returns immediately and lets you follow it
> in the journal, where Ctrl-C detaches without touching the run.

`install-restic.sh` refuses to proceed if either credentials file has the wrong
ownership or mode, and finishes with a `--dry-run` so a wrong exclude pattern
surfaces immediately rather than in six months.

---

## Restoring

```bash
# always, first:
sudo -i; set -a; . /etc/restic/restic.env; set +a

restic snapshots                       # what exists
restic ls latest | grep wp-config      # find a path
```

**One file, to a scratch directory** (never restore straight over a live tree):

```bash
restic restore latest --target /tmp/r --include /var/www/vhosts/dotaim/skinosis.com/httpdocs/wp-config.php
```

**A whole site:**

```bash
restic restore latest --target /tmp/r --include /var/www/vhosts/dotaim/skinosis.com
# inspect /tmp/r, then move into place deliberately
```

**A database:**

```bash
restic restore latest --target /tmp/r --include /var/www/backups/db
bzcat /tmp/r/var/www/backups/db/skinosis_skinosis_com_wp_2026-07-30.sql.bz2 \
  | mysql --defaults-file=/etc/mysql/debian.cnf skinosis_skinosis_com_wp
```

**From a specific date:** `restic snapshots` for the ID, then use it in place
of `latest`.

**Browse without restoring:**

```bash
mkdir /tmp/mnt && restic mount /tmp/mnt     # snapshots appear as directories
```

## Routine checks

```bash
systemctl list-timers 'restic-*'            # are they scheduled
journalctl -u restic-backup --since '3 days ago'
restic stats --mode raw-data                # what it actually costs
restic check --read-data                    # full verification, on demand
```

If a run is interrupted the repository can be left locked. `restic-backup.sh`
clears stale locks on entry; by hand it is `restic unlock`.

---

## Retiring the Hostinger archive

`/var/www/backups/hostinger/synced/` (~16 GB) is the verified point-in-time
capture of the Hostinger estate: 16 sites, 11 databases, all file counts
matched at capture and all dumps confirmed to restore into MySQL 8.0.

It is **not** redundant with the live sites. They have diverged from it —
menamaps.com has taken orders since cutover — and the Hostinger plan lapses
2026-08-01, after which this is the only copy of that state.

### It needs a snapshot that retention will never prune

Being inside the nightly snapshots is **not** enough. Those are tagged
`nightly`, and `restic forget --keep-monthly 12` eventually discards the oldest
of them — so if the local copy were deleted, the archive would quietly vanish
from R2 about a year later, long after anyone was watching.

It therefore has its own snapshot, taken 2026-07-30 and tagged
`hostinger-archive`:

```
4f4eb80f  2026-07-30 21:47:54  hetzner-dotaim  hostinger-archive
```

`restic-backup.sh` scopes its retention to `restic forget --tag nightly`, so
nothing tagged otherwise is ever considered for pruning. That snapshot is
permanent until someone deletes it by hand. Because the data was already in the
repository it cost **1.4 KiB**.

Refresh it only if the archive on disk changes:

```bash
restic backup --tag hostinger-archive --exclude-file=/etc/restic/excludes.txt \
  /var/www/backups/hostinger
```

### Then, and only then

Delete the local copy when all five are true:

1. The R2 repository exists and `install-restic.sh` has run clean. ✅ 2026-07-30
2. A snapshot containing `/var/www/backups/hostinger` has been taken. ✅ `dfb5177c`
3. `restic check --read-data` passes over the whole repository. ✅ 783/783 packs, no errors
4. A test file has been restored *out of R2* and compared byte-for-byte. ✅ sha256 match
5. A permanently-retained snapshot exists outside the `nightly` tag. ✅ `4f4eb80f`

Then remove it, and delete the `/var/www/backups/hostinger` line from `PATHS`
in `restic-backup.sh` so the next run stops looking for it.

## If the password is lost

There is no recovery. restic repositories are encrypted and Cloudflare cannot
help. The password in `/root/.restic-pass` must exist in a second place —
your credentials store — or the backups are decorative.
