#!/usr/bin/env bats

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$DIR/../skills/crosscut/scripts/plan-review-limits.sh"
}

@test "plan_review block absent → disabled no-op" {
  TMP="$(mktemp -d)"
  cat > "$TMP/no-plan-review-block.yaml" <<EOF
version: 1
EOF
  export CROSSCUT_CONFIG="$TMP/no-plan-review-block.yaml"
  export CODEX_HOME="$(mktemp -d)"
  local codex_home="$CODEX_HOME"
  run bash "$SCRIPT"
  rm -rf "$codex_home" "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"disabled"* ]]
}

@test "plan_review none → no-op line, exit 0" {
  export CROSSCUT_CONFIG="$DIR/fixtures/plan-review-none.config.yaml"  # plan_review: none
  export CODEX_HOME="$(mktemp -d)"   # belt-and-suspenders: no real data even if gating regresses
  local codex_home="$CODEX_HOME"
  run bash "$SCRIPT"
  rm -rf "$codex_home"
  [ "$status" -eq 0 ]
  [[ "$output" == *"disabled"* ]]
}

@test "output is English (no Cyrillic) when enabled but no rollout" {
  export CROSSCUT_CONFIG="$DIR/fixtures/plan-review-codex.config.yaml"
  export CODEX_HOME="$(mktemp -d)"   # empty → no rollout
  local codex_home="$CODEX_HOME"
  run bash "$SCRIPT"
  rm -rf "$codex_home"
  [ "$status" -eq 0 ]
  # must not contain Cyrillic
  [[ ! "$output" =~ [А-Яа-я] ]]
}

@test "malformed rate_limits line degrades gracefully" {
  export CROSSCUT_CONFIG="$DIR/fixtures/plan-review-codex.config.yaml"
  codex_home="$(mktemp -d)"
  export CODEX_HOME="$codex_home"
  d="$CODEX_HOME/sessions/$(date +%Y/%m/%d)"
  mkdir -p "$d"
  printf '%s\n' '{"foo":1,"rate_limits":{"primary":{"used_perce' > "$d/rollout-x.jsonl"
  run bash "$SCRIPT"
  rm -rf "$codex_home"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Traceback"* ]]
  [[ "$output" == *"plan_review"* ]]
}
