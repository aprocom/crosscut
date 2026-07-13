#!/usr/bin/env bats

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  source "$DIR/../skills/crosscut/scripts/lib/config.sh"
  export CROSSCUT_CONFIG="$DIR/fixtures/sample.config.yaml"
}

@test "crosscut_config_path returns the env-provided path" {
  run crosscut_config_path
  [ "$status" -eq 0 ]
  [ "$output" = "$CROSSCUT_CONFIG" ]
}

@test "cfg_get reads a top-level scalar" {
  run cfg_get language
  [ "$output" = "en" ]
}

@test "cfg_get returns default for a missing key" {
  run cfg_get nope.missing fallback
  [ "$output" = "fallback" ]
}

@test "cfg_get reads a nested scalar" {
  run cfg_get executor_options.image
  [ "$output" = "ghcr.io/umputun/ralphex:latest" ]
}

@test "cfg_repo_names lists all repo names" {
  run cfg_repo_names
  [ "${lines[0]}" = "backend" ]
  [ "${lines[1]}" = "web" ]
}

@test "cfg_repo_field reads a repo entry field" {
  run cfg_repo_field web kind
  [ "$output" = "nodejs" ]
}

@test "cfg_repo_field returns default for missing field" {
  run cfg_repo_field web venv_isolation false
  [ "$output" = "false" ]
}

@test "cfg_repo_product returns the explicit product field" {
  run cfg_repo_product backend
  [ "$output" = "platform" ]
}

@test "cfg_repo_product defaults to the repo name when product is absent" {
  run cfg_repo_product web
  [ "$output" = "web" ]
}

@test "cfg_products lists the unique, sorted set of resolved products" {
  run cfg_products
  [ "${lines[0]}" = "platform" ]
  [ "${lines[1]}" = "web" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "cfg_product_repos lists every repo sharing a product" {
  run cfg_product_repos platform
  [ "${lines[0]}" = "backend" ]
  [ "${lines[1]}" = "mono" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "cfg_product_repos lists a name-defaulted solo repo" {
  run cfg_product_repos web
  [ "$output" = "web" ]
}

@test "cfg_list reads a YAML list" {
  run cfg_list executor_options.mounts
  [ "${lines[0]}" = "~/.claude:/mnt/claude" ]
  [ "${lines[1]}" = "~/.codex:/mnt/codex" ]
}

@test "crosscut_config_path falls back to \$HOME/.crosscut when no env var is set" {
  unset CROSSCUT_CONFIG
  local home
  home="$(mktemp -d)"
  mkdir -p "$home/.crosscut"
  printf 'version: 1\nlanguage: en\n' > "$home/.crosscut/crosscut.config.yaml"
  HOME="$home" run crosscut_config_path
  [ "$status" -eq 0 ]
  [ "$output" = "$home/.crosscut/crosscut.config.yaml" ]
  rm -rf "$home"
}

@test "crosscut_config_path returns 1 when no config is found anywhere" {
  unset CROSSCUT_CONFIG
  local home
  home="$(mktemp -d)"
  HOME="$home" run crosscut_config_path
  [ "$status" -eq 1 ]
  rm -rf "$home"
}

@test "cfg_repo_monorepo reads a monorepo sub-key" {
  run cfg_repo_monorepo mono tool
  [ "$output" = "nx" ]
}

@test "cfg_repo_monorepo substitutes nothing (raw value with {base})" {
  run cfg_repo_monorepo mono affected_test
  [ "$output" = "npx nx affected -t test --base={base}" ]
}

@test "cfg_repo_monorepo returns default when repo has no monorepo block" {
  run cfg_repo_monorepo backend tool "none"
  [ "$output" = "none" ]
}

@test "cfg_repo_monorepo returns default for a missing sub-key" {
  run cfg_repo_monorepo mono affected_build "none"
  [ "$output" = "none" ]
}

@test "malformed YAML fails gracefully via cfg_get (exit 2, no traceback)" {
  tmp="$(mktemp)"
  printf 'executor: ralphex\n  bad: [unclosed\n' > "$tmp"
  export CROSSCUT_CONFIG="$tmp"
  run cfg_get executor ralphex
  [ "$status" -eq 2 ]
  [[ "$output" == *"config YAML is invalid"* ]]
  [[ "$output" != *"Traceback"* ]]
  rm -f "$tmp"
}

@test "malformed YAML fails gracefully via cfg_check_depends (exit 2, no traceback)" {
  tmp="$(mktemp)"
  printf 'executor: ralphex\n  bad: [unclosed\n' > "$tmp"
  export CROSSCUT_CONFIG="$tmp"
  run cfg_check_depends someslug
  [ "$status" -eq 2 ]
  [[ "$output" == *"config YAML is invalid"* ]]
  [[ "$output" != *"Traceback"* ]]
  rm -f "$tmp"
}
