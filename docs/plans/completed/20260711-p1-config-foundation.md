---
repo: crosscut
status: done
depends_on: []
feature_id: workspace-redesign
---
# P1 — Config foundation: global home, products, init rewrite

**Goal:** Move `/crosscut` to a single global home `~/.crosscut/` (one
config + one ROADMAP for all projects), register each project by running `init` from
inside its own repo, and introduce a `product` grouping that bounds cross-repo
coordination — delivering a working orchestrator on the new config model with
sensible defaults (`executor: ralphex`, `plan_review: codex`). Selectable executor
kinds (P2), the knowledge base (P3), and cross-repo parallelism (P4) build on this.

**Context:** `skills/crosscut/scripts/lib/config.sh`,
`skills/crosscut/scripts/run-executor.sh`,
`skills/crosscut/scripts/validator-limits.sh`, a new
`skills/crosscut/scripts/config-mutate.sh`, `skills/crosscut/SKILL.md`,
`skills/crosscut/templates/ROADMAP.template.md`,
`skills/crosscut/templates/crosscut.config.example.yaml`, `docs/configuration.md`,
`docs/DESIGN.md`, `docs/executors.md`, `docs/validators.md`, `docs/monorepos.md`,
`docs/examples/two-repo-python-node/` (config + README + ROADMAP), `README.md`, and
`tests/` (incl. `tests/fixtures/*.yaml`). Sets defaults only — the
executor/plan_review/knowledge-base *wizard questions* arrive with P2/P3. The repo's
old-format root `crosscut.config.yaml` has already been removed.

**Exact new schema (this plan is the source of truth for it):**
```yaml
version: 1
language: ru                      # init asks; drives orchestrator response language
workspace_root: ~/.crosscut   # fixed to the global home
roadmap: ROADMAP.md               # relative to workspace_root → ~/.crosscut/ROADMAP.md
git: { merge_ff: false, push_enabled: false }
executor: ralphex                 # scalar; P1 implements ralphex only
executor_options:                 # optional; overrides for the active executor
  image: ghcr.io/umputun/ralphex:latest
  idle_timeout: 10m
  mounts: [ ... ]
  venv_cache: ~/.cache/crosscut-venv
  runs_dir: ~/.cache/crosscut-runs
  pre_run_hook: ""
plan_review: codex                # scalar: none | codex
plan_review_options:              # optional (formerly validator.*)
  path_prepend: ""
  extra_args: "--sandbox read-only --skip-git-repo-check"
products: {}                      # optional per-product metadata (P3 fills it)
repos:
  - { name, path, kind, product, test_cmd, lint_cmd, plans_dir, venv_isolation, monorepo? }
```

### Task 1: config.sh — canonical global home + product helpers

- **Resolution (fixes the shadowing bug):** rewrite `crosscut_config_path` to resolve
  `$CROSSCUT_CONFIG` → `$HOME/.crosscut/crosscut.config.yaml` **only**.
  **Remove the upward-from-`$PWD` search** so a stray repo-local config can never
  shadow the home. The home is `$HOME`-relative and still overridable by
  `$CROSSCUT_CONFIG`, consistent with the "no hardcoded absolute paths" invariant.
- Add helpers (existing Python/PyYAML pattern): `cfg_repo_product <name>` (repo's
  `product`, default = its `name`); `cfg_products` (sorted unique products);
  `cfg_product_repos <product>` (repos in a product).

### Task 1 tests

Update `tests/config.bats`: **replace** the upward-search test with a home-fallback
test (`$CROSSCUT_CONFIG` unset → resolves the home path when present) and keep the
not-found (exit 1) case; env-var precedence still holds. Add product-helper tests
(`cfg_repo_product` default, `cfg_products` unique+sorted, `cfg_product_repos`).

### Task 2: Config schema — scalar executor / plan_review (+ *_options), migrate readers, fixtures, docs

- **executor:** scalar (default `ralphex`). In `run-executor.sh`: remove the
  `executor.enabled` gate; read `cfg_get executor ralphex`; move every advanced read
  to `executor_options.*` (`image`, `idle_timeout`, `mounts`, `venv_cache`,
  `runs_dir`, `pre_run_hook`); the `ralphex` case is the current Docker invocation;
  any other value exits non-zero ("only ralphex implemented in P1"). No `enabled` flag.
- **plan_review:** rename the `validator` role to `plan_review`, scalar (`none` |
  `codex`, default `codex`). Rename `validator-limits.sh` → `plan-review-limits.sh`,
  keying on `plan_review`/`plan_review_options.*` (no-op unless `codex`). Update every
  `validator*` reference and prose in `SKILL.md` to `plan_review`, and
  `validator_skipped` → `plan_review_skipped`. Preserve the distinction: `plan_review`
  reviews the **plan**; it is not the code review.
- **Codex-unavailable default:** document that when `plan_review: codex` but `codex`
  is absent or its quota is exhausted on first use, Phase 3 degrades to
  `validated` + `plan_review_skipped` (existing quota-handling rule), never a hard
  fail.
- **Migrate all fixtures + their tests to the new schema:** rewrite
  `tests/fixtures/*.yaml` (drop `executor.enabled`; `executor:` scalar +
  `executor_options:`; `validator:` → `plan_review:`/`plan_review_options:`) and fix
  the assertions in `tests/config.bats`, `tests/run-executor.bats`,
  `tests/validator-limits.bats` (renamed) so the suite stays green.

