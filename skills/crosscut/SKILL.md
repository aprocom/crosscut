---
name: crosscut
description: Drives a feature across one or many repos through plan -> validate -> execute -> accept -> merge, with independent models checking each gate. Trigger: /crosscut
---

# /crosscut — autonomous dev-orchestrator

Config: `~/.crosscut/crosscut.config.yaml` — the single global home
(resolved via `$CROSSCUT_CONFIG` → that home; **no upward search** from `$PWD` —
see `${SCRIPT_DIR}/scripts/lib/config.sh`). Schema reference and a fully
annotated example: `${SCRIPT_DIR}/templates/crosscut.config.example.yaml`. Full
methodology narrative (if present): `docs/DESIGN.md`. This file is the operational
summary — it is authoritative for how `/crosscut` behaves.

This SKILL.md is the **lean activation core** — enough to validate, reconcile, and
summarize on every `/crosscut` start. Two sibling files hold the detail and are read
**only when needed**, keeping activation cheap:
- `${SKILL_DIR}/INIT.md` — the `/crosscut init` procedure; read **only** when initializing.
- `${SKILL_DIR}/LIFECYCLE.md` — Phases 1–7, recipes, quota, cross-repo rules, knowledge
  base; read **before authoring, driving, or merging any plan** (not needed just to show
  status).

**Respond to the operator in the configured `language`** (default `en`; set during
`/crosscut init`, read back with `cfg_get language`). All internal methodology in
this skill file is English; that does not change at runtime — only your responses do.

Paths and scripts referenced below are resolved at runtime, never hardcoded:
- `${SCRIPT_DIR}` — this skill's own `scripts/` directory (wherever the plugin is
  installed; resolve from the skill's own location, do not assume a fixed path).
- `${SKILL_DIR}` — this skill's own directory (the parent of `${SCRIPT_DIR}`); the
  sibling docs `INIT.md` and `LIFECYCLE.md` live here.
- ROADMAP: `<workspace_root>/<roadmap>` (from config; template at
  `${SCRIPT_DIR}/templates/ROADMAP.template.md`).
