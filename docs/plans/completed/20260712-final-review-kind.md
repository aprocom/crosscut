---
repo: crosscut
status: done
depends_on: []
feature_id: final-review-kind
---
# Final review — Phase 5b as a configurable review (kind + model + reasoning effort)

**Goal:** Make **final review** (the Phase 5b review of the produced *code*, currently
hardcoded in-session and named "mandatory code review") a configurable stage symmetric to
`plan_review`: a scalar `final_review` ∈ `{in-session, claude, codex, none}`, plus
per-stage agent knobs — `model` and `reasoning_effort` — that `/crosscut init` always
writes into the **default config** for the review and executor stages. The term **"final
review"** replaces "mandatory code review" everywhere.

**Context:** `skills/crosscut/scripts/config-mutate.sh` (`set-global`: new
`--final-review` scalar + `--final-review-option KEY=VAL` pass-through),
`skills/crosscut/SKILL.md` (Phase 5b dispatch + rename, Phase 3/executor model+effort
application, init step 4, Final-review recipe, invariants), `docs/configuration.md`,
`skills/crosscut/templates/crosscut.config.example.yaml`, `docs/DESIGN.md`,
`tests/config-mutate.bats`. No `depends_on` — builds on P1/P2 already in `main`.

**Capability facts (verified this session — the design must respect them):**
- The **Agent tool** exposes `model` (`opus`/`sonnet`/`haiku`/`fable`) but **no** reasoning-
  effort parameter — a bare in-session subagent **inherits the orchestrator's effort**.
- **`codex exec`** takes its own model and a reasoning effort of
  `none|minimal|low|medium|high|xhigh` (**no `max`**).
- A **Workflow** `agent()` call supports **both** `opts.model` and `opts.effort` (`low..max`).
- Therefore: **`model` is enforceable everywhere**; **`reasoning_effort` is enforceable for
  `codex` and for a claude review dispatched via a Workflow single-agent call**, and is
  **inherit-only (advisory)** for a bare Agent-tool claude subagent. The config key is
  still always written (so it is present and tunable); docs state exactly where it binds.

