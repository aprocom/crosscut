# Contributing

## Dev setup

Requirements: `python3` + PyYAML (`pip install pyyaml`), and [`bats`](https://github.com/bats-core/bats-core)
for running the test suite.

```bash
git clone <this-repo-url> ~/path/to/crosscut
cd ~/path/to/crosscut
bats tests/
```

All suites (`tests/*.bats`) must pass before opening a PR. Tests are self-contained —
they build fixtures at runtime (see `tests/fixtures/`) rather than depending on any
machine-specific state.

## The publication scrub gate

Before any PR or publish, the whole tree must pass the no-PII gate:

```bash
git add -A
bash skills/crosscut/scripts/lib/check-no-pii.sh .
```

This scans every **git-tracked** file (`git grep --cached`, so run it after
`git add`) for personal paths and origin markers that must never appear in this
public repo — real home-directory paths, machine-specific identifiers, and similar.

The forbidden-pattern list is split in two so the public repo never ships the very
literals it is meant to scrub:

- **`skills/crosscut/scripts/lib/pii-patterns.txt`** — git-tracked, holds only
  **generic shape patterns** (e.g. `/Users/[a-z]`), safe to publish.
- **`pii-patterns.local.txt`** (beside that file) and/or the file named by
  **`$CROSSCUT_PII_EXTRA`** — a git-ignored **private overlay** for
  machine-/project-specific literals. `check-no-pii.sh` loads it in addition to the
  tracked list when present, so your local gate stays fully strict while the
  literals themselves never enter the repo. Keep your own machine's markers here.

If the gate flags a match: **fix the offending file** — rewrite the example as
`~/...` or `/path/to/...`, remove the leaked identifier, etc. Do not add an
exclusion for it. The one file excluded from the scan is the tracked pattern list
itself, since it necessarily contains the literal patterns it defines.

## Code style

- **Comments in code are English**, regardless of contributor.
- **Scripts self-locate.** Any script under `skills/crosscut/scripts/` resolves
  its own directory via `BASH_SOURCE` (see the existing scripts for the pattern) —
  never hardcode an install path or assume a fixed working directory.
- **No PII, ever** — no real home-directory paths, hostnames, usernames, or
  other machine-identifying strings in code, docs, tests, or fixtures. Use
  `~/...` or `/path/to/...` placeholders in every example. Test fixtures that need
  a match string for `check-no-pii.sh` build it at runtime instead of embedding it
  literally.
- **Commits carry no `Co-Authored-By` trailer.** This applies to contributions to
  this repo itself, and is also an invariant the skill enforces on the commits it
  makes autonomously — see `skills/crosscut/SKILL.md`.

## Before opening a PR

1. `bats tests/` — green.
2. `bash skills/crosscut/scripts/lib/check-no-pii.sh .` (after `git add -A`) — clean.
3. If you touched `docs/` or `skills/crosscut/SKILL.md`, check for now-inconsistent
   cross-references (flag names, file paths, config keys) between the two — `SKILL.md`
   is the operational summary and must never contradict `docs/DESIGN.md`.
