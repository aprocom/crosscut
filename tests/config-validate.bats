#!/usr/bin/env bats
#
# config-validate.sh — human-friendly whole-file config validation.

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$DIR/../skills/crosscut/scripts/config-validate.sh"
  TMP="$(mktemp -d)"
  export CROSSCUT_CONFIG="$TMP/crosscut.config.yaml"
}
teardown() { rm -rf "$TMP"; }

_valid() {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
repos:
- {name: core, path: $TMP, product: platform}
executor: ralphex
plan_review: codex
final_review: in-session
YAML
}

@test "a well-formed config is valid (exit 0)" {
  _valid
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"config valid"* ]]
  [[ "$output" == *"executor=ralphex"* ]]
}

@test "malformed YAML → exit 2, reports the line, no traceback" {
  printf 'executor: ralphex\n  bad: [unclosed\n' > "$CROSSCUT_CONFIG"
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"line"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "non-mapping root (a list) → exit 1 with a root-mapping error" {
  printf -- '- a\n- b\n' > "$CROSSCUT_CONFIG"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"root must be a YAML mapping"* ]]
}

@test "bad executor → exit 1, names the allowed set" {
  printf 'version: 1\nrepos: []\nexecutor: frobnicate\n' > "$CROSSCUT_CONFIG"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"executor:"* ]]
  [[ "$output" == *"ralphex, claude, codex"* ]]
}

@test "all problems are reported in one run (does not stop at the first)" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
executor: frobnicate
plan_review: nope
repos:
- {name: a, path: $TMP}
- {name: a}
YAML
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"executor:"* ]]
  [[ "$output" == *"plan_review:"* ]]
  [[ "$output" == *"duplicate name 'a'"* ]]
  [[ "$output" == *"no 'path'"* ]]   # second repo 'a' → warning
}

@test "bool is not a valid integer (bool ⊄ int for numeric keys)" {
  printf 'version: 1\nrepos: []\nmax_parallel: true\nexecutor_options: {runs_retention_days: true}\n' > "$CROSSCUT_CONFIG"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"max_parallel:"* ]]
  [[ "$output" == *"runs_retention_days:"* ]]
}

@test "type errors: banana retention, zero max_parallel, empty runs_dir, bad venv_isolation" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
max_parallel: 0
executor_options: {runs_retention_days: banana, runs_dir: ""}
repos:
- {name: r, path: $TMP, venv_isolation: maybe}
YAML
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"max_parallel:"* ]]
  [[ "$output" == *"runs_retention_days:"* ]]
  [[ "$output" == *"runs_dir:"* ]]
  [[ "$output" == *"venv_isolation"* ]]
}

@test "products.<name>.knowledge_base as a scalar is an error" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
repos: []
products: {foo: {knowledge_base: notamapping}}
YAML
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"products.foo.knowledge_base: must be a mapping"* ]]
}

@test "reasoning_effort: error on an active stage, warning on an inactive one" {
  # active: plan_review is codex → invalid effort is an ERROR
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
repos: [{name: r, path: $TMP}]
plan_review: codex
plan_review_options: {reasoning_effort: banana}
YAML
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERRORS (must fix):"* ]]
  [[ "$output" == *"plan_review_options.reasoning_effort"* ]]
  # inactive: final_review is in-session → same value is only a WARNING
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
repos: [{name: r, path: $TMP}]
final_review: in-session
final_review_options: {reasoning_effort: banana}
YAML
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNINGS:"* ]]
  [[ "$output" == *"final_review_options.reasoning_effort"* ]]
}

@test "model on a claude stage warns on a pinned version; codex stage does not warn" {
  for stage in plan_review final_review executor; do
    cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
repos: [{name: r, path: $TMP}]
$stage: claude
${stage}_options: {model: opus-4.8}
YAML
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${stage}_options.model"* ]]
    [[ "$output" == *"tier aliases"* ]]
  done
  # a codex stage with a codex model name → NO model warning
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
repos: [{name: r, path: $TMP}]
plan_review: codex
plan_review_options: {model: gpt-5.5-codex}
YAML
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"plan_review_options.model"* ]]
}

@test "non-existent repo path and empty repos are warnings, still exit 0" {
  printf 'version: 1\nrepos:\n- {name: r, path: /no/such/dir/xyz}\n' > "$CROSSCUT_CONFIG"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not exist"* ]]
  printf 'version: 1\nrepos: []\n' > "$CROSSCUT_CONFIG"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNINGS:"* ]]
}

@test "--json emits parseable JSON with ok and lists" {
  printf 'version: 1\nrepos: []\nexecutor: frobnicate\n' > "$CROSSCUT_CONFIG"
  run bash "$SCRIPT" --json
  [ "$status" -eq 1 ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False; assert any("executor" in e for e in d["errors"])'
  # a warnings-only config → ok=true with a non-empty warnings list
  printf 'version: 1\nrepos: []\n' > "$CROSSCUT_CONFIG"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True; assert len(d["warnings"])>=1'
}

@test "--quiet drops the success summary but still prints problems" {
  _valid
  run bash "$SCRIPT" --quiet
  [ "$status" -eq 0 ]
  [[ "$output" != *"executor=ralphex"* ]]   # summary suppressed
  # problems still print under --quiet
  printf 'version: 1\nrepos: []\nexecutor: bad\n' > "$CROSSCUT_CONFIG"
  run bash "$SCRIPT" --quiet
  [ "$status" -eq 1 ]
  [[ "$output" == *"executor:"* ]]
}

@test "missing config file → exit 3 with the init hint" {
  rm -f "$CROSSCUT_CONFIG"
  run bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no config found"* ]]
  [[ "$output" == *"/crosscut init"* ]]
  # reports the $CROSSCUT_CONFIG path even though it does not exist
  [[ "$output" == *"$CROSSCUT_CONFIG"* ]]
}
