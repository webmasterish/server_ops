# Runbook — health checks

How `hetzner` is monitored, what each check asserts, and what to do when one
fires. Decided 2026-08-09.

## The regime in one table

| cadence | what | who | cost |
|---|---|---|---|
| daily 06:30 UTC | `health-check.sh` — backups, capacity, services, certs | unattended | silent unless something is wrong |
| 1st of month 09:00 UTC | `review-reminder.sh` pushes the review prompt | unattended | one notification |
| monthly | `health-check.sh --report` + `audit-sites.sh` | you, with Claude | ~15 min |
| quarterly | restore drill from R2 | you, with Claude | ~30 min |

The monthly and quarterly rows are the only two with no automatic trigger, so
`review-reminder.timer` exists to fire them. A runbook nobody re-opens is a
runbook that documents an intention.

It is deliberately **not** part of `health-check.sh`. A chore is not a fault:
folding it in would make the daily check go non-OK for a reason unrelated to
the health of the machine, and once WARN can mean "it is the 1st", you have
taught yourself to skim past WARN. It also arrives at 09:00 rather than 06:30
so it does not get read as part of the daily batch and dismissed with it.

The reminder tracks the restore drill in `/var/lib/health-check/last-restore-drill`
and escalates if it has never been recorded or is over 100 days old. Record a
completed drill with:

```bash
sudo ~/server_ops/scripts/review-reminder.sh --drill-done
```

Three layers because the failure modes are different in kind. The daily check
catches things that cross a line — a disk filling, a backup stopping, a cert
not renewing. The monthly review catches things that only exist as a trend and
have no line to cross: log volume drifting up, traffic shape changing, pool
counts growing past their memory budget. The quarterly drill catches the thing
neither of the others can, which is that the backups are not actually
restorable.

### Why daily and not hourly

Every check here measures something with a horizon of a day or more. The
backup runs nightly, certs renew at 30 days remaining, logrotate is daily,
disk moves at ~71 MB/day of logs against 40 GB free. An hourly check would
find the same answer 24 times and turn the alert channel into something you
filter. The one genuinely fast-moving failure — a site being down — is not in
scope here and would need external checking anyway, since a box that is down
cannot report that it is down.

### Why silence means healthy

The daily run prints only WARN and FAIL lines. A report that is 25 green lines
every morning is a report nobody reads on the morning it is 24 green lines and
one red one. `--report` gives the full picture when you actually want it.

## Exit codes

| code | verdict | meaning |
|---|---|---|
| 0 | OK | nothing to do |
| 2 | WARN | degraded; look this week |
| 1 | FAIL | broken now |

`health-check.service` sets `SuccessExitStatus=2`, so a WARN does not mark the
unit failed. That keeps `systemctl --failed` meaning "the check could not run",
which is a different problem from "the check ran and found something".

## What each check asserts

### Backups

| check | asserts | threshold |
|---|---|---|
| `backup/freshness` | the repository actually received a snapshot | newest `nightly` < 36h |
| `backup/lastrun` | `restic-backup.service` last exited success | ≤ 2d |
| `backup/repocheck` | `restic-check.service` last exited success | ≤ 9d |
| `timer/*` | the four timers are active | — |

`backup/freshness` is the reason this script exists. Everything else in this
section checks a *mechanism*; that one checks the *outcome*. A timer can be
enabled, the service can exit 0, and the repository can still have received
nothing for a week — expired R2 credentials, a stale lock, a dump that filled
the disk. Only the age of the newest snapshot catches all of those, because
only it asks the repository rather than asking systemd.

It filters on `--tag nightly` deliberately. The `hostinger-archive` snapshot
(`4f4eb80f`, 2026-07-30) is a permanent point-in-time record that is never
renewed; counting it would make the repository look fresh forever.

36h rather than 24h: the backup starts at 03:15 with up to 15m of jitter and
runs ~12 minutes, and the check is at 06:30. A 24h window would false-alarm on
the first slow night. 36h still catches a single missed run.

### The cross-boot trap

`backup/lastrun`, `backup/repocheck` and `logrotate/lastrun` read the last run
time via `unit_last_run()`, which tries `systemctl` first and falls back to the
journal. The fallback is not optional.

