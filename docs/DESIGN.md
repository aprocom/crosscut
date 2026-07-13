# Design: the `crosscut` methodology — an autonomous dev-orchestrator for multi-repo workspaces

Status: implemented (`skills/crosscut/`).
Type: meta-tooling — this mode does not belong to any one of the repos it
drives; it lives in its own plugin and is discovered from any working
directory the operator activates it from.

This document is the full narrative behind `skills/crosscut/SKILL.md`.
`SKILL.md` is the operational summary — authoritative for exact runtime
behavior, flag names, and file paths. This document explains the *why* behind
those choices, at more length, and should never contradict it. Section
numbers below are stable and are referenced implicitly by `SKILL.md`; treat
renumbering as a breaking change.

## 1. Purpose

A reusable mode of an ordinary agent session that activates quickly
(`/crosscut`) and immediately puts the assistant into the role of
dev-orchestrator/architect across an arbitrary set of configured
repositories — not a fixed pair, not a fixed count: whatever `repos[]` in
`crosscut.config.yaml` lists. Instead of re-explaining workflow rules
every session, the mode bakes in:

- plan authoring (per repo, in an executor-compatible format);
- self-review of a plan without any external reviewer, with an
  improve-and-retry loop;
- a final plan-review pass through an external tool before execution;
- running an executor (headless, backgrounded, always inside an isolated
  worktree) against a plan once it is ready;
- acceptance of the outcome — both automated tests/lint *and* a logic/
  architecture review, not tests alone;
- local merge of the resulting branch into the integration branch and
  finalization of the plan's bookkeeping;
- coordinating the order and dependencies of plans across repos through a
  single index;
- spawning a research subagent on non-trivial architectural or strategic
  decisions;
- keeping each product's knowledge base current with the durable outcomes of
  the work (decisions, architecture, research, incidents).

The goal of the system this mode drives is to build the product on the best
available approaches, practices, libraries, and data sources — not merely to
push plans through a pipeline.

### Infrastructure context (reference stack)

The methodology names external tools as its **reference stack**, but neither the
executor nor plan review is a single fixed tool. The executor is chosen by the
`executor` scalar — `ralphex` (reference), `claude`, or `codex`; plan review by the
`plan_review` scalar — `codex` (default), `claude`, or `none`. The mode degrades
gracefully, not fatally: plan review can be turned off or degrade when its tool is
unavailable, and any plan can be implemented by hand instead of by the executor.

**Two dispatch layers.** The executor kinds split by *how* they are launched, not just
which binary runs. `ralphex` and `codex` are **external-process adapters** driven by
`run-executor.sh` (a Docker container, and a host git worktree running `codex exec`,
respectively); `claude` is **in-session** — the orchestrator itself creates the `<slug>`
worktree and points a Claude Code subagent at it, with no external process, no Docker,
and no CLI. `run-executor.sh` therefore implements only the two external kinds; handed
`executor: claude` it exits non-zero, because that kind is the orchestrator's own job.

- **executor** — the module that writes code from a validated plan, always inside an
  isolated worktree/branch `<slug>`, in one of three kinds. **`ralphex`** (reference) is
  a containerized coding-agent runner, invoked as `<binary> [OPTIONS] [plan-file]` with
  the plan file as its positional argument; relevant flags: `--worktree` (isolated git
  worktree + a branch named after the plan file), `--branch=`, `--base-ref=`,
  `-t/--tasks-only`, `-r/--review`, `-e/--external-only` (external review only),
  `--external-review-tool=[codex|custom|none]`, `--wait=<dur>` (wait out a rate limit
  before retrying), `--idle-timeout=<dur>`, `--session-timeout=<dur>`,
  `--max-iterations=`. **`codex`** runs `codex exec --sandbox workspace-write` in an
  orchestrator-managed host git worktree (extra flags via `executor_options.codex_args`,
  default `--skip-git-repo-check`); it uses the **same codex account** as a `codex` plan
  review. **`claude`** is an in-session Claude Code subagent — no Docker, no CLI: the
  orchestrator creates the `<slug>` worktree and drives a subagent pointed at it.
  `executor` is a scalar with no on/off toggle; an unknown value exits "not implemented".
  When a plan is implemented by a human instead — a **manual-run** — Phase 4 hands the
  validated plan to the operator directly and resumes at Phase 5 once the branch is
  ready (this is also the fallback when the chosen kind cannot run: `ralphex` without
  Docker, `codex` without the CLI, or `claude` with no subagent capability).
- **plan review** — a read-only pass over the plan file (Phase 3), in one of three
  kinds. **`codex`** (default, reference) is an external CLI invoked read-only against
  the plan; **`claude`** is an in-session read-only Claude Code subagent (no external
  account, no quota check — it draws on the orchestrator's own budget, so
  `plan-review-limits.sh` no-ops for it); **`none`** skips Phase 3 entirely. The
  `plan_review` scalar is decoupled from the `executor` scalar — any review kind pairs
  with any executor kind — though picking `plan_review: codex` alongside `executor:
  codex` means both stages share one codex account (shared quota, and one tool that both
  plans and reviews). **If `plan_review: none`** — or if `codex` is unavailable or
  quota-exhausted on first use — Phase 3 is skipped and the plan proceeds with flag
  `plan_review_skipped`, never a hard fail.
- **final review** — the code-side twin of plan review: a review of the produced
  *code/diff* at Phase 5b, chosen by the `final_review` scalar — `in-session` (default;
  the orchestrator reviews it), `claude` (an **independent** Agent-tool subagent — a fresh,
  possibly different-model reviewer, best for objectivity), `codex` (external cross-model
  review), or `none` (skip — deliberately drops the code-safety gate). Where plan review
  reviews the *plan* before the build, final review reviews the *code* before the merge;
  the two are separate gates and neither substitutes for the other. It runs for every
  executor run unless `final_review: none`.
- **per-stage model & reasoning effort** — `plan_review_options`, `final_review_options`,
  and `executor_options` each carry `model` and `reasoning_effort` (default `inherit`),
  so each stage can pick a tier (cheap/fast for mechanical work, strongest — or a
  *different* model for cross-model independence — for judgment). For the codex **plan_review / final_review** stages both `model` and `reasoning_effort`
  bind (mapped to codex flags; `max`→`xhigh`), and `model` binds for claude subagents (the
  Agent `model` param); for the codex **executor** neither binds — pass them through
  `executor_options.codex_args`. `reasoning_effort` also binds for a claude stage dispatched
  via a Workflow — the Agent tool has no effort knob, so a bare Agent subagent inherits the
  orchestrator's effort (the config value is advisory there). The keys are always written by init, so
  model and reasoning type are recorded in the default config and are tunable.
