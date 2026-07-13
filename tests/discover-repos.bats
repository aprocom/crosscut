#!/usr/bin/env bats

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$DIR/../skills/crosscut/scripts/discover-repos.sh"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/py/.git"    && touch "$TMP/py/pyproject.toml"
  mkdir -p "$TMP/js/.git"    && touch "$TMP/js/package.json"
  mkdir -p "$TMP/go/.git"    && touch "$TMP/go/go.mod"
  mkdir -p "$TMP/plain/.git"
  mkdir -p "$TMP/nogit"
  mkdir -p "$TMP/nxmono/.git"  && touch "$TMP/nxmono/package.json" "$TMP/nxmono/nx.json"
  mkdir -p "$TMP/lernamono/.git" && touch "$TMP/lernamono/package.json" "$TMP/lernamono/lerna.json"
}

teardown() { rm -rf "$TMP"; }

@test "detects python by pyproject" {
  run bash "$SCRIPT" "$TMP"
  [[ "$output" == *$'py\t'*$'\tpython'* ]]
}

@test "detects nodejs by package.json" {
  run bash "$SCRIPT" "$TMP"
  [[ "$output" == *$'js\t'*$'\tnodejs'* ]]
}

@test "detects go by go.mod" {
  run bash "$SCRIPT" "$TMP"
  [[ "$output" == *$'go\t'*$'\tgo'* ]]
}

@test "falls back to other" {
  run bash "$SCRIPT" "$TMP"
  [[ "$output" == *$'plain\t'*$'\tother'* ]]
}

@test "skips non-git dirs" {
  run bash "$SCRIPT" "$TMP"
  [[ "$output" != *$'nogit\t'* ]]
}

@test "detects nx monorepo tool in 4th column" {
  run bash "$SCRIPT" "$TMP"
  [[ "$output" == *$'nxmono\t'*$'\tnodejs\tnx'* ]]
}

@test "detects lerna monorepo tool" {
  run bash "$SCRIPT" "$TMP"
  [[ "$output" == *$'lernamono\t'*$'\tnodejs\tlerna'* ]]
}

@test "non-monorepo repo has dash in 4th column" {
  run bash "$SCRIPT" "$TMP"
  [[ "$output" == *$'js\t'*$'\tnodejs\t-'* ]]
}
