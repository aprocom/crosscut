# crosscut

Turn [Claude Code](https://claude.com/claude-code) into a hands-off project
manager for your code — one that plans the work, checks the plan, (optionally)
writes the code, runs your tests, and merges the result. Across one repo or
many, all driven by a single config file.

## What it does

Normally you steer Claude Code one instruction at a time. `crosscut`
lets you hand it a bigger goal and have it carry that goal through the same
five-step track every time — like an assembly line for a piece of work:

```
plan  →  validate  →  execute  →  accept  →  merge
```

| Step | What happens | Plain English |
|------|--------------|---------------|
| **1. Plan** | Claude writes a detailed implementation plan into the repo, then reviews and improves its own plan. | "Here's exactly what I'm going to do, and I double-checked it." |
| **2. Validate** *(optional)* | An outside tool reads the plan and gives a second opinion — it only reads, it doesn't change anything. | "A reviewer signed off before any code was written." |
| **3. Execute** *(pluggable)* | A coding agent implements the plan in a safe, separate copy of your repo (a git *worktree*) and produces a branch of commits. | "The code got written on a side branch, not on your live files." |
| **4. Accept** | Your lint and tests run, plus a review of the logic and design — not just a green test run. | "Tests and lint pass, and the approach holds up." |
| **5. Merge** | The branch is merged into your integration branch **on your machine**, and the plan is filed as done. | "Merged locally and the paperwork is tidy." |

Everything above is controlled by one file, `crosscut.config.yaml`: which
repos exist, which **product** each belongs to, how to test and lint each one, how
plan review and the executor behave, and the git-safety settings. There is a single
config, at `~/.crosscut/crosscut.config.yaml` — nothing is hardcoded to a
specific project or machine.

> **Plan review and the executor are pluggable modules.** Plan review (step 2) defaults
> to `codex`, or can be `claude` (in-session) or `none`. The executor (step 3) has three
> choices — `ralphex` (Docker), `codex` (the `codex` CLI), or `claude` (an in-session
> Claude Code subagent that needs neither Docker nor a CLI). Whichever you pick, code is
> only ever written on an isolated side branch, never merged or pushed automatically; and
> if the chosen executor can't run in your environment, driving a plan just hands it to
> you to implement (a *manual-run*). See [Is it safe?](#is-it-safe) below.

## What you need

**To get started, all you need is:**

- **Claude Code** (any recent version) — see the [install guide](https://code.claude.com/docs/en/setup)
- **Python 3** with **PyYAML** — `pip install pyyaml` (used to read the config file)

That's it. Planning, acceptance, and merging all work with just these.

**Optional extras**, only if you want the extra steps to actually run:

- **Plan review (step 2)** — reads the plan and gives a second opinion. Choose
  `plan_review: codex` (the default; the external `codex` CLI), `plan_review: claude`
  (an in-session Claude Code subagent — no external tool), or `none` to skip step 2. If
  `codex` is configured but not installed or out of quota, step 2 simply degrades to
  skipped rather than failing.
- **The executor (step 3)** — the coding agent that writes code for you. Three choices,
  each with its own requirement:
  - **`claude`** — an in-session Claude Code subagent. The dependency-light option:
    needs **neither Docker nor any CLI**, just the Claude Code session you're already in.
  - **`ralphex`** (the default) — the [`ralphex`](https://github.com/umputun/ralphex)
    reference runner, which runs in **Docker**, so you'd need Docker for it.
  - **`codex`** — runs the **`codex` CLI** against a git worktree (the same account a
    `codex` plan review would use).

  Whichever you pick, if it can't run in your environment, step 3 falls back to a
  manual-run (you implement the plan yourself).

Each is a swappable module — see [Bring your own tools](#bring-your-own-tools).

*(Contributors also need [`bats`](https://github.com/bats-core/bats-core) to run
the test suite in `tests/`.)*

**Monorepos** (Nx, Lerna, and similar) are supported alongside ordinary repos —
acceptance asks the monorepo tool itself which packages were affected instead of
guessing. See [`docs/monorepos.md`](docs/monorepos.md).

## Install

### As a Claude Code plugin

Add this repository as a plugin source and install it with the `/plugin` command
inside a Claude Code session. (Check Claude Code's own docs for the exact
`/plugin` subcommands your version uses.)

### Manually

```bash
git clone <this-repo-url> ~/path/to/crosscut
ln -s ~/path/to/crosscut/skills/crosscut ~/.claude/skills/crosscut
```

Claude Code looks for skills in `~/.claude/skills/`. The symlink keeps the skill
in sync with your clone, so there's no separate copy to update.

## Quickstart

**1. Register each repo — run `init` from inside it:**

```
cd ~/code/my-first-repo
/crosscut init
```

There is one config, at `~/.crosscut/crosscut.config.yaml`, and you
build it by running `/crosscut init` **from inside each project** you want managed.
The first run also asks a couple of global questions (your language, git-safety
preferences) and seeds the ROADMAP; every run asks about the current repo — which
**product** it belongs to, its language/kind, how to test and lint it. Repeat from
inside each repo:

```
cd ~/code/my-second-repo
/crosscut init
```

This step only writes config; it doesn't write any code or touch git.

**2. Run it:**

```
/crosscut
```

Claude reads that single config, looks at the current state of your plans, and shows a
per-product summary of what's `ready` to work on. Then it **waits for you** to pick a
plan (or ask for a new one). Once you choose, it drives that plan through all five steps
on its own — only stopping to ask when it hits a real design decision or a genuine
blocker.

## Is it safe?

Short version: **the skill only ever writes code on an isolated side branch, never on
your live files, and never pushes** — and the executor always runs, falling back to a
*manual-run* you implement yourself if it can't run in your environment. Read this
section before wiring it into a project you care about.

- **The executor always runs, but can't run just anywhere.** Which coding agent runs is
  your choice — `claude` (in-session, no extra tooling), `ralphex` (needs Docker), or
  `codex` (needs the `codex` CLI). If the one you picked can't run in your environment,
  driving a plan produces the plan and hands it to you to implement (a *manual-run*) —
  nothing is auto-written to your repos.
- **Code is written on a side branch, never your live files.** The executor works in an
  isolated git *worktree* and its own branch — your checked-out files are never edited
  directly.
- **Plan review is read-only.** `plan_review` (step 2) only *reads* your plan text; set
  it to `none` to skip it, and it degrades to skipped on its own if `codex` is
  unavailable.
- **Merges stay on your machine.** They're local and, by default, create a real merge
  commit (`--no-ff`) into your integration branch.
- **It never pushes anywhere.** The skill won't push to any remote unless you
  explicitly set `git.push_enabled: true`. The safe default is off.
- **No AI credit-taking.** Commits made by this skill never add a `Co-Authored-By` line.

Choosing an **executor** is what lets Claude write and commit code on its own — from the
dependency-light in-session `claude` kind to the external `ralphex`/`codex` runners.
**Plan review** gives a reviewer read-only access to your plan text. Before wiring either
into a project you care about, read [`docs/executors.md`](docs/executors.md) and
[`docs/validators.md`](docs/validators.md).

## Bring your own tools

`ralphex` (executor) and `codex` (plan review) are just the **reference examples** —
the methodology doesn't depend on them, and each scalar ships more than one built-in
kind. Each step is:

- **Selectable** — `executor` is `ralphex` / `claude` / `codex`, and `plan_review` is
  `codex` / `claude` / `none`. The `ralphex` and `codex` executors run as external
  processes through `run-executor.sh`; the `claude` executor runs in-session. See
  [`docs/executors.md`](docs/executors.md) and [`docs/validators.md`](docs/validators.md)
  for each kind's requirements and contract.
- **Swappable** — point the `executor` / `plan_review` scalar at a different tool of your
  own; the contract each must satisfy (its inputs, outputs, and exit behavior) is
  documented in those same two files. A brand-new external executor needs its own
  `run-executor.sh` adapter.
- **Skippable** — set `plan_review: none` to drop step 2 entirely, or rely on a
  manual-run for step 3, with no loss to planning, acceptance, or merging.

## Documentation & knowledge

Two kinds of written record come out of the pipeline, and they live in different
places:

- **Implementation plans** — the step-by-step plan for a specific piece of work.
  These live **inside each repo**, under `docs/plans/` (configurable per repo via
  `plans_dir`), and move to `docs/plans/completed/` once merged. A plan is scoped to
  one change in one repo.
- **The knowledge base** — the durable, per-**product** record of *outcomes*:
  `decisions` (why an approach was chosen), `architecture` (specs and contracts),
  `research`, and `incidents`. Every product has one, and it is **always on** — there's
  no enable switch. After a plan merges, its lasting decisions/research get written
  here so the next piece of work can build on them.

The knowledge base is plain, **Obsidian-compatible** markdown — YAML frontmatter,
`[[wikilinks]]`, and tags — and it works **with or without an Obsidian vault**. Point a
product's `knowledge_base` at a filesystem `path` or an `mcp` endpoint; either way the
markdown files are the source of truth, and Obsidian is entirely optional (you install
it yourself only if you want a nicer way to browse the same files). The global default
lives at `~/.crosscut/knowledge`, and any product can override it — see
[`docs/configuration.md`](docs/configuration.md) § Knowledge base.

## Recommended companions

None of these are required — `crosscut` works on its own. But they pair
well with what it does, and they're what this project was built and run with.

| Companion | What it is | Why it pairs well |
|-----------|------------|-------------------|
| **[superpowers](https://github.com/obra/superpowers)** *(recommended)* | Claude Code plugin (skills) | Its process skills map straight onto the pipeline: `writing-plans` + `brainstorming` (Plan), `using-git-worktrees` + `executing-plans` (Execute), `requesting-code-review` + `verification-before-completion` (Accept), `systematic-debugging` (when acceptance fails). This project was itself built with its subagent-driven-development workflow. |
| **[context7](https://github.com/upstash/context7)** | MCP server | Pulls up-to-date, version-specific library docs into context while a plan is written and executed — fewer mistakes from stale APIs. |
| **[graphify](https://github.com/safishamsi/graphify)** | Claude Code skill (`pip install graphifyy`) | Turns a repo into a queryable knowledge graph — useful for the cross-repo "architect" role, and it writes its output as Obsidian-compatible markdown, which dovetails with the knowledge base above. |
| **[Obsidian](https://obsidian.md)** | Desktop app | An optional way to browse each product's **knowledge base**. The base is plain markdown either way; point a product's `knowledge_base` path at a vault (or use its `mcp` endpoint) and each finished plan's decisions/architecture/research/incidents show up there to browse. You install and configure Obsidian yourself — the skill only ever writes `.md` files; Obsidian is never a hard dependency. |

These install through Claude Code's `/plugin` command, an MCP config, or the app's
own installer — not through this repo, and never automatically.

## Learn more

- [`docs/DESIGN.md`](docs/DESIGN.md) — the full story of how and why the method works.
- [`docs/configuration.md`](docs/configuration.md) — every option in `crosscut.config.yaml`.
- [`docs/executors.md`](docs/executors.md) / [`docs/validators.md`](docs/validators.md) — how to plug in your own tools.
- [`docs/examples/two-repo-python-node/`](docs/examples/two-repo-python-node/) — a complete, worked example config.
- [`skills/crosscut/SKILL.md`](skills/crosscut/SKILL.md) — the operating manual Claude Code actually reads.

## License

MIT — see [`LICENSE`](LICENSE).