- **Plans** live at `<repo.path>/<plans_dir>/YYYYMMDD-slug.md`; completed
  plans move to `<plans_dir>/completed/`, rejected ones to
  `<plans_dir>/rejected/`.
- **Git safety default:** never push unless `git.push_enabled=true` (default
  `false` — local commits only, the operator pushes); merges use
  `--no-ff` unless `git.merge_ff=true`. No `Co-Authored-By` trailer on any
  commit this mode makes. The executor is always invoked with `--worktree`.

## 2. Form and activation

A skill file (`skills/crosscut/SKILL.md`) backed by the single
`crosscut.config.yaml` at the global home
(`~/.crosscut/crosscut.config.yaml`), resolved via
`$CROSSCUT_CONFIG` or that fixed home path — never by searching up from the
current directory.

- **Start:** `/crosscut` — loads the persona, the workflow, and the
  recipes for invoking the plan-review/executor/tests; **validates the config
  first** (a fail-fast gate: `config-validate.sh`, standalone, runs before any
  `cfg_get` — a hand-broken config is reported in plain language, never as a silent
  default or a Python traceback, and blocks until fixed), runs **reconcile**
  (§3.2: settles the ROADMAP against git branches/worktrees/`run.json`/
  `completed/`), builds the dependency graph, prints a status summary
  (done / ready / blocked / stalled counts per product, plus a plan-review quota
  line), and waits for direction. `/crosscut validate` runs that same gate on demand.
- **Stop:** `/crosscut stop`, or the operator saying so — summarizes
  current status and exits the mode. Any backgrounded executor run keeps
  going unless the operator also asks to stop it. State lives in the
  ROADMAP plus each run's `run.json`; a new session reconciles and resumes
  from wherever things were left.

## 3. State: the ROADMAP

The ROADMAP (`<workspace_root>/<roadmap>` from config) is a
**human-readable index of desired/current state**, spanning every configured
repo, pointing at plan files that live inside each repo. It is **not**
ground truth by itself: the real state lives in git branches, worktrees, per-
run `run.json` files, and the `completed/`/`rejected/` directories. On every
activation the ROADMAP is **reconciled** against those sources (§3.2), never
taken on faith.

Format — a markdown table, one row per plan:

| field | meaning |
|---|---|
| `slug` | plan identifier, e.g. `20260626-example-feature` |
| `repo` | one of the configured repo names |
| `title` | human-readable title |
| `status` | state from the state machine (§3.1) |
| `depends_on` | list of slugs (can cross repos — a plan in one repo can depend on a plan in another) |
| `feature_id` | (optional) shared id for a cross-repo feature group — every plan in the group carries it |
| `plan` | relative path to the `.md` file inside its repo |
| `branch` | worktree branch of the plan's last executor run |
| `run` | path to that run's directory (`run.json` + log, §5) |
| `notes` | short notes / links to follow-up plans |

"Ready" = `status=todo` and every entry in `depends_on` is `done`.

At activation: reconcile settles the **existing** ROADMAP rows — parsing each
row and probing `completed/`/`rejected/` for that row — and does **not**
auto-discover or append missing plan files (new plans are added to the ROADMAP
when authored, not auto-seeded here). The ROADMAP is authoritative as an **index** (which
plans exist, their order, `depends_on`, `feature_id`), but **statuses** are
always settled against git/`run.json` at activation (§3.2) rather than
trusted; a plan's own frontmatter `status` field is optionally mirrored, not
relied on.

A cross-repo feature is modeled as **two or more separate plans** (one per
affected repo) linked by `depends_on` and a shared `feature_id`. There is no
single "root plan" for a feature — each plan physically lives in the repo it
touches. Group semantics, recovery, and integration-readiness are in §13.

### 3.1 State machine (single source of truth)

Full status enum (nothing outside this list is valid):
`draft`, `todo`, `validated`, `running`, `stalled`, `review_pending`,
`accepted`, `merging`, `done`, `failed`, `blocked`, `rejected`,
`superseded`.

- `draft` — plan written, self-review (Phase 2) not yet passed;
- `todo` — self-review passed, waiting on plan review; **ready** =
  `todo` + every `depends_on` in `done`;
- `validated` — plan review is clean (or was skipped, see below);
- `running` — the executor is active (an unfinished run exists);
- `stalled` — a run has gone quiet (heartbeat, §5.3) — needs attention;
- `review_pending` — the executor finished, acceptance (Phase 5) is in
  progress;
