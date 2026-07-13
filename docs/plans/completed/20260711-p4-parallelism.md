---
repo: crosscut
status: done
depends_on: [20260711-p2-selectable-executor]
feature_id: workspace-redesign
---
# P4 — Cross-repo parallelism (sequential within a repo)

**Goal:** Let executor runs for plans in **different repos** proceed in parallel while
staying **sequential within a single repo**, reversing the current "one plan at a time"
non-goal — with an **atomic per-repo lock** so the busy-check↔launch step cannot race.

**Context:** `skills/crosscut/scripts/lib/config.sh` (lock helper),
`skills/crosscut/scripts/run-executor.sh` (acquire/release the lock),
`skills/crosscut/SKILL.md` (Phase 4, Phase 7, reconcile), `docs/DESIGN.md` (§10/§11),
`docs/configuration.md`, `skills/crosscut/scripts/config-mutate.sh` (`--max-parallel`),
`tests/`. Depends on P2.

Design (settled + hardened per the P4 plan-review):
- **Policy:** launch executors for `ready` plans in **different repos** concurrently;
  within one repo, at most one executor at a time. Merges (Phase 6) stay sequential per
  repo. Cross-repo runs touch distinct integration branches, so the merge-conflict risk
  is confined to within a repo — which per-repo serialization prevents.
- **Atomic per-repo lock (fixes the race + stale problems):** a lock is an atomically
  created directory `<runs_dir>/<repo>/executor.lock/` whose `owner` file records the
  owning **PID + a unique owner-token** (e.g. the run's `RUN_ID`, or `$$-$RANDOM`).
  `mkdir` is atomic, so two launches for one repo cannot both acquire a free lock. The
  lock is checked for **liveness** (owning PID alive); a lock whose PID is dead is
  *stale*. **Stale reclaim is atomic**: remove the stale dir then `mkdir` again and
  re-check — whoever's `mkdir` wins owns it (a loser sees busy), never "edit in place".
  **Release is ownership-safe**: only remove the lock when the stored owner-token
  matches the caller's — so a process never releases a lock that was reclaimed by
  another (guards against PID reuse). A completed run releases its own lock, so a
  finalized run leaves the repo free.
- **Uniform across kinds:** `run-executor.sh` acquires the lock for `ralphex`/`codex`;
  the orchestrator acquires it (in-session) around the `claude` subagent. Both release
  on completion/failure/interrupt.

### Task 1: per-repo lock helper (`config.sh`)

Add three functions (bash; the lock is filesystem state, no PyYAML needed). Each
caller passes/keeps a unique owner-token; `acquire` prints the token it took so the
caller can pass it to `release`:
- `executor_lock_acquire <repo> [token]` — `mkdir` the lock dir atomically under
  `<runs_dir>/<repo>/` (runs_dir = `executor_options.runs_dir`, default
  `~/.cache/crosscut-runs`, `~`-expanded). On success write `<pid> <token>` to the
  `owner` file, print the token, exit 0. If the dir exists, read the owner PID: alive →
  exit non-zero (busy). Dead (stale) → **atomic reclaim**: `rm -rf` the stale dir then
  `mkdir` again; if that `mkdir` wins, take ownership (write pid+token) and exit 0,
  else exit non-zero (another launcher won).
- `executor_lock_release <repo> <token>` — remove the lock dir **only if** the stored
  owner-token equals `<token>` (idempotent; never removes another owner's lock).
- `executor_active_for_repo <repo>` — exit 0 (busy) iff the lock exists AND its owner
  PID is alive; else non-zero (free), reclaiming a stale lock. Quiet by default; a
  `--print` flag may emit the owner pid/token for diagnostics.

### Task 1 tests

`tests/`: acquire on a free repo → 0 and lock exists; a second acquire while held by a
live PID → non-zero; a lock owned by a **dead** PID is reclaimed (acquire succeeds;
`executor_active_for_repo` reports free); `release <repo> <token>` frees the repo, but
`release` with a **non-matching token** leaves the lock intact (ownership-safe); a
finalized run (its lock released) → repo free; a lock under a **different** repo does
not mark this repo busy.

### Task 2: run-executor.sh — acquire/release the per-repo lock

External adapters take the lock before doing work: near the top of the run (before
`begin_run`), call `executor_lock_acquire <repo> <RUN_ID>` and capture the returned
owner-token into a var; if acquire fails, exit non-zero with a clear "repo <name>
already has an active executor" message (do not start a second run). Release the lock
with `executor_lock_release <repo> <token>` in the existing cleanup path
(EXIT/INT/TERM) alongside the worktree cleanup, for both `ralphex` and `codex` — so a
stale lock is never left. `EXECUTOR_DRYRUN=1` must NOT acquire the lock (no side
effects).

### Task 2 tests

`tests/run-executor.bats`: a real run holds the lock so a concurrent invocation for the
**same** repo exits non-zero without launching; two **different** repos both proceed;
the lock is released after the run (repo free again); dry-run takes no lock.

### Task 3: SKILL.md — parallel launch, sequential within a repo, reconcile

- Phase 4 / Phase 7: when multiple plans are `ready`, drive them **concurrently across
  different repos**. For `ralphex`/`codex`, `run-executor.sh` enforces the per-repo lock
  (a busy repo's next plan is queued until free). For the in-session `claude` executor,
  the orchestrator calls `executor_lock_acquire`/`release` around the subagent so the
  same repo is serialized. No cross-repo gate — different repos run in parallel. An
  optional top-level `max_parallel` (integer; default unbounded) caps total concurrent
  executors.
- Reconcile: state the **multi-run** expectation explicitly — scan ALL
  `<runs_dir>/<repo>/<slug>/<run_id>/` entries across repos, select the current/final
  record per plan (final `run.json` wins over `running.json`; a `running.json` with no
  live process / a terminal sibling is `stalled`), and reclaim stale locks. Merges stay
  sequential per repo.

### Task 4: DESIGN.md — lift the non-goal, scope the risk

- §10 "Out of scope (YAGNI)": remove the "Running multiple executor instances
  concurrently — one plan at a time" non-goal; replace with the P4 policy (parallel
  across repos, sequential within, atomic per-repo lock).
- §11 "Open risks": note the merge-conflict risk is confined to within a repo (hence
  per-repo serialization); the lock's liveness check bounds stale-lock risk; mention the
  optional `max_parallel` cap.

### Task 5: config + docs

- `config-mutate.sh set-global`: add `--max-parallel <n>` writing top-level
  `max_parallel` (validate a positive integer); + a bats test.
- `docs/configuration.md`: document `max_parallel` (optional, default unbounded across
  repos) and the concurrency policy (parallel across repos, sequential within a repo,
  atomic per-repo lock).
- Confirm no doc still claims single-plan-at-a-time; `bats tests/` stays 100% green.
