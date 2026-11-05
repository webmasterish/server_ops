# Outbound mail for sites — open project

**Status (2026-11-05): parked, direction chosen, nothing built.** The owner
leans towards one server-wide Brevo relay and will pick this up in a later
session. Nothing on `hetzner` has been changed for this yet.

## The problem

No site on `hetzner` can send mail through PHP. Password resets from Piwigo
(`memories.mardini.net`), and from any WordPress site without an SMTP plugin,
are silently dropped.

Not "fails most of the time" — **fails every time**: PHP `mail()` pipes to
`/usr/sbin/sendmail`, which does not exist. No MTA is installed and no
`sendmail_path` is set for PHP 7.4, 8.3 or 8.5. `msmtp` is installed, but only
for alerting (`/etc/msmtprc`, 0600 root, placeholders) — see
`runbook-health-checks.md`, "The notify hook".

Some WordPress sites work around this today with per-site SMTP plugins (Brevo
or Mailgun). The goal is to stop configuring mail per site.

## Options evaluated

### Chosen direction: one server-wide relay via msmtp → Brevo

- A separate config, e.g. `/etc/msmtp-web.conf`, readable by `www-data`
  (0640 root:www-data). The alerting `/etc/msmtprc` stays root-only and
  untouched.
- One line per FPM pool, and in the pool template so new sites inherit it:
  `php_admin_value[sendmail_path] = "/usr/bin/msmtp -C /etc/msmtp-web.conf -t"`
- Submission on port **587** (open from hetzner; 25 and 465 are blocked).
- Brevo free tier: 300 emails/day across the whole account — ample for
  password resets and contact forms. SMTP2GO (1,000/month free) is the
  fallback provider.
- Per-site WordPress SMTP plugins keep working and can be retired later.
- Accepted trade-off: every site runs as `www-data`, so every site can read
  the relay key. Mitigated by using a dedicated, revocable SMTP key.

**Brevo account:** one account for all of DotAim, under a dotaim.com role
address (Google Workspace), not a personal one — `accounts@dotaim.com`, or a
group/alias such as `hosting@dotaim.com`. Brevo refuses free-mail sign-ups.
If the WordPress sites' existing Brevo setup already lives under a dotaim.com
address, reuse that account rather than opening a second. Enable 2FA (the
account can send as every client domain). Create a dedicated SMTP key named
for the server (e.g. `hetzner-server`); the owner pastes it into the config
on the server — it must never pass through a transcript or this repo.

**Per domain, unavoidable with any provider:** verify the domain in Brevo —
SPF include + DKIM records in Cloudflare DNS. For dotaim.com, merge into the
existing Google Workspace SPF record; never add a second SPF record.

### Rejected: self-hosted send-only Postfix (no third party)

The owner's first preference; rejected 2026-11-05 as too complicated and too
unreliable. Findings from the server that day:

| Check | Result |
|---|---|
| Outbound 25 | Blocked (Hetzner default; lifted on request via support ticket) |
| Outbound 465 | Blocked |
| Outbound 587 | Open (`smtp.gmail.com:587` answers) |
| IPv4 PTR | Hetzner generic `static.….clients.your-server.de` — would need `mail.dotaim.com` set in the Hetzner console, A record **DNS only (grey cloud)** |
| Barracuda RBL | IPv4 **listed** (common for Hetzner ranges; free delisting form) |
| Spamhaus | Inconclusive — Spamhaus refuses queries via public resolvers |

It would also need Postfix + OpenDKIM, per-domain SPF/DKIM/DMARC, and a
mail-queue check in `health-check`, and Outlook/Hotmail would still likely
junk mail from a new VPS IP. Possible later hybrid: Postfix direct with a
relay fallback — only if the relay path ever becomes a problem.

### Rejected: Google Workspace SMTP relay

Covers dotaim.com only, not the client domains; needs Workspace admin
changes, and App Passwords are already blocked on that account.

## Plan when resumed

1. Owner: create/confirm the Brevo account (see above), enable 2FA, create the
   `hetzner-server` SMTP key, verify `mardini.net` as the first sender domain.
2. Claude: write an idempotent script — `/etc/msmtp-web.conf` with a key
   placeholder, the `sendmail_path` line per pool and in the pool template.
   Show it before anything runs on hetzner.
3. Owner: paste the key into the config on the server; apply the pool changes
   and reload PHP-FPM (live config changes are the owner's to run).
4. Test: Piwigo password reset on `memories.mardini.net`.
5. Verify the remaining sender domains in Brevo as needed, one at a time.
6. Consider a `health-check` assertion that the relay config has no
   placeholder left and that msmtp can reach port 587.
