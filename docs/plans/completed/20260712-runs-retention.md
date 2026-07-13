---
repo: crosscut
status: done
depends_on: []
feature_id: runs-retention
---
# Runs retention + always-persisted runs_dir

**Goal:** Persist `executor_options.runs_dir` into the config at init, and add
`executor_options.runs_retention_days` (int, default `0`) that governs when executor run
records under `runs_dir` are pruned — `0` deletes a plan's runs once it reaches `done`
(successful merge); `>0` keeps runs for that many days before a time-based sweep removes
them.

**Context:** `skills/crosscut/scripts/config-mutate.sh` (`set-global`: two new
first-class flags), `skills/crosscut/scripts/prune-runs.sh` (NEW — the prune engine),
`skills/crosscut/scripts/lib/config.sh` (reuse `_crosscut_pid_alive` for the liveness
guard; runs_dir resolution matches `run-executor.sh`), `skills/crosscut/SKILL.md`
(init step 4 writes both keys; Phase 6 event-prune; reconcile time-sweep; `executor_options`
docs), `skills/crosscut/templates/crosscut.config.example.yaml`,
`docs/configuration.md`, `tests/` (`config-mutate.bats`, new `prune-runs.bats`). No
`depends_on` — the P1 config foundation and P4 lock helpers this builds on are already in
`main`.

**Design (locked before authoring):**
- **Placement:** both keys live under `executor_options` (they configure the run
  artifacts that `run-executor.sh` writes) — `executor_options.runs_dir` (string,
  default `~/.cache/crosscut-runs`) and `executor_options.runs_retention_days` (int,
  default `0`).
- **Retention semantics:**
  - `0` → **event-triggered** prune. When a plan reaches `done` (Phase 6 merge, or
    reconcile confirming a merged plan), delete `<runs_dir>/<repo>/<slug>/` — every
    `run_id` for that plan. The merge commit is the durable truth; the run bookkeeping is
    then obsolete.
  - `>0` → **time-triggered** sweep at activation/reconcile. Delete terminal run
    directories older than N days. Never delete a **live** run (a `running.json` whose
    owning process is still alive).
- **Never pruned:** failed/stalled runs younger than the window (kept for diagnosis).
  Under `0` they persist until their plan reaches `done`; if it never does, they remain —
  which is exactly "delete after *successful* execution", not "delete unconditionally".
