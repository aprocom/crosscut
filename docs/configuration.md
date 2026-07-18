# Configuration reference

`crosscut.config.yaml` is the single source of truth for every repo `/crosscut`
drives: which repos are in scope, which **product** each belongs to, how tests/lint
run, where each product's **knowledge base** lives, and how the executor and
plan-review modules behave. Nothing in this plugin hardcodes a path or a repo —
everything is resolved from this file at runtime.

There is exactly **one** config file, at a fixed global home:
`~/.crosscut/crosscut.config.yaml`. It is not per-workspace and not
per-repo — you register each repo into that single file by running `/crosscut init`
from inside it. `workspace_root` is always that home directory; `roadmap` is resolved
relative to it. The knowledge base is resolved separately (see "Knowledge base" below).

A fully annotated example lives at
`skills/crosscut/templates/crosscut.config.example.yaml`; that file and this
document should never disagree — if they do, trust the template.

## Path resolution

`skills/crosscut/scripts/lib/config.sh` resolves the config path in this order:

1. `$CROSSCUT_CONFIG`, if set and the file exists.
2. Otherwise, `~/.crosscut/crosscut.config.yaml`, if it exists.
3. If neither is found, resolution fails (`crosscut_config_path` returns exit status 1)
   and every `cfg_*` helper that depends on it fails the same way.

There is **no** upward search from the current directory (`$PWD`) — the config's
location never depends on where you launch `/crosscut` from. This is the same order
`/crosscut` itself uses when it activates, and the same target `config-mutate.sh`
writes to during `/crosscut init`.

## The PyYAML requirement

`config.sh` reads the config through a small embedded Python snippet:

```python
try:
    import yaml
except ImportError:
    sys.stderr.write("crosscut: PyYAML required (pip install pyyaml)\n")
    sys.exit(3)
```

`python3`'s standard library has no YAML parser, so PyYAML is a hard prerequisite —
without it, every `cfg_get`/`cfg_repo_field`/`cfg_list`/`cfg_repo_names` call exits
**3** with that exact message on stderr. Install it once per machine (or per
container image, if the executor's own environment also needs to read the config):

```bash
pip install pyyaml
```

`/crosscut init` checks for `python3` + PyYAML as part of its tooling detection
and warns (does not hard-block) if either is missing.

## Validation (`/crosscut validate`)

`scripts/config-validate.sh` checks the **whole** config in one pass and prints a
human-friendly, ASCII report. `/crosscut` runs it as a **gate at Start (step 0)** —
before any `cfg_get` — so a hand-broken config is reported clearly instead of failing with a
Python traceback or, worse, running on silent defaults. Run it any time with
`/crosscut validate`, or invoke the script directly:

```bash
bash <skill-dir>/scripts/config-validate.sh            # human report
bash <skill-dir>/scripts/config-validate.sh --json     # {ok, errors, warnings} (+message on meta-errors)
```

It is **standalone** (never calls `cfg_get`), so it can report a malformed file that the
readers themselves could not parse.

- **Errors** block operation (the config is wrong/broken): a non-mapping root; a bad enum
  (`executor` / `plan_review` / `final_review`); a wrong type (`version`, `max_parallel`,
  `executor_options.runs_retention_days` must be integers — and a YAML `true` is **not** an
  integer; `git.*` and `repos[].venv_isolation` must be booleans; `executor_options.runs_dir`
  non-empty); a non-mapping `git` / `knowledge_base` / `*_options` / `products` /
  `products.<name>` / `products.<name>.knowledge_base`; a duplicate repo `name`; an invalid
  `reasoning_effort` on an **active** review/executor stage.
- **Warnings** are advisory (survivable): no repos configured; a repo with no `path` or a
  `path` that does not exist on this machine; an unknown `kind`; an invalid
  `reasoning_effort` on an inactive stage; a **`model` on a `claude` stage** that is not a
  tier alias (`opus`/`sonnet`/`haiku`/`fable`) — the Agent tool honors only tier aliases, so a
  pinned version like `opus-4.8` won't bind on the claude path (codex stages keep their own
  model namespace).

