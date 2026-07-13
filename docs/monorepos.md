# Monorepos reference

A monorepo repo is **one git repo containing many packages** — an Nx workspace, a
Lerna/pnpm workspace, or a Turborepo. This document is the how-to for configuring
one; the base-ref/fallback rules it depends on are also documented in
`docs/configuration.md` § Monorepo repos, and the acceptance-time behavior is
summarized in `docs/DESIGN.md` §4 Phase 5(a). Where the two disagree, trust
`docs/configuration.md` (it documents the actual `acceptance.sh` behavior); this
file is the narrative walkthrough.

## The model

`/crosscut` treats a monorepo repo exactly like any other `repos[]` entry for
everything except acceptance: one `name`, one `path`, one plan directory, one
integration branch. The only thing that changes is which commands Phase 5
(acceptance) runs — instead of a fixed `lint_cmd`/`test_cmd` pair, it runs a
tool-scoped selection of packages.

**Delegation, not reimplementation.** The orchestrator does not parse
`package.json` workspaces, walk a dependency graph, or compute which packages a
diff touched. That is exactly the job Nx/Lerna/pnpm/Turbo already do well, and
`crosscut.config.yaml` only ever holds the shell command that asks the tool to
do it — `acceptance.sh` runs (at most) three commands per acceptance pass and has
no opinion about how the underlying tool scopes, orders, or caches the work
inside them. If you find yourself wanting the orchestrator to understand the
package graph directly, that's a sign the fix belongs in the monorepo tool's own
config instead (see "Push runner quirks into the tool" below).

## The `monorepo:` config block

Attach it to a `repos[]` entry to mark that repo as a monorepo. Once
`monorepo.tool` is set, `acceptance.sh` ignores that repo's `test_cmd`/`lint_cmd`
entirely and uses the commands below instead.

```yaml
repos:
  - name: web-mono
    path: /path/to/web-mono
    kind: nodejs
    monorepo:
      tool: nx                     # nx | lerna | pnpm | turbo
      affected_build: "npx nx affected -t build --base={base}"
      affected_lint:  "npx nx affected -t lint  --base={base}"
      affected_test:  "npx nx affected -t test  --base={base}"
      full_build: "npx nx run-many -t build --all"
      full_lint:  "npx nx run-many -t lint  --all"
      full_test:  "npx nx run-many -t test  --all"
```

| key | required | meaning |
|---|---|---|
| `tool` | yes | `nx \| lerna \| pnpm \| turbo` — presence of `monorepo:` with a `tool` is what marks the repo as a monorepo. `acceptance.sh` doesn't branch on the value itself, only on whether the key is non-empty; it's documentation for the operator/executor. |
| `affected_build` / `affected_lint` / `affected_test` | no | shell command, `{base}` token allowed — build/lint/test only the packages affected since `{base}`. |
| `full_build` / `full_lint` / `full_test` | no | shell command — build/lint/test the whole workspace. Fallback used whenever affected mode doesn't apply. |

None of the six is individually required — an unset command for the chosen tier
is skipped, not substituted from the other tier. But `acceptance.sh` fails with
"no commands configured for repo" if the resolved tier ends up empty entirely, so
configure at least one `full_*` command per monorepo — affected-only, with no
full-suite fallback, breaks the first acceptance run against a fresh clone (no
base ref yet resolvable).

## Supported tools

`tool` is a documented label (`nx | lerna | pnpm | turbo`); `acceptance.sh` itself
just runs whatever command string you give it. Two worked examples:

### nx

```yaml
    monorepo:
      tool: nx
      affected_build: "npx nx affected -t build --base={base}"
      affected_lint:  "npx nx affected -t lint  --base={base}"
      affected_test:  "npx nx affected -t test  --base={base}"
      full_build: "npx nx run-many -t build --all"
      full_lint:  "npx nx run-many -t lint  --all"
      full_test:  "npx nx run-many -t test  --all"
```

`npx nx affected -t <target> --base={base}` computes the changed-since-`{base}`
package set itself (git-diff based) and runs `<target>` only for those packages
plus their dependents, in the topological order Nx's own task graph produces.
`npx nx run-many -t <target> --all` is the full-workspace equivalent.

### lerna

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

`--since {base}` is Lerna's equivalent of Nx's `affected --base` — packages
changed since `{base}` (plus dependents). `--sort` runs the full-suite fallback in
dependency (topological) order.