### Task 2 tests

Covered above (fixture + assertion migration). Add: `run-executor.sh` via
`EXECUTOR_DRYRUN` builds the ralphex command with no `enabled` gate; unknown
`executor` exits non-zero; `plan-review-limits.sh` no-op unless `plan_review == codex`.

### Task 3: config-mutate.sh + rewrite `/crosscut init`

- **New helper `skills/crosscut/scripts/config-mutate.sh`** (deterministic,
  testable via bats): given repo fields on argv/env, **merge the repo into `repos[]`
  by `name`** (update in place or append) and **write the config atomically** (temp
  file + rename), preserving every other key. This is the mutation the wizard calls,
  extracted out of SKILL prose so it can be tested.
- **Rewrite `## /crosscut init` in `SKILL.md`:** home is always
  `~/.crosscut/crosscut.config.yaml`; ROADMAP `~/.crosscut/<roadmap>`;
  `workspace_root` fixed to the home. First run creates home + config + ROADMAP;
  later runs load it. Create-or-add by config presence. Repo = `$PWD` (derive
  name/path; detect kind/monorepo inline; no child scan — `discover-repos.sh` stays as
  an optional bulk helper). One question at a time. Global block (first run only):
  language; `git.merge_ff`; `git.push_enabled` (executor/plan_review/KB questions come
  in P2/P3 — init writes defaults `executor: ralphex`, `plan_review: codex`). Per-repo
  block (every run): product (existing from `cfg_products` / new / default solo = repo
  name); confirm `kind`; `test_cmd`; `lint_cmd` (may be empty); `plans_dir` (default
  `docs/plans`); python → `venv_isolation`. Persist via `config-mutate.sh`; create
  `<plans_dir>/{reviews,completed,rejected}/`. Note old-format configs are not migrated.

### Task 3 tests

`tests/config-mutate.bats`: add-repo appends a new repo; re-adding the same `name`
updates in place and preserves other keys and other repos; the atomic write leaves no
partial file (simulate failure before rename); a product value is recorded.

### Task 4: product-boundary helper + ROADMAP by product + mandatory code review

- **Product boundary as a testable helper** (in `config.sh` or `config-mutate.sh`):
  `cfg_check_depends <slug>` verifies a plan's `depends_on` only references plans whose
  repos share its product; cross-product → non-zero (blocker). **Contract for
  deterministic tests:** the plan's `repo` and `depends_on` come from that plan file's
  YAML frontmatter (plans live at `<repo.path>/<plans_dir>/<slug>.md`; the slug→plan
  file is found by scanning configured repos' `plans_dir`); repo→product via
  `cfg_repo_product`. Behavior — empty `depends_on` → exit 0 (ok); a dependency slug
  with no matching plan file, or whose repo is not in the config → exit non-zero
  (unresolved dependency); a slug matching plan files in two different repos → exit
  non-zero (ambiguous). `SKILL.md` calls it and treats any non-zero as a blocker.
- **ROADMAP grouping (specified):** `templates/ROADMAP.template.md` gets one section
  per product, `## Product: <name> (repos: ...)` over its own table (columns
  unchanged). Specify migration: on first product-aware write, existing flat rows are
  bucketed by their repo's product; a new plan's row is inserted under its repo's
  product section, creating the section if absent; duplicate product sections are
  normalized to one. Also rename the leftover `validator_skipped` →
  `plan_review_skipped` in `ROADMAP.template.md`. `SKILL.md` reconcile/summary reports
  counts per product.
- **Product scoping + mandatory Phase 5b** in `SKILL.md` + `docs/DESIGN.md`:
  `feature_id`/`depends_on` scoped within a product; integration readiness per product;
  `/crosscut` from inside a repo defaults to that repo's product. Make Phase 5b
  explicit and mandatory — the orchestrator reviews the produced code for every
  executor, independent of `plan_review`.

### Task 4 tests

`tests/`: the boundary helper rejects a cross-product `depends_on` (non-zero) and
accepts an in-product one; ROADMAP writer places a row under the correct product
section (dry-run/unit if a helper is extracted, else document as a SKILL-layer check).

### Task 5: Documentation + examples (all old-schema references)

Update every authoritative surface to the new schema — leaving any stale is a
correctness risk:
- `docs/configuration.md`: global home + resolution (env → home, no upward search);
  `product` field + `products:` map; scalar `executor` + `executor_options`; scalar
  `plan_review` + `plan_review_options` (with the codex-unavailable degrade); the
  rewritten init.
- `docs/DESIGN.md`: config-model + init narrative + §13 per-product model; home is
  `$HOME`-relative (invariant-compatible).
- `docs/executors.md`, `docs/validators.md`, `docs/monorepos.md`: replace
  `executor.enabled`/`validator.*` wording with the new scalar model and
  `plan_review` naming.
- `skills/crosscut/templates/crosscut.config.example.yaml` and
  `docs/examples/two-repo-python-node/{crosscut.config.yaml,README.md,ROADMAP.md}`:
  rewrite to the new schema (global-home shape, `product` fields, scalar
  `executor`/`plan_review`, `*_options`, `products:` map, per-product ROADMAP sections).
- `README.md`: Install/Quickstart → "run `/crosscut init` from inside each project"
  against the global home; drop per-workspace/per-repo config wording.