- `accepted` — acceptance is clean, waiting on merge;
- `merging` — a merge is in progress;
- `done` — merged, plan is under `completed/`;
- `failed` — the run failed and was not carried to completion (see "On
  failure" in §4);
- `blocked` — waiting on a dependency or an operator decision;
- `rejected` — rejected (moved to `rejected/`);
- `superseded` — replaced by another plan.

Two modifier **flags** (not separate statuses; recorded alongside a status):
- `plan_review_skipped`, set alongside `validated` when `plan_review` was `none`,
  or its tool was unavailable / quota-exhausted for that pass (§12.3) — behaves
  like a plain `validated` in the rest of the flow;
- `review_deferred`, set alongside `done` when a deferred plan-review-only
  pass is still owed (§12.4) — `done` plus an open follow-up task to run plan
  review against the merged branch once quota resets.

Allowed transitions:
```
draft → todo → validated → running → review_pending → accepted → merging → done
running ↔ stalled            (stalled → running on resume, or → failed)
running/review_pending → failed
failed → running             (after a fix, see "On failure" in §4)
todo/validated → blocked|rejected|superseded
blocked → (its prior status)  once the blocker clears
```
Transitions are **adjacent only** when the orchestrator **forward-drives** a
plan — jumps (e.g. `running → done`, skipping acceptance) are never allowed on
that path. Reconcile's activation-settle is the exception: as a repair/settle
pass (not a forward transition) it may set the status **directly** to the
truth-derived value per §3.2 (e.g. `running → done` when a merged head is
reachable, or `todo → review_pending`). Every ROADMAP write is atomic (temp file +
rename). Any status other than `done`/`rejected`/`superseded` with open work
underneath it is a potential blocker for integration readiness (§13).

### 3.2 Reconcile at activation (deterministic)

**Truth priority** (highest wins on disagreement):
1. The integration branch: **is the newest completed run's produced head reachable
   from it?** (`git merge-base --is-ancestor <head_sha> <integration>`, where
   `<head_sha>` is the newest run with `run.json.status == "completed"` — only
   `completed` runs count, since they guarantee `head_sha != base_sha`; a
   `failed`/`interrupted` run may record `head_sha == base_sha` and must not read
   as merged, and `head_sha` survives the post-merge `<slug>` deletion) — the only
   positive signal that settles "merged", covering
   both a `--no-ff` merge commit and a `git.merge_ff=true` fast-forward (which
   leaves no merge commit). A `claude`/manual run has no `run.json.head_sha`, so
   merge is **not** inferred from bare branch reachability (a just-cut branch is
   trivially an ancestor); that case settles via the ROADMAP `done` Phase 6
   writes before deleting `<slug>`, or an idempotent Phase 6 re-run (§5.4: the
   executor moves a plan to `completed/` *before* merge, so `completed/` alone
   cannot be trusted as "done");
2. `run.json` (the finalized result of a run);
3. `running.json` plus a live-process check (is a run actually still going);
4. `completed/`/`rejected/` (where the plan file physically sits) — a
   **weak** signal;
5. the `status` field stored in the ROADMAP itself — least trusted (and the
   one this process repairs).

**Resolution table** (fact → action):

| fact | action |
|---|---|
| the newest `completed` run's produced head (`run.json.head_sha`) is reachable from the integration branch, status ∉ {`done`,`blocked`,`superseded`,`rejected`}, **and no newer live run** | → `done` (auto) |
| a newer **live** run exists (running.json, no terminal run.json, PID alive), **status remappable** — excludes `accepted`/`merging` | → `running` — a live executor outranks an older merged head; never `done` (so retention can't prune its live dir). `accepted`/`merging` take the resume-Phase-6 path instead, so a false-live (reused-PID) run can't demote them |
| status is a human `blocked`/`superseded` | leave unchanged — reconcile never auto-clears a human escalation |
| `status=accepted`/`merging`, branch `<slug>` present, Phase 6 preconditions met | → resume Phase 6 finalize (idempotent re-merge/move/`done`); do **not** rerun the executor or infer `done` from bare branch reachability |
| plan is in `completed/`, branch `<slug>` exists, **not** merged, **status before `accepted`** | → `review_pending` (executor finished, waiting on acceptance + merge) — **not** `done` (an `accepted`/`merging` plan takes the resume-Phase-6 row instead, which has precedence) |
| plan is in `rejected/` | → `rejected` (auto) |
| `status=running`, no live process, `run.json` is final with `status=completed` | → `review_pending` (auto) |
| `status=running`, no live process, `run.json` is final with `status=failed` | → `failed` (auto) |
| `status=running`, no live process, `run.json` is final with `status=interrupted` | → `stalled` (auto) |
| `status=running`, no live process, `run.json` not finalized (or `running.json` present with no `run.json` and no live process) | → `stalled` + **repair-gate** |
| the run's branch exists but its worktree is gone | normal (the executor removes its own worktree on success, §5.4) — leave alone |
| an in-progress knowledge-base sync was left incomplete | finish the write, or note the gap in `notes` |

**Multi-run precedence:** a plan may accumulate several `run_id`s. Order them by
recency — by the fixed-width `YYYYMMDDTHHMMSS` prefix of `run_id`, tie-breaking a
same-second pair by mtime then `started_at` (mtime leads: a crashed/interrupted run's
`run.json` carries no `started_at`; the `-<pid>` suffix is not fixed-width and does
not sort chronologically) — and let the **newest meaningful run decide**: an older
terminal `run.json` never overrides a newer live rerun; within one run dir a terminal
`run.json` still wins over a bare `running.json`. Reachability (priority 1) overrides any
**terminal** run state, but a newer **live** run wins over reachability (a live executor is
active rework — settle `running`, never `done`).

**Auto** — reconcile fixes the ROADMAP to match the fact by itself,
idempotently, with no other side effects. **Repair-gate** — the discrepancy
is surfaced with a suggested action, but nothing irreversible (recreating or
deleting a worktree, re-running the executor) happens without confirmation.

## 4. Plan lifecycle (Phases 1–6)

> **Autonomy note:** the phase gates below run **automatically through to
> `done`** — they do not stop to ask for a go-ahead at every step. The
> operator is asked only when (a) an architecture decision or fork can't be
> resolved from the plan, the code, or a reasonable default, or (b) a
> genuine blocker appears (self-review didn't converge, plan review's
> required fix can't be resolved without an architecture call, the executor
> crashed or half-delivered, acceptance is red or shows regressions, a merge
> conflict, a cross-repo integration blocker, or a non-trivial choice tied
> to quota exhaustion). Preconditions for automatic merge (clean integration
> branch, acceptance green, no open blockers) are never skipped just because
> the phase runs unattended.

For the plan being driven (a `ready` plan, or one named explicitly):

```
Phase 1 — Authoring (if the plan file doesn't exist yet)
  Write <repo.path>/<plans_dir>/YYYYMMDD-slug.md:
    - frontmatter: repo, status, depends_on, feature_id (for cross-repo work)
    - body: `### Task N: <title>` sections (executor format), ordered
      top-down by dependency (no forward references), code-first,
      code comments in English in any example code
    - tests as their own `### Task N: Tests` section, if needed
  Add a ROADMAP row (status=draft).

Phase 2 — Self-review, no plan review involved (always runs, right after
  creation and the ROADMAP row)
  Self-review → improve loop, capped at 5 cycles total.
  Criteria: completeness, executor-format compliance, correct dependency
  ordering, logical soundness, no placeholder implementations, respect for
  that repo's own domain boundaries and rules.
  A non-trivial architecture/strategic decision → spawn a research subagent
  (§7).
  On completion: status=draft → todo.

Phase 3 — Plan review (pre-final)
  Run the plan-review tool directly against the plan .md (read-only) with a
  prompt asking for architecture / feasibility / risk / project-fit review.
  Recipe: §6. Apply the fixes it raises.
  status=validated.
  If plan_review: none → skip this phase entirely: status=validated with flag
  plan_review_skipped, straight to Phase 4. Same degrade (validated +
  plan_review_skipped) if codex is unavailable or quota-exhausted on first
  use (§12.3).

Phase 4 — Executor run (dispatch by the `executor` scalar; §5)
  Two dispatch layers. ralphex/codex -> an external adapter run via
  run-executor.sh with --worktree (headless, background); watch run.json +
  the log, report progress. claude -> in-session: the orchestrator creates
  the <slug> worktree itself and drives a Claude Code subagent pointed at it,
  removing the worktree on return (no run.json/heartbeat). status=running.
  Manual-run (a human implements the plan, or the chosen kind can't run): hand
  the validated plan to the operator and wait for them to report the branch is
  ready, then resume at Phase 5.

Phase 5 — Acceptance (status=review_pending; not tests alone)
  a) Acceptance run: for each repo in the plan/feature group, run
     `scripts/acceptance.sh --repo <name> --base <base>`. `<base>` is the
     executor run's `run.json.base_sha`; in a manual-run (no executor), the
     orchestrator resolves it itself via `git merge-base
     <integration-branch> <slug>`; if neither is available (e.g. first run
     against a fresh clone), the call omits `--base`.
     For a flat repo (no `repos[].monorepo` block), `acceptance.sh` runs
     that repo's configured `lint_cmd` then `test_cmd`, stopping on the
     first failure. For a monorepo repo (`repos[].monorepo.tool` set), the
     orchestrator does **not** build its own project graph or
     affected-file list — it delegates that entirely to the configured
     tool (Nx/Lerna/pnpm/Turbo): `acceptance.sh` runs the tool's
     `affected_build` → `affected_lint` → `affected_test` commands (with
     the `{base}` token substituted) only when **both** a base ref is
     present **and** at least one `affected_*` command is configured for
     that repo; otherwise (no base ref, or no `affected_*` configured) it
     falls back to `full_build` → `full_lint` → `full_test`. For a
     monorepo repo, acceptance order is always build → lint → test,
     regardless of tier (affected or full). Full
     base-ref resolution and fallback rules: `docs/configuration.md` §
     Monorepo repos; a dedicated how-to with tool examples:
     `docs/monorepos.md`. A clean exit code is necessary but not
     sufficient — read the actual output (skipped-test counts, stale
     build-artifact warnings) before calling it green.
  b) Phase 5b — final review (for every executor run unless `final_review:
     none`, independent of plan_review). Dispatched by the `final_review` scalar
     (`in-session` default, `claude`, `codex`, `none`): the reviewer reads the produced
     code — not merely the exit codes — and reviews how the change landed in
     the project: does it do what the plan intended; regressions;
     domain-boundary violations (domain/services/adapters); dead or
     placeholder code; unsafe data-access patterns; non-idempotent message
     handling; that it stays within its product (no new cross-product
     coupling); and whatever else that repo's own rules call out. This is a
     distinct gate from Phase 3 plan review: plan_review reviews the *plan*
     before execution, Phase 5b reviews the *code* after it, and running one
     never waives the other — 5b runs even when plan_review was skipped
     (`plan_review_skipped`) or disabled. A material finding is a blocker
     (escalate), never a silent pass.
  c) Emergent work (surfaced during the run but out of scope for the plan)
     → its own new plan in the right repo + a ROADMAP row (todo).
  d) Knowledge-base sync (§7) — the product's knowledge base is always
     present, so this always runs: determine which notes the change touches:
     a decision with real alternatives → a decision record; a changed
     data/queue contract or domain boundary → an architecture note; a notable
     subsystem/strategy change → its own note; research/experiments → a
     research note. List the intended edits before applying them.

