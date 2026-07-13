---
repo: crosscut
status: done
depends_on: [20260711-p1-config-foundation]
feature_id: workspace-redesign
---
# P3 — Knowledge base (per-product, Obsidian-compatible, path or MCP)

**Goal:** Replace the old `memory`/`obsidian` config model with a per-product
`knowledge_base` that is always present, writes Obsidian-compatible markdown, targets
either a plain folder (`path`, default) or an MCP endpoint (`mcp`, preferred when set),
and works with OR without Obsidian installed.

**Context:** `skills/crosscut/scripts/lib/config.sh`,
`skills/crosscut/scripts/config-mutate.sh`, `skills/crosscut/SKILL.md`
(memory-module section + Phase 5d/6 + init + top-of-file refs), `docs/configuration.md`,
`docs/DESIGN.md`, `README.md`, `skills/crosscut/templates/crosscut.config.example.yaml`,
`docs/examples/two-repo-python-node/`, `tests/`.

Design (settled during the workspace-redesign discussion):
- `knowledge_base` is always present (no `enabled` flag). Global default:
  `knowledge_base: { path: ~/.crosscut/knowledge, mcp: "" }`. "Always present"
  is realized by the resolver defaulting an ABSENT block to that base — config-mutate
  need not force-write it, but init/example document it.
- Per-product override: `products.<name>.knowledge_base: { path, mcp }`. **Schema note:**
  product *membership* still derives from `repos[].product`; `products.<name>` becomes
  a script-read metadata map (this contradicts the current schema text that says
  `products` is not read by scripts — Task 5 must update
  `crosscut.config.example.yaml` and `docs/configuration.md` accordingly).
- **Resolution** (`cfg_product_kb <product>`): `mcp` wins if a non-empty value is set
  (per-product first, else global); else `path` — the per-product `path` verbatim, or
  `<knowledge_base.path>/<product>` for the shared global base. Every configured
  `path` value is `~`-expanded (not only the built-in default). An empty-string `mcp`
  falls through to `path`.
- **MCP contract:** the stored `knowledge_base.mcp` value is the raw endpoint string
  (the wizard's `mcp:` is only input syntax to distinguish it from a path — the prefix
  is NOT stored). The endpoint is an MCP server reference the orchestrator writes/reads
  notes through in-session. If `mcp` is set but the endpoint is unavailable at runtime,
  SKILL falls back to the resolved `path` target and warns — a note is never lost; so
  `cfg_product_kb` returns `mcp\t<endpoint>\t<fallback-path>` when MCP wins, exposing the
  path SKILL falls back to. The MCP write/read itself is SKILL-layer (in-session), so
  only `cfg_product_kb`'s `mcp`-vs-`path` selection (and the fallback path) is
  bats-testable.
- **Categories** (subfolders): `decisions/` (ADRs) · `architecture/` (specs/design) ·
  `research/` · `incidents/` — domain-neutral; a product may add its own.
- **Obsidian-like style always** (YAML frontmatter, `[[wikilinks]]`, tags).

### Task 1: config.sh — `cfg_product_kb` resolver

Add `cfg_product_kb <product>` (python3/PyYAML, existing style). Compute the path
target first: `products.<product>.knowledge_base.path` (verbatim, `~`-expanded) or
`<knowledge_base.path>/<product>` (global base, `~`-expanded; default base
`~/.crosscut/knowledge`). Then: if a non-empty `mcp` is set
(`products.<product>.knowledge_base.mcp`, else global `knowledge_base.mcp`), print
`mcp\t<endpoint>\t<path-target>` (the third field is the fallback SKILL uses if the
endpoint is unavailable); else print `path\t<path-target>`. Empty-string `mcp` → path.

### Task 1 tests

`tests/`: per-product `mcp` wins; global `mcp` wins when no per-product mcp (and wins
over a per-product `path`); the `mcp` output includes the `<fallback-path>` third field;
empty-string `mcp` falls through to `path`; per-product `path` returned verbatim;
`<base>/<product>` for the shared default; `~` expanded in both a configured global path
and a per-product path.

### Task 2: config-mutate.sh — `set-product` + global KB in `set-global`

