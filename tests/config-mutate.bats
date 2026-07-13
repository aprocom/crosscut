#!/usr/bin/env bats

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$DIR/../skills/crosscut/scripts/config-mutate.sh"
  source "$DIR/../skills/crosscut/scripts/lib/config.sh"
  TMP="$(mktemp -d)"
  export CROSSCUT_CONFIG="$TMP/crosscut.config.yaml"
}

teardown() { rm -rf "$TMP"; }

@test "add-repo creates a skeleton when the target is absent" {
  [ ! -e "$CROSSCUT_CONFIG" ]
  run bash "$SCRIPT" add-repo --name backend --path /repos/backend --kind python
  [ "$status" -eq 0 ]
  [ -f "$CROSSCUT_CONFIG" ]
  run cfg_get version
  [ "$output" = "1" ]
  run cfg_get roadmap
  [ "$output" = "ROADMAP.md" ]
  run cfg_repo_names
  [ "$output" = "backend" ]
}

@test "add-repo appends a new repo, preserving the existing one" {
  bash "$SCRIPT" add-repo --name backend --path /repos/backend --kind python
  run bash "$SCRIPT" add-repo --name web --path /repos/web --kind nodejs
  [ "$status" -eq 0 ]
  run cfg_repo_names
  [ "${lines[0]}" = "backend" ]
  [ "${lines[1]}" = "web" ]
  [ "${#lines[@]}" -eq 2 ]
  run cfg_repo_field web kind
  [ "$output" = "nodejs" ]
  # untouched repo keeps its field
  run cfg_repo_field backend kind
  [ "$output" = "python" ]
}

@test "re-adding the same name updates in place, preserving other keys and other repos" {
  bash "$SCRIPT" add-repo --name backend --path /repos/backend --kind python \
    --test-cmd ".venv/bin/pytest" --lint-cmd ".venv/bin/flake8" --venv-isolation true
  bash "$SCRIPT" add-repo --name web --path /repos/web --kind nodejs
  # update only kind on backend
  run bash "$SCRIPT" add-repo --name backend --kind go
  [ "$status" -eq 0 ]
  # still exactly two repos, same order (updated in place, not appended)
  run cfg_repo_names
  [ "${lines[0]}" = "backend" ]
  [ "${lines[1]}" = "web" ]
  [ "${#lines[@]}" -eq 2 ]
  # changed field took effect
  run cfg_repo_field backend kind
  [ "$output" = "go" ]
  # other keys on the same repo preserved (not wiped by the partial update)
  run cfg_repo_field backend path
  [ "$output" = "/repos/backend" ]
  run cfg_repo_field backend test_cmd
  [ "$output" = ".venv/bin/pytest" ]
  run cfg_repo_field backend lint_cmd
  [ "$output" = ".venv/bin/flake8" ]
  run cfg_repo_field backend venv_isolation false
  [ "$output" = "true" ]
  # the other repo is untouched
  run cfg_repo_field web kind
  [ "$output" = "nodejs" ]
}

@test "product is recorded and readable via cfg_repo_product" {
  bash "$SCRIPT" add-repo --name backend --path /repos/backend --kind python --product platform
  run cfg_repo_product backend
  [ "$output" = "platform" ]
}

@test "a repo with no product defaults to its name via cfg_repo_product" {
  bash "$SCRIPT" add-repo --name web --path /repos/web --kind nodejs
  run cfg_repo_product web
  [ "$output" = "web" ]
}

@test "bad input leaves an existing target byte-for-byte unchanged (atomic)" {
  bash "$SCRIPT" add-repo --name backend --path /repos/backend --kind python
  before="$(cat "$CROSSCUT_CONFIG")"
  # missing --name
  run bash "$SCRIPT" add-repo --kind python
  [ "$status" -ne 0 ]
  # invalid boolean for --venv-isolation
  run bash "$SCRIPT" add-repo --name x --venv-isolation maybe
  [ "$status" -ne 0 ]
  # unknown flag
  run bash "$SCRIPT" add-repo --name x --bogus y
  [ "$status" -ne 0 ]
  after="$(cat "$CROSSCUT_CONFIG")"
  [ "$before" = "$after" ]
}