Phase 6 — Finalize (accepted → merging → done)
  Context (§5.4): finalization is orchestrator-owned. Every executor kind
  produces only commits on branch <slug>, unmerged; the orchestrator moves the
  plan to completed/ and updates the ROADMAP here. (The ralphex reference
  executor self-moves the plan to completed/ before merge as an optimization —
  a commit already on the integration branch — so the move step is idempotent.)
  - before merging: `git status --porcelain` is clean on the integration
    branch; branch <slug> is exactly what passed acceptance
  - merge <slug> into the integration branch LOCALLY (per git.merge_ff,
    §9), no push unless git.push_enabled=true; on conflict (the
    integration branch moved ahead, or the move-plan commit collides) —
    resolve it or escalate
  - move the plan under completed/ if not already there (ralphex self-moved
    it; codex/claude did not), status=done in the ROADMAP
  - delete branch <slug> ONLY after status=done is written (its worktree is
    already gone) — done-before-delete, so a crash between the merge and the
    done write leaves the merged branch for reconcile to settle rather than an
    unreconstructable state (a claude/manual run has no run.json.head_sha)
  - apply the knowledge-base edits queued in Phase 5d
  - update the dependency graph / ROADMAP
  - if the plan has a feature_id and EVERY plan in that group is now done
    → report integration readiness for that group's product (§13): "no
    blockers" plus a diff against the last known-good reference point, per
    repo in the product

