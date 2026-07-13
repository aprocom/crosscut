# Example: multi-repo, multi-product workspace (python + nodejs)

A sanitized, illustrative `crosscut.config.yaml` for three repos spread across two
**products** (the integration boundary):

- **Product `platform`** — two repos that ship together:
  - `api` — Python (`kind: python`), tests via `pytest`, lint via `flake8`.
  - `web` — Node.js (`kind: nodejs`), tests via `jest`, lint via `eslint`.
- **Product `web-mono`** — one repo, a solo product (no `product:` field → its product
  defaults to its name):
  - `web-mono` — Node.js **monorepo** (`kind: nodejs` + a `monorepo:` block,
    `tool: nx`) — acceptance runs Nx's `affected`/`run-many` targets instead of a
    fixed `test_cmd`/`lint_cmd` pair. See `docs/monorepos.md` for the how-to and
    `docs/configuration.md` § Monorepo repos for the field reference.

Products matter because `feature_id`, `depends_on`, and integration-readiness are all
scoped **per product** — never across products. `api` and `web` share the `platform`
product, so the sample feature below (a plan in each) is allowed to link them.

Use this as a reference for the full config shape, alongside `docs/configuration.md` and
`skills/crosscut/templates/crosscut.config.example.yaml`.

## Files here

- `crosscut.config.yaml` — an illustrative config, with `/path/to/...` placeholders
  in place of real filesystem paths. The real config lives at one fixed global home,
  `~/.crosscut/crosscut.config.yaml` — this copy just shows its shape.
- `ROADMAP.md` — the plan index (same layout as
  `skills/crosscut/templates/ROADMAP.template.md`), grouped **by product**, with two
  sample rows under `platform`: one plan in `api`, one in `web`, linked by a shared
  `feature_id`.
- `README.md` — this file.

## How the real setup works

You do **not** copy this config anywhere. There is exactly one config file, at
`~/.crosscut/crosscut.config.yaml`, and you build it by running
`/crosscut init` **from inside each repo**:

1. **`cd` into a repo and run `/crosscut init`.** The first run creates the global
   home (`~/.crosscut/`), seeds the ROADMAP, and interviews you once for the
   global settings (language, git-safety). Every run — first or later — then asks the
   per-repo questions for the current directory (`$PWD`): which **product** it belongs
   to (join an existing one or start a new solo product), its `kind`, `test_cmd` /
   `lint_cmd`, `plans_dir`, and (python only) `venv_isolation`. It writes the repo into
   the single config, merging by `name`.

2. **Repeat for each repo.** Run `/crosscut init` from inside `api`, then `web`
   (joining product `platform` both times), then `web-mono` (a solo product). Re-running
   it inside an already-registered repo safely updates that repo's entry.

3. **Run `/crosscut`** from anywhere to activate. It reads the global config,
   reconciles the ROADMAP against each repo's `<plans_dir>/{completed,rejected}/`, and
   shows a per-product status summary of the ready plans — then waits for you to choose
   which one to drive (or write a new plan, or just show status). Launched from inside a
   configured repo, it leads with that repo's product. Once you pick a plan, it drives
   that plan autonomously to `done`.

The `crosscut.config.yaml` here is what such a config looks like once all three repos
are registered — handy for reading the schema, or hand-editing if you prefer, but `init`
is the intended path (it rewrites the file from its own interview, so a later `init`
would overwrite a hand-edit for the same repo).

## About `executor` and `plan_review` in this example

Both are shown at their defaults, to illustrate the fully-active shape end to end:

- `executor: ralphex` (Phase 4, autonomous run) — one of `ralphex` (default; needs
  **Docker** + the `ghcr.io/umputun/ralphex:latest` image), `claude` (in-session
  subagent — no Docker/CLI), or `codex` (`codex exec` in a worktree). There is no
  enabled/disabled toggle: Phase 4 always runs the executor, and `executor_options.*`
  tunes the run. See `docs/executors.md`.
- `plan_review: codex` (Phase 3, pre-flight review) — needs a `codex` CLI on `PATH`. Set
  it to `none` to skip Phase 3 entirely: the plan moves to `validated` with the
  `plan_review_skipped` flag instead of being reviewed first. Even with `codex`, if the
  CLI is unavailable or its quota is exhausted on first use, Phase 3 degrades to
  `plan_review_skipped` rather than failing. See `docs/validators.md`.

Whatever `plan_review` is set to, the **Phase 5b final review** (the `final_review` scalar,
default `in-session`) reviews the produced code for every executor run unless
`final_review: none` — plan review checks the *plan* before execution, final review checks
the *code* after it, and neither waives the other.
