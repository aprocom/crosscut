---
repo: crosscut
status: done
depends_on: []
feature_id: config-validate
---
# Human-friendly config validation (`/crosscut validate` + Start gate)

**Goal:** Add a single validator that checks the **whole** `crosscut.config.yaml` at
once and reports problems in **plain, actionable language** (no Python tracebacks, no
silent defaults). Run it as a fail-fast gate at Start/reconcile and expose it as
`/crosscut validate` (doctor). Harden `cfg_get` so hand-broken YAML fails with a clean
message everywhere, not a traceback.

**Context:** `skills/crosscut/scripts/config-validate.sh` (NEW — the validator),
`skills/crosscut/scripts/lib/config.sh` (wrap `safe_load` in try/except so every reader
degrades gracefully), `skills/crosscut/SKILL.md` (Start/reconcile gate, `/crosscut
validate` entry, scripts-list), `docs/configuration.md`, `docs/DESIGN.md`, `tests/`
(`config-validate.bats`). No `depends_on` — builds on config schema already in `main`.

**Why (verified this session):** there is no config-validation step today. On a hand-edit:
malformed YAML makes `cfg_get` emit a **raw Python traceback** (exit 1); a **non-mapping
root** makes `cfg_get` **silently return defaults** (exit 0 — the orchestrator runs on
phantom defaults); a bad enum/type is only caught (if at all) far downstream. The dangerous
case is the silent one — this plan closes it with an explicit gate.

**Design (settled):**
- **One engine, whole-file:** `config-validate.sh` reads the resolved config path
  (`$CROSSCUT_CONFIG` → `~/.crosscut/crosscut.config.yaml`), parses it in an
  embedded `python3` block wrapped in `try/except yaml.YAMLError`, runs **every** check,
  and prints a **grouped human report** — never stops at the first problem, so the operator
  sees all of them in one pass.
- **Standalone — no `cfg_get` (plan-review finding).** `config-validate.sh` parses the file
  itself and must **not** call `cfg_get`/`config.sh`; otherwise a malformed config would make
  the reader traceback *before* the validator could report it (chicken-and-egg). The
  Start-gate calls this standalone script first, before any `cfg_get`.
- **Two severities.** **ERROR** blocks (operation would be wrong/broken); **WARNING** is
  advisory (suspicious but survivable). **Exit codes** (disambiguated — `3` is already
  PyYAML-missing in readers): **0** valid (warnings allowed) · **1** validation errors
  present · **2** unparseable YAML · **3** no config file · **4** PyYAML missing. The Start
  gate blocks on `1`/`2`, reports+continues on warnings, and suggests init on `3`.
- **Every message says what + where + how to fix** (the key path, the bad value, and the
  allowed values / expected type). No stack traces, no internal jargon. **ASCII-only report
  markers** (`valid` / `ERRORS (must fix):` / `WARNINGS:` / `- ` bullets — no `✓`/`✗`/`·`)
  for portability in constrained terminals and robust shell-test matching.

### Task 1: config-validate.sh (NEW) — the validator engine

New executable `skills/crosscut/scripts/config-validate.sh` (bash wrapper + embedded
`python3`/PyYAML, same style as `config-mutate.sh`). Resolve the target via the same rule as
`config.sh` (`$CROSSCUT_CONFIG` else `~/.crosscut/crosscut.config.yaml`).

- **No file** → the resolver uses `$CROSSCUT_CONFIG` when that env var is set (report
  **that** path even if it does not exist — matching `crosscut_config_path`, which only *uses* the
  env path when the file exists), else `~/.crosscut/crosscut.config.yaml`; print
  `no config found at <path> — run /crosscut init`; exit **3**.
