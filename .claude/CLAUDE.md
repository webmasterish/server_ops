# server_ops

Infrastructure and server-management repo for DotAim. Scripts, Apache
templates, runbooks, and server inventory. Not a web project — nothing
here is served.

## Machines

- `hetzner` — Hetzner CPX21 (3 vCPU / 4GB RAM / 80GB SSD), Ubuntu 24.04.
  **The only server.** Daily provider snapshots (7-day retention), plus
  nightly restic backups to Cloudflare R2 — see `docs/runbook-backups.md`.

Reachable via the SSH alias in `~/.ssh/config`. Always use the alias — never
an inline host, user, or plaintext secret of any kind.

```
ssh webmasterish@hetzner-dotaim
```

Hostinger is **gone**. The account is closed, the migration is finished, and
everything worth keeping was backed up before it went. There is nothing left
to do with it and no reason to reference it in new work. Mailboxes were
explicitly abandoned — that was a deliberate decision, not an oversight, so
do not resurface it as an open item. Historical detail is in
`migration/status.md` and `docs/inventory.md`, both closed.

## Current objective

Run and improve `hetzner`. All 15 sites are live on it. Mostly low-traffic
static HTML and WordPress, plain Apache + PHP with no hosting control panel,
provisioned by the scripts in this repo. Apache is the deliberate choice: it
matches the local dev environment.

Day-to-day this means keeping the estate healthy rather than moving it:
`health-check.timer` reports daily and `review-reminder.timer` prompts the
monthly review and quarterly restore drill. Start at
`docs/runbook-health-checks.md`.

## Conventions

- Server docroots: `/var/www/vhosts/<group>/<domain>/httpdocs` (e.g.
  `/var/www/vhosts/dotaim/grand-emerald.com/httpdocs`) — mirrors the
  local layout at `/media/data2/www/localhost/subs/<project>/httpdocs`.
  Each site also has `config/` (vhost.conf, vhost-ssl.conf, symlinked
  into `/etc/apache2/sites-enabled/`) and `logs/` alongside `httpdocs`.
- One PHP-FPM pool per site. Sized deliberately against traffic, not one
  number everywhere — `scripts/tune-fpm-pools.sh` holds the sizing and the
  reasoning. Keep `sum(pm.max_children)` under RAM+swap.
- WordPress lives at `<docroot>/cms/`, not at the docroot. All ten installs
  follow this. It is load-bearing for the origin probe blocks in
  `templates/block-wp-probes.conf` — check before breaking the pattern.
- Certs via certbot. WordPress managed with wp-cli.
- All sites sit behind Cloudflare. Two consequences worth remembering: origin
  firewall rules cannot ban a real client (the packets arrive from
  Cloudflare), and `curl` from the box to a public hostname may return 403
  from the edge while the origin is fine — test with
  `curl -k --resolve <domain>:443:127.0.0.1`.
- **There is no MTA and no SMTP relay on the server.** An earlier version of
  this file claimed outbound WordPress mail went through a relay; that was
  never true. `msmtp` is installed for alerting only and is not wired to
  WordPress. If a site ever needs to send mail, that is a project, not a
  setting.

## Layout

- `scripts/` — provisioning, backup, monitoring scripts
- `templates/` — Apache vhost, PHP pool, systemd units
- `docs/` — inventory.md, runbooks
- `migration/` — closed. Historical record of the Hostinger migration.

## Rules

- Never print, echo, or write credentials into files, logs, or output.
- Credentials live at `/media/data2/www/sites/DotAim.com/Hosting/` in
  plaintext. That path is OUT OF SCOPE — do not read it. Auth to the server
  is via SSH keys; nothing here needs a password.
- WordPress DB credentials: read from each site's `wp-config.php` on the
  server at the moment they're needed. Never copy them into this repo.
- Never commit database dumps or site archives.
- The ntfy alert topic in `/etc/health-check/notify` is a credential. Read it
  on the server when needed; never echo it into output or this repo.
- On `hetzner`: no destructive command (rm, DROP, service disable,
  config overwrite) without showing it to me first. Back up any config
  file before editing it.
- Prefer idempotent scripts over one-off commands, so they're reusable
  for the next site.