systemd does **not** persist `ExecMainStartTimestamp` across a reboot. After a
restart it reads empty for any oneshot that has not run since boot, and the
naive reading of empty is "has never run". This was found the honest way: the
first health check after the 2026-08-09 reboot reported both restic units as
never-run while the repository plainly held a 13h-old snapshot. Left alone it
would have pushed two FAILs after every single reboot — and a monitor that
cries wolf on every restart is one you stop reading, which makes the false
positive a worse bug than anything it would have reported.

The journal persists (`/var/log/journal`, boots recorded back to 2025-08), so
it is the durable source. If you ever set `Storage=volatile` in
`journald.conf`, this check silently regresses to the same false alarm.

### Capacity

| check | threshold |
|---|---|
| `disk/root` | WARN 80%, FAIL 90% |
| `mem/available` | WARN below 15% available |
| `swap` | WARN above 50% used |
| `fpm/headroom` | WARN if `sum(pm.max_children) × avg RSS` exceeds RAM + swap |

`fpm/headroom` compares against RAM **plus swap**, and that is the whole point
of the check. Exceeding RAM means the box swaps and gets slow — survivable and
self-correcting. Exceeding RAM+swap means the OOM killer has to choose a
victim, and it chooses by RSS, which on this machine is `mysqld`. That takes
every site down at once rather than the one site that caused it.

It uses the **median** per-process RSS, not the mean. Measured 2026-08-09,
per-process RSS ran min 15 / median 52 / max 129 MB — an 8× spread, because a
WordPress request mid-render and an idle worker are not the same animal. Two
runs four minutes apart gave means of 38 MB and 48 MB, moving the verdict by
1.1 GB; the median held at 50 MB across three consecutive runs. A check whose
answer depends on when you asked it is not a check.

**This one is currently marginal and it is the open item on this server.** As
of 2026-08-09 it reads 111 children × 50 MB = 5550 MB against 5866 MB of
RAM+swap — 95% of budget, about 3 MB of median RSS away from warning.

The worst case is genuinely reachable, which is why it warns rather than
merely reporting:

| layer | limit | binding? |
|---|---|---|
| Apache `MaxRequestWorkers` | 150 concurrent requests | no — above 111 |
| `sum(pm.max_children)` across 15 pools | 111 children | **yes** |

Nothing caps concurrency below the number being priced. `ondemand` on 12 of
the 15 pools makes it unlikely — observed peak is ~29 processes against a
theoretical 111 — but a bot storm hitting several vhosts at once is exactly
the shape that gets there, and 65% of current traffic is already bots.

The fix is `scripts/tune-fpm-pools.sh`, which right-sizes the pools against
actual traffic rather than applying one number everywhere. Yesterday's request
counts are not close:

| site | requests/day | pool |
|---|---|---|
| ayatalquran.com | 243,691 | 8 (unchanged) |
| singlefunction.com | 16,326 | 4 |
| menamaps.com | 11,144 | 6 (takes orders) |
| everything else | ≤ 7,985 | 4 |

243,691/day is 2.8 req/s average; at a 100 ms PHP response that is well under
one concurrent worker, and 8 covers a 20× burst. The long tail runs at
0.04–0.19 req/s, where 8 was never load-derived — it is the number the
provisioning template happened to carry. 4 covers a 100× burst there.

The three `www.conf` pools are the packaged defaults, and 8.3's is **not**
dead: `/etc/apache2/conf-enabled/php-fpm-default.conf` routes any `.php` that
no per-vhost `FilesMatch` claims to `/run/php/php8.3-fpm.sock`. That is what
the "Primary script unknown" scanner noise has been hitting, and it is the
fallback for the five sites with no pool of their own (sasf-ksa, lamarkazia,
webmasterish, mardini.net, nizonet). It keeps its 5. Nothing references the
7.4 or 8.5 defaults, so those drop to 2 — reduced rather than disabled, which
stays reversible.

Result: 111 → 63 children, ~3400 MB at a 54 MB median, 58% of budget. That
leaves the median room to drift to ~93 MB before warning again.

Lowering `MaxRequestWorkers` would not have helped on its own, since 111 was
already the binding constraint.

