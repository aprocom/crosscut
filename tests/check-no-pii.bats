#!/usr/bin/env bats
#
# Note: forbidden-pattern fixtures below are built at runtime via string
# concatenation (never as a contiguous literal) so this test file itself
# passes check-no-pii.sh when scanned as a tracked file in this repo.

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$DIR/../skills/crosscut/scripts/lib/check-no-pii.sh"
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q
  git config user.email t@t; git config user.name t
}

teardown() { rm -rf "$TMP"; }

@test "clean tree passes" {
  echo "hello world" > a.txt
  git add -A && git commit -qm x
  run bash "$SCRIPT" "$TMP"
  [ "$status" -eq 0 ]
}

@test "personal path fails" {
  home="/Users"
  bad="$home/someone/x"
  echo "$bad" > a.txt
  git add -A && git commit -qm x
  run bash "$SCRIPT" "$TMP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"/Users/"* ]]
}

@test "overlay pattern from CROSSCUT_PII_EXTRA fails" {
  marker="ZZ_PII_TEST_TOKEN_ZZ"
  echo "$marker" > "$TMP/extra-patterns.txt"
  bad="see ${marker}-core"
  echo "$bad" > a.txt
  git add -A && git commit -qm x
  export CROSSCUT_PII_EXTRA="$TMP/extra-patterns.txt"
  run bash "$SCRIPT" "$TMP"
  unset CROSSCUT_PII_EXTRA
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.txt"* ]]
  [[ "$output" == *"$bad"* ]]
}

@test "overlay pattern is not applied without CROSSCUT_PII_EXTRA" {
  marker="ZZ_PII_TEST_TOKEN_ZZ"
  echo "leak ${marker} here" > a.txt
  git add -A && git commit -qm x
  run bash "$SCRIPT" "$TMP"
  [ "$status" -eq 0 ]
}

@test "untracked file is ignored" {
  echo "committed" > a.txt
  git add -A && git commit -qm x
  home="/Users"
  bad="$home/someone/leak"
  echo "$bad" > untracked.txt
  run bash "$SCRIPT" "$TMP"
  [ "$status" -eq 0 ]
}

@test "leading-dash filename is scanned" {
  home="/Users"
  bad="$home/someone/secret"
  echo "$bad" > -dash.txt
  git add -- -dash.txt
  git commit -qm x
  run bash "$SCRIPT" "$TMP"
  [ "$status" -eq 1 ]
}

@test "symlink target is scanned" {
  home="/Users"
  bad="$home/someone/secret"
  ln -s "$bad" alink
  git add alink
  git commit -qm x
  run bash "$SCRIPT" "$TMP"
  [ "$status" -eq 1 ]
}

@test "binary file with embedded personal path is scanned" {
  home="/Users"
  bad="$home/someone/x"
  printf 'prefix\000%s\n' "$bad" > bin.dat
  git add bin.dat && git commit -qm x
  run bash "$SCRIPT" "$TMP"
  [ "$status" -eq 1 ]
}