@test "missing subcommand and unknown subcommand both fail" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" frobnicate
  [ "$status" -ne 0 ]
}

@test "no temp files are left behind after a successful mutation" {
  run bash "$SCRIPT" add-repo --name backend --path /repos/backend --kind python
  [ "$status" -eq 0 ]
  run bash -c "ls -a '$TMP' | grep -c '\.orch-cfg\.' || true"
  [ "$output" = "0" ]
}

@test "set-global creates a skeleton and writes scalars + git booleans" {
  [ ! -e "$CROSSCUT_CONFIG" ]
  run bash "$SCRIPT" set-global --language en --executor codex --plan-review claude \
    --merge-ff true --push-enabled false
  [ "$status" -eq 0 ]
  [ -f "$CROSSCUT_CONFIG" ]
  run cfg_get language
  [ "$output" = "en" ]
  run cfg_get executor
  [ "$output" = "codex" ]
  run cfg_get plan_review
  [ "$output" = "claude" ]
  run cfg_get git.merge_ff
  [ "$output" = "true" ]
  run cfg_get git.push_enabled
  [ "$output" = "false" ]
}

@test "set-global updates a value in place, preserving repos[] and other globals" {
  bash "$SCRIPT" set-global --language en --executor codex --merge-ff false
  bash "$SCRIPT" add-repo --name backend --path /repos/backend --kind python
  # update only the executor and one git bool
  run bash "$SCRIPT" set-global --executor claude --merge-ff true
  [ "$status" -eq 0 ]
  # changed values took effect
  run cfg_get executor
  [ "$output" = "claude" ]
  run cfg_get git.merge_ff
  [ "$output" = "true" ]
  # previously-set globals preserved (not clobbered by the partial update)
  run cfg_get language
  [ "$output" = "en" ]
  # repos[] preserved: the repo still resolves with its fields intact
  run cfg_repo_names
  [ "$output" = "backend" ]
  run cfg_repo_field backend kind
  [ "$output" = "python" ]
  run cfg_repo_field backend path
  [ "$output" = "/repos/backend" ]
}

@test "set-global only writes passed flags (does not clobber other globals)" {
  bash "$SCRIPT" set-global --language en
  run bash "$SCRIPT" set-global --executor codex
  [ "$status" -eq 0 ]
  # setting only --executor left --language untouched
  run cfg_get language
  [ "$output" = "en" ]
  run cfg_get executor
  [ "$output" = "codex" ]
}

@test "set-global merges executor_options and plan_review_options pass-throughs" {
  run bash "$SCRIPT" set-global --executor codex \
    --executor-option model=gpt-5 --plan-review-option depth=2
  [ "$status" -eq 0 ]
  run cfg_get executor_options.model
  [ "$output" = "gpt-5" ]
  run cfg_get plan_review_options.depth
  [ "$output" = "2" ]
}

@test "set-global rejects invalid values and leaves the target unchanged (atomic)" {
  bash "$SCRIPT" set-global --language en --executor codex
  before="$(cat "$CROSSCUT_CONFIG")"
  # invalid executor
  run bash "$SCRIPT" set-global --executor bogus
  [ "$status" -ne 0 ]
  # invalid plan_review
  run bash "$SCRIPT" set-global --plan-review sometimes
  [ "$status" -ne 0 ]
  # non-bool git values
  run bash "$SCRIPT" set-global --merge-ff maybe
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" set-global --push-enabled maybe
  [ "$status" -ne 0 ]
  # unknown flag / no flags at all
  run bash "$SCRIPT" set-global --bogus y
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" set-global
  [ "$status" -ne 0 ]
  after="$(cat "$CROSSCUT_CONFIG")"
  [ "$before" = "$after" ]
}