The script backs up every pool file to `/var/backups/php-fpm/<timestamp>/`,
runs `php-fpm -t` per version **before** reloading anything, reverts
automatically if a config test fails, and reloads one service at a time.
`--dry-run` shows the whole plan; `--revert` restores the most recent set.

`swap` at 30-40% is normal here and is not pressure. Linux pages out genuinely
idle memory and leaves it there for weeks; it only means something alongside a
low `mem/available`. It reads 0% immediately after a reboot and climbs for
weeks; that is the expected shape, not a leak.

### Services and config

`svc/*` covers apache2, mysql, redis-server, ufw, fail2ban, and every enabled
`php*-fpm`. The FPM pools are globbed rather than listed because
`set-site-php.sh` can introduce a version at any time and a hardcoded list
would silently stop covering it.

`apache/configtest` catches a vhost that was edited but never reloaded: the
running Apache is fine, so nothing looks wrong until the next restart takes
every site down at once.

`certs` reads the certificate files with `openssl` rather than asking certbot,
because certbot takes its own lock and this runs while `certbot.timer` may be
mid-renewal. WARN at 21 days, FAIL at 10. certbot renews at 30 days remaining
and runs twice daily, so anything under 21 has failed to renew ~18 times and
needs a human.

`ssh/passwordauth` is a regression guard, not a discovery. It exists so that an
`openssh-server` upgrade dropping a new file into `/etc/ssh/sshd_config.d/`
cannot quietly undo the hardening without anyone noticing.

## Install

```bash
# on hetzner, from the server checkout
cd ~/server_ops/scripts
./install-health-check.sh --dry-run    # look first
./install-health-check.sh
```

The installer runs the check once before scheduling it and refuses to install
if it exits with anything other than 0, 1, or 2. A monitor that has never been
observed to pass is not a monitor.

Read a run:

```bash
journalctl -u health-check -n 40
sudo ~/server_ops/scripts/health-check.sh --report
```

## The notify hook

The check writes to journald and exits non-zero. Without a notify hook, nothing
tells you — you would have to go and look, which is the failure mode monitoring
exists to prevent.

The hook is `/etc/health-check/notify`, executable, receiving the verdict
(`OK`/`WARN`/`FAIL`) as `$1` and the full report on stdin. It is deliberately
not installed by the script: it is the one part that needs a credential or a
URL, and requiring a secret before the thing will run at all is how monitoring
ends up never being installed.

**Active channel: ntfy push**, via `scripts/install-notify-ntfy.sh`.

Chosen 2026-08-09 after Google App Passwords turned out to be unavailable on
the Workspace account — the email path is built and ready but needs a
credential that could not be issued. ntfy needs no account and no credential
at all, which is why it works today.

Read the topic on the server, in your own terminal — it is never printed by
any script and has not passed through a transcript:

```bash
sudo grep -o 'ntfy\.sh/[a-z0-9-]*' /etc/health-check/notify
```

Subscribe in the ntfy app, or just open `https://ntfy.sh/<topic>` in a browser
tab — **the app is optional**, it only adds background push. The topic is the
only thing keeping these alerts private, so treat it as a credential: save it
in the password manager, and `--rotate` if it is ever exposed.

FAIL is sent at `Priority: high` so it breaks through a silent phone; WARN and
REVIEW go at default priority. A monitor that buzzes at 3am for a disk at 82%
is a monitor you mute.

### The email path, for when App Passwords become available

`scripts/install-notify-email.sh` sends to **dev@dotaim.com** through Google
Workspace. It is installed and working apart from the credential: msmtp is on
the box, `/etc/msmtprc` holds a skeleton at 0600 root, and the hook refuses to
attempt a send while placeholders remain — so a half-configured channel fails
loudly at setup rather than silently at 3am.

To finish it later: issue an App Password (needs 2-Step Verification, and the
Workspace admin must not have blocked them), fill in the `user`, `from` and
`password` lines in `/etc/msmtprc`, then `install-notify-email.sh --test`. If
App Passwords stay blocked, the alternative is the Workspace SMTP relay
(`smtp-relay.gmail.com`), which authenticates by IP and needs an admin to
allow-list the Hetzner address.