── move to the next ready plan, or stop ──
```

**Cycle-limit note:** the total review/improvement effort spent on a plan
before it reaches the executor is bounded (self-review ≤ 5 cycles; plan
review gets one final pass with fixes applied). If a plan hasn't
stabilized after 5 self-review cycles, stop and escalate to the operator
rather than looping indefinitely.

**On failure (Phase 4/5):** if the executor failed mid-pipeline, or
acceptance didn't pass, the orchestrator's job is to **find out why and
carry the work to completion**: diagnose the cause → apply a targeted fix,
or re-run the executor on the same branch → repeat acceptance. If it truly
can't be carried through (an unrecoverable error, an ambiguous decision),
stop and ask the operator with the exact current state (what was done,
where it failed, which branch/worktree/log to look at). Half-delivered work
is never left silent: the plan stays `failed`/`running`, and if it belongs
to a `feature_id` group, that group is a blocker for integration readiness
(§13).

## 5. Executor adapter and result contract

The executor has **two dispatch layers**. The external kinds — `ralphex` (Docker
container) and `codex` (host git worktree running `codex exec`) — go through a dedicated
adapter script (`scripts/run-executor.sh`); the in-session `claude` kind is driven by
the orchestrator directly (Phase 4) and never touches this script. A reference
executor's own default CLI wrapper commonly assumes an interactive terminal (aliased
with an interactive flag, or otherwise unusable from a non-interactive shell), so the
adapter invokes the underlying binary/container directly. This is not a thin passthrough
— it is an **adapter**: it produces a machine-readable result the orchestrator can use
to decide success/fail/stalled, instead of parsing human-oriented log text. The `claude`
kind produces no `run.json` — the orchestrator observes the subagent's return directly.

Interface:
```
run-executor.sh --repo <name> --plan <relative-path> [--tasks-only] [extra args...]
```
What it does:
- resolves the repo's absolute path from config (`cfg_repo_field <name>
  path`);
- runs `executor_options.pre_run_hook` if configured (an optional host command,
  e.g. refreshing a credential) — **best-effort**: on failure the adapter logs a
  warning to stderr and the run **continues** regardless;
- creates `<executor_options.venv_cache>/<repo>` when that repo declares
  `venv_isolation: true` (keeps the executor's own virtualenv isolated from
  the host's);
- creates a run directory
  `<executor_options.runs_dir>/<repo>/<slug>/<run_id>/`;
- launches the executor without an interactive TTY, with the mounts listed
  in `executor_options.mounts` plus the venv-cache mount above, working directory
  set to the repo;
- by default adds `--worktree --branch <slug> --idle-timeout
  <executor_options.idle_timeout>` (`--branch` matters: without it, some executors
  strip the date prefix off the plan filename and the resulting branch name
  becomes unpredictable);
- writes `executor.log` (human-readable progress, not JSON) and a separate
  stderr log;
- writes `run.json` on completion (contract below).

The steps above are the `ralphex` (container) path. The `codex` external kind reuses the
same run-directory / `run.json` bookkeeping but, in place of a container, materializes
the `<slug>` worktree on the host (reusing the branch if it exists, else cutting it off
`base_sha`), runs `codex exec -C <worktree> --sandbox workspace-write`
(`executor_options.codex_args`, default `--skip-git-repo-check`), commits any leftover
work on `<slug>`, then removes its own worktree. The in-session `claude` kind bypasses
this script entirely (Phase 4) and writes no `run.json`.

### 5.1 Result contract (`running.json` / `run.json`) and write protocol

Two files per run directory, written by `scripts/run-executor.sh`:
- **`running.json`** — written at **start** (marks "a run is in progress").
  Fields, exactly: `run_id`, `repo`, `plan`, `branch`, `base_sha`,
  `started_at`. `running.json` present without `run.json` means the run is
  active or was interrupted.
- **`run.json`** — written **atomically** on completion (temp file +
  rename), then `running.json` is removed.
  - Normal-completion fields, exactly: `run_id`, `repo`, `plan`, `branch`,
    `base_sha`, `head_sha`, `started_at`, `finished_at`, `exit_code`,
    `status`, `run_dir`. `base_sha` is the `<base>` value Phase 5 (§4)
    feeds to `scripts/acceptance.sh --base` for affected-mode resolution.
  - On **any** unfinished exit before it completes, the adapter's exit trap
    writes a smaller subset instead: `run_id`, `repo`, `plan`, `branch`,
    `status`, `run_dir` — no `base_sha`/`head_sha`/`exit_code`/timestamps in
    that path. The `status` is `failed` by default (the EXIT cleanup trap) and
    `interrupted` only on a trapped INT/TERM signal — so a plain early failure
    yields this same minimal subset with `status: failed`.

`status` is one of exactly three values — `completed`, `failed`,
`interrupted` (nothing else is valid) — computed **deterministically**
(checked top to bottom) on the normal-completion path:
1. `exit_code != 0` → `failed`;
2. `exit_code == 0` and no new commits (`head_sha == base_sha`) → `failed`
   (nothing was actually done) — on the codex path the comparison is against
   this run's starting head (`RUN_BASE`), not the recorded `base_sha`, so a
   codex no-op rerun on a pre-existing branch is `failed` even when
   `head_sha != base_sha`;
3. `exit_code == 0` and new commits exist → `completed`.
The exit trap sets `status=interrupted` (rather than its default `failed`;
see the subset above) only when the process is killed by a trapped INT/TERM
signal before the normal-completion path runs. (`stalled` is never read out of `run.json` — it comes from the
heartbeat against `running.json`, §5.3, or from reconcile finding an
`interrupted` `run.json`, §3.2.)

Mapping to the ROADMAP status (§3.1) — stated directly in §3.2: `completed`
→ `review_pending`; `failed` → `failed`; `interrupted` → `stalled`.

### 5.2 Reading the result

The executor's stdout is typically a human-readable progress log — lines
like `[timestamp] message` — not machine-parseable JSON, even if the
executor's own config asks its internal step for structured output (that
setting usually applies to the executor's inner agent loop, not its own
top-level stdout). So the success criterion is **not** JSON parsing, it's:
1. `exit_code == 0` (primary signal);
2. branch `<slug>` has new commits (`head_sha != base_sha` — on the codex path
   the comparison is against this run's starting head `RUN_BASE`, not `base_sha`);
3. (corroboration) the log tail contains success markers such as "all
   phases completed successfully", a timing/diff-stat summary line, or a
   "moved plan to .../completed/..." line.
Any failure is `exit_code != 0` OR (`exit_code == 0` with no new commits) —
see §5.1 for the exact `status` computation the adapter writes.

### 5.3 Heartbeat

The orchestrator watches `executor.log` growth (mtime/size): no new lines
for longer than a threshold → `stalled` (not `failed`), and it escalates.
The threshold is configurable, default **10 minutes**, kept at or above
`executor_options.idle_timeout` so the container's own idle timeout fires first.

The adapter is launched in the background; the orchestrator watches
`executor.log` for the heartbeat and reads `run.json` once the run ends.

### 5.4 Finalization contract (orchestrator-owned)

Finalization is **uniform across all three executor kinds and owned by the
orchestrator**, not the executor. Every kind is responsible for exactly one thing:
producing commits on branch `<slug>` (in its own isolated worktree), which it removes
when done. **No executor merges** — the feature code stays on `<slug>` until Phase 6,
where the orchestrator merges it locally and moves the plan file to `completed/` +
updates the ROADMAP.

The `ralphex` reference executor additionally **self-moves** the plan to `completed/`
on success — a "move completed plan → `completed/`" commit on the **integration
branch** — as an optimization. This is *not* finalization: it does not merge `<slug>`,
and Phase 6 still owns the merge and the ROADMAP `done` transition. The `codex` and
`claude` kinds do not self-move; Phase 6's move step handles them, and is idempotent
for `ralphex` (reconcile and Phase 6 treat an already-moved plan as
move-already-satisfied — see the Phase 6 recipe in `LIFECYCLE.md`).

Consequences:
- "the plan is under `completed/` on the integration branch" does **not** mean the
  feature is merged — for `ralphex` it only marks that the executor self-moved the
  plan. The real "done" signal is the newest completed run's **produced head being reachable
  from the integration branch** (`merge-base --is-ancestor`, via the `completed` run's
  `run.json.head_sha`) — covering
  both a `--no-ff` merge commit and a `git.merge_ff=true` fast-forward. This is what
  makes truth-priority #1 in §3.2 what it is.
- merging the feature branch is the orchestrator's own job (Phase 6). After a `ralphex`
  run, the integration branch and the feature branch have diverged (the integration
  branch gained the move-plan commit, the feature branch gained the feature commits) —
  `git merge --no-ff <slug>` (or fast-forward per `git.merge_ff`) reconciles them.
- each kind's worktree is already gone by the time the run finishes — nothing to
  clean up there.

## 6. Plan-review recipe

Run the plan-review tool directly against the plan's `.md` file (not the
executor's own review mode, which reviews a code diff, not a plan):
```
export PATH="<plan_review_options.path_prepend>:$PATH"   # only if set
codex exec -C <repo.path> <model/effort flags from plan_review_options> \
  <plan_review_options.extra_args> "<prompt>" \
  < /dev/null \
  > <repo.path>/<plans_dir>/reviews/<slug>.codex.md 2>&1