- Extend `set-global` with `--kb-path` / `--kb-mcp` → top-level
  `knowledge_base.path` / `knowledge_base.mcp`.
- Add `set-product <name>` writing `products.<name>.knowledge_base.{path,mcp}` (only the
  flags passed), atomic (temp + `os.replace`), preserving `repos[]` and other products.
- **Validation** (all before touching the target, non-zero on failure): non-empty
  product name; reject no-flags-passed, unknown flags, and missing flag values; a
  non-mapping `products`, `products.<name>`, or `products.<name>.knowledge_base` is an
  error, not a silent overwrite.

### Task 2 tests

`tests/config-mutate.bats`: `set-global --kb-path/--kb-mcp` writes the global keys;
`set-product foo --kb-path ...` creates/updates `products.foo.knowledge_base`,
preserving `repos[]` + other products; re-run updates in place; invalid inputs (no
flags, bad name, non-mapping existing node) rejected and atomic (file unchanged).

### Task 3: SKILL.md — knowledge_base module (fully replaces memory/obsidian)

Rewrite the memory-module section AND every stale reference to it (known spots include
`SKILL.md` around lines 94, 293, 452, 507 and the top-of-file refs — sweep for
`memory`, `memory-module`, `memory module`, `obsidian`, and "if enabled" wording tied
to it):
- **Write** durable outcomes at Phase 5d/6 as Obsidian-like markdown into the target
  from `cfg_product_kb <product>` — via MCP when set (fall back to the path + warn if
  the endpoint is unavailable), else the resolved directory — under `decisions/`,
  `architecture/`, `research/`, `incidents/`; each note references plan slug/repo/commit.
- **Read** at activation and before a non-trivial decision (prior art) from the same
  target.
- Always present (no `enabled` gate). Obsidian optional (plain markdown, with or
  without a vault).

### Task 4: init wizard — knowledge-base target question

Extend the `## /crosscut init` wizard, one question at a time, stated as **"Obsidian
or an Obsidian-compatible markdown store"**:
- Global block (first run): default knowledge-base base — a path (default
  `~/.crosscut/knowledge`) or an MCP endpoint (input as `mcp:<endpoint>`;
  store just `<endpoint>`) — persisted via `config-mutate.sh set-global --kb-path/--kb-mcp`.
- Per-repo block, when a **new** product is introduced: that product's target — Enter =
  default `<base>/<product>`, a path, or `mcp:<endpoint>` — persisted via
  `config-mutate.sh set-product <product> --kb-path/--kb-mcp`.

### Task 5: Documentation + examples + broad grep

- `docs/configuration.md`: `knowledge_base` (global `path`/`mcp`), per-product
  `products.<name>.knowledge_base`, the resolution rule + MCP contract, categories;
  **update the "`products` not read by scripts" text** — membership derives from
  `repos[].product`, but `products.<name>.knowledge_base` is script-read metadata; drop
  the old `memory` rows.
- `docs/DESIGN.md`: the knowledge-base model (per-product, path/mcp, Obsidian-decoupled);
  replace the memory-module narrative.
- `README.md`: add a **"Documentation & knowledge"** section — plans live in each repo
  under `docs/plans/`; the knowledge base keeps durable per-product outcomes
  (`decisions`/`architecture`/`research`/`incidents`), plain Obsidian-compatible markdown
  that works **with or without a vault** (path or MCP; Obsidian optional).
- `skills/crosscut/templates/crosscut.config.example.yaml` and
  `docs/examples/two-repo-python-node/crosscut.config.yaml`: replace the `memory`
  block with `knowledge_base` + a commented `products.<name>.knowledge_base` example;
  fix the "`products` is not read" comment.
- **Final grep for LEGACY config/module references** (must return nothing in touched
  scripts/docs/templates/examples, excluding `docs/plans/`):
  `grep -rniE 'memory[-_ ]?module|^[[:space:]]*memory:|obsidian:|obsidian\.|memory\.(enabled|dir|obsidian)'`.
  Prose mentions of "Obsidian-compatible" / "Obsidian optional" are **intentional and
  allowed** — the grep targets the old config keys + module wording, not the word
  Obsidian. `bats tests/` stays 100% green.