@test "set-global writes top-level knowledge_base.{path,mcp} via --kb-path/--kb-mcp" {
  [ ! -e "$CROSSCUT_CONFIG" ]
  run bash "$SCRIPT" set-global --kb-path /kb/global --kb-mcp mcp://global
  [ "$status" -eq 0 ]
  [ -f "$CROSSCUT_CONFIG" ]
  run cfg_get knowledge_base.path
  [ "$output" = "/kb/global" ]
  run cfg_get knowledge_base.mcp
  [ "$output" = "mcp://global" ]
}

@test "set-global --kb-* writes only passed flags, preserving other knowledge_base keys" {
  bash "$SCRIPT" set-global --kb-path /kb/global
  run bash "$SCRIPT" set-global --kb-mcp mcp://global
  [ "$status" -eq 0 ]
  # the earlier path survived a partial update that only set mcp
  run cfg_get knowledge_base.path
  [ "$output" = "/kb/global" ]
  run cfg_get knowledge_base.mcp
  [ "$output" = "mcp://global" ]
}

@test "set-global --max-parallel writes a positive integer readable via cfg_get" {
  [ ! -e "$CROSSCUT_CONFIG" ]
  run bash "$SCRIPT" set-global --max-parallel 4
  [ "$status" -eq 0 ]
  [ -f "$CROSSCUT_CONFIG" ]
  run cfg_get max_parallel
  [ "$output" = "4" ]
  # written as a real YAML int, not a quoted string
  run grep -qE '^max_parallel: 4$' "$CROSSCUT_CONFIG"
  [ "$status" -eq 0 ]
}

@test "set-global rejects a non-positive / non-integer --max-parallel (atomic)" {
  bash "$SCRIPT" set-global --max-parallel 2
  before="$(cat "$CROSSCUT_CONFIG")"
  # zero
  run bash "$SCRIPT" set-global --max-parallel 0
  [ "$status" -ne 0 ]
  # negative
  run bash "$SCRIPT" set-global --max-parallel -1
  [ "$status" -ne 0 ]
  # non-numeric
  run bash "$SCRIPT" set-global --max-parallel two
  [ "$status" -ne 0 ]
  # missing value
  run bash "$SCRIPT" set-global --max-parallel
  [ "$status" -ne 0 ]
  after="$(cat "$CROSSCUT_CONFIG")"
  [ "$before" = "$after" ]
}

@test "set-global --max-parallel combines with another global, preserving both" {
  run bash "$SCRIPT" set-global --max-parallel 8 --executor codex
  [ "$status" -eq 0 ]
  run cfg_get max_parallel
  [ "$output" = "8" ]
  run cfg_get executor
  [ "$output" = "codex" ]
  # a later partial update to another global leaves max_parallel intact
  run bash "$SCRIPT" set-global --language en
  [ "$status" -eq 0 ]
  run cfg_get max_parallel
  [ "$output" = "8" ]
  run cfg_get language
  [ "$output" = "en" ]
}

@test "set-product creates products.<name>.knowledge_base.path" {
  run bash "$SCRIPT" set-product foo --kb-path /kb/foo
  [ "$status" -eq 0 ]
  run cfg_get products.foo.knowledge_base.path
  [ "$output" = "/kb/foo" ]
}