### pnpm and turbo

No built-in default command is documented here — confirm the exact filter syntax
with the operator during `/crosscut init`. For pnpm, `--filter
'...[{base}]'` (or an equivalent affected filter) selects packages changed since
`{base}` plus their dependents; plain `pnpm -r <script>` already runs in
topological order by default, so the only thing an affected filter buys you is
narrowing the changed set, not fixing ordering. For turbo, `turbo run <target>
--filter='...[{base}]'` is the analogous affected selection.

## Affected vs. full: the selection rule

`acceptance.sh --repo <name> --base <base>` picks a tier by this rule, checked
in order:

1. **Affected mode** runs only when **both**:
   - a base ref is present (resolved by the caller — see below), **and**
   - at least one of `affected_build` / `affected_lint` / `affected_test` is
     configured for that repo.
2. **Full mode** (`full_build` → `full_lint` → `full_test`) runs otherwise — no
   base ref, *or* no `affected_*` command configured. In particular, a monorepo
   entry configured with only `full_*` (no `affected_*` at all) always runs
   `full_*`, even when a base ref resolves cleanly.

### Where `{base}` comes from

Any `affected_*` command may contain the literal token `{base}`, substituted
with the value passed via `acceptance.sh --base <ref>` before the command runs
through `eval`. Resolving *what* that ref is happens one layer up, before
`acceptance.sh` is even called:

1. **Executor runs**: `run.json`'s `base_sha` — the repo's `git rev-parse HEAD`
   at the moment the run started, captured by `run-executor.sh`.
2. **Manual-run** (a human implemented the plan — no executor run happened): no
   `run.json` exists, so the orchestrator resolves a base ref itself, typically
   `git -C <repo.path> merge-base <integration-branch> <slug>`.
3. **No base ref resolvable** (fresh clone, first run, `git merge-base` failure):
   `acceptance.sh` is invoked without `--base` at all → full mode, unconditionally.

### Acceptance order

Fixed regardless of tier: **build → lint → test**. `acceptance.sh` stops at the
first failing command (non-zero exit) and reports that repo's acceptance as
failed.

## Push runner quirks into the tool's targets

`acceptance.sh` only runs the (at most) three commands you configure, in
build → lint → test order — it has no opinion about how the underlying tool
scopes or sequences work *inside* one of those commands. If a workspace needs
more than that — a typecheck step, or making sure a shared package rebuilds
before the packages that depend on it — that belongs in the monorepo tool's own
target configuration, not in `crosscut.config.yaml` or in a change to
`acceptance.sh` itself.

### Example: rebuild a shared package before dependents (Nx)

Declare the dependency in `targetDefaults` in the repo's `nx.json`:

```json
{
  "targetDefaults": {
    "test": {
      "dependsOn": ["^build", "build"]
    }
  }
}
```

`"^build"` means "run `build` on every dependency of this project first";
plain `"build"` means "run this project's own `build` first too". With this in
place, `npx nx affected -t test --base={base}` (the `affected_test` command
above) is enough on its own — Nx's task graph resolves that a shared package
needs rebuilding before a dependent's tests run, and caches what it can. The
`monorepo:` block in `crosscut.config.yaml` stays a thin passthrough; it
never needs to spell out `build` as a separate step before `test`.

### Example: fold a typecheck into the test target (Nx)

Add a `typecheck` target and make `test` depend on it, the same way:

```json
{
  "targetDefaults": {
    "typecheck": {
      "executor": "@nx/js:tsc",
      "options": { "noEmit": true }
    },
    "test": {
      "dependsOn": ["^build", "build", "typecheck"]
    }
  }
}
```

`affected_test: "npx nx affected -t test --base={base}"` then exercises the
typecheck too, without `crosscut.config.yaml` growing a fourth acceptance
command. The same idea applies to Lerna via per-package `npm` lifecycle scripts
(`pretest` running `tsc --noEmit`) plus `--sort`/`--stream` for cross-package
ordering, and to pnpm/turbo via each tool's own pipeline/task-dependency config.

## See also

- `docs/configuration.md` § Monorepo repos — the authoritative field-by-field
  schema reference for `monorepo.*`.
- `docs/DESIGN.md` §4 Phase 5(a) and §13 — how acceptance and integration
  readiness use this at the methodology level.
- `skills/crosscut/scripts/acceptance.sh` — the script that implements the
  selection rule above.
