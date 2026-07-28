# Git hooks

Version-controlled hooks. They live here rather than in `.git/hooks/` so they
survive a fresh clone and can be reviewed like any other code.

## Activating (once per clone)

```bash
git config core.hooksPath scripts/hooks
```

`core.hooksPath` is local git config, not something a commit can carry — so
each clone has to run that line once. If the hooks ever seem inactive, check it:

```bash
git config core.hooksPath   # should print: scripts/hooks
```

## `pre-commit`

Blocks commits that look like they carry live credentials, backing the standing
rule in `.claude/CLAUDE.md` that credentials never get written into files, logs
or output.

Two deliberate design choices, both learned the hard way:

- **It scans added lines only.** The original version scanned the whole diff,
  which meant a flagged line could not even be *removed* without
  `--no-verify` — the deletion re-tripped the hook.
- **The pattern requires a `:` or `=` after the keyword.** This matches an
  assignment, not every prose mention of the word. Without it the hook fires
  constantly on documentation, and a hook that cries wolf gets overridden
  reflexively, which is worse than no hook.

If it fires on prose, reword the prose. Reach for `--no-verify` only after
reading the diff and confirming there is no real value in it — and say so in
the commit message when you do.