@test "set-product updates in place, preserving path, other products, and repos[]" {
  # seed: another product, a repo, and product foo with a path
  bash "$SCRIPT" set-product bar --kb-path /kb/bar --kb-mcp mcp://bar
  bash "$SCRIPT" add-repo --name backend --path /repos/backend --kind python
  bash "$SCRIPT" set-product foo --kb-path /kb/foo
  # update only mcp on foo
  run bash "$SCRIPT" set-product foo --kb-mcp mcp://foo
  [ "$status" -eq 0 ]
  # new value took effect and the earlier path was preserved
  run cfg_get products.foo.knowledge_base.mcp
  [ "$output" = "mcp://foo" ]
  run cfg_get products.foo.knowledge_base.path
  [ "$output" = "/kb/foo" ]
  # the other product is untouched
  run cfg_get products.bar.knowledge_base.path
  [ "$output" = "/kb/bar" ]
  run cfg_get products.bar.knowledge_base.mcp
  [ "$output" = "mcp://bar" ]
  # repos[] preserved with fields intact
  run cfg_repo_names
  [ "$output" = "backend" ]
  run cfg_repo_field backend kind
  [ "$output" = "python" ]
  run cfg_repo_field backend path
  [ "$output" = "/repos/backend" ]
}

@test "set-product rejects bad input and leaves the target byte-for-byte unchanged" {
  bash "$SCRIPT" set-product foo --kb-path /kb/foo
  before="$(cat "$CROSSCUT_CONFIG")"
  # no name (first token is a flag)
  run bash "$SCRIPT" set-product --kb-path /kb/x
  [ "$status" -ne 0 ]
  # name but no flags
  run bash "$SCRIPT" set-product foo
  [ "$status" -ne 0 ]
  # unknown flag
  run bash "$SCRIPT" set-product foo --bogus y
  [ "$status" -ne 0 ]
  # missing value
  run bash "$SCRIPT" set-product foo --kb-path
  [ "$status" -ne 0 ]
  after="$(cat "$CROSSCUT_CONFIG")"
  [ "$before" = "$after" ]
}

@test "set-product errors (not overwrites) when products.<name> is a non-mapping" {
  # hand-write a config where products.foo is a scalar string
  cat > "$CROSSCUT_CONFIG" <<'YAML'
version: 1
repos: []
products:
  foo: notamapping
YAML
  before="$(cat "$CROSSCUT_CONFIG")"
  run bash "$SCRIPT" set-product foo --kb-path /kb/foo
  [ "$status" -ne 0 ]
  after="$(cat "$CROSSCUT_CONFIG")"
  [ "$before" = "$after" ]
}

@test "set-product errors (not overwrites) when top-level products is a non-mapping" {
  # hand-write a config where the whole products node is a scalar string
  cat > "$CROSSCUT_CONFIG" <<'YAML'
version: 1
repos: []
products: notamapping
YAML
  before="$(cat "$CROSSCUT_CONFIG")"
  run bash "$SCRIPT" set-product foo --kb-path /kb/foo
  [ "$status" -ne 0 ]
  after="$(cat "$CROSSCUT_CONFIG")"
  [ "$before" = "$after" ]
}

@test "set-product errors (not overwrites) when products.<name>.knowledge_base is a non-mapping" {
  # hand-write a config where products.foo.knowledge_base is a scalar string
  cat > "$CROSSCUT_CONFIG" <<'YAML'
version: 1
repos: []
products:
  foo:
    knowledge_base: notamapping
YAML
  before="$(cat "$CROSSCUT_CONFIG")"
  run bash "$SCRIPT" set-product foo --kb-path /kb/foo
  [ "$status" -ne 0 ]
  after="$(cat "$CROSSCUT_CONFIG")"
  [ "$before" = "$after" ]
}

@test "set-global --kb-path errors (not overwrites) when top-level knowledge_base is a non-mapping" {
  # hand-write a config where knowledge_base is a scalar string
  cat > "$CROSSCUT_CONFIG" <<'YAML'
version: 1
repos: []
knowledge_base: notamapping
YAML
  before="$(cat "$CROSSCUT_CONFIG")"
  run bash "$SCRIPT" set-global --kb-path /kb/global
  [ "$status" -ne 0 ]
  after="$(cat "$CROSSCUT_CONFIG")"
  [ "$before" = "$after" ]
}

