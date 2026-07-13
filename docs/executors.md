# Executors reference

The executor is the module that actually writes code: given a validated plan file, it
produces a branch of commits (`<slug>`) inside an isolated git worktree. The `executor`
config scalar selects one of **three kinds**:

| kind | how it runs | requirement | dispatched by |
|------|-------------|-------------|---------------|
| `ralphex` (default) | containerized coding-agent runner | **Docker** | `run-executor.sh` (external) |
| `codex` | `codex exec --sandbox workspace-write` in a host git worktree | the **`codex` CLI** | `run-executor.sh` (external) |
| `claude` | in-session Claude Code subagent | **neither Docker nor a CLI** | the orchestrator, **in-session** |

There are **two dispatch layers**: `ralphex` and `codex` are external processes launched
by `skills/crosscut/scripts/run-executor.sh`; `claude` runs in-session, driven by the
orchestrator itself (it is *not* routed through `run-executor.sh`). All three isolate
their work on branch `<slug>` and leave it unmerged — merging is the orchestrator's job
(see [Finalization](#finalization-orchestrator-owned)).

There is no on/off config toggle — Phase 4 runs an executor every time. When you'd
rather implement a plan by hand — or when the chosen kind can't run (`ralphex` without
Docker, `codex` without the CLI, `claude` with no subagent capability) — the
methodology's *manual-run* fallback covers it (see [Manual-run](#manual-run-implementing-a-plan-by-hand)
below); `/crosscut` never fails just because you skip an automated run.

## The reference executor: ralphex