The wizard writes conservative defaults that pass validation, but `validate` performs
additional enum/type checks that the wizard does not enforce (the `reasoning_effort` enum,
the `model` tier-alias, the `repos[].kind` enum, and the `version` integer type — whereas
`config-mutate.sh` passes `*_options` `KEY=VAL` entries through unvalidated and accepts any
`--kind`), so a hand-edited config (or an injected option value) can still trip validation — as an
**error** (a bad `version` type, or an out-of-range `reasoning_effort` on the *active* wired
stage) or a **warning** (an unknown `repos[].kind`, a non-alias `model` on a `claude` stage, or a
`reasoning_effort` on a non-binding stage such as the codex executor). **Exit codes:** `0` valid (warnings
allowed) · `1` validation errors · `2` unparseable YAML · `3` no config file · `4` PyYAML
missing. `--json` emits `{ok, errors, warnings}` (the meta-error exits `2`/`3`/`4` also add a
`message` field and force `ok:false`, `warnings:[]`); `--quiet` drops the success summary.

If your config is hand-editable and you break it, the readers (`config.sh`) also degrade
gracefully now — a malformed YAML makes `cfg_get`/`cfg_check_depends` exit **2** with
`config YAML is invalid (<file>): <reason>; run /crosscut validate` instead of a traceback.

## How the config is built (`/crosscut init`)

You don't copy or hand-write the config — you build it by running `/crosscut init`
**from inside each repo**, and it maintains the single global-home file for you:

- **Create-or-add by presence, not a flag.** `init` runs `crosscut_config_path`: a non-zero
  exit means first run (create the config), exit 0 means the config already exists (add
  this repo to it). The repo being registered is always the current directory (`$PWD`) —
  `init` inspects `$PWD` only (bulk child-scanning is `discover-repos.sh`'s separate job).
- **One question at a time.** The interview asks a single question per turn. On the
  **first run only** it also asks the global block — `language`, `executor`
  (`ralphex`/`claude`/`codex`), `plan_review` (`codex`/`claude`/`none`), `git.merge_ff`,
  and `git.push_enabled` — defaulting each to the value shown but writing whatever the
  operator picks, not a fixed default. Every run then asks the per-repo block:
  `product` (join an existing product from `cfg_products`, or start a new solo one
  defaulting to the repo name), `kind`, `test_cmd`/`lint_cmd`, `plans_dir`, and
  (python only) `venv_isolation`.
- **Atomic, merge-by-name writes.** Persisting the per-repo block goes through
  `skills/crosscut/scripts/config-mutate.sh add-repo`, which merges the repo into
  `repos[]` **by `name`** (update in place if present, else append), overwrites only the
  fields passed, preserves every other repo and key, and rewrites the whole file
  atomically. Re-running `init` inside an already-registered repo first **stops to confirm
  a reassign** (default `no` — leave the repo unchanged); on `yes` it re-runs the per-repo
  questions seeded from the stored values, so an untouched answer stays a no-op. The
  first-run global
  block is persisted separately through `config-mutate.sh set-global`, which writes the
  top-level `language`/`executor`/`plan_review` scalars and the `git.*` booleans (plus
  any `--executor-option KEY=VAL` / `--plan-review-option KEY=VAL` pass-throughs), again
  preserving every other key including `repos[]`.
- **Old-format configs are not migrated.** `init` expects either no config or a config
  already in this schema; a legacy file is not upgraded in place — start fresh.

## Products

A **product** is the integration boundary. Each repo's `product` field (defaulting to
its `name`, so a lone repo is its own product) groups repos that ship together;
`feature_id`, `depends_on`, and integration-readiness are all scoped **per product** and
never cross one (`cfg_check_depends` enforces the `depends_on` boundary at Phase 2). The
resolved product set is whatever the repos' `product` fields produce (`cfg_products`);
the optional top-level `products:` map changes nothing about that *membership*
resolution. That map is **not** wholly inert, though: its
`products.<name>.knowledge_base` sub-key **is** read by a script — `cfg_product_kb`
consults it to resolve where a product's knowledge base lives (see "Knowledge base"
below). Any other keys you add under `products.<name>` (descriptions, ownership) remain
human-facing metadata. The ROADMAP is organized with one section per product.

## Knowledge base

