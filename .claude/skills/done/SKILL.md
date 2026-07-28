---
name: done
description: End-of-session wrap-up for the server_ops repo. Use when the user signals the session is finished — "/done", "we're done", "let's wrap this", "that's it", "wrap up", or anything similar (judge by intent, not exact words). Persists memory + project docs, runs safety checks, commits only this session's files, pushes to GitHub, then writes and displays a session file in `__/sessions/`. Flags: no-commit / no-push / no-session / just-docs.
---

# End the session (`/done`)

One pass that closes a working session: persist what's durable, ship what's ready,
and leave the user a file they can read later or hand to the next session.

Runs **in order**. Each step reports what it did in one line; the detail goes in the
session file, not the chat.

This repo has **no deploy step** — nothing here is served (see `.claude/CLAUDE.md`).
Scripts in this repo *act on* servers; that happens during the session, deliberately,
never as part of a wrap-up. `/done` never touches `hetzner` or `hostinger`.

---

## 0. Parse the flags — by INTENT, not exact spelling

Everything after `/done` is freeform. Match on meaning:

| Intent | Recognise (any of) | Effect |
|---|---|---|
| skip commit | `no commit`, `no-commit`, `nocommit`, `skip commit`, `don't commit`, `without committing` | No commit. Implies no GitHub push (nothing to push). |
| skip GitHub push | `no push`, `no-push`, `don't push`, `local only` | Commit, but don't `git push`. |
| skip session file | `no session`, `no-session`, `no file` | Skip steps 6-7. |
| persist only | bare `docs` / `notes` (when that word **is** the whole argument), plus `just docs`, `just-docs`, `docs only`, `docs-only`, `only docs`, `just notes`, `notes only`, `just save`, `just memory`, `no code` — and the same shapes with docs/notes swapped | Shorthand for **no-commit + no-push**. Runs steps 1-3 and 6-7 only: memory + project docs get written, nothing is committed or pushed. The session file records the changes as **not committed — `just-docs` run**, so the next session knows they're sitting uncommitted. |

Anything else in the argument is treated as a **note from the user** and goes into the
session file's summary (e.g. `/done no-push waiting on the menamaps backup to finish`).

**The one genuine ambiguity is a bare `docs` / `notes`** — it reads as the persist-only
flag, but `/done docs need a rewrite next time` is plainly a note. Rule: treat it as the
flag only when the word stands alone (or with a filler like "just"/"only"); if it opens a
sentence, it's a note. When it could honestly be either, **ask** — one question beats an
unwanted commit or a silently skipped one.

Ambiguous or unrecognised wording → ask, don't guess.

## 1. Guard — is anything still in flight?

Before touching anything: if a background task, subagent, or long-running command is
still going, **stop and say so**. Don't wrap a session whose work hasn't landed.

This repo's specific case: **migration transfers**. An `rsync`, `scp`, `mysqldump` or
backup script against `hostinger` or `hetzner` can run for hours. Check for running
background shells before wrapping. A session file that says "backup complete" when the
transfer is at 60% is worse than no session file.

If a transfer is mid-flight, either wait, or wrap with the session file explicitly
recording **what was still running and how to check on it**.

## 2. Persist — memory, then project docs

1. **Memory** (`~/.claude/projects/-media-data2-www-server-ops-repo/memory/`) — add or
   update memories for anything **durable and non-obvious** that surfaced: user
   preferences / working-style feedback (with the *why*), project state, decisions,
   constraints not derivable from the code or git history, useful external references.
   Update an existing memory rather than duplicating; keep the `MEMORY.md` index line
   in sync.
   **Skip** anything the repo already records (code structure, past fixes, git history,
   CLAUDE.md) or that only mattered to this conversation.
2. **Project docs** — this repo's docs *are* the deliverable, more than its code is.
   If the session changed what we know about either server, update the relevant file:
   - `docs/inventory.md` — server state, site facts, blockers, migration order.
     Anything discovered by inspecting a server belongs here, not just in the chat.
   - `docs/` runbooks — if a procedure was worked out, write it down so it's repeatable.
   - `migration/` — working notes and logs for the Hostinger migration.
   - `.claude/CLAUDE.md` — only for conventions and standing rules. If reality was found
     to contradict CLAUDE.md, **fix CLAUDE.md** rather than leaving the contradiction
     (this has already happened once, with nginx vs Apache).

Quality over volume. A wrong or noisy memory is worse than none — if it's genuinely
borderline, ask instead of guessing.

Do this **first**: it creates files that step 4 must commit.

## 3. Pre-flight checks

Only on files this session changed. These exist because of this repo's standing rules.

1. **Credential scan — the one that matters most.** `.claude/CLAUDE.md` forbids writing
   credentials into files, logs or output. Before committing, scan every changed file
   for anything that reads as a live secret — credentials pulled from a
   `wp-config.php` or `.env`, private keys, connection strings with auth embedded.
   **Anything found blocks the commit — stop and tell the user.**
   Note that database *names* and *users* are fine and expected in the inventory;
   live credential values are not.

   A `pre-commit` hook in `.git/hooks/` enforces this independently. It flags a
   keyword followed by `:` or `=`, so ordinary prose can trip it — if that happens,
   reword rather than reaching for `--no-verify`, and only override once you have
   read the diff and confirmed it is prose.
