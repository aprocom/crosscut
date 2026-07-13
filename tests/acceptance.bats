#!/usr/bin/env bats

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$DIR/../skills/crosscut/scripts/acceptance.sh"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

# Rewrite a fixture's placeholder path to a real temp repo dir.
_mkcfg() { # $1=fixture $2=reponame
  mkdir -p "$TMP/$2"
  sed "s#/path/to/$2#$TMP/$2#" "$DIR/fixtures/$1" > "$TMP/config.yaml"
  export CROSSCUT_CONFIG="$TMP/config.yaml"
}

@test "flat repo dryrun prints lint then test" {
  _mkcfg accept-flat.config.yaml api
  run env ACCEPT_DRYRUN=1 bash "$SCRIPT" --repo api
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "echo LINT" ]
  [ "${lines[1]}" = "echo TEST" ]
}

@test "flat repo run executes the commands" {
  _mkcfg accept-flat.config.yaml api
  run bash "$SCRIPT" --repo api
  [ "$status" -eq 0 ]
  [[ "$output" == *"LINT"* ]]
  [[ "$output" == *"TEST"* ]]
}

@test "monorepo with base uses affected targets and substitutes {base}" {
  _mkcfg accept-mono.config.yaml web
  run env ACCEPT_DRYRUN=1 bash "$SCRIPT" --repo web --base abc123
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "nx affected -t build --base=abc123" ]
  [ "${lines[1]}" = "nx affected -t lint --base=abc123" ]
  [ "${lines[2]}" = "nx affected -t test --base=abc123" ]
}

@test "monorepo without base falls back to full targets" {
  _mkcfg accept-mono.config.yaml web
  run env ACCEPT_DRYRUN=1 bash "$SCRIPT" --repo web
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "nx run-many -t build --all" ]
  [ "${lines[2]}" = "nx run-many -t test --all" ]
}

@test "unknown repo errors" {
  _mkcfg accept-flat.config.yaml api
  run env ACCEPT_DRYRUN=1 bash "$SCRIPT" --repo nope
  [ "$status" -eq 2 ]
}

@test "missing --repo errors" {
  _mkcfg accept-flat.config.yaml api
  run env ACCEPT_DRYRUN=1 bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "run-mode stops on first failure and returns nonzero" {
  _mkcfg accept-flat.config.yaml api
  sed -i.bak 's#echo LINT#false#; s#echo TEST#echo TEST#' "$TMP/config.yaml"
  rm -f "$TMP/config.yaml.bak"
  run bash "$SCRIPT" --repo api
  [ "$status" -ne 0 ]
  [[ "$output" != *"TEST"* ]]
}

@test "--base with shell metacharacters exits 2" {
  _mkcfg accept-mono.config.yaml web
  run env ACCEPT_DRYRUN=1 bash "$SCRIPT" --repo web --base ';id'
  [ "$status" -eq 2 ]
}

@test "monorepo --base with embedded newline is rejected" {
  _mkcfg accept-mono.config.yaml web
  run env ACCEPT_DRYRUN=1 bash "$SCRIPT" --repo web --base "$(printf 'abc\n;id')"
  [ "$status" -eq 2 ]
}

@test "trailing --repo with no value exits 2" {
  _mkcfg accept-flat.config.yaml api
  run bash "$SCRIPT" --repo
  [ "$status" -eq 2 ]
}
