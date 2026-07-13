# /crosscut init

Read this file only when initializing (first run, or adding a repo). Path/script
conventions (`${SCRIPT_DIR}`, `${SKILL_DIR}`, the `cfg_*` API) are defined in `SKILL.md`,
which stays loaded alongside this file.

Init is **global-home** and **per-repo**. The config lives at one fixed path,
`~/.crosscut/crosscut.config.yaml`; the ROADMAP at
`~/.crosscut/<roadmap>` (default `ROADMAP.md`); `workspace_root` is always
that home directory, never `$PWD`. Whether init **creates** a config or **adds a repo**
to the existing one is decided by config presence, not a flag: run `crosscut_config_path`
(from `config.sh`) — a non-zero exit means first run, exit 0 means the config already
exists. The repo being added is always the current directory (`$PWD`) — and when that
repo is **already** in `repos[]`, the per-repo interview first stops to confirm a reassign
(see the already-registered gate in step 3). Old-format
configs are **not migrated** — init expects either no config or a config in the current
schema; if you find a legacy file, tell the operator to start fresh.

**1. Detect available tooling** (informational — never hard-block on a missing tool,
just warn and let the operator decide): `git` (required); `python3` + PyYAML (required —
`config.sh`/`config-mutate.sh` depend on it); `docker` (only if the executor module is
later enabled); a plan_review CLI, e.g. `codex` (only if plan_review is later enabled).

**2. Inspect `$PWD`** (no child scan — that's `discover-repos.sh`'s job for bulk setup):
- `name` = `basename "$PWD"`; `path` = the absolute path of `$PWD`.
- `kind` from marker files at the repo root: `pyproject.toml`/`requirements.txt`/
  `setup.py` → `python`; `package.json` → `nodejs`; `go.mod` → `go`; else `other`.