2. **No dumps or archives staged.** `*.sql`, `*.sql.gz`, `*.tar`, `*.tar.gz`, `*.zip`,
   `backups/` are gitignored, but check nothing slipped through with `git add -f` or a
   renamed extension. Never commit a database dump or site archive.
3. **No `__*` paths staged** — local-only by convention and gitignored. If one shows up
   as tracked, stop and flag it.
4. **`bash -n`** on every changed `.sh` file. A syntax error in a provisioning or backup
   script must never be the thing you discover mid-migration.
5. **Idempotency sanity check** — if a script under `scripts/` was added or changed, does
   re-running it do the right thing? CLAUDE.md prefers idempotent scripts over one-off
   commands. Not a hard gate; note it in the session file if it's not idempotent yet.

## 4. Commit — only this session's files

**Hard rule: stage by explicit path. Never `git add -A`, `git add .`, or `git commit -a`.**

The user often has more than one session open. Committing a foreign session's
work-in-progress is the failure mode this step exists to prevent.

1. `git status --short` and compare against the files **this session actually edited**.
2. Stage only this session's paths.
3. Any *other* dirty file: leave it alone and **list it in the reply** as
   "left alone (not this session's)". Don't ask about it, just report it.
4. If a file this session touched contains changes you don't recognise, **stop and ask**
   — that's the concurrent-edit case and it can't be resolved by guessing.
5. Commit on `main` (no branches, no PRs), using conventional-commit style:
   `type(scope): imperative summary`, e.g.
   `docs(inventory): drop woo.lushlebanon from migration scope`.
   Useful scopes here: `inventory`, `dns`, `hetzner`, `hostinger`, `backup`, `migration`,
   `scripts`, `templates`, `skills`. Body only when the *why* isn't obvious from the
   summary. Keep the `Co-Authored-By` trailer.
6. Separate concerns → separate commits. Don't force one commit over unrelated work.
7. Nothing to commit → say so and move on. Not an error.

**Residual risk, stated honestly:** if another session edited a file *this* session also
edited, its changes ride along in the commit. There is no way to detect that from the
working tree. Flag anything that looks off rather than committing silently.

## 5. Push

- `git push` to `origin` (branch `main`). Report the result.
- There is no deploy step in this repo. If the session's work needs to be *applied* to a
  server, that is a deliberate action taken during a session — put the exact command in
  the session file's "needs doing" section instead of running it here.

## 6. Write the session file

Path: `__/sessions/session_YYYY-MM-DD.md` — same day already exists → `_2`, `_3`, …
(`__*` is gitignored; these files are the user's, not the repo's.)

Write it **after** the commit so it can record the sha. Aim for 50-90 lines. It should be
readable cold, weeks later, by someone who wasn't here.

```markdown
# Session — YYYY-MM-DD[ _N]

**Focus:** one line — what this session was about.

## What was done
- Short bullets. Outcomes, not narration.

## Decisions
- The call, and the *why*. This is the part worth re-reading in a month.
- Include rejected options where the rejection is the useful bit.

## Server state touched
- `hetzner` / `hostinger` — what was inspected or changed, and whether it was
  read-only. Say plainly if a server was modified.
- Omit this section entirely if no server was touched.

## Changes
- `path/to/file.md` — what changed, one clause.
- **Commit:** `<sha>` `type(scope): summary`  (or "not committed — <reason>")
- **Pushed:** yes / no / FAILED — <error>

## Open / deferred
- What's unfinished, and why it was left.

## Needs doing elsewhere
- Commands to run against a server, things to do in hPanel / Cloudflare / GoDaddy,
  anything waiting on a person. Exact commands in a code block, copy-pasteable.

## Deadline watch
- Only while the Hostinger migration is live. Days remaining to 2026-07-31, and
  which of the two hard items (verified backups / DNS off Hostinger NS) are done.
- Drop this section once both are complete.

## Saved to memory / docs
- `memory/<file>.md` — one line on what it records.
- `docs/<file>.md` — section updated.

## Pick up from here

​```
<A ready-to-paste prompt for the next session: the goal, where things stand,
the files that matter, and the first concrete step. Written as an instruction
to Claude, not a description of the past.>
​```
```

Omit any section that would be empty — an empty "Open / deferred" is noise.
Follow the house formatting rules: **no markdown blockquotes** anywhere (the `▎` gutter
breaks copy-paste), copyable content in code blocks.

## 7. Display it

Print the session file's content in the reply so the user can read it without opening
the file. Then a short closing line: path, commit sha, push status.

Keep the chat reply itself to a few lines beyond the file — the file *is* the summary.

---

## Notes

- `/done` is a standing instruction to push. It does **not** authorise touching a server:
  the read-only rule on `hostinger` and the show-me-first rule on `hetzner` both still
  apply, and `/done` never runs a command against either.
- It's fine to run mid-session as a checkpoint. It does **not** replace saving an
  important fact the moment it appears.
- While the migration is active, the most valuable thing this skill produces is the
  **deadline watch** and **needs doing elsewhere** sections — several required steps
  (hPanel cron export, Cloudflare zone moves) can only be done by a person, and they are
  easy to lose track of between sessions.