The reference implementation is [`ralphex`](https://github.com/umputun/ralphex),
distributed as a container image, `ghcr.io/umputun/ralphex:latest`
(`executor_options.image` in config). It is invoked as
`<binary> [OPTIONS] [plan-file]`, taking the plan file as its positional argument.
Relevant flags this plugin relies on:

- `--worktree` — run inside an isolated git worktree + a branch named after the plan
  file. Always passed by the adapter (see Invariants in `SKILL.md`).
- `--branch <slug>` — pin the branch name explicitly. Always passed — without it,
  some executor versions strip the date prefix off the plan filename and the
  resulting branch name becomes unpredictable.
- `--idle-timeout <duration>` — the container's own idle cutoff.

Requirements:
- **Docker** must be installed and reachable from wherever `run-executor.sh` runs
  (it shells out to `docker run`). `/crosscut init` checks for `docker`, but only
  warns — it doesn't hard-block — if it's missing, since Docker is needed only when a
  plan is actually executed (a manual-run needs none).
- The image (`executor_options.image`) must be pullable — `docker run --rm ... "$IMAGE" ...`
  will pull it implicitly if it isn't already local.

## The adapter script (`ralphex` / `codex`)

`skills/crosscut/scripts/run-executor.sh` is the external-process adapter: it drives
both the `ralphex` and `codex` executor kinds (dispatching on the `executor` scalar) and
produces a machine-readable result (`run.json`) the orchestrator uses to decide
success/fail/stalled, instead of parsing human-oriented log text. It is not a thin
passthrough — a reference executor's own default CLI wrapper commonly assumes an
interactive terminal, so the adapter invokes the underlying container/binary directly.

```
run-executor.sh --repo <name> --plan <relative-path> [extra args...]
```

Dispatch: it reads `executor` (`cfg_get executor ralphex`) and routes — `ralphex` → the
Docker path (below), `codex` → the host git-worktree path (see [The `codex`
executor](#the-codex-executor)). `executor: claude` exits 2 (that kind is dispatched
in-session, not here); any unknown value exits 2 (messages below).

What it does for the `ralphex` (Docker) kind, in order:
1. Resolves `<name>`'s absolute path via `cfg_repo_field <name> path`; exits 2 if
   the repo is unknown, its directory doesn't exist, or the plan file doesn't exist
   under it.
2. If the repo declares `venv_isolation: true`, creates and mounts
   `<executor_options.venv_cache>/<repo>` at `/project/.venv` in the container (keeps
   the executor's own virtualenv isolated from the host's).
3. Adds any `executor_options.mounts` entries as extra `-v` mounts (with a leading `~`
   expanded to `$HOME`).
4. Under `EXECUTOR_DRYRUN=1`, prints the assembled `docker run` command and exits
   here — none of the steps below run (see `EXECUTOR_DRYRUN` below).
5. Acquires the per-repo executor lock; if the repo already has an active executor it
   exits 1 without launching (see below). Otherwise it creates a run directory
   `<executor_options.runs_dir>/<repo>/<slug>/<run_id>/` (`<slug>` = the plan filename
   without `.md`; `<run_id>` = `<UTC-timestamp>-<pid>`) and writes `running.json`.
6. Runs `executor_options.pre_run_hook` if configured — **best-effort**: on failure it
   logs a warning to stderr and the run continues regardless.
7. Launches the container without an interactive TTY:
   ```
   docker run --rm -e APP_UID=<uid> -v <repo.path>:/project [venv mount] [extra mounts] \
     -w /project <executor_options.image> /srv/ralphex --worktree --branch <slug> \
     --idle-timeout <executor_options.idle_timeout> [extra CLI args passed to run-executor.sh] <plan>
   ```
8. Writes `executor.log` (stdout) and `stderr.log` (stderr) into the run directory.
9. Writes `run.json` on completion (contract below), then removes `running.json`.

### Dispatch and unimplemented-executor messages

Past the usual argument/repo/plan validation, `run-executor.sh` also declines to launch in
three dispatch cases — the first two exit 2, the third exits 1:

- `executor: claude` — that kind is run in-session by the orchestrator, not here:
  ```
  executor kind 'claude' is dispatched in-session, not by run-executor.sh
  ```
- any value that isn't `ralphex`, `codex`, or `claude` (a typo, an unsupported kind):
  ```
  executor kind '<x>' not implemented
  ```
- the repo already has an active executor — the per-repo executor lock is held, so the
  run is skipped without launching anything (no run directory, container, or worktree):
  ```
  run-executor: repo '<name>' already has an active executor; skipping
  ```

### `EXECUTOR_DRYRUN`

```bash
EXECUTOR_DRYRUN=1 bash run-executor.sh --repo backend --plan docs/plans/x.md
```

Prints the exact `docker run ...` command (shell-quoted) that would be executed and
exits 0 — no run directory is created, no container is launched, `running.json`/
`run.json` are not written. Useful for verifying image/mount/flag resolution without
spending a run. (For `executor: codex`, it prints the worktree path and the assembled
`codex exec` command instead.)

## The `codex` executor

Set `executor: codex` to run [`codex`](https://developers.openai.com/codex) as the
executor instead of `ralphex`. It shares all of `run-executor.sh`'s bookkeeping (repo/
plan resolution, the run directory, `running.json`/`run.json`, `EXECUTOR_DRYRUN`) but,
in place of a container, drives `codex exec` against a **host git worktree**:

1. Materializes the `<slug>` worktree under
   `<executor_options.runs_dir>/<repo>/<slug>/worktree` — reusing branch `<slug>` if it
   already exists, else cutting a fresh branch off `base_sha` (the repo's current HEAD).
2. Runs, without a TTY and with stdin closed (`< /dev/null`):
   ```
   codex exec -C <worktree> --sandbox workspace-write <executor_options.codex_args> [extra args forwarded to run-executor.sh] "<prompt>"
   ```
   where the prompt instructs codex to implement the plan and commit its work.
3. If codex left any uncommitted changes, commits them on `<slug>`
   (`crosscut(codex): <slug>`), then removes the worktree on normal completion (the branch
   persists — removed even if `codex exec` exited non-zero) and writes `run.json` exactly as
   the ralphex path does; only an auto-commit failure preserves the worktree for recovery.

Requirements:
- The **`codex` CLI** must be installed and on `PATH` wherever `run-executor.sh` runs.
- `--sandbox workspace-write` lets codex edit files in the worktree. Extra flags come
  from `executor_options.codex_args` (string, default `--skip-git-repo-check`); they are
  word-split and appended verbatim.

`executor: codex` uses the **same codex account** as a `plan_review: codex` review, so
running both draws on one shared quota (and one tool both plans and reviews) — see
[`docs/validators.md`](validators.md).

## The `claude` executor (in-session)

Set `executor: claude` for a dependency-light executor that needs **neither Docker nor
any CLI**: the work is done by an in-session Claude Code subagent. This kind is **not**
dispatched through `run-executor.sh` (handed `executor: claude`, that script exits 2) —
the orchestrator drives it directly in Phase 4:

1. The orchestrator creates the isolated worktree itself:
   `git -C <repo.path> worktree add -b <slug> <worktree-path> <integration-base>` (or,
   if branch `<slug>` already exists, adds the worktree without `-b`).
2. It spawns a Claude Code subagent (via the Agent tool) **pointed at that worktree
   path** — not via the Agent `isolation` flag, since the orchestrator, not the Agent
   tool, owns the branch — instructing it to implement the plan, run the repo's tests,
   self-review, and commit its work on `<slug>`.
3. On the subagent's return (commits on `<slug>`), the orchestrator removes the worktree
   (`git worktree remove --force`; the branch persists) and sets `status=review_pending`.

There is **no** `run.json` and **no** heartbeat for the `claude` kind — the orchestrator
observes the subagent's return directly, and the run directory / result contract below
applies only to the external (`ralphex`/`codex`) adapters. Requirement: a Claude Code
session that can spawn a subagent (the Agent tool); with none, Phase 4 falls back to a
manual-run.

## Result contract (external kinds)

Two files per run directory, written by `run-executor.sh` for the `ralphex` and `codex`
kinds — **exactly** these fields, nothing else. (The in-session `claude` kind writes
neither; see above.)

**`running.json`** — written at start, marks "a run is in progress":

```json
{
  "run_id": "...",
  "repo": "...",
  "plan": "...",
  "branch": "...",
  "base_sha": "...",
  "started_at": "..."
}
```

`running.json` present with no `run.json` next to it means the run is still active,
or was interrupted before it could finalize.

**`run.json`** — written atomically (temp file + rename) once the run finishes, then
`running.json` is removed. Two shapes depending on how the run ended:

- **Normal completion** (the container exited on its own, whether success or
  failure):
  ```json
  {
    "run_id": "...",
    "repo": "...",
    "plan": "...",
    "branch": "...",
    "base_sha": "...",
    "head_sha": "...",
    "started_at": "...",
    "finished_at": "...",
    "exit_code": 0,
    "status": "completed",
    "run_dir": "..."
  }
  ```
- **Unfinished exit** (the adapter process reached its `EXIT` cleanup before the
  normal-completion path ran — a deterministic command failure, or a killed/trapped
  `INT`/`TERM` signal): the exit trap writes a smaller subset instead — no `base_sha`,
  `head_sha`, `exit_code`, or timestamps — with status `failed` by default and
  `interrupted` only when the run was killed by a trapped `INT`/`TERM` signal:
  ```json
  {
    "run_id": "...",
    "repo": "...",
    "plan": "...",
    "branch": "...",
    "status": "failed",
    "run_dir": "..."
  }
  ```

`status` is exactly one of `completed` | `failed` | `interrupted` — nothing else is
valid. On the normal-completion path it's computed deterministically:
1. `exit_code != 0` → `failed`.
2. `exit_code == 0` and no new commits (`head_sha == base_sha`) → `failed` (nothing
   was actually done).
3. `exit_code == 0` and new commits exist → `completed`.

For `codex`, the "no new commits" test in step 2 compares against *this run's* starting
head (`RUN_BASE`), not `base_sha` — so a codex no-op rerun on a pre-existing branch is
correctly `failed` even though `head_sha != base_sha`; `ralphex` compares against
`base_sha`.

The orchestrator maps this to the ROADMAP: `completed` → `review_pending`, `failed`
→ `failed`, `interrupted` → `stalled`. (`stalled` itself is never a `run.json`
value — it comes from the heartbeat watching `executor.log` growth, or from
reconcile finding an `interrupted` `run.json`.)

### Reading the result

The executor's stdout (`executor.log`) is a human-readable progress log, not
machine-parseable JSON — the success criterion is not JSON-parsing stdout, it's:
1. `exit_code == 0` (primary signal).
2. Branch `<slug>` has new commits (`head_sha != base_sha` — for `codex`, against
   this run's starting head `RUN_BASE`, not `base_sha`).
3. (Corroboration only) the log tail contains a success marker such as "all phases
   completed successfully" or a "moved plan to .../completed/..." line.

## Finalization (orchestrator-owned)

Finalization is uniform across all three kinds and **owned by the orchestrator**, not
the executor. Each kind's only job is to produce commits on branch `<slug>`; the worktree is then
cleaned up — `codex` removes its host worktree (the adapter), `ralphex` has no host
worktree (it works inside its `--rm` container, torn down with the container), and the
**orchestrator** removes the `claude` kind's worktree (its subagent doesn't clean up
after itself); **none of them merge**. The feature code stays on `<slug>` until Phase
6, where the orchestrator merges it locally and moves the plan file to
`<plans_dir>/completed/` + updates the ROADMAP (see `SKILL.md`).

The one wrinkle is `ralphex`, which — as an optimization — **self-moves** the plan to
`completed/` on success (a "move completed plan → `completed/`" commit on the
**integration branch**) before Phase 6 merges. This is not a merge and not the `done`
transition: Phase 6 still owns both. `codex` and `claude` do **not** self-move; Phase
6's move step handles them and is idempotent for `ralphex` (an already-moved plan is
treated as move-already-satisfied). So "the plan is under `completed/`" never by itself
means the feature is merged — for `ralphex`/`codex` runs the real "done" signal is the
newest `completed` run's produced head being reachable from the integration branch
(`merge-base --is-ancestor`, via `run.json.head_sha`), covering both a `--no-ff` merge
commit and a `git.merge_ff=true` fast-forward. For `claude`/manual runs (which write no
`run.json`/`head_sha`), reconcile instead relies on the ROADMAP `done` written before the
branch is deleted (an idempotent finalize re-run), not `head_sha` reachability.

## Manual-run (implementing a plan by hand)

There is no config switch that turns the executor off — `executor` selects *which* of
the three kinds runs. When you'd rather not launch an automated run for a plan, or the
chosen kind can't run in this environment (`ralphex` without Docker, `codex` without the
`codex` CLI, `claude` with no subagent capability), the methodology's **manual-run**
fallback applies: the validated plan is handed to the operator to implement directly.
There is no
`run.json` and no heartbeat tracking in this mode — the operator *is* the executor.
Once the branch is ready, the orchestrator resumes at Phase 5 (Acceptance) exactly as
if an executor run had completed — it resolves the acceptance base ref itself via
`git merge-base <integration-branch> <slug>` (no `run.json` `base_sha` to read; see
`docs/configuration.md`).

## Swapping the executor

To use a different executor, replace `run-executor.sh` (or point
`${SCRIPT_DIR}/scripts/run-executor.sh` at your own script) as long as the
replacement honors the same interface:

- **Invocation:** `--repo <name> --plan <relative-path-to-plan> [extra args]`.
- **Config keys it may read:** the `executor` scalar (to recognize its own kind — the
  bundled `run-executor.sh` implements `ralphex` and `codex`, and rejects `claude` as
  in-session; a brand-new external kind needs its own adapter branch or script) plus
  anything under `executor_options.*`.
- **Result contract:** write `running.json` at start and `run.json` on completion
  under `<executor_options.runs_dir>/<repo>/<slug>/<run_id>/`, with exactly the fields
  documented above — the orchestrator's Phase 4/heartbeat/reconcile logic depends on
  those field names and the three-value `status` enum, not on anything
  ralphex-specific.
- **Isolation:** run the replacement inside its own isolated worktree/branch per run
  (the orchestrator's invariant is "the executor always runs with `--worktree`" —
  whatever mechanism your executor uses to get equivalent isolation).
- **Finalization:** your executor only needs to leave commits on `<slug>` and clean up
  its own worktree — the orchestrator owns moving the plan to `completed/` and the merge
  (Phase 6). Self-moving the plan the way `ralphex` does is an optional optimization, not
  required.

No other script or config key needs to change — the orchestrator's Phase 4 recipe in
`LIFECYCLE.md` only shells out to `${SCRIPT_DIR}/scripts/run-executor.sh` and reads back
`run.json`.