- Plan template: `${SCRIPT_DIR}/templates/plan-template.md`.
- Repo discovery (optional bulk helper): `${SCRIPT_DIR}/scripts/discover-repos.sh`.
- Config mutation (run, don't source): `${SCRIPT_DIR}/scripts/config-mutate.sh` —
  atomic writes to the config; `add-repo` merges a repo into `repos[]` by `name`;
  `set-global` / `set-product <name>` set the knowledge base (`--kb-path` / `--kb-mcp`).
- Executor adapter: `${SCRIPT_DIR}/scripts/run-executor.sh`.
- Plan-review limits: `${SCRIPT_DIR}/scripts/plan-review-limits.sh`.
- Acceptance: `${SCRIPT_DIR}/scripts/acceptance.sh`.
- Config validation (run, don't source): `${SCRIPT_DIR}/scripts/config-validate.sh` —
  whole-file, human-friendly validation of `crosscut.config.yaml`. Standalone (does not
  call `cfg_get`), so it reports a broken config instead of tracebacking. Exit `0` valid ·
  `1` errors · `2` bad YAML · `3` no config · `4` PyYAML missing; `--json` / `--quiet`.
- Runs retention (run, don't source): `${SCRIPT_DIR}/scripts/prune-runs.sh` —
  `--repo <name> --plan <slug>` event-prunes one plan's run records; `--sweep
  [--preserve-file <f>]` age-prunes by `executor_options.runs_retention_days`, keeping any
  run that is young, live, or listed in `--preserve-file`. `reconcile.sh` **drives both**:
  event-prune at retention `0`, and a **status-aware sweep** at retention `>0` where it
  passes each non-`done` plan's newest `completed` run in the preserve file so the merged/done
  `head_sha` is never aged out. Only run-id dirs are ever removed (never a `worktree`
  sibling); `--dry-run` reports without deleting.
- Reconcile / activation-settle (run, don't source): `${SCRIPT_DIR}/scripts/reconcile.sh` —
  the **one-call** reconcile that Start step 1 runs. Parses config + ROADMAP + git + run
  state (one YAML parse), settles every plan's status per § Reconcile below (which it
  encodes), reclaims stale per-repo executor locks, event-prunes `done` plans' run records,
  **writes the ROADMAP atomically**, and prints a JSON summary — keys `plans`,
  `status_counts_by_product`, `ready`, `running`, `blocked`, `stalled`, `changes_applied`,
  `warnings`, `focus_product`, `prune_results`. It is activation-settle **only**: it never
  merges, re-runs an executor, or touches a branch / worktree / plan file. `--dry-run`
  computes and prints the JSON but writes nothing and prunes nothing. Exit `0` settled ·
  `2` bad/invalid config · `3` no config.
- Config API (source, don't execute): `${SCRIPT_DIR}/scripts/lib/config.sh` —
  `cfg_get <dotted.path> [default]`, `cfg_repo_names`, `cfg_repo_field <name> <field>
  [default]`, `cfg_repo_monorepo <name> <field> [default]`, `cfg_list <dotted.path>`.
- Products (source, don't execute): also from `config.sh` — `cfg_repo_product <name>`
  (a repo's `product` field, else its `name`), `cfg_products` (the unique product set),
  `cfg_product_repos <product>` (the repos in a product), `cfg_product_kb <product>`
  (resolve a product's knowledge base: prints `mcp\t<endpoint>\t<fallback-path>` when an
  MCP endpoint wins, else `path\t<dir>`), and `cfg_check_depends <slug>`
  (exit 0 iff the plan's `depends_on` stays inside its own product; non-zero on a
  cross-product, unresolved, or ambiguous dependency — a boundary violation is a blocker).
- Repos: iterate `cfg_repo_names`; per-repo fields via `cfg_repo_field <name> path|kind|
  test_cmd|lint_cmd|plans_dir|venv_isolation`; monorepo sub-fields (only for repos with
  a `monorepo:` block) via `cfg_repo_monorepo <name> tool|affected_build|affected_lint|
  affected_test|full_build|full_lint|full_test`. Never assume a fixed set of repos or a
  fixed repo count — the config is the only source of truth for what exists.

---

## `/crosscut init`

First run (no config), or adding the current repo (`$PWD`) to an existing config. **Read
`${SKILL_DIR}/INIT.md` and follow it** — it holds the tooling detection, `$PWD`
inspection, the interview (global + per-repo), and the persist/scaffold/allowlist steps.
Whether init **creates** a config or **adds a repo** is decided by config presence, not a
flag: `crosscut_config_path` (from `config.sh`) exits non-zero on first run, `0` when the
config already exists. `workspace_root` is always the `~/.crosscut` home, never `$PWD`.

---

## Start / Stop

**Start** (`/crosscut` activation):
0. **Validate the config first (gate).** Run `bash ${SCRIPT_DIR}/scripts/config-validate.sh`
   before any `cfg_get`. On **errors** (exit `1`) or **bad YAML** (exit `2`), **stop and
   show the report** — do not reconcile or drive anything on a broken config (this closes the
   silent-default / traceback hole). On **no config** (exit `3`), report it and suggest
   `/crosscut init`. On **warnings only** (exit `0` with a `WARNINGS:` block), surface them
   and continue.
1. Run **reconcile** in one call: `bash ${SCRIPT_DIR}/scripts/reconcile.sh`. It reads
   config, ROADMAP, git, and executor run state, settles every plan's status by the
   truth-priority in § Reconcile below (which it encodes), reclaims stale per-repo locks,
   writes the ROADMAP atomically, and prints the JSON summary — **relay that summary;
   do not re-derive the statuses by hand.** On exit `2`/`3` fall back to the step-0 config
   gate (which should already have caught a broken/absent config).
2. Build the dependency graph from `depends_on`; compute `ready` = `todo` with every
   `depends_on` in `done`.
3. Show a summary: **status counts per product** (iterate `cfg_products`; for each,
   the `done` / `ready` / `blocked` / `stalled` counts over that product's plans), plus
   one line from `${SCRIPT_DIR}/scripts/plan-review-limits.sh` (no-op if the plan_review
   module is disabled or not `codex`-kind). When `/crosscut` is launched from inside a
   configured repo, **default the focus to that repo's product** (`cfg_repo_product` of
   the repo whose `path` contains `$PWD`) — lead with its section, and still summarize
   the other products briefly.
4. Wait for direction (which plan to drive, write a new one, or show status). Once a
   plan/feature is picked (to drive **or** to author), **read `${SKILL_DIR}/LIFECYCLE.md`**
   and follow it to drive the plan **autonomously to `done`**, asking the operator only on
   an architecture decision or a blocker. Do **not** read `LIFECYCLE.md` (or the knowledge
   base) merely to show status — activation stays lean.

**Stop** (`/crosscut stop`, or the operator says so): summarize current status and
exit orchestration mode. A backgrounded executor run keeps going unless the operator
asks to stop it too. State lives in the ROADMAP plus each run's `run.json` — the next
session reconciles and continues from there.

**Validate** (`/crosscut validate`, doctor): run
`bash ${SCRIPT_DIR}/scripts/config-validate.sh` and relay its human-friendly report
verbatim — it checks the whole `crosscut.config.yaml` (structure, enums, types, mapping
nodes, per-stage model/effort) and changes nothing. This is the same gate Start runs at
step 0; the operator can invoke it any time after hand-editing the config.

---

## State machine

The ROADMAP is an **index of desired/current state** (set of plans, order,
`depends_on`, `feature_id`) — it is not ground truth by itself; every status is
settled by reconcile. Writes to it are always atomic (temp file + rename).

Status enum: `draft → todo → validated → running → review_pending → accepted →
merging → done`; terminal/special: `failed`, `stalled`, `blocked`, `rejected`,
`superseded`. Modifier flags: `plan_review_skipped` (set alongside `validated` when the
plan_review module was disabled for that pass), `review_deferred` (set alongside `done`
when a deferred plan_review-only pass is still owed — see `${SKILL_DIR}/LIFECYCLE.md`
§ Quota handling). Transitions are **adjacent only** — never skip a state.

## Reconcile at activation

Truth priority, highest first:
1. Branch `<slug>` is **merged** — the newest **`completed`** run's produced head is
   **reachable from** the integration branch: `git -C <repo.path> merge-base --is-ancestor
   <head_sha> <integration-branch>` exits 0, where `<head_sha>` is the newest run whose
   `run.json.status == "completed"`. **Only `completed` runs count** — they guarantee
   `head_sha != base_sha` (real work); a `failed`/`interrupted` run may record
   `head_sha == base_sha` (a no-op), which is trivially reachable and must **not** read as
   merged. `head_sha` **survives the post-merge `<slug>` deletion** and needs no
   merge commit — so this covers **both** a `--no-ff` merge commit **and** a
   `git.merge_ff=true` fast-forward (requiring a literal merge commit would strand ff
   merges). This is the **only** positive "merged/done" signal. A `claude`/manual run has
   **no** `run.json.head_sha`; do **not** infer its merge from bare branch-tip reachability
   (a just-cut branch is trivially an ancestor of the integration branch, so that would
   false-`done` unstarted work). For that case reconcile leans on the durable ROADMAP
   `done` that Phase 6 writes **before** deleting `<slug>`; a finalize interrupted before
   that write is recovered by re-running Phase 6, whose merge step is idempotent (`git
   merge` of an already-merged branch is a no-op). See LIFECYCLE.md § Merge.
2. That run's `run.json` (final report written by the executor adapter).
3. `running.json` + a live process check (is the executor actually still running).
4. The plan file's presence under `<plans_dir>/completed/` or `<plans_dir>/rejected/`
   — a **weak** signal only (the reference executor moves a plan to `completed/`
   *before* merge — see `${SKILL_DIR}/LIFECYCLE.md` § Executor run).
5. The `status` field in the ROADMAP row — last resort.

Fact → outcome:
- The newest **`completed`** run's produced head (`run.json.head_sha`, `status=completed`
  only) is **reachable from** the integration branch, current status ∉ {`done`, `blocked`,
  `superseded`, `rejected`}, **and there is no newer live run** → set `done` (auto). A newer
  **live** run instead settles `running` (active rework outranks an older merged head); a
  human `blocked`/`superseded` is left untouched. No `run.json` (claude/manual) → do **not**
  infer merge from branch-tip reachability; settle via the ROADMAP `done` written before
  branch deletion, or an idempotent Phase 6 re-run.
- `status=accepted` or `merging` with branch `<slug>` **present** and Phase 6
  preconditions still met (clean integration branch, acceptance green) → **resume Phase 6
  finalize** (idempotent re-merge / move / `done`); do **not** re-run the executor, and do
  **not** set `done` from bare branch reachability.
- Plan is in `completed/`, branch `<slug>` exists and is **not** merged, **and the plan
  has not yet passed acceptance** (status before `accepted`) → `review_pending` (the
  executor finished its part and is waiting on acceptance + merge) — **not** `done`. An
  `accepted`/`merging` plan instead takes the resume-Phase-6 rule below, which **takes
  precedence** (it already passed acceptance; do not demote it back to `review_pending`).
- Plan is in `rejected/` → `rejected`.
- `status=running`, no live process, `run.json` is final → map by its `status` field
  (`completed` → `review_pending`, `failed` → `failed`, `interrupted` → `stalled`).
- `status=running`, no live process, `run.json` missing or not finalized — **including no
  run records at all** (records wiped / cache cleared) → `stalled` + repair-gate (diagnose
  before resuming); never leave it falsely `running`.
- Branch exists, worktree is gone → normal (the `<slug>` worktree is removed on
  completion — by the adapter for `ralphex`/`codex`, by the orchestrator for `claude`)
  — leave it alone.

**Multi-run scan (parallel-aware, recency-ordered).** Because runs proceed concurrently
across repos, reconcile scans **all** run directories across **every** repo — walk each
`<runs_dir>/<repo>/<slug>/<run_id>/` entry, not just one repo's, and expect **multiple
`run_id`s per plan**. Order a plan's runs by recency — by the **fixed-width** UTC prefix of
`run_id` (`YYYYMMDDTHHMMSS`, the part before `-<pid>`), breaking a same-second tie by
dir **mtime** then `started_at` (mtime leads: a crashed/interrupted run's terminal `run.json`
is written with **no** `started_at`, so a started_at-first tie-break would wrongly out-rank a
newer such run by an older completed one); the `-<pid>` suffix is **not**
fixed-width and does not sort chronologically (`-9999` sorts after `-10000`). Let the
**newest meaningful run decide** — an older terminal `run.json` must **not** override a
newer live rerun. Within one run dir a
**terminal** `run.json` (`completed` / `failed` / `interrupted`) **wins over a bare
`running.json`** sibling, and a `running.json` with a **dead PID** or a terminal sibling is
**not live**. Then, for the plan: newest run **live** → `running`; else map by the newest
**terminal** run's `status` (`completed` → `review_pending`, `failed` → `failed`,
`interrupted` → `stalled`); a newest run that is a non-live `running.json` with no terminal
report → `stalled`. Reachability truth (priority 1) overrides any **terminal** run state,
but a **live** newer run **wins over reachability** — a live executor is active rework, so
settle `running` (never `done`, which would let retention prune the live run's directory out
from under it). A human `blocked`/`superseded` status is **never** auto-changed by reconcile.
Then
**reclaim stale per-repo executor locks**: `executor_active_for_repo <repo>` reports busy
only for a **live** owner and otherwise reclaims the dead lock in place, so a repo whose
executor died is freed for its next `ready` plan (do this for every repo before recomputing
`ready`). Merges (Phase 6) are still applied **sequentially per repo**.

**Runs retention (`reconcile.sh`, after status is settled, locks reclaimed).** Driven by
`executor_options.runs_retention_days`:
- **`0`** — `reconcile.sh` event-prunes the run tree of **every** plan it resolves as `done`
  that still has run records — **not only** plans whose status *changed* to `done` this pass —
  via `prune-runs.sh --repo <name> --plan <slug>` (idempotent), so plans finished in a prior
  session are cleaned too.
- **`>0`** — **status-aware age sweep**: reconcile computes the preserve-set (each non-`done`
  plan's newest `completed` run dir — whose `head_sha` is the merged/done signal) and runs
  `prune-runs.sh --sweep --preserve-file <f>`, which ages out run dirs older than the window
  while keeping any that are young, live, or in that set. `done` plans are **not**
  event-pruned here — their records age out via the sweep like the rest.

Retention runs only when the ROADMAP is consistent on disk (written this pass, or nothing to
write) — a settle that couldn't be persisted skips retention so a not-yet-durable `done`
never loses its `head_sha`. Retention never blocks reconcile; a failure is logged.

Silent auto-fixes for the above. Irreversible actions (re-running the executor,
merging) happen automatically once their Phase preconditions are met — preconditions
are never skipped. Anything ambiguous, or a genuine blocker, is escalated to the
operator.

---

## Product boundary (for the Start summary)

The **product** is the integration boundary — a repo's `product` field, else its `name`.
`cfg_products` lists them; `cfg_product_repos <product>` the repos in each. All status
counts and integration-readiness are computed **per product, never across products**; one
blocked product never blocks another. The full cross-repo / feature-group (`feature_id`),
`depends_on`, and per-product integration-readiness rules live in
`${SKILL_DIR}/LIFECYCLE.md` § Cross-repo features.

---

## Driving a plan

Once the operator picks a plan to drive or author, **read `${SKILL_DIR}/LIFECYCLE.md`**
and follow it: the autonomous lifecycle (Phases 1–6), the continue-across-repos policy
(Phase 7), the recipes (executor run / plan review / acceptance / final review / merge /
runs retention), quota handling, cross-repo & feature rules, and the knowledge base. The
core contract: phases run **automatically through to `done`** without a go-ahead at each
step; ask the operator **only** on an architecture decision or a genuine blocker; never
leave half-delivered work silent.

---

## Invariants

- Every path used or written by this skill is config-resolved at runtime — no
  hardcoded absolute paths, in this file or in anything it produces.
- Every executor produces its work in an isolated `<slug>` worktree: the external
  executors (`ralphex`/`codex`) via `run-executor.sh`'s `--worktree`; the in-session
  `claude` executor via a worktree the orchestrator creates and removes itself. Each
  executor's sole deliverable is commits on `<slug>`; the orchestrator finalizes at
  Phase 6 — move the plan to `completed/`, set the ROADMAP `done`, **then** delete `<slug>`
  (done written before the branch is removed, so a crash can't strand the plan).
- Git safety default: never push unless `git.push_enabled=true`; merge locally per
  `git.merge_ff` (default `--no-ff`). **No `Co-Authored-By` trailer** on any commit
  this skill makes.
- **Final review (Phase 5b) runs for every executor run unless `final_review: none`** —
  it reviews the produced *code* and is not substituted by `plan_review` (which reviews the
  *plan*). Setting `final_review: none` drops that code-safety gate deliberately.
- **Per-stage model/reasoning:** `plan_review_options` / `final_review_options` /
  `executor_options` carry `model` and `reasoning_effort` (default `inherit`). `model` binds
  for claude subagents (Agent `model`) and codex kinds; `reasoning_effort` binds for codex
  (mapped; `max`→`xhigh`) and for a claude stage dispatched via a Workflow — a bare
  Agent-tool subagent has no effort knob and inherits the orchestrator's (advisory).
- ROADMAP writes are atomic (temp file + rename); state transitions are adjacent
  only — never skip a status.
- Irreversible actions (merge, launching the executor) run automatically once their
  Phase preconditions are met — preconditions are never skipped. The operator is
  asked only for an architecture decision or a genuine blocker.
- Half-delivered work is never left silent — always driven to completion or
  escalated with the exact state.
- Respect each repo's own declared rules (its own CLAUDE.md/README, lint config,
  do-not-touch paths) — this skill assumes nothing project-specific; everything
  repo-shaped comes from `crosscut.config.yaml`.