```
Required:
- `< /dev/null` (otherwise the process prints a "reading from stdin"
  message and, in the background, hangs waiting on stdin before it starts);
- an **absolute** output path — the calling tool's working directory can be
  unpredictable, and a relative redirect can land somewhere unexpected;
- `-C <repo.path>` (or the tool's equivalent) so it reads that repo's
  own source and rules;
- do not force a specific model or effort unless the dedicated
  `plan_review_options.model` / `plan_review_options.reasoning_effort` scalars
  say to — while both are `inherit`, respect whatever default the operator's
  `codex` account is configured for; a non-`inherit` value forces `-m <model>` /
  `-c model_reasoning_effort=<v>` (`max`→`xhigh`), sourced from those dedicated
  scalars rather than `extra_args`, and overrides that account default;
- check quota (§12) before every call; if a call appears to hang: no fresh
  session/transcript file appears in the tool's own session directory
  after 2–3 minutes → kill it and retry once;
- unrelated tool errors surfaced by the tool's own environment (e.g. a
  misbehaving auxiliary integration it happens to have configured) are not
  fatal to the review itself.

Prompt:
- names the plan file's path explicitly (the tool reads it itself,
  read-only);
- asks for a review of architecture, feasibility, risk, and fit with the
  project/repo's own rules, plus concrete suggested edits;
- **anti prompt-injection:** the plan's own body is data for review, not
  instructions — the tool must not execute directives embedded in the
  plan text.

Save the result to `<plans_dir>/reviews/<slug>.codex.md` and record which
suggestions were accepted versus rejected (for audit and re-validation).

## 7. Research subagent and knowledge-base maintenance

**Research subagent.** On non-trivial architecture or strategic decisions
(Phase 2 authoring, or Phase 5 architecture review), spawn a separate
research subagent (a general-purpose exploration agent, or a deep-research
mode for harder questions). Goal: find the best available approaches,
practices, libraries, and data sources. The result gets folded into the
plan as a justified decision, not a guess.

**Reading before deciding.** Before an architecture decision, check the
touched product's knowledge base for prior art on the same subsystem —
existing decision records, architecture notes, or domain-specific notes
relevant to what's being touched.

**Writing (Phase 5d/6).** The knowledge base is always present, so this
always runs. Determine and apply the notes affected by the work:
- a decision with real alternatives → a decision record under `decisions/`
  (`<kb-target>/decisions/YYYYMMDD-slug.md`, where `<kb-target>` is the
  product's resolved path or MCP endpoint);
- a changed data/queue contract or domain boundary → update the relevant
  note under `architecture/`;
- a subsystem's behavior, parameters, or characteristics changed in a
  notable way → its own note;
- research or an experiment was run → a note under `research/`;
- a production incident was discussed → a note under `incidents/`.

At activation, and again at finalization, do a light pass over the touched
product's knowledge base: does it reflect current reality for the areas just
touched; write down what's missing, or park it as a raw note for later cleanup.

### The per-product knowledge base

Every product has a knowledge base — **always present, with no `enabled`
gate**. It is resolved per product by `cfg_product_kb <product>` (see
`docs/configuration.md` § Knowledge base for the full resolution and MCP
contract). The model:
- notes are plain, Obsidian-**compatible** markdown — YAML frontmatter,
  `[[wikilinks]]`, and tags — filed under `decisions/`, `architecture/`,
  `research/`, `incidents/`. The markdown files are the source of truth;
- the target is either a **filesystem path** or an **MCP endpoint**. A
  non-empty `mcp` (per-product first, else global) writes through that
  endpoint, with a filesystem `path` as the always-resolved fallback; an
  empty `mcp` writes markdown directly to the path. Default global base:
  `~/.crosscut/knowledge` (a product with no override lands under
  `<base>/<product>/`);
- **Obsidian is decoupled — and optional.** The knowledge base works with or
  without an Obsidian vault: the operator installs and configures Obsidian
  (or the MCP endpoint) themselves if they want one, and this mode only ever
  reads and writes markdown. Obsidian is never a hard dependency of the rest
  of the methodology;
- every entry references the plan slug, repo, and commit it came from, so it
  stays traceable back to the work that produced it.

## 8. Components

1. `skills/crosscut/SKILL.md` — persona + lean activation core (state machine
   + reconcile, Start/Stop, ROADMAP operations, product-boundary summary,
   invariants). Skill name `crosscut` → activated via `/crosscut`. Detail is
   split into two sibling files read on demand, so activation stays cheap:
   `skills/crosscut/INIT.md` (the `/crosscut init` interview + persist/scaffold)
   and `skills/crosscut/LIFECYCLE.md` (Phases 1–7, recipes — plan-review + quota,
   executor adapter, acceptance, final review, merge, runs retention — cross-repo
   integration readiness, and research/knowledge-base maintenance).
2. `skills/crosscut/scripts/run-executor.sh` — headless executor adapter
   (§5): launch + `run.json` contract, executable.
3. `skills/crosscut/scripts/plan-review-limits.sh` — reads rate limits
   from the plan-review tool's own latest session/transcript file (§12.1);
   no-ops cleanly when `plan_review` isn't the reference kind (`codex`).
4. `skills/crosscut/scripts/discover-repos.sh` — repo auto-detection
   used by `/crosscut init`.
5. `skills/crosscut/scripts/acceptance.sh` — Phase 5 acceptance runner
   (§4): flat repos run `lint_cmd`/`test_cmd`; monorepo repos delegate to
   the configured tool's affected or full-suite targets (`docs/configuration.md`
   § Monorepo repos, `docs/monorepos.md`).
6. `skills/crosscut/scripts/reconcile.sh` — the one-call activation-settle
   (§3.2): one YAML parse, settles every ROADMAP plan's status from git +
   `run.json` state, reclaims stale per-repo locks, event-prunes `done` plans'
   run records, writes the ROADMAP atomically, and prints a JSON summary the
   orchestrator relays. Activation-settle only — never merges, re-runs the
   executor, or touches a branch/worktree/plan file.
7. `<workspace_root>/<roadmap>` — the state index (§3), seeded from
   existing plans on first run; every write atomic.
8. `skills/crosscut/templates/plan-template.md` — the plan-authoring
   template for Phase 1; `<plans_dir>/reviews/<slug>.codex.md` — saved
   plan-review transcripts (§6).
9. `skills/crosscut/templates/crosscut.config.example.yaml` and
   `skills/crosscut/templates/ROADMAP.template.md` — the config schema
   reference and the ROADMAP seed file used by `/crosscut init`.

## 9. Rules and invariants

- Never push unless `git.push_enabled=true`; merge is always local, per
  `git.merge_ff` (default `false` → `--no-ff`).
- No `Co-Authored-By` trailer on any commit this mode makes.
- The executor always runs with `--worktree`; when a repo declares
  `venv_isolation: true`, its virtualenv cache is isolated per
  `executor_options.venv_cache`.
- Every path used or written by this mode is config-resolved at runtime —
  no hardcoded absolute paths, in the skill file or in anything it
  produces.
- Plans for the executor use strictly `### Task N:` sections, ordered
  top-down by dependency.
