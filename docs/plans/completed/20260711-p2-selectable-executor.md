---
repo: crosscut
status: done
depends_on: [20260711-p1-config-foundation]
feature_id: workspace-redesign
---
# P2 — Selectable executor kinds + claude plan_review

**Goal:** On P1's scalar `executor`/`plan_review`, make both roles pluggable: add the
`claude` and `codex` executor kinds (P1 shipped `ralphex` only) and the `claude`
plan-review kind, a `set-global` config mutation for the wizard, and the init
questions that let the operator choose them.

**Context:** `skills/crosscut/scripts/run-executor.sh`,
`skills/crosscut/scripts/config-mutate.sh`, `skills/crosscut/SKILL.md`
(Phase 3/4, executor + plan-review recipes, init section, finalization/§5.4),
`docs/configuration.md`, `docs/DESIGN.md`, `docs/executors.md`, `docs/validators.md`,
`README.md`, `tests/`.

**Contracts settled (addressing the P2 plan-review):**
- **Executor contract (all kinds):** an executor is given a validated plan + repo +
  an isolated git worktree on branch `<slug>` and must produce commits on `<slug>`
  (`head_sha != base_sha`). It is NOT responsible for finalization.
- **Finalization contract (orchestrator-owned, uniform):** the orchestrator moves the
  plan to `<plans_dir>/completed/` and updates the ROADMAP at Phase 6, for every
  executor kind. `ralphex` self-moves the plan as an optimization; reconcile treats an
  already-moved plan as *move-already-satisfied* (do not double-move) — not as ROADMAP
  `done`, which only Phase 6 sets. `codex`/`claude` do not move it.
- **Worktree lifecycle (codex & claude):** worktree at
  `<executor_options.runs_dir>/<repo>/<slug>/worktree`; create with
  `git worktree add -b <slug> <path> <integration-base>` (if branch `<slug>` already
  exists — a rerun — add the worktree onto the existing branch instead of `-b`); after
  the run, if the worktree has uncommitted changes, commit them so `head_sha` advances;
  then `git worktree remove <path> --force` on success, failure, AND interruption (a
  trap) — the branch always persists. Never leave a dangling worktree.
- **Two dispatch layers:** `ralphex`/`codex` are external processes driven by
  `run-executor.sh`; `claude` is dispatched in-session by the orchestrator (it creates
  the `<slug>` worktree itself and runs a Claude Code subagent pointed at it — the same
  mechanism used to build P1 — not the Agent `isolation` flag, so the branch name is
  controlled). `manual-run` is the fallback when the chosen executor cannot run.

### Task 1: `run-executor.sh` — refactor + codex executor case

- **Refactor** so repo/plan resolution and `run.json` bookkeeping are shared setup,
  then dispatch on `executor` (currently the non-`ralphex` rejection happens before
  setup — move dispatch after shared setup).
- `ralphex` → unchanged Docker path.
- `codex` → create the `<slug>` worktree (lifecycle above), run
  `codex exec -C <worktree> --sandbox workspace-write <executor_options.codex_args>
  "<prompt naming the plan>" < /dev/null` (do not force a model). `codex_args` is a
  **string** of extra flags, default `"--skip-git-repo-check"`; document quoting.
  After codex returns, commit any uncommitted changes in the worktree; compute
  `head_sha`; write the SAME `running.json`/`run.json` (status=completed when exit 0
  and `head_sha != base_sha`, else failed); remove the worktree.
- `claude` / unknown → still exit non-zero from the adapter (claude is in-session).

### Task 1 tests

`tests/run-executor.bats`: (a) `executor: codex` + `EXECUTOR_DRYRUN=1` builds a
`codex exec --sandbox workspace-write` invocation against a `<slug>` worktree (not the
read-only plan-review form); ralphex still builds Docker; claude/unknown exit non-zero.
(b) **non-dry-run adapter test with a fake `codex` on `$PATH`** that makes+commits a
change in the worktree: assert `run.json.status=completed`, `head_sha != base_sha`,
branch `<slug>` exists, and the worktree was removed.