- **Two entrypoints, one engine:** `prune-runs.sh --repo <name> --plan <slug>` (event
  prune of one plan's tree) and `prune-runs.sh --sweep` (age sweep across all repos).
- **`claude` executor safety:** the in-session `claude` kind writes no run dir, so
  event-prune for such a plan simply finds nothing — prune is idempotent (absent path →
  no-op, exit 0).
- **Never delete a non-run sibling (plan-review finding).** `run-executor.sh` keeps the
  codex worktree at `<runs_dir>/<repo>/<slug>/worktree` (line 187) and **preserves it on
  auto-commit failure** — recoverable work. Prune therefore only ever targets directories
  whose basename matches the strict run-id pattern `^[0-9]{8}T[0-9]{6}-[0-9]+$`
  (`RUN_ID = <UTCstamp>-<pid>`); `worktree` and any other sibling are never deletion
  candidates, in either mode.

### Task 1: config-mutate.sh — first-class `--runs-dir` / `--runs-retention-days` on `set-global`

In `cmd_set_global`, add both flags to the scalar-flag `case` so they parse a value, but
route them into `executor_options` (not top-level `cfg[f]`) — mirror how `git.*` and
`knowledge_base.*` are nested:
- Parse `--runs-dir <p>` → field `runs_dir`; `--runs-retention-days <n>` → field
  `runs_retention_days` (the existing `${flag#--}` → `${//-/_}` mapping already yields
  `runs_dir` / `runs_retention_days`).
- **Validation (before touching the target, non-zero + no write on failure):**
  `runs_retention_days` must be a **non-negative integer** (`>= 0`; `0` is valid — unlike
  `--max-parallel` which rejects `0`). Reject negatives and non-numeric input. Write it as
  a real YAML int. `runs_dir` must be a non-empty string.
- Apply into the `executor_options` mapping via the same nested-mapping pattern used for
  `git`/`knowledge_base` (create the mapping if absent; error, not silent overwrite, if a
  pre-existing `executor_options` is a non-mapping). This must compose with the existing
  `--executor-option KEY=VAL` pass-through in the same call (both land in
  `executor_options`; the first-class flags win on key collision, applied after the
  pass-through `merge_opts`). Preserve `repos[]` and every other key; keep the write
  atomic.
- Update `_usage` to list `[--runs-dir <p>] [--runs-retention-days <n>]` under
  `set-global`.

### Task 1 tests

`tests/config-mutate.bats`: `set-global --runs-dir <p>` writes `executor_options.runs_dir`;
`--runs-retention-days 7` writes the int `7` (a YAML integer, not `"7"`);
`--runs-retention-days 0` writes `0`; a **negative** or **non-integer** value is rejected
and the file is unchanged (atomic); both flags in one call with an unrelated
`--executor-option foo=bar` preserve `foo` and all of `repos[]`; a re-run updates in place;
a pre-existing non-mapping `executor_options` is an error.

### Task 2: prune-runs.sh (NEW) — the prune engine

New executable `skills/crosscut/scripts/prune-runs.sh` (bash; sources `lib/config.sh`
and **reuses its helpers** — `_crosscut_runs_dir` for the `~`-expanded runs-dir base and
`_crosscut_pid_alive` for liveness; do not duplicate that logic). Read `RETENTION` = `cfg_get
executor_options.runs_retention_days 0` and **validate it at runtime, before any
filesystem traversal**: it must be a non-negative integer (`>= 0`); a non-integer or
negative value (e.g. a hand-edited config) is refused with a non-zero exit and **no**
deletion (`set-global` validates too, but the destructive script must not trust the
config). Resolve `RUNS_DIR` via `_crosscut_runs_dir`; refuse to run if it is empty, `/`, or
`.`.

A directory is a **run dir** only when its basename matches the run-id pattern
`^[0-9]{8}T[0-9]{6}-[0-9]+$` (`run-executor.sh` `RUN_ID` = `<UTCstamp>-<pid>`). This guard
is what keeps prune from ever touching the codex `worktree` sibling (line 187, preserved on
failure) or any other non-run entry. Two modes:
- `--repo <name> --plan <slug>` — **event prune**: delete every **run-id-matching** child
  of `<RUNS_DIR>/<repo>/<slug>/`, leaving a `worktree` (or any non-matching) sibling
  untouched; then remove the `<slug>` dir itself only if it is now empty. Idempotent
  (absent tree → exit 0). **Destructive-path hardening (plan-review finding):** reject a
  `repo` or `slug` that is empty/whitespace, equals `.` or `..`, or contains `/` or a
  traversal component; build the target `<RUNS_DIR>/<repo>/<slug>`, normalize it
  (realpath-style), and refuse unless it is **strictly under** the normalized `RUNS_DIR`.
  Only then delete. Ignores `RETENTION` (Phase 6 invokes this only when `RETENTION == 0`).
- `--sweep` — **age sweep**: no-op (exit 0) when `RETENTION == 0`. When `RETENTION > 0`,
  walk every `<RUNS_DIR>/<repo>/<slug>/` and, for each child whose basename matches the
  run-id pattern, delete it iff it is **older than RETENTION days AND not live**. Compute
  "older than" from the dir's `os.stat().st_mtime` in an embedded **`python3`** block
  (avoid `find -mtime` / `stat` flag differences across macOS/Linux). "Live" = a
  `running.json` present, **no** terminal `run.json` sibling, and the PID parsed from the
  run-id basename still alive via `_crosscut_pid_alive`; a live run is kept regardless of age.
  `worktree` and any non-matching sibling are never candidates.
- `--dry-run` (and `EXECUTOR_DRYRUN=1`): print each dir that *would* be removed, delete
  nothing, exit 0. Emit a one-line summary (`pruned N run dir(s)` / `would prune N`) so
  SKILL/reconcile can surface it.

Structure: bash parses args and calls the `_crosscut_*` helpers; the age/liveness/mtime and
path-normalization logic lives in an embedded `python3` block (same style as `config.sh`)
for portable `st_mtime` handling.

### Task 2 tests

`tests/prune-runs.bats` (build the tree by hand under a temp `runs_dir`, point config at it
via `CROSSCUT_CONFIG`; back-date dirs with Python `os.utime`, not `touch -t`):
- `--repo r --plan s` removes `<runs>/r/s/`'s run-id dirs and nothing else; a second call on
  the now-absent tree exits `0` (idempotent);
- a sibling **`worktree`** dir under `<runs>/r/s/` is **NOT** deleted by event-prune nor by
  sweep (the run-id-pattern guard);
- **path safety:** `--repo`/`--plan` containing `/`, `..`, `.`, or empty is rejected with
  no deletion; a `runs_dir` of `/` or `.` is refused;
- a basename that does not match the run-id pattern (e.g. `worktree`, `garbage`) is ignored
  by the sweep;
- with `runs_retention_days=0`, `--sweep` is a no-op; with `=7`, a run dir back-dated 10
  days (terminal `run.json`) is swept while one back-dated 2 days is kept;
- a 10-day-old dir with `running.json` and **no** `run.json`, PID **alive** (`$$`), is
  **kept**; the same with a **dead** PID is swept; a 10-day-old dir with **both**
  `running.json` and a terminal `run.json` is not-live → swept;
- an invalid hand-written `runs_retention_days` (non-integer / negative) makes `--sweep`
  refuse with non-zero exit and no deletion;
- `--dry-run` / `EXECUTOR_DRYRUN=1` deletes nothing and lists the candidates.

### Task 3: SKILL.md — wire prune into the lifecycle + init

- **init step 4 (first run):** the `set-global` call always appends
  `--runs-dir ~/.cache/crosscut-runs --runs-retention-days 0`, so the config records
  both from the start (no new interview question). Document the two keys in the same edit
  where `executor_options` is described.
- **Phase 6 (Finalize):** after a plan is set `done` and merged, if
  `cfg_get executor_options.runs_retention_days 0` == `0`, run
  `prune-runs.sh --repo <name> --plan <slug>` to delete that plan's runs (idempotent; a
  `claude`-executed plan has no run dir → no-op). State it stays out of the merge's
  critical path (a prune failure is logged, never blocks `done`).
