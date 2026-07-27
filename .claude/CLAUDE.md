# server_ops

Infrastructure and server-management repo for DotAim. Scripts, Apache
templates, runbooks, and server inventory. Not a web project — nothing
here is served.

## Machines

- `hetzner` — Hetzner CPX21 (3 vCPU / 4GB RAM / 80GB SSD), Ubuntu.
  Primary server. Daily provider snapshots, 7-day retention.
- `hostinger` — Hostinger Business shared plan. Plan expires 2026-08-01.
  Being decommissioned.

Both reachable via SSH aliases in `~/.ssh/config`. Use the alias, never
an inline host, user, or password.
To ssh into Hetzner use `ssh webmasterish@hetzner-dotaim`,
and for Hostinger use `ssh u918436082@hostinger`

## Current objective

Migrate all sites off `hostinger` onto `hetzner` before the plan lapses.
Mostly low-traffic static HTML and WordPress. No hosting control panel —
plain Apache + PHP, provisioned by scripts in this repo. Apache is the
deliberate choice: it matches the local dev environment.

Hard deadline is NOT the migration itself. By 2026-07-31 we need:
complete verified backups of everything on Hostinger, and DNS moved off
Hostinger nameservers. With those two done, the rest can proceed calmly.

Two items to resolve before anything else:
1. Which domains use Hostinger nameservers → move those zones to Cloudflare.
2. Which domains have live Hostinger mailboxes → mail is NOT in a hosting
   backup and breaks on cutover. Resolve before touching DNS.

## Conventions

- Server docroots: `/var/www/<domain>/httpdocs` — mirrors the local
  layout at `/media/data2/www/localhost/subs/<project>/httpdocs`.
- One PHP-FPM pool per site.
- Certs via certbot. WordPress managed with wp-cli.
- Outbound WordPress mail goes through an SMTP relay, never the VPS
  directly.

## Layout

- `scripts/` — provisioning, backup, migration scripts
- `templates/` — Apache vhost, PHP pool, systemd units
- `docs/` — inventory.md, runbooks
- `migration/` — working notes and logs for the Hostinger migration

## Rules

- Never print, echo, or write credentials into files, logs, or output.
- Credentials live at `/media/data2/www/sites/DotAim.com/Hosting/` in
  plaintext. That path is OUT OF SCOPE — do not read it. Auth to both
  servers is via SSH keys; nothing here needs a password.
- WordPress DB credentials: read from each site's `wp-config.php` on the
  server at the moment they're needed. Never copy them into this repo.
- Never commit database dumps or site archives.
- On `hostinger`: read-only until migration is verified complete.
- On `hetzner`: no destructive command (rm, DROP, service disable,
  config overwrite) without showing it to me first. Back up any config
  file before editing it.
- Prefer idempotent scripts over one-off commands, so they're reusable
  for the next site.