### Task 2: `config-mutate.sh` — `set-global` command

Add a `set-global` subcommand alongside `add-repo`: set top-level scalars the wizard
needs — `language`, `executor`, `plan_review`, `git.merge_ff`, `git.push_enabled`
(and pass-through for `executor_options.*`/`plan_review_options.*` if given) — merged
into the same global-home config, written atomically (temp + `os.replace`), preserving
`repos[]` and everything else. Validate values (e.g. `executor ∈ {ralphex,claude,codex}`,
`plan_review ∈ {none,codex,claude}`, booleans for git.*); non-zero on bad input.

### Task 2 tests

`tests/config-mutate.bats`: `set-global` writes each scalar; re-running updates in
place and preserves `repos[]` and other globals; invalid `executor`/`plan_review`/git
values are rejected; atomic (target unchanged on bad input).

### Task 3: `SKILL.md` Phase 4 — unified dispatch, claude executor, finalization

Rewrite Phase 4 + the executor recipe + finalization (§5.4) in `SKILL.md`:
- Dispatch by `executor`: `ralphex`/`codex` → `run-executor.sh` (+ `run.json`);
  `claude` → the orchestrator creates the `<slug>` worktree (`git worktree add -b`),
  spawns a Claude Code subagent **pointed at that worktree path** with a prompt to
  implement the plan, run the repo's tests, self-review, and commit; on the subagent's
  return (commits on `<slug>`) set `status=review_pending`, then remove the worktree.
  State the fallback: if the environment has no subagent/Agent capability, `claude` is
  unavailable → manual-run.
- `manual-run` fallback when the chosen executor cannot run (ralphex w/o Docker; codex
  CLI absent; claude w/o subagents).
- **Finalization contract** (uniform, orchestrator-owned): executors only produce
  commits on `<slug>`; the orchestrator moves the plan to `completed/` and updates the
  ROADMAP at Phase 6. Note `ralphex` self-moves as an optimization and reconcile must
  not double-move.

### Task 4: `SKILL.md` Phase 3 — claude plan_review

`plan_review` ∈ {`none`, `codex`, `claude`}: `codex` = existing read-only recipe;
`claude` = an in-session Claude Code subagent that reads the plan + repo read-only and
returns a verdict/notes (modifies nothing), feeding the same accept/fix loop; `none` =
skip. Clarify `plan-review-limits.sh` is meaningful only for `codex` (a `claude` review
draws on the orchestrator's own budget) — it already no-ops otherwise.

### Task 5: init wizard — executor + plan_review questions

Extend the `## /crosscut init` global block, one question at a time, persisting via
`config-mutate.sh set-global`: **executor** (`ralphex` default / `claude` / `codex`;
warn `ralphex` needs Docker) → **plan_review** (`codex` default / `claude` / `none`;
**here** warn if `plan_review == codex` AND `executor == codex` about the shared codex
account — placed at the plan_review step so the ordering reads naturally) → `git.merge_ff`
→ `git.push_enabled`. Order: language → executor → plan_review → git.* → per-repo block.

### Task 6: Documentation + final grep

- `docs/configuration.md`: three `executor` kinds (ralphex→Docker, claude→in-session
  subagent, codex→shared codex account) + `executor_options` (incl. `codex_args`);
  three `plan_review` kinds; `set-global`.
- `docs/DESIGN.md`: the two dispatch layers, the executor + finalization contracts, the
  decoupled review with claude/codex.
- `docs/executors.md` / `docs/validators.md`: added kinds + their contracts.
- `README.md`: three executor choices, `claude` being the dependency-light one.
- Final grep: no stale single-kind (`ralphex`-only) claims remain in the touched docs;
  `bats tests/` stays 100% green.