@test "set-global --runs-dir / --runs-retention-days write executor_options.*" {
  run bash "$SCRIPT" set-global --runs-dir /var/runs --runs-retention-days 7
  [ "$status" -eq 0 ]
  run cfg_get executor_options.runs_dir
  [ "$output" = "/var/runs" ]
  run cfg_get executor_options.runs_retention_days
  [ "$output" = "7" ]
  # retention is a real YAML int, not a quoted string (nested 2-space indent)
  run grep -qE '^  runs_retention_days: 7$' "$CROSSCUT_CONFIG"
  [ "$status" -eq 0 ]
}

@test "set-global --runs-retention-days 0 is valid (0 = prune on done)" {
  run bash "$SCRIPT" set-global --runs-retention-days 0
  [ "$status" -eq 0 ]
  run cfg_get executor_options.runs_retention_days
  [ "$output" = "0" ]
  run grep -qE '^  runs_retention_days: 0$' "$CROSSCUT_CONFIG"
  [ "$status" -eq 0 ]
}

@test "set-global rejects a negative / non-integer / missing --runs-retention-days (atomic)" {
  bash "$SCRIPT" set-global --runs-retention-days 3
  before="$(cat "$CROSSCUT_CONFIG")"
  run bash "$SCRIPT" set-global --runs-retention-days -1
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" set-global --runs-retention-days seven
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" set-global --runs-retention-days 1.5
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" set-global --runs-retention-days
  [ "$status" -ne 0 ]
  after="$(cat "$CROSSCUT_CONFIG")"
  [ "$before" = "$after" ]
}

@test "set-global first-class runs flags compose with --executor-option and preserve repos[]" {
  bash "$SCRIPT" add-repo --name backend --path /repos/backend --kind python
  run bash "$SCRIPT" set-global --executor-option idle_timeout=15m \
    --runs-dir /var/runs --runs-retention-days 5
  [ "$status" -eq 0 ]
  # pass-through preserved alongside the first-class scalars
  run cfg_get executor_options.idle_timeout
  [ "$output" = "15m" ]
  run cfg_get executor_options.runs_dir
  [ "$output" = "/var/runs" ]
  run cfg_get executor_options.runs_retention_days
  [ "$output" = "5" ]
  # repos[] untouched
  run cfg_repo_names
  [ "$output" = "backend" ]
}

@test "set-global first-class runs flag wins over a colliding --executor-option (applied last)" {
  run bash "$SCRIPT" set-global --executor-option runs_dir=/from/passthrough --runs-dir /from/flag
  [ "$status" -eq 0 ]
  run cfg_get executor_options.runs_dir
  [ "$output" = "/from/flag" ]
}

@test "set-global --runs-* update in place, preserving other executor_options" {
  bash "$SCRIPT" set-global --runs-dir /var/runs --runs-retention-days 7 --executor-option idle_timeout=10m
  run bash "$SCRIPT" set-global --runs-retention-days 30
  [ "$status" -eq 0 ]
  run cfg_get executor_options.runs_retention_days
  [ "$output" = "30" ]
  run cfg_get executor_options.runs_dir
  [ "$output" = "/var/runs" ]
  run cfg_get executor_options.idle_timeout
  [ "$output" = "10m" ]
}

@test "set-global --runs-dir errors (not overwrites) when executor_options is a non-mapping" {
  cat > "$CROSSCUT_CONFIG" <<'YAML'
version: 1
repos: []
executor_options: notamapping
YAML
  before="$(cat "$CROSSCUT_CONFIG")"
  run bash "$SCRIPT" set-global --runs-dir /var/runs
  [ "$status" -ne 0 ]
  after="$(cat "$CROSSCUT_CONFIG")"
  [ "$before" = "$after" ]
}