- Any path an operator marks as do-not-touch in their own repo config/rules
  is respected without exception; secrets (`.env` and equivalents) are
  never read or logged.
- Any irreversible or externally visible action (merge, launching the
  executor) still requires its Phase precondition to hold — the
  precondition itself is never skipped, even though the phase runs
  unattended.
- ROADMAP writes are atomic (temp file + rename); status transitions are
  adjacent only when the orchestrator forward-drives a plan (§3.1; reconcile's
  activation-settle settles directly to the truth-derived status).
- Before merge: the integration branch and the run's worktree are both
  clean (`git status --porcelain` empty); the branch head is exactly what
  passed acceptance. After merge: run a minimal smoke check/tests already
  on the integration branch.
- Half-delivered state is never left silent: carry it to completion, or
  escalate (see "On failure" in §4, and §13).
- Keep each product's knowledge base current (Phase 5d/6); it lives outside
  version control unless the operator chooses to track it — treat writes to
  it as best-effort documentation, not a transactional store.
- Code-first over TDD by default (write the implementation, then tests,
  unless the operator's own repo rules say otherwise); code comments in
  English; respond to the operator in their configured `language`.

## 10. Out of scope (YAGNI)

- A fully autonomous mode with zero operator involvement at all — explicitly
  rejected; an architecture decision or a genuine blocker always surfaces to
  the operator (§4).
- Running multiple executor instances concurrently was previously out of
  scope but is now **implemented** (P4): executors run in parallel across
  different repos and sequentially within a single repo, enforced by an
  atomic per-repo lock (`<runs_dir>/<repo>/executor.lock`, owner file holding
  the owner's PID + token, liveness-checked). An optional top-level
  `max_parallel` caps total concurrent executors (default unbounded across
  repos).
- A web/TUI status dashboard — the ROADMAP as plain markdown is enough.
- A separate global machine-readable state file duplicating the ROADMAP —
  not done: machine truth is git plus each run's own `run.json`; the
  ROADMAP is settled against them by reconcile, not maintained as a second
  source of truth.
- Mandatory backward-compatibility/expand-contract discipline in the code
  the executor produces — applied only when a specific task genuinely
  requires it, not as a blanket rule.
- Auto-push and remote-branch/PR workflows — out of scope; see the git
  safety default in §9.

## 11. Open risks

- Merge conflicts when `--worktree` runs against an integration branch that
  has moved ahead in the meantime (it already picked up the executor's own
  move-plan commit): before merging in Phase 6, check cleanliness and
  escalate on conflict rather than forcing it.
- Cross-repo parallelism (§10) runs concurrent executors against **distinct**
  integration branches, one per repo, so the merge-conflict risk above is
  confined to *within* a single repo — which per-repo serialization (at most
  one executor per repo) prevents. An optional top-level `max_parallel`
  (integer; **default unbounded** across repos) caps the total number of
  concurrent executors when the operator wants to bound load.
- Stale executor locks are bounded by the lock's PID-liveness check plus
  **capture-by-rename** reclaim: a lock whose owner PID is no longer alive is
  `mv`'d aside by the next launcher, the moved copy's owner PID is
  re-validated (restored intact if it turns out live), otherwise the
  moved-aside copy is `rm`'d — a blind `rm -rf "$lock"` is explicitly
  forbidden — so a crashed run never wedges its repo. The residual risk — PID reuse making a dead owner appear live — is
  mitigated by the owner token: release only removes a lock whose stored token
  matches, so a run never drops another owner's lock.
- The 5-cycle self-review cap: if a plan doesn't stabilize in that budget,
  escalate rather than looping.
- Plan-review usage spent *inside* an executor run is invisible on the
  orchestrating side until the next direct plan-review call is made (§12.2) —
  treat a quota reading as a lower bound on remaining budget right after an
  executor run that used plan review internally.

## 12. Quota / rate-limit handling (plan review)

**Fact (reference: codex-shaped plan-review tools):** many such CLIs write
rate-limit state into their own session/transcript files — the latest such
event typically carries something like:
```json
"rate_limits": {
  "primary":   {"used_percent": N, "window_minutes": 300,   "resets_at": <unix>},
  "secondary": {"used_percent": N, "window_minutes": 10080, "resets_at": <unix>},
  "plan_type": "...",
  "rate_limit_reached_type": null
}
```
`primary` is typically a short window (hours), `secondary` a longer one
(days/weeks); `resets_at` is a unix timestamp; a non-null
`rate_limit_reached_type` means the limit is already hit.

### 12.1 Monitoring

`scripts/plan-review-limits.sh` reads the plan-review tool's newest session/
transcript file and reports primary %, secondary %, the nearer `resets_at`,
and whether a limit is already reached. It no-ops cleanly when `plan_review`
isn't the reference kind (`codex`) — including when it is `none`. Applied:
- **proactively**, before every plan-review call (don't burn a call that's
  guaranteed to fail);
- **reactively**, after a call (an error, or `rate_limit_reached_type !=
  null` in the response).
A quota summary is shown at mode activation and at each phase boundary:
`plan_review: 5h N% · weekly N%, next reset <date/time>`.
`wait = resets_at(binding window) − now`.

### 12.2 Quota separation (important)

- **plan-review quota**: spent by Phase 3's plan review and by the
  executor's own internal code-review step.
- **orchestrating-model quota**: spent by plan authoring/self-review
  (Phase 2), the executor's own task-execution phase, and the orchestrating
  session itself.

⇒ The plan-review tool running out never blocks authoring/self-review or the
executor's task phase — only the plan-review step gets parked.
This keeps the backlog moving productively "around" the limit.

Plan-review limits are typically **account-level** (shared between a direct,
host-side call and a call made from inside a container the executor
spawns). If the executor runs in a container that mounts the tool's
credentials/session directory somewhere other than the host's own home
directory, its session/transcript files are written **inside the
container** and don't show up in the host's own session directory — so a
host-side quota reading reflects the budget as of the last **host** call;
usage spent inside an executor run only becomes visible after the next
host-side plan-review call. Treat a reading as a lower bound on what's left.

### 12.3 Phase 3 (plan review) on exhaustion

Exhaustion never blocks progress by default — this is an **autonomous
auto-default**, not gated on operator approval:
1. **Wait + auto-retry** (default, when the binding window resets soon —
   roughly ≤ 60 min): schedule a wakeup for `resets_at` + a buffer, then
   retry. While parked, keep productively authoring/self-reviewing the rest
   of the backlog (orchestrating-model quota, not plan-review quota) and
   batch plan-review calls for right after reset.
2. **Proceed without plan review** (default when the window is not
   imminent — and likewise when `codex` is simply unavailable on first
   use): set `status=validated` with flag `plan_review_skipped` for
   audit — no operator approval is required to take this default path.
3. Escalate to the operator only when the choice is genuinely non-trivial
   (e.g. a high-risk plan where skipping review is a real judgment
   call) — not as a routine gate on the default path above.

### 12.4 Phase 4 (executor pipeline) on exhaustion

Relevant only if the executor's own internal review step depends on the
same plan-review tool. This is likewise an **autonomous auto-default**, not
gated on operator approval:
- plan review healthy → run the full pipeline.
- binding window is **short** (resets soon — roughly ≤ 60 min): pass a wait
  option to the executor if it supports one — the task phase (orchestrating
  model) keeps going while the executor's own internal review step parks
  and retries after reset.
- binding window is **long** (resets in days): don't hold a container idle
  that long — run the executor now **without** its internal plan-review pass
  (the task phase and any non-review checks complete now), and schedule
  a deferred plan-review-only pass on the same branch for after reset;
  ROADMAP flag `done` + `review_deferred`. No operator approval is required
  to take this default path.
- A non-trivial choice here (e.g. dropping the deferred pass entirely
  instead of scheduling it) is escalated to the operator, not decided
  silently.
- Either way, run the executor with its own idle/session timeouts set, so
  it never hangs indefinitely while parked.

## 13. Products, cross-repo features, recovery, and integration readiness

**The product is the integration boundary.** A *product* is a repo's
`product` field, defaulting to its `name` when unset (so a solo repo is its
own product). `cfg_products` lists the resolved product set;
`cfg_product_repos <product>` lists the repos that belong to one;
`cfg_repo_product <repo>` resolves a single repo. Feature grouping,
dependencies, and integration readiness are all scoped **per product** —
never across products. Two repos in different products are independent
integration units and are reported separately.

**Base model:**
- A product's integration branch is not production. Merging into it deploys
  nothing by itself — it is purely an integration point for that product.
- **Deployment is an operator action**, done manually, after the
  orchestrator reports "no blockers" for the product. Whatever
  tagging/versioning scheme the operator uses on deploy is how a diff
  against the last released state gets tracked — this mode doesn't assume a
  specific one.
- Backward compatibility in the code the executor produces is not imposed
  by default (it would add code complexity for no reason); an
  expand/contract approach is used only when a specific task genuinely
  requires it, not as a blanket rule.

**Feature group (`feature_id`).** A cross-repo feature is a group of plans
(one or more per affected repo) sharing one `feature_id`. A `feature_id`
groups **only plans whose repos resolve to the same product** — it never
spans products; a would-be cross-product feature is two separate features,
one per product. This is a bookkeeping marker: the orchestrator knows the
plans belong together and does not consider the feature finished until
**every** plan in the group is `done`.

**Dependencies stay within a product.** A plan's `depends_on` may only
reference plans whose repos share that plan's product. The check is
`cfg_check_depends <slug>` (config.sh): it locates the plan across every
configured repo's `<repo.path>/<plans_dir>/<slug>.md`, reads its frontmatter
`repo`/`depends_on`, and exits non-zero if the slug is unresolved or
ambiguous, if any dependency's plan file is missing/ambiguous or names a
repo absent from the config, or if any dependency resolves to a different
product. A non-zero result is a **blocker** (Phase 2), not something to work
around — cross-product coupling is expressed through a shared contract, not
a `depends_on` edge.

**Recovery on failure is a primary responsibility.** If a plan in a group
fails (executor crash, failed acceptance), the orchestrator must **carry it
to completion**: diagnose → apply a targeted fix or re-run on the same
branch → repeat acceptance. If it can't be carried through, escalate to the
operator with the exact state. Half-delivered state (one repo's half of the
feature merged, the other not) is never left silent — it's an explicit
blocker.

**Local integration readiness is reported per product** (this is **not** a
deployment guarantee — there is no CI gate implied; it's a local "no known
blockers" check; the deploy decision itself stays with the operator). For a
given product, once every plan in every open feature group of that product
is `done`, the orchestrator reports either `no blockers` or `blocked` (with
specifics) **for that product**. Required checks for `no blockers` (all must
pass):
1. every plan in every open feature group of the product is `done`
   (acceptance was green for each);
2. `git status --porcelain` is clean on the integration branch of every
   repo in the product (`cfg_product_repos`);
3. each repo in the product passes local tests/lint **on the integration
   branch** (post-merge) — run via `scripts/acceptance.sh --repo <name>`
   (no `--base`, since there is no plan-branch base ref post-merge): a flat
   repo runs its configured `lint_cmd`/`test_cmd`; a monorepo repo runs its
   `full_*` targets (post-merge acceptance has no meaningful "affected
   since" base, so affected mode never applies here);
4. per repo in the product, a diff against the last known-good reference
   point (however that repo/operator tracks releases) shows exactly what
   would ship — the exact reference-point convention is left to the
   operator's own tooling, confirmed during `/crosscut init`;
5. the list of unresolved blockers for the product is empty.

If any repo in the product isn't ready or failed → the product is
`blocked`, and deployment of that product is not recommended
(half-delivered). One product being `blocked` never blocks a different
product — each is evaluated on its own.

Contract tests (verifying the shape of a shared data record or queue
message between repos) are **optional**, used selectively for genuinely
risky cross-repo changes — never a blanket requirement.