Every product has a **knowledge base** — a durable store of the work's outcomes
(decisions, architecture, research, incidents). Unlike the `memory` module it
replaced, it is **always present: there is no `enabled` toggle**. It is plain
Obsidian-**compatible** markdown — YAML frontmatter, `[[wikilinks]]`, and tags — so it
works **with or without** an Obsidian vault, over either a filesystem path or an MCP
endpoint. Obsidian is optional; the markdown files are the source of truth.

It is configured in two places:

- **Global default** — top-level `knowledge_base: { path, mcp }`. `path` defaults to
  `~/.crosscut/knowledge`; `mcp` defaults to `""` (none). This is the base
  every product inherits from.
- **Per-product override** — `products.<name>.knowledge_base: { path, mcp }`. Either
  field, when set, overrides the global one **for that product only**. Setting the
  per-product `mcp` to the empty string (`mcp: ""`) is an explicit **opt-out**: it forces
  the path form for that product even when a global `knowledge_base.mcp` is configured
  (see resolution step 1 below).

`skills/crosscut/scripts/lib/config.sh`'s `cfg_product_kb <product>` resolves the
effective target and prints exactly one tab-separated line:

1. **`mcp` wins when set — resolved by key presence, not truthiness.** If the
   per-product `products.<name>.knowledge_base` has an `mcp` key, that key is
   authoritative: a **non-empty** value makes the target that MCP endpoint; an
   **empty-string** value (`mcp: ""`) is an explicit **opt-out** that forces the path
   form and does **not** fall through to the global `mcp`. Only when there is **no**
   per-product `mcp` key does the global `knowledge_base.mcp` apply (non-empty → MCP).
   When an MCP endpoint is in effect the line is `mcp\t<endpoint>\t<fallback-path>`: the
   third field is a filesystem path to fall back to (and warn) if the endpoint is
   unavailable, so a note is never lost.
2. **Otherwise `path`.** The line is `path\t<dir>`. `<dir>` is the per-product
   `products.<name>.knowledge_base.path` **verbatim** if set, else
   `<global-base>/<product>` where `<global-base>` is the global `knowledge_base.path`
   (default `~/.crosscut/knowledge`).

All paths — the per-product `path`, the global base, and the MCP fallback — are
`~`-expanded. Notes are filed under a subfolder by kind: `decisions/` (ADRs),
`architecture/` (specs/design), `research/`, and `incidents/`; each note references the
plan slug, repo, and commit it came from. The operator installs and configures Obsidian
(or the MCP endpoint) themselves — this plugin only reads and writes markdown, and never
manages the application. The global fields are written by `config-mutate.sh set-global
--kb-path`/`--kb-mcp` and the per-product fields by `config-mutate.sh set-product <name>
--kb-path`/`--kb-mcp` (both prompted during `/crosscut init`).

## Full schema

Every key below, its type, its default when omitted, and which component actually
reads it at runtime. "Orchestrator" means the running `/crosscut` skill session
itself (it reads config via the `cfg_*` shell functions, following the recipes in
`SKILL.md`) — most keys are consumed there, not by any of the shell scripts in
`scripts/`.