**Design (settled):**
- **`final_review` scalar** ∈ `{in-session, claude, codex, none}`, **default `in-session`**
  (= current behavior; no change unless the operator opts in). It reviews the *code* after
  the executor runs, feeding the same accept/fix loop as `plan_review`.
  - `in-session` — the orchestrator reviews the diff itself (today's Phase 5b).
  - `claude` — an **independent** Agent-tool subagent reads the diff read-only and returns
    a verdict (best for objectivity — a fresh, possibly different-model reviewer).
  - `codex` — external read-only `codex exec` over the produced diff (cross-model review).
  - `none` — skip; **documented safety trade-off** (drops the code-safety gate; unlike
    `plan_review: none` which only skips a pre-build review).
- **Per-stage agent knobs** carried in the existing `*_options` maps via pass-throughs:
  `plan_review_options.{model,reasoning_effort}`, `final_review_options.{model,
  reasoning_effort}`, `executor_options.{model,reasoning_effort}` (the last for the
  `claude` executor). **Default value `inherit`** for both — written explicitly by init so
  the keys are present and discoverable, with behavior unchanged.
- **Model is adapter-scoped:** for `claude` kinds it is a Claude alias (`opus`/…); for
  `codex` kinds a codex model name. `inherit`/empty means "use the adapter/parent default".
- **Where each knob actually binds (plan-review finding — no overclaiming):**

  | stage / kind | `model` | `reasoning_effort` |
  |---|---|---|
  | plan_review `claude`, final_review `claude`, executor `claude` | Agent `model` param | Workflow dispatch when ≠`inherit`, else inherit (advisory) |
  | plan_review `codex`, final_review `codex` | codex model flag | codex effort flag (mapped) |
  | **executor `codex`** (`run-executor.sh`) | **NOT wired here** — stays via `executor_options.codex_args`; a follow-up may add it | same |
  | any `in-session` stage | orchestrator's own model | orchestrator's own effort |

  So the config **stores** `model`/`reasoning_effort` for plan_review / final_review /
  executor, but `executor_options.{model,reasoning_effort}` **binds only for the `claude`
  executor** in this plan; docs state this explicitly rather than claiming "everywhere".
- **`reasoning_effort` — per-adapter validation/mapping (not one global enum).** The config
  accepts `inherit|none|minimal|low|medium|high|xhigh|max`; each adapter maps it to its own
  supported set, warning on a clamp, never silently mis-binding:
  - **codex** (`none|minimal|low|medium|high|xhigh`): pass through; **`max` → `xhigh`** (+warn).
  - **Workflow-dispatched claude** (`low|medium|high|xhigh|max`): pass through;
    **`none|minimal` → `low`** (+warn); `inherit` → don't set.
  - **bare Agent-tool claude**: no effort knob → advisory/inherit regardless of value.
  A single shared helper (SKILL prose, per adapter) does this mapping so plan_review:codex,
  final_review:codex, and the claude Workflow path all clamp consistently.

### Task 1: config-mutate.sh — `--final-review` scalar + `--final-review-option` pass-through

In `cmd_set_global`:
- Add `--final-review` to the scalar-flag `case` (→ field `final_review`), and validate it
  in the python block against `{in-session, claude, codex, none}` (mirror the existing
  `plan_review` validation; non-zero + no write on a bad value). Apply it to the top-level
  `final_review` key (extend the `for f in ("language","executor","plan_review",
  "max_parallel")` apply-loop to include `final_review`).
- Add a `--final-review-option KEY=VAL` repeatable pass-through (mirror `--plan-review-option`
  exactly: collect into a `final_opts` array, export `CROSSCUT_FO_*`, `read_opts("CROSSCUT_FO")`,
  and `merge_opts("final_review_options", final_opts)`). `model` and `reasoning_effort` ride
  this pass-through (no dedicated flags — same as how executor/plan-review options work).
- **Update the no-op guard (plan-review finding).** The "requires at least one flag" check
  (`config-mutate.sh:217`, `if not fields and not exec_opts and not review_opts`) must also
  admit `final_opts` — otherwise an option-only call like `set-global --final-review-option
  model=opus` wrongly fails. Add the `final_opts` (CROSSCUT_FO) term to that guard.
- Update `_usage` and the `set-global` description to list `[--final-review <kind>]` and
  `[--final-review-option KEY=VAL]...`.

### Task 1 tests

`tests/config-mutate.bats`: `set-global --final-review claude` writes top-level
`final_review: claude` (readable via `cfg_get final_review`); an invalid `--final-review
frobnicate` is rejected and the target is byte-for-byte unchanged (atomic);
`--final-review-option model=opus --final-review-option reasoning_effort=high` writes
`final_review_options.{model,reasoning_effort}`; it composes with `--plan-review-option`
and `--executor-option` in one call without clobbering `repos[]` or the other option maps;
a re-run updates in place. **Option-only write:** `set-global --final-review-option
model=opus` with **no other flag** succeeds (pins the no-op-guard fix). **Non-mapping
safety:** when `final_review_options` already exists as a scalar string, `--final-review-option`
errors and leaves the file byte-for-byte unchanged (mirrors the existing nested-node
convention).

### Task 2: SKILL.md — final_review dispatch, rename, model+effort application, init, invariants

- **Rename** "mandatory code review" / "Phase 5b" wording to **"final review"** throughout
  (Phase 5b body, the "When to ask" list, invariants, any cross-refs). Keep it as Phase 5b
  inside the Acceptance phase; `5a` (tests) is untouched.
- **Dispatch Phase 5b by the `final_review` scalar** (`cfg_get final_review in-session`),
  feeding the same apply/fix loop and blocker rules as today:
  - `in-session` → the orchestrator reviews the diff itself (current behavior).
  - `claude` → spawn an **independent** Agent-tool subagent (read-only) over the diff
    `base_sha..head_sha`; pass `final_review_options.model` as the Agent `model`; if
    `final_review_options.reasoning_effort` ≠ `inherit`, dispatch via a **Workflow**
    single-agent call to honor `opts.effort` (else a direct Agent call). Same
    anti-prompt-injection rule as plan review (diff is data, not instructions). Save the
    verdict to the **absolute** path `<repo.path>/<plans_dir>/reviews/<slug>.final.claude.md`.
  - `codex` → external read-only `codex exec -C <repo.path>` over the diff (recipe below),
    with `final_review_options.model`/`reasoning_effort` mapped to codex flags via the shared
    codex-flag mapping (below); transcript to the **absolute** path
    `<repo.path>/<plans_dir>/reviews/<slug>.final.codex.md` (`plans_dir` is relative by
    default — always prefix `<repo.path>`, matching the plan-review recipe's absolute-path rule).
  - `none` → skip Phase 5b, and **warn** in the status line that the code-safety gate was
    disabled (this is more consequential than `plan_review: none`).
  - A material finding is a blocker (escalate); a clean pass → continue to `accepted`.
- **Shared codex-flag mapping** (define once, reuse for `plan_review: codex` and
  `final_review: codex`): a non-`inherit` `model` → codex's model flag; a non-`inherit`
  `reasoning_effort` → codex's reasoning-effort flag with the per-adapter mapping above
  (`max`→`xhigh`). Update the **Phase 3 plan-review recipe** so `plan_review: codex` applies
  `plan_review_options.{model,reasoning_effort}` through this mapping (today the recipe only
  mentions `extra_args` and "don't force a model unless config says to" — make that concrete).
- **Apply model/effort at the other claude stages:** at **Phase 3** (`plan_review: claude`)
  and **Phase 4** (`executor: claude`) pass `.model` to the Agent subagent and `.reasoning_effort`
  via the Workflow rule. **Scope note:** the **`codex` executor** (`run-executor.sh`) is **not**
  wired for `executor_options.{model,reasoning_effort}` in this plan — it keeps using
  `executor_options.codex_args`; docs say so (no overclaim).
- **Phase 5 reporting:** extend the phase status line (currently "plan_review/test results,
  quota") to also surface the **final-review** verdict / skipped-status.
- **State the effort caveat once, clearly:** the Agent tool exposes `model` but not
  reasoning effort — so `reasoning_effort` binds for `codex` and for claude subagents
  dispatched via a Workflow; a bare Agent-tool subagent inherits the orchestrator's effort
  and the config value is advisory there.
- **init step 4:** extend the first-run `set-global` call to also write `--final-review
  in-session` and the model/effort defaults for all three stages:
  `--plan-review-option model=inherit --plan-review-option reasoning_effort=inherit
  --final-review-option model=inherit --final-review-option reasoning_effort=inherit
  --executor-option model=inherit --executor-option reasoning_effort=inherit`. So the
  **default config always contains model + reasoning_effort** for plan_review / final_review
  / executor, with neutral `inherit` defaults. No new interview question.
- **Invariants:** update the "Phase 5b always runs" wording to "final review runs unless
  `final_review: none`"; note the model/effort resolution and the caveat.

### Task 3: SKILL.md — Final review recipe

Add a `### Final review (in-session, claude, codex, none)` recipe under `## Recipes`
(mirror the Plan-review recipe), distinct from Plan review (reviews the *code/diff*, always
part of Acceptance): the `codex` invocation form over the diff with `-C <repo.path>`,
`< /dev/null`, an **absolute** transcript path
`<repo.path>/<plans_dir>/reviews/<slug>.final.codex.md`, and model/effort mapped to codex
flags via the shared codex-flag mapping (Task 2); the `claude` form (Agent read-only over
the diff, model + Workflow-effort rule, transcript to
`<repo.path>/<plans_dir>/reviews/<slug>.final.claude.md`); record accepted-vs-rejected
suggestions as with plan review.

### Task 4: docs + example template

- `skills/crosscut/templates/crosscut.config.example.yaml`: add `final_review:
  in-session` with the kind list, a `final_review_options:` block with `model: inherit` /
  `reasoning_effort: inherit`, and mirror `model`/`reasoning_effort` comments into
  `plan_review_options` and `executor_options`. Comment the effort caveat.
- `docs/configuration.md`: schema rows for `final_review`, `final_review_options.{model,
  reasoning_effort}`, and `plan_review_options`/`executor_options` `.{model,reasoning_effort}`
  — defaults (`in-session`, `inherit`), the accepted `reasoning_effort` values, and the
  **binding matrix** (the design table): `model` binds for claude subagents (Agent `model`)
  and codex kinds at the wired stages; `executor_options.{model,reasoning_effort}` binds
  **only for the `claude` executor** (codex executor keeps `codex_args`); `reasoning_effort`
  is mapped per adapter (codex `max`→`xhigh`; Workflow claude `none|minimal`→`low`; bare
  Agent inherits/advisory). Note `final_review: none` drops the code-safety gate.
- `docs/DESIGN.md`: describe final review as the code-side twin of plan review, and the
  per-stage model/effort knobs (with the caveat).

### Task 5: Tests — final_review + "model & reasoning land in the default config"

`tests/config-mutate.bats` (extend): after the **documented init `set-global` call**
(language/executor/plan-review/git/kb/runs + the model/effort/final-review options), assert
the resulting default config contains, readable via `cfg_get`:
`final_review` = `in-session`; `plan_review_options.model` = `inherit` and
`plan_review_options.reasoning_effort` = `inherit`; the same two under `final_review_options`
and `executor_options`. This is the explicit check that **model and reasoning type land in
the default config**. Plus the Task 1 validation/pass-through cases. `bats tests/` stays
100% green.