There was no relay to reuse. `CLAUDE.md` says outbound WordPress mail goes
through an SMTP relay, but that is policy, not current state: as of
2026-08-09 hetzner had no MTA, no `sendmail_path`, no SMTP plugin and no SMTP
constants in any `wp-config.php`. Nothing on the box could send mail at all.

dotaim.com mail is on Google Workspace (MX `aspmx.l.google.com`, SPF
`include:_spf.google.com`, DNS on Cloudflare), so the relay is
`smtp.gmail.com:587` with an app password.

**Why authenticated relay and not direct delivery.** The VPS could hand mail
straight to `aspmx.l.google.com` with no credentials — that is how ordinary
internet mail works, and it is tempting because it needs no secret. Don't. A
Hetzner IP with no matching PTR, no SPF authorisation for dotaim.com and no
DKIM signature is the precise profile of a spam source; Google will
spam-folder it or reject it. The one thing an alert channel must never do is
fail quietly.

**Why msmtp and not postfix.** postfix is a full MTA — listening daemon,
queue, spool. msmtp is a ~200 KB sendmail-shaped pipe that opens one
authenticated connection and exits. For "send one email when a check fails",
a daemon is pure attack surface and pure maintenance.

`/etc/msmtprc` (0600 root) holds the app password and is **not** written by
any script in this repo, same rule as `/etc/restic/restic.env`. The installer
lays down a skeleton with placeholders; the two credential lines are filled in
by hand on the server. `--test` refuses to send while placeholders remain, so
a half-configured channel fails loudly at setup rather than silently at 3am.

`/var/log/msmtp.log` records every send and is the first place to look when an
alert does not arrive. It has its own logrotate rule (monthly, 6 kept).

### The alternative: ntfy push

`scripts/install-notify-ntfy.sh` is kept as a working alternative — phone push
via ntfy.sh, no credentials anywhere. Worth knowing: **it needs no app.**
Opening `https://ntfy.sh/<topic>` in any browser tab subscribes you; the app
only adds background push. It generates the topic on the server from
`/dev/urandom` and never prints it, since the topic is the only thing keeping
those alerts private:

```bash
sudo grep -o 'ntfy\.sh/[a-z0-9-]*' /etc/health-check/notify
```

Both installers write the same `/etc/health-check/notify` path, so running one
cleanly replaces the other. Only one channel is active at a time.

## Monthly review

Run both, then read them together:

```bash
sudo ~/server_ops/scripts/health-check.sh --report
~/server_ops/scripts/audit-sites.sh
```

`audit-sites.sh` is the per-site half and is deliberately not in the daily run:
it writes a probe file into every docroot and makes ~30s of HTTP requests
against production. That is fine monthly and wrong daily.

Things to look at that no threshold can judge:

- **Log volume against the 30-day window.** Re-measure with
  `find /var/www/vhosts -name '*.log.1' -printf '%s\n' | awk '{s+=$1} END {print s/1048576}'`.
  It was 59 MB/day on 2026-07-30 and 71 MB/day on 2026-08-09.
- **Traffic shape.** On 2026-08-09 roughly 65% of ayatalquran.com's 149k daily
  requests were self-identified bots. Worth a Cloudflare bot rule; costs
  nothing and cuts both log volume and PHP load.
- **Pending package updates and reboots.** The daily check warns at 7 days
  pending; the monthly review is where you actually schedule the window.
- **Pool count against `fpm/headroom`.**

## Quarterly restore drill

The one that matters, and the one that gets skipped.

`restic check --read-data-subset=5%` proves the repository is internally
consistent. It does not prove you can rebuild a site from it. Those are
different claims, and only the second one is the reason the backups exist.

```bash
# pick a small site and a database
sudo restic restore latest --target /tmp/drill \
  --include /var/www/vhosts/dotaim/skinosis.com/httpdocs
sudo diff -r /tmp/drill/var/www/vhosts/dotaim/skinosis.com/httpdocs \
             /var/www/vhosts/dotaim/skinosis.com/httpdocs

sudo restic restore latest --target /tmp/drill \
  --include /var/www/backups/db/skinosis_skinosis_com_wp
bunzip2 -t /tmp/drill/var/www/backups/db/*.sql.bz2   # integrity, not just presence

sudo rm -rf /tmp/drill
```

A clean `diff -r` and a passing `bunzip2 -t` is the whole drill. Record the
date it was last done in `migration/status.md` — an undated drill is a drill
nobody can prove happened.