- **Reconcile at activation:** after status is settled and stale locks reclaimed, if
  `runs_retention_days > 0` run `prune-runs.sh --sweep` once (time GC across all repos). If
  `runs_retention_days == 0`, event-prune the runs of **every** plan reconcile resolves as
  `done` that still has a run tree — **not only** plans whose status *changed* to `done`
  this pass — so a plan already `done` from a prior session is cleaned too (idempotent, via
  the `--repo/--plan` entrypoint; plan-review finding). The sweep never touches a live run
  or a preserved `worktree`.
- **`executor_options` docs block in SKILL.md:** add `runs_dir` and
  `runs_retention_days` (with the `0` = delete-on-done, `>0` = keep-N-days semantics)
  next to the existing options.

### Task 4: Docs + example template

- `skills/crosscut/templates/crosscut.config.example.yaml`: under
  `executor_options`, add `runs_dir: ~/.cache/crosscut-runs` and
  `runs_retention_days: 0` with comments spelling out both behaviors.
- `docs/configuration.md`: document both keys — placement under `executor_options`,
  defaults, the `0` vs `>0` semantics, and which phase performs each prune (Phase 6
  event-prune, reconcile sweep). Note that failed/stalled runs are retained for
  diagnosis.
- `bats tests/` stays 100% green (the two new-key rows must not break existing
  `config.bats`/`run-executor.bats` expectations).