| key | type | default | read by |
|---|---|---|---|
| `version` | int | — (optional; defaults to 1) | schema marker; read only by `config-validate.sh` (integer type-check), not by any runtime script or the orchestrator's logic today — reserved for future migrations |
| `language` | string | `en` | orchestrator (`cfg_get language`) — sets the language of all responses to the operator; asked explicitly during `/crosscut init` |
| `workspace_root` | string (abs path, `~` ok) | `~/.crosscut` (fixed — `init` always writes the home) | orchestrator — base for `roadmap`; it is the crosscut home, never a project directory (the knowledge base has its own base, `knowledge_base.path`) |
| `roadmap` | string (relative to `workspace_root`) | `ROADMAP.md` (skeleton default) | orchestrator — locates the ROADMAP index at `<workspace_root>/<roadmap>` |
| `products` | map: `<name>: {…}` (optional) | absent (product *membership* is derived from `repos[].product`) | product membership is **not** taken from here — the effective product set always comes from the repos' `product` fields (`cfg_products`). But `products.<name>.knowledge_base` **is script-read** (`cfg_product_kb` — see the row below and "Knowledge base" above); any other keys (descriptions, ownership) are human-facing metadata |
| `products.<name>.knowledge_base` | map: `{ path, mcp }` (optional) | absent → this product uses the global `knowledge_base` | `config.sh` (`cfg_product_kb <product>`) — per-product override of the global knowledge base. A non-empty `path`/`mcp` here wins over the global one **for this product only**; `mcp` wins over `path`. A per-product `mcp: ""` (present-but-empty) is an explicit **opt-out** that forces the path form even when a global `mcp` is set — resolution is by `mcp`-key presence, not truthiness. See "Knowledge base" above for the full resolution and MCP contract |
| `repos[].name` | string | — (required) | `run-executor.sh` (`--repo` is matched against it via `cfg_repo_field`); orchestrator (`cfg_repo_names`, ROADMAP `repo` field, plan-review recipe) |
| `repos[].path` | string (abs path) | — (recommended; missing = warning) | `run-executor.sh` (`cfg_repo_field <name> path`, mounted into the executor container as `/project`); orchestrator (plan-review's `-C` flag, `test_cmd`/`lint_cmd` working directory) |
| `repos[].kind` | string: `python \| nodejs \| go \| other` | — (recommended) | `discover-repos.sh` (detects and emits it); orchestrator, during `/crosscut init`, to pick the per-kind `test_cmd`/`lint_cmd` defaults below. Not read by `run-executor.sh` or `plan-review-limits.sh` |
| `repos[].product` | string | the repo's own `name` (a solo, single-repo product) | orchestrator (`cfg_repo_product <name>`, `cfg_products`, `cfg_product_repos <product>`); `cfg_check_depends` (product-boundary enforcement) — a product is the integration boundary: `feature_id`, `depends_on`, and integration-readiness are all scoped per product, never across |
| `repos[].venv_isolation` | bool | `false` | `run-executor.sh` (`cfg_repo_field <name> venv_isolation`) — when `true`, mounts `<executor_options.venv_cache>/<name>` at `/project/.venv` in the container instead of the host's own `.venv` |
| `repos[].test_cmd` | string | — (per-kind default suggested at init; no runtime default) | orchestrator (Phase 5 acceptance: `cd <repo.path> && <test_cmd>`) — not read by any script |
| `repos[].lint_cmd` | string | — (per-kind default suggested at init; no runtime default) | orchestrator (Phase 5 acceptance) — not read by any script |
| `repos[].plans_dir` | string (relative to `repo.path`) | `docs/plans` | orchestrator — plan file location, `<plans_dir>/{reviews,completed,rejected}/` subdirectories — not read by any script |
| `repos[].monorepo` | object (optional) | absent → flat repo, uses `test_cmd`/`lint_cmd` | `acceptance.sh` (`cfg_repo_monorepo <name> <key>`) — see "Monorepo repos" below for the `monorepo` sub-keys |
| `executor` | string (scalar): `ralphex \| claude \| codex` | `ralphex` | Phase 4. Three kinds in **two dispatch layers**: `ralphex` (reference; Docker container) and `codex` (`codex exec --sandbox workspace-write` in an orchestrator-managed git worktree) are **external processes** dispatched by `run-executor.sh` (`cfg_get executor ralphex`); `claude` (in-session Claude Code subagent — needs neither Docker nor a CLI) is run **in-session** by the orchestrator, not through the script. Handing `run-executor.sh` an `executor: claude` exits 2 with `executor kind 'claude' is dispatched in-session, not by run-executor.sh`; any unknown value exits 2 with `executor kind '<x>' not implemented`; an absent key defaults to `ralphex`. There is **no** `enabled` toggle — Phase 4 always runs an executor; handing a plan to a human instead is a *manual-run* (see below), an operator choice, not a config switch |
| `executor_options.image` | string | `ghcr.io/umputun/ralphex:latest` | `run-executor.sh` (`cfg_get executor_options.image`) — the Docker image launched for each run |
| `executor_options.idle_timeout` | string (duration, e.g. `10m`) | `10m` | `run-executor.sh` (`cfg_get executor_options.idle_timeout`, passed to the executor as `--idle-timeout`); orchestrator (heartbeat threshold — kept at or above this value) |
| `executor_options.pre_run_hook` | string (shell command) | `""` (none) | `run-executor.sh` (`cfg_get executor_options.pre_run_hook`) — run via `eval` before launching the container; **best-effort**: on failure it logs a warning to stderr and the run continues anyway |
| `executor_options.mounts` | list of `"src:dst"` strings | `[]` | `run-executor.sh` (`cfg_list executor_options.mounts`) — extra `-v` mounts added to the `docker run` invocation, on top of the repo mount and the optional venv-cache mount. **For `ralphex`:** credential mounts (`~/.claude:/mnt/claude` and, on macOS, `~/.claude/claude-credentials.json:/mnt/claude-credentials.json`) are added automatically before these user-declared entries; you do not need to list them here. Mounts are deduplicated by container target (last wins), so a user-declared mount to the same container target overrides the automatic credential mount and disables the corresponding auto-preparation — an existing manual credential setup continues to work unchanged |
| `executor_options.venv_cache` | string (abs path, `~` expanded) | `~/.cache/crosscut-venv` | `run-executor.sh` (`cfg_get executor_options.venv_cache`) — host directory holding `<venv_cache>/<repo>`, mounted at `/project/.venv` when `venv_isolation: true` |
| `executor_options.runs_dir` | string (abs path, `~` expanded) | `~/.cache/crosscut-runs` | `run-executor.sh` (`cfg_get executor_options.runs_dir`) — base of `<runs_dir>/<repo>/<slug>/<run_id>/` where `running.json`/`run.json`/logs are written. Written by `config-mutate.sh set-global --runs-dir <p>`; `/crosscut init` persists it from the first run |
| `executor_options.runs_retention_days` | int (non-negative) | `0` | `prune-runs.sh` (`cfg_get executor_options.runs_retention_days`) — run-record retention, driven by `reconcile.sh` at activation. **`0`** = a plan's run records are deleted once it is `done` (event-pruned at Phase 6 / reconcile catch-up). **`>0`** = keep records that many days, then a **status-aware** age-sweep removes old run-id dirs (non-live, non-preserved) older than the window while preserving each non-terminal (not `done`/`rejected`/`superseded`) plan's newest `completed` run (its produced head is the merged/done signal): reconcile computes that preserve-set and calls `prune-runs.sh --sweep --preserve-file <f>` (a status-blind `--sweep` alone would strand a plan un-`done`). Under `>0`, `done` plans' records age out via the sweep rather than being event-pruned at Phase 6. Only run-id dirs (`<UTCstamp>-<pid>`) are ever removed — a live run, a run in the preserve-file, and a codex `worktree` are never touched. Written by `config-mutate.sh set-global --runs-retention-days <n>` (validated as a non-negative integer — `0` allowed, negatives and non-numeric rejected) |
| `executor_options.codex_args` | string (extra `codex exec` flags) | `--skip-git-repo-check` | `run-executor.sh` (`cfg_get executor_options.codex_args`, **`codex` executor only**) — word-split and appended to `codex exec -C <worktree> --sandbox workspace-write`; ignored by the `ralphex` and `claude` kinds |
| `plan_review` | string (scalar): `codex \| claude \| none` | `codex` (what `/crosscut init` defaults to) | orchestrator (Phase 3 gate). Three kinds: `codex` (external read-only `codex exec`), `claude` (in-session read-only Claude Code subagent — no external account/quota), `none` (skip Phase 3 → `validated` + `plan_review_skipped`). `plan-review-limits.sh` (`cfg_get plan_review none`) is **`codex`-only** — it no-ops unless the value is exactly `codex`, so both `claude` and an absent key read as "limits n/a". When `codex` but the CLI is unavailable or its quota is exhausted **on first use**, Phase 3 degrades to `validated` + `plan_review_skipped` — never a hard fail. The Phase 5b **final review** (see `final_review`) reviews the produced *code* and runs for every executor run unless `final_review: none` — separate from this plan review |
| `plan_review_options.path_prepend` | string (PATH prefix) | `""` (none) | orchestrator — prepended to `$PATH` before invoking `codex`, only if set; not read by any script |
| `plan_review_options.extra_args` | string (CLI args) | `""` (none) | orchestrator — passed through to `codex exec` verbatim (e.g. `--sandbox read-only --skip-git-repo-check`); not read by any script |
| `plan_review_options.model` | string | `inherit` | orchestrator (Phase 3) — for `plan_review: claude` the Agent `model` (opus/sonnet/…); for `plan_review: codex` the codex model flag. `inherit` = adapter/parent default |
| `plan_review_options.reasoning_effort` | string: `inherit\|none\|minimal\|low\|medium\|high\|xhigh\|max` | `inherit` | orchestrator (Phase 3) — codex maps to its effort flag (`max`→`xhigh`); a `claude` review binds effort only via a Workflow dispatch (bare Agent inherits — advisory) |
| `final_review` | string (scalar): `in-session \| claude \| codex \| none` | `in-session` (what `/crosscut init` defaults to) | orchestrator (Phase 5b gate) — reviews the produced **code/diff** before merge. `in-session` (orchestrator reviews it), `claude` (independent Agent-tool subagent), `codex` (external cross-model review), `none` (skip — **drops the code-safety gate**, more consequential than `plan_review: none`). Runs for every executor run unless `none`; a material finding is a blocker. Written by `config-mutate.sh set-global --final-review <kind>` |
| `final_review_options.model` | string | `inherit` | orchestrator (Phase 5b) — claude alias or codex model per the kind; `inherit` = default. A **different** model than the author improves objectivity (cross-model review) |
| `final_review_options.reasoning_effort` | string (same enum as above) | `inherit` | orchestrator (Phase 5b) — same binding as `plan_review_options.reasoning_effort` (codex mapped; Workflow-dispatched claude; bare Agent advisory) |
| `final_review_options.extra_args` | string (CLI args) | `""` (none) | orchestrator — passed through to the `codex exec` final-review invocation verbatim |
| `executor_options.model` | string | `inherit` | orchestrator (Phase 4) — the Agent `model` for the **`claude` executor** subagent only (the `codex` executor uses `codex_args`, not this key); `inherit` = orchestrator's model |
| `executor_options.reasoning_effort` | string (same enum) | `inherit` | orchestrator (Phase 4) — for the `claude` executor, binds only via a Workflow dispatch (bare Agent inherits — advisory) |
| `git.push_enabled` | bool | `false` | orchestrator (Phase 6 merge recipe) — push after a local merge only when `true`; never otherwise |
| `git.merge_ff` | bool | `false` | orchestrator (Phase 6 merge recipe) — `false` → `git merge --no-ff <slug>`; `true` → omit `--no-ff` and allow a fast-forward |
| `max_parallel` | int (positive) | absent → **unbounded** across repos | orchestrator (Phase 4) — optional cap on the **total** number of executors running concurrently across all repos. Written by `config-mutate.sh set-global --max-parallel <n>` (validated as a positive integer — `0`, negatives, and non-numeric values are rejected). See "Concurrency" below. Independent of the per-repo lock, which already serializes executors *within* one repo regardless of this value |
| `knowledge_base` | map: `{ path, mcp }` | always present (missing keys take the defaults below) | the **global** knowledge base — the default every product inherits. **No `enabled` toggle** (unlike the old `memory` module it replaces): a product's knowledge base is always resolvable. Resolved per product by `config.sh` (`cfg_product_kb`); read by the orchestrator (Phase 5d/6 writes, read before decisions). See "Knowledge base" above |
| `knowledge_base.path` | string (abs path, `~` ok) | `~/.crosscut/knowledge` | `config.sh` (`cfg_product_kb`) — the global base directory. When a product has no `mcp` and no per-product `path`, its notes go under `<knowledge_base.path>/<product>/` (subfolders `decisions/`, `architecture/`, `research/`, `incidents/`). Obsidian-compatible markdown; works with or without a vault |
| `knowledge_base.mcp` | string (MCP endpoint) | `""` (none) | `config.sh` (`cfg_product_kb`) — when non-empty, the global knowledge base is written **through this MCP endpoint** (with `knowledge_base.path` as the disk fallback), instead of directly to disk. A product inherits this only when it has no `mcp` key of its own; a per-product `mcp: ""` opts that product out back to the path form (see `products.<name>.knowledge_base` above) |

## Concurrency

Phase 4 runs executors **in parallel across different repos, but sequentially within a
single repo**. Per-repo serialization is enforced by an atomic per-repo lock
(`<runs_dir>/<repo>/executor.lock`, acquired/released by `run-executor.sh`): at most one
executor holds a given repo's lock at a time, so two runs never touch the same repo's
working tree or integration branch concurrently, while runs against *distinct* repos
proceed at the same time. This is why the merge-conflict risk stays confined to within a
single repo.

The optional top-level `max_parallel` (a positive integer) caps the **total** number of
executors running concurrently across all repos, for operators who want to bound machine
load. It is **independent of** the per-repo lock: the lock already prevents two executors
in the *same* repo no matter what `max_parallel` is, whereas `max_parallel` bounds the
sum across *different* repos. **The default is unbounded across repos** — omit the key and
every repo that has a plan ready can run at once (still one executor per repo). Set it via
`config-mutate.sh set-global --max-parallel <n>`; `0`, negatives, and non-numeric values
are rejected.

## Monorepo repos

Use `monorepo:` on a `repos[]` entry when that repo is **one git repo containing
many packages** (an Nx workspace, a Lerna/pnpm workspace, a Turborepo) and you want
acceptance to run against only the packages a change actually touched, instead of
the whole tree on every plan. `skills/crosscut/scripts/acceptance.sh` checks
`repos[].monorepo.tool` first: if it's set, that repo's `test_cmd`/`lint_cmd` are
ignored entirely and the commands below are used instead. Flat repos (no
`monorepo:` block) are unaffected — they keep using `lint_cmd`/`test_cmd` as today.

| key | type | required | meaning |
|---|---|---|---|
| `monorepo.tool` | string: `nx \| lerna \| pnpm \| turbo` | yes — presence of `monorepo:` with a `tool` is what marks the repo as a monorepo | documented reference for the operator/executor; `acceptance.sh` itself doesn't branch on the value, only on whether the key is non-empty |
| `monorepo.affected_build` | string (shell command, `{base}` token allowed) | no | build only the packages affected since `{base}` |
| `monorepo.affected_lint` | string (shell command, `{base}` token allowed) | no | lint only the packages affected since `{base}` |
| `monorepo.affected_test` | string (shell command, `{base}` token allowed) | no | test only the packages affected since `{base}` |
| `monorepo.full_build` | string (shell command) | no | build the whole workspace — fallback used whenever affected mode doesn't apply (no base ref, *or* no `affected_*` command configured for this repo) |
| `monorepo.full_lint` | string (shell command) | no | lint the whole workspace — same fallback condition |
| `monorepo.full_test` | string (shell command) | no | test the whole workspace — same fallback condition |

None of the six is individually required — a command that's unset for the chosen
tier is skipped, not substituted from the other tier. But `acceptance.sh` fails with
"no commands configured for repo" if the resolved tier ends up empty, so configure
at least one `full_*` fallback per monorepo (affected-only, with no full-suite
fallback, breaks the first run against a fresh clone).

### The `{base}` token and base-ref strategy

Any `affected_*` command may contain the literal token `{base}`. `acceptance.sh`
substitutes it with the base ref passed via `--base <ref>` before running the
command through `eval` — the same trust model as `pre_run_hook`. The `--base` value
itself is treated as untrusted input (it's validated against a git-ref-safe
charset, `^[A-Za-z0-9._@/^~-]+$`, exiting 2 on anything else) before substitution.
Resolving *what* `--base` is gets layered on top by the caller:

1. **Executor runs**: the base ref is `run.json`'s `base_sha` — the repo's
   `git rev-parse HEAD`, captured by `run-executor.sh` at the moment the run
   started (see `docs/executors.md`).
2. **Manual-run** (a human implemented the plan directly — no executor run happened):
   there's no `run.json`, so the operator/orchestrator resolves a base ref itself,
   typically `git merge-base <integration-branch> <slug>`.
3. **No base ref resolvable** (fresh clone, first run, `git merge-base` failure):
   `acceptance.sh` is invoked without `--base`, and it falls back to the `full_*`
   commands for that repo.

A resolved base ref is necessary but not sufficient for affected mode:
`acceptance.sh` only runs the `affected_*` tier when **both** a base ref is present
**and** at least one of `affected_build`/`affected_lint`/`affected_test` is
configured for that repo. If either condition fails — no base ref, *or* no
`affected_*` command set — it runs `full_*` instead. In particular, a monorepo
entry configured with only `full_*` (no `affected_*` at all) always runs `full_*`,
even when `--base` resolves cleanly per (1) or (2) above.

Acceptance order is fixed regardless of tier: **build → lint → test**.

### Lerna equivalent

Swap in Lerna's own since/topological flags for the same shape:

```yaml
    monorepo:
      tool: lerna
      affected_build: "npx lerna run build --since {base}"
      affected_lint:  "npx lerna run lint  --since {base}"
      affected_test:  "npx lerna run test  --since {base}"
      full_build: "npx lerna run build --sort"
      full_lint:  "npx lerna run lint"
      full_test:  "npx lerna run test"
```

`--since {base}` is Lerna's equivalent of Nx's `affected --base`; `--sort` runs the
full-suite fallback in dependency (topological) order.

### Runner quirks belong in the tool's config, not the orchestrator

`acceptance.sh` only runs the (at most) three commands you give it, in build →
lint → test order — it has no opinion about how the underlying tool scopes or
sequences work internally. If a workspace needs more than that — a typecheck step,
or rebuilding a shared package before the packages that depend on it — push that
into the monorepo tool's own target configuration, not into `crosscut.config.yaml`
or the orchestrator's recipe:

- **Nx**: declare it in `targetDefaults` in `nx.json`, e.g. make `build` a
  dependency of `test` (`{ "targetDefaults": { "test": { "dependsOn": ["^build", "build"] } } }`),
  or add a `typecheck` target that `build`/`test` depend on. Nx's task graph then
  handles ordering (and caching); `affected_test: "npx nx affected -t test --base={base}"`
  just triggers it.
- **Lerna**: use per-package `npm` lifecycle scripts (`prebuild`, `pretest`) plus
  `--sort`/`--stream` for cross-package ordering.
- **pnpm**: use `pnpm --filter '...[{base}]'` (or an equivalent affected filter) in
  `affected_build`/`affected_lint`/`affected_test` so the workspace script runs only
  the packages changed since `{base}` plus their dependents, instead of a flat
  `pnpm -r build` that runs everything regardless of what changed. (`pnpm -r` is
  already topological by default — dependency build order isn't the issue here.)

Keep the `monorepo:` block a thin passthrough to whatever single command already
does the right thing for that workspace — don't reimplement the tool's own
dependency graph in `crosscut.config.yaml`.

## Per-kind default command table

Used only during `/crosscut init` (and `--add-repo`) as the starting point for
each repo's `test_cmd`/`lint_cmd` — the operator confirms or overrides them per repo,
and the result is what's actually written to `repos[].test_cmd`/`lint_cmd`. There is
no runtime fallback: `acceptance.sh` treats a flat repo with neither `test_cmd` nor
`lint_cmd` configured as a misconfiguration and exits 2, rather than silently
skipping Phase 5.

| kind | default `test_cmd` | default `lint_cmd` |
|------|--------------------|---------------------|
| `python` | `.venv/bin/pytest` | `.venv/bin/flake8` |
| `nodejs` | `npx jest` | `npx eslint src/` |
| `go` | `go test ./...` | `golangci-lint run` |
| `other` | ask the operator | ask the operator |

`repos[].kind` itself comes from `discover-repos.sh`, which classifies a directory by
the first matching marker file: `pyproject.toml`/`requirements.txt`/`setup.py` →
`python`; `package.json` → `nodejs`; `go.mod` → `go`; otherwise → `other`.

## Minimal example

```yaml
version: 1
language: en
workspace_root: ~/.crosscut
roadmap: ROADMAP.md

repos:
  - name: backend
    path: /path/to/backend
    kind: python
    product: platform          # optional; defaults to the repo name (a solo product)
    venv_isolation: true
    test_cmd: ".venv/bin/pytest -m 'not integration'"
    lint_cmd: ".venv/bin/flake8"
    plans_dir: docs/plans

executor: ralphex              # default; also `claude` (in-session) or `codex` (worktree)

plan_review: codex             # default; also `claude` (in-session) or `none` (skips Phase 3)

git:
  push_enabled: false
  merge_ff: false
```

See `docs/executors.md` for the executor (`executor` / `executor_options.*`) and
`docs/validators.md` for plan review (`plan_review` / `plan_review_options.*`).