## When a check fires

| check | first thing to do |
|---|---|
| `backup/freshness` | `journalctl -u restic-backup -n 100`. Most likely a held lock (`restic unlock`) or R2 credentials. |
| `backup/repocheck` | `journalctl -u restic-check -n 100`. A genuine integrity error means restore from an older snapshot and investigate; do not prune. |
| `disk/root` | `du -sh /var/www/vhosts/*/*/logs` first — logs are the usual cause and the safest thing to shed. |
| `certs` | `sudo certbot renew --dry-run` for the named cert. Usually DNS or a redirect breaking the HTTP-01 challenge. |
| `apache/configtest` | Do **not** restart Apache. Fix the syntax first; the running config is still serving. |
| `svc/*` down | `systemctl status <unit>` then `journalctl -u <unit> -n 50`. |
| `ssh/passwordauth` | Something re-enabled it. `sudo sshd -T \| grep -i password`, then check `/etc/ssh/sshd_config.d/`. |
| `fpm/headroom` | A pool was added. Either lower `pm.max_children` on the new pool or accept it deliberately. |
| `reboot` | A kernel update is waiting and nothing will apply it but you. See "Rebooting hetzner" below. |

## Rebooting hetzner

The `reboot` check WARNs at 7 days pending (`REBOOT_WARN_D=7`). Nothing clears
it automatically — `unattended-upgrades` has `Automatic-Reboot` commented out
deliberately, so the box never reboots itself under traffic.

**Order matters, and it is decided by one question: is a kernel, libc or
systemd update also pending?**

```
apt list --upgradable 2>/dev/null | grep -E 'linux-image|linux-generic|libc6|systemd'
```

- **Nothing returned** → reboot **first**, patch after. The reboot is then the
  only variable, so if a site comes back wrong you know exactly what caused it.
  None of the remaining updates will ask for a second reboot.
- **Something returned** → patch first, then one reboot covers everything.

### The procedure

Baseline first — this is the comparison that makes the verification meaningful.
All sites must be captured *before* the reboot. Note the `--resolve`: curl from
the box to a public hostname gets a 403 from the Cloudflare edge, so the origin
must be addressed directly.

```
for d in ayatalquran.com dotaim.com grand-emerald.com hirement.com \
         lamarkazia.com lebanese.tech menamaps.com nidaldirani.com \
         nizonet.com sasf-ksa.com skinosis.com videotizer.com \
         mardini.net singlefunction.com webmasterish.com \
         analytics.dotaim.com memories.mardini.net; do
  printf '%-26s %s\n' "$d" \
    "$(curl -k -s -o /dev/null -w '%{http_code}' \
        --resolve "$d:443:127.0.0.1" --max-time 15 "https://$d/")"
done
```

Expected: 16 × `200`, and `memories.mardini.net` → `302`. That 302 is its
normal state, not a fault.

Then check Redis before restarting it. It holds ~500k keys, but they are
WordPress object-cache entries (`<site>_wp:post-queries:*`) with RDB
persistence on and AOF off — regenerable, and saved on clean shutdown. Confirm
that is still what is in there rather than assuming:

```
sudo redis-cli -n 1 --scan --count 200 | head -5
sudo redis-cli info persistence | grep -E 'aof_enabled|rdb_last_save_time'
```

Reboot, then re-run the same baseline loop and compare. Also confirm:

```
test -f /var/run/reboot-required && echo STILL PENDING || echo CLEARED
systemctl --failed
sudo /home/webmasterish/server_ops/scripts/health-check.sh
```

Downtime measured on 2026-08-30 was **under a minute** — SSH answered on the
first 10-second poll.

### Two results that look alarming and are not

- **`systemctl is-enabled ssh` returns `disabled`.** Correct on 24.04.
  SSH is socket-activated: `ssh.socket` is enabled, `ssh.service` is not.
  Check `ssh.socket` before concluding you are about to lock yourself out.
- **`mariadb` is `not-found`.** The database is MySQL 8.0.46 —
  `mysql.service`. The MariaDB names in this repo refer to *Hostinger's*
  engine, which is what `scripts/sanitize-mariadb-dump.sh` converts **from**.