- **Parse** with `try: yaml.safe_load(open(path)) except yaml.YAMLError as e:` → a friendly
  one-liner from the exception's `problem` + `problem_mark` (line, column), e.g. `YAML syntax
  error at line 2, column 6: mapping values are not allowed here`; exit **2**. No traceback
  ever reaches the operator. If PyYAML itself is missing, print the install hint and exit **4**.
- **Checks** (collect ALL, then report — never stop at the first). The allowed-value sets
  and type rules are the **same ones `config-mutate.sh` enforces on write**, so read- and
  write-validation never diverge (Task 5 asserts this).
  **Integer rule (plan-review finding):** `bool` is an `int` subclass in Python, so every
  numeric check is `isinstance(v, int) and not isinstance(v, bool)` — a YAML `true` is **not**
  a valid `version`/`max_parallel`/`runs_retention_days`.
  - **ERROR:** root not a mapping; `version` present and not an int; `repos` present and not a
    list; a `repos[i]` not a mapping; a repo missing `name`; duplicate repo `name`s;
    `executor` ∉ `{ralphex,claude,codex}`; `plan_review` ∉ `{none,codex,claude}`;
    `final_review` ∉ `{in-session,claude,codex,none}`; `max_parallel` present and not a
    positive int; `executor_options.runs_retention_days` present and not a non-negative int;
    `executor_options.runs_dir` present and empty / not a string; a `repos[i].venv_isolation`
    present and not a bool; `git.merge_ff` / `git.push_enabled` present and not a bool; any of
    `git` / `knowledge_base` / `executor_options` / `plan_review_options` /
    `final_review_options` / `products` present and not a mapping; a `products.<name>` present
    and not a mapping; a **`products.<name>.knowledge_base`** present and not a mapping (matches
    `config-mutate.sh`); a `*_options.reasoning_effort` **on an ACTIVE stage** (the scalar
    selects that kind) not in `{inherit,none,minimal,low,medium,high,xhigh,max}` — it would be
    passed to codex or a Workflow claude and mis-bind.
  - **WARNING:** `repos` absent or empty (nothing to drive); a repo **missing `path`**
    (un-runnable, but the config is not broken — `add-repo` may write it, so warn not error, no
    divergence); a repo `path` that does not exist on this machine (may be another host); a
    `*_options.reasoning_effort` on an **inactive** stage outside the accepted set; a repo
    `kind` not in `{python,nodejs,go,other}`; a **`model` on a `claude`-dispatched stage** not
    in `{inherit,opus,sonnet,haiku,fable}` — i.e. `plan_review == claude` and
    `plan_review_options.model` outside that set (same for `final_review`/`final_review_options`
    and `executor`/`executor_options`): warn the Agent tool honors only tier aliases, so
    `opus-4.8` won't bind (a `codex`-dispatched stage keeps its own model namespace — no warning).
- **Report format** (human-friendly, **ASCII-only**): a header line with the config path and a
  one-line tally (`config valid` or `config invalid: N error(s), M warning(s)`); then an
  `ERRORS (must fix):` group and a `WARNINGS:` group, each a `- `-bulleted list of `<message>`
  with the key path and fix hint; on success a one-line summary (`1 repo, 1 product,
  executor=ralphex, plan_review=codex, final_review=in-session`). Support `--quiet` (suppress the success summary; still prints
  problems) and `--json` (machine form: `{ok, errors:[…], warnings:[…]}`) for reuse.

### Task 1 tests

`tests/config-validate.bats` (write a temp config, point `$CROSSCUT_CONFIG` at it):
- well-formed config → **exit 0**, prints `valid`;
- **malformed YAML** → **exit 2**, message contains `line`, and **no** `Traceback`;
- **non-mapping root** (a list — parses fine, but invalid) → **exit 1** with a "root … mapping"
  error (the silent-default case made loud);
- bad `executor` → **exit 1**, error names the allowed set;
- **all-at-once:** a duplicate repo `name` (error) + a repo missing `path` (warning) + a bad
  `plan_review` (error) are **all** reported in one run; exit 1;
- **bool ≠ int:** `max_parallel: true` and `runs_retention_days: true` → type errors (exit 1);
  also `runs_retention_days: banana` and `max_parallel: 0` → type errors;
- `repos[].venv_isolation: maybe` → error; `executor_options.runs_dir: ""` → error;
  `products.foo.knowledge_base` as a scalar → error;
- **reasoning_effort:** active `plan_review: codex` with `plan_review_options.reasoning_effort:
  banana` → **error**; the same value on an **inactive** stage → **warning** (still exit 0 if no
  other error);
- **model alias:** `plan_review: claude` + `plan_review_options.model: opus-4.8` → **warning**
  (and likewise `final_review: claude` / `executor: claude`); a `plan_review: codex` with a
  codex model name → **no** model warning;
- non-existent repo `path` → **warning**, exit 0; empty `repos` → warning, exit 0;
- `--json` → parseable JSON with `ok=false` + the error list; a warnings-only config → JSON
  `ok=true` with a non-empty `warnings`; `--quiet` suppresses the success summary but still
  prints problems;
- missing config file → **exit 3** with the init hint.

### Task 2: config.sh — graceful YAML errors (no traceback)

Wrap the two `yaml.safe_load(open(os.environ["CROSSCUT_CFG"]))` sites in `config.sh` (the
`cfg_get`/read path and the `cfg_repo_names`-style loader) in `try/except yaml.YAMLError` →
write `crosscut: config YAML is invalid (<file>): <short reason>; run /crosscut
validate` to stderr and `sys.exit(2)`. This changes **only** the malformed-YAML path (today
a raw traceback); a valid or absent config is unaffected, so existing `config.bats` stays
green. A non-mapping root keeps returning defaults at the `cfg_get` level (that structural
case is caught by the validator/gate, not by every getter).

### Task 2 tests

`tests/config.bats`: a malformed-YAML config makes **both** `config.sh` read paths fail
gracefully — `cfg_get <any-key>` (the `_crosscut_py` loader, `config.sh:30`) and
`cfg_check_depends <slug>` (`config.sh:205`) each **exit 2** with a clear
`config YAML is invalid` message and **no** `Traceback` in the output. A valid config still
reads normally (existing cases stay green).

### Task 3: SKILL.md — Start gate + `/crosscut validate` + scripts list

- **Start / reconcile:** make **step 0** run `bash ${SCRIPT_DIR}/scripts/config-validate.sh`.
  On **errors**, **stop and show the report** — do not run reconcile or any phase on a broken
  config (this closes the silent-default hole). On **warnings only**, surface them and
  continue. On **no config**, report it and suggest `/crosscut init`.
- **`/crosscut validate` (doctor):** document it in the Start/Stop area — an operator can
  run the validator on demand; it prints the same human report and changes nothing.
- **Scripts list:** add `config-validate.sh` with a one-line description.

### Task 4: docs

- `docs/configuration.md`: a **Validation** section — what `/crosscut validate` checks,
  the error-vs-warning split, the Start gate behavior, and the exit codes (0 valid, 2
  invalid, 3 no-config).
- `docs/DESIGN.md`: note the fail-fast config gate (no silent defaults; no tracebacks) as a
  reliability invariant.

### Task 5: final grep + suite

Confirm the validator, the Start gate, and the `config.sh` hardening agree on the resolved
path and the enum/type sets (single source of truth — reuse the same allowed-value lists
`config-mutate.sh` validates on write, so write-validation and read-validation never
diverge). `bats tests/` stays 100% green.