- `monorepo.tool` from a root marker: `nx.json` → `nx`, `lerna.json` → `lerna`,
  `pnpm-workspace.yaml` → `pnpm`, `turbo.json` → `turbo`; none → flat repo (no
  `monorepo:` block). When present, offer to fill the `monorepo:` block seeded with
  that tool's defaults — Nx: `npx nx affected -t <target> --base={base}` / `npx nx
  run-many -t <target> --all`; Lerna: `npx lerna run <target> --since {base}` / `npx
  lerna run <target>` (pnpm/turbo have no built-in default — ask; see
  `docs/configuration.md` § Monorepo repos). Prefer encoding runner quirks (a typecheck
  step, rebuilding a shared package before its dependents) in the monorepo tool's own
  target config, not in `crosscut.config.yaml`.

**3. Interview — ask exactly one question at a time**, in this order.

**Global block — first run only** (skip entirely when the config already exists):
1. **Language.** What language to respond in going forward (`language`, default `en`).
   Use it for every later question in this interview.
2. **`executor`** — *the agent that actually implements a validated plan*: the build
   stage that writes the code, runs the repo's tests, and commits on the plan branch.
   **When you ask, first explain that role in one line** — the operator is choosing *who
   writes the code*, not a cosmetic knob — then offer `ralphex` (default) / `claude` /
   `codex`:
   - `ralphex` — reference executor; runs in a **Docker** container, backgrounded and
     tracked via `run.json`/heartbeat. **Warn it needs Docker**; without it `ralphex`
     falls back to a manual-run flow (the operator implements the plan by hand).
   - `codex` — drives the codex CLI in a git worktree cut and removed by the codex
     adapter (`run-executor.sh`), not by the orchestrator.
   - `claude` — runs in-session as a Claude Code subagent (no external CLI or Docker;
     draws on this session's budget).
3. **`plan_review`** — *an independent review of the PLAN before any code is written*: a
   pre-build gate that reads the plan + repo **read-only** and returns approve /
   needs-changes. **When you ask, first explain that role in one line**, and that it is
   **distinct from the Phase 5b final review** (which reviews the produced *code*) — then
   offer `codex` (default) / `claude` / `none`:
   - `codex` — external read-only `codex exec` verdict (its own account/quota).
   - `claude` — in-session Claude Code subagent, read-only (uses this session's budget).
   - `none` — skip the pre-build plan review (`validated` + `plan_review_skipped`); the
     Phase 5b code review still runs.
   If the operator picked `plan_review: codex` **and** `executor: codex`, warn that both
   stages then share one codex account (shared quota, plus reduced review independence
   since the same tool plans and reviews). Warn about the **same tradeoff** for
   `plan_review: claude` **and** `executor: claude`: both then draw on the one in-session
   session/task budget, and the same in-session model both plans and implements (shared
   budget + reduced review independence).
4. **`git.merge_ff`** — default `false` (→ `--no-ff` merges).
5. **`git.push_enabled`** — default `false` (local-merge-only, the safe default).
6. **Knowledge base — default store.** The default knowledge-base **base** every product
   inherits, held in an **Obsidian or Obsidian-compatible markdown store**. Ask for a
   path (default `~/.crosscut/knowledge`) **or** an MCP endpoint entered as
   `mcp:<endpoint>` — when the answer starts with `mcp:`, store just `<endpoint>` (drop
   the `mcp:` prefix). Persist via `config-mutate.sh set-global --kb-path <p>` (path) or
   `config-mutate.sh set-global --kb-mcp <endpoint>` (MCP).

**Per-repo block — every run** (this is the whole interview on an add-repo run):

**Already-registered gate — add-repo run only** (skip on first run): before asking
question 7, check whether `repos[]` already holds this repo — match `basename "$PWD"`
against `cfg_repo_names`. If it does, **do not silently re-interview**:
- State plainly that repo `<name>` is **already registered**, and echo its current stored
  fields (`path`, `kind`, `product`, `test_cmd`, `lint_cmd`, `plans_dir`,
  `venv_isolation`) via `cfg_repo_field`.
- Ask **one** yes/no question — reassign this repo's parameters? — **default `no`**.
  - **`no`** → change nothing; report the repo is left unchanged and stop init (there is
    nothing to persist — the missing-plan-dirs scaffold in step 4 still runs).
  - **`yes`** → run questions 7–12, but **seed every default from the existing stored
    value** (fall back to detection / the per-kind table only where a stored value is
    empty), so pressing Enter *preserves* the current setting instead of resetting it.
    `add-repo` overwrites only the fields you pass, and the interview passes them all, so
    seeding from the stored value is what keeps an untouched answer a no-op.

7. **`product`** — offer the existing products from `cfg_products` to join, or a new
   product name, defaulting to a solo product equal to the repo `name`.
8. **Product knowledge base — only when the product is new** (skip entirely when the repo
   joins a product that already exists; that product keeps its knowledge base). For a
   newly introduced product, ask its knowledge-base target: Enter accepts the default
   `<base>/<product>` (`<base>` is the global store from question 6), or give a path, or
   an MCP endpoint as `mcp:<endpoint>`. Persist via `config-mutate.sh set-product
   <product> --kb-path <p>` or `config-mutate.sh set-product <product> --kb-mcp
   <endpoint>`.
9. **Confirm `kind`** (from the detection in step 2; let the operator override).
10. **`test_cmd`** and **`lint_cmd`**, seeded from this per-kind table (`lint_cmd` may be
   left empty):

   | kind | default `test_cmd` | default `lint_cmd` |
   |------|--------------------|---------------------|
   | python | `.venv/bin/pytest` | `.venv/bin/flake8` |
   | nodejs | `npx jest` | `npx eslint src/` |
   | go | `go test ./...` | `golangci-lint run` |
   | other | ask the operator | ask the operator |

11. **`plans_dir`** — default `docs/plans`.
12. For **`python`** repos only: **`venv_isolation`** (`true`/`false`, default `false` —
   isolates the executor's `.venv` from the host's).

**4. Persist and scaffold:**
- **First run:** create `~/.crosscut/`, then materialize the ROADMAP at
  `~/.crosscut/<roadmap>` from `${SCRIPT_DIR}/templates/ROADMAP.template.md`
  (if absent). The config file itself is created by the first `config-mutate.sh set-global`
  call below (it writes a skeleton with `workspace_root: ~/.crosscut` when the
  target is absent). Persist the global answers with
  `${SCRIPT_DIR}/scripts/config-mutate.sh set-global --language <l> --executor <e>
  --plan-review <p> --final-review in-session --merge-ff <bool> --push-enabled <bool>
  [--kb-path <p> | --kb-mcp <endpoint>] --runs-dir ~/.cache/crosscut-runs
  --runs-retention-days 0
  --plan-review-option model=inherit --plan-review-option reasoning_effort=inherit
  --final-review-option model=inherit --final-review-option reasoning_effort=inherit
  --executor-option model=inherit --executor-option reasoning_effort=inherit`
  (add more `--executor-option KEY=VAL` / `--plan-review-option KEY=VAL` /
  `--final-review-option KEY=VAL` for any kind-specific settings) — this writes the
  operator's chosen `executor` / `plan_review` and default knowledge base rather than
  fixed defaults. **Always persist `--runs-dir` and `--runs-retention-days`** (default the
  runs dir to `~/.cache/crosscut-runs` and retention to `0`) so both are recorded from
  the start; `0` means a plan's run records are pruned once it is `done`; a positive value
  keeps records that many days, then `reconcile.sh` age-sweeps them (status-aware — each
  non-terminal (not `done`/`rejected`/`superseded`) plan's newest `completed` run is preserved as the merged/done signal; see
  `${SKILL_DIR}/LIFECYCLE.md` § Runs retention). **Always persist `--final-review`
  (default `in-session`) and the `model` / `reasoning_effort` defaults (`inherit`)** for the
  plan_review / final_review / executor stages, so model and reasoning type are recorded in
  the default config and are tunable (see `${SKILL_DIR}/LIFECYCLE.md` § Final review for how each binds). No
  extra interview question — these are written with their defaults unless the operator overrides.
- **Every run** (skip when the already-registered gate above was answered `no` — there is
  nothing to write): persist the repo by running
  `${SCRIPT_DIR}/scripts/config-mutate.sh add-repo --name <name> --path <abspath>
  --kind <kind> --product <product> --test-cmd <cmd> --lint-cmd <cmd> --plans-dir <dir>
  [--venv-isolation true|false]`. It merges into `repos[]` **by `name`** (update in place
  if present, else append), overwrites only the fields you pass, preserves every other repo
  and key, and writes the file atomically — so an add-repo run that reaches this step
  (first add, or a re-add the operator confirmed) safely updates the entry. When
  question 8 introduced a **new** product, also persist that product's knowledge base
  with `${SCRIPT_DIR}/scripts/config-mutate.sh set-product <product> --kb-path <p>` (or
  `--kb-mcp <endpoint>`); skip this when the repo joined an existing product.
- Create `<repo.path>/<plans_dir>/{reviews,completed,rejected}/` if missing.
- **Autonomy — crosscut command allowlist (offer; skip when the already-registered gate
  above was answered `no`).** So the orchestrator can run its routine helper scripts
  without a permission prompt on every call, **offer** to allowlist crosscut's own scripts.
  **First read the candidate target** — the recommended **global** `~/.claude/settings.json`
  (one entry covers every repo and CWD, since the resolved `${SCRIPT_DIR}/scripts` path is
  fixed) — and if both rules below are already present, **skip the offer silently** (the
  merge would be a no-op). Otherwise ask **one** yes/no — add it now? (default `yes`) — and,
  if yes, let the operator choose that global target or the **project**
  `<$PWD>/.claude/settings.local.json` (gitignored; applies only when `/crosscut` is
  launched from that repo). Then **merge — never replace** — into `permissions.allow`,
  resolving `${SCRIPT_DIR}` to its **absolute** path and adding only the rules not already
  present:
  - `Bash(bash <abs-SCRIPT_DIR>/scripts/*)` — covers `bash <dir>/….sh …` invocations
    (e.g. config-validate, run-executor).
  - `Bash(<abs-SCRIPT_DIR>/scripts/*)` — covers directly-executed invocations (e.g.
    acceptance.sh, config-mutate.sh, prune-runs.sh, discover-repos.sh).
  Both globs are added, so a script is covered whichever form the recipes use — some (e.g.
  plan-review-limits) appear both ways. Scope is deliberately **crosscut's own scripts
  only**: the repo's `test_cmd` and `docker` run *inside* those scripts (acceptance.sh runs
  `test_cmd`; run-executor.sh drives docker), so they need no separate rule — while
  `codex exec` and `git merge/worktree` stay prompted. Emit each script call with the
  **literal** resolved absolute path (resolve the recipes' `${SCRIPT_DIR}` placeholder
  rather than leaving an unexpanded `$SCRIPT_DIR` in the command string), or the globs
  won't match. If the operator picks the project file and it is newly created, make sure
  `.claude/settings.local.json` is gitignored. Write the JSON atomically.