@test "set-global --final-review writes the top-level scalar; invalid kind is rejected (atomic)" {
  run bash "$SCRIPT" set-global --final-review claude
  [ "$status" -eq 0 ]
  run cfg_get final_review
  [ "$output" = "claude" ]
  # invalid enum → rejected, file unchanged
  before="$(cat "$CROSSCUT_CONFIG")"
  run bash "$SCRIPT" set-global --final-review frobnicate
  [ "$status" -ne 0 ]
  after="$(cat "$CROSSCUT_CONFIG")"
  [ "$before" = "$after" ]
}

@test "set-global --final-review-option writes final_review_options.{model,reasoning_effort}" {
  run bash "$SCRIPT" set-global --final-review-option model=opus --final-review-option reasoning_effort=high
  [ "$status" -eq 0 ]
  run cfg_get final_review_options.model
  [ "$output" = "opus" ]
  run cfg_get final_review_options.reasoning_effort
  [ "$output" = "high" ]
}

@test "set-global --final-review-option model=opus alone succeeds (no-op guard admits final_opts)" {
  # option-only call, no other flag — must NOT trip 'requires at least one flag'
  run bash "$SCRIPT" set-global --final-review-option model=opus
  [ "$status" -eq 0 ]
  run cfg_get final_review_options.model
  [ "$output" = "opus" ]
}

@test "set-global final/plan/executor option maps compose in one call, preserving repos[]" {
  bash "$SCRIPT" add-repo --name backend --path /repos/backend --kind python
  run bash "$SCRIPT" set-global \
    --plan-review-option model=sonnet \
    --final-review-option model=opus --final-review-option reasoning_effort=high \
    --executor-option model=inherit
  [ "$status" -eq 0 ]
  run cfg_get plan_review_options.model
  [ "$output" = "sonnet" ]
  run cfg_get final_review_options.model
  [ "$output" = "opus" ]
  run cfg_get executor_options.model
  [ "$output" = "inherit" ]
  run cfg_repo_names
  [ "$output" = "backend" ]
  # re-run updates in place
  run bash "$SCRIPT" set-global --final-review-option reasoning_effort=low
  [ "$status" -eq 0 ]
  run cfg_get final_review_options.reasoning_effort
  [ "$output" = "low" ]
  run cfg_get final_review_options.model
  [ "$output" = "opus" ]
}

@test "set-global --final-review-option errors (not overwrites) when final_review_options is a non-mapping" {
  cat > "$CROSSCUT_CONFIG" <<'YAML'
version: 1
repos: []
final_review_options: notamapping
YAML
  before="$(cat "$CROSSCUT_CONFIG")"
  run bash "$SCRIPT" set-global --final-review-option model=opus
  [ "$status" -ne 0 ]
  after="$(cat "$CROSSCUT_CONFIG")"
  [ "$before" = "$after" ]
}

@test "init-style set-global lands model + reasoning_effort in the default config" {
  # The documented first-run init call (SKILL.md step 4): model/effort defaults for all
  # three stages, plus final_review. This is the explicit check that model and reasoning
  # type are recorded in the default config.
  run bash "$SCRIPT" set-global \
    --language ru --executor ralphex --plan-review codex --final-review in-session \
    --merge-ff false --push-enabled false \
    --kb-path '~/.crosscut/knowledge' \
    --runs-dir '~/.cache/crosscut-runs' --runs-retention-days 0 \
    --plan-review-option model=inherit --plan-review-option reasoning_effort=inherit \
    --final-review-option model=inherit --final-review-option reasoning_effort=inherit \
    --executor-option model=inherit --executor-option reasoning_effort=inherit
  [ "$status" -eq 0 ]
  run cfg_get final_review
  [ "$output" = "in-session" ]
  # model + reasoning_effort present for all three stages
  for stage in plan_review_options final_review_options executor_options; do
    run cfg_get "$stage.model"
    [ "$output" = "inherit" ]
    run cfg_get "$stage.reasoning_effort"
    [ "$output" = "inherit" ]
  done
}
