#!/usr/bin/env bats
#
# cfg_check_depends <slug> — product-boundary enforcement on a plan's depends_on.
# Builds throwaway repos (each with a docs/plans/ dir + frontmatter plan files) and a
# temp $CROSSCUT_CONFIG pointing at them, then exercises the exit-code contract.

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  source "$DIR/../skills/crosscut/scripts/lib/config.sh"
  TMP="$(mktemp -d)"

  # Two products: `platform` (repos alpha, beta) and `web` (repo gamma).
  mkdir -p "$TMP/alpha/docs/plans" "$TMP/beta/docs/plans" "$TMP/gamma/docs/plans"

  export CROSSCUT_CONFIG="$TMP/crosscut.config.yaml"
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - name: alpha
    path: $TMP/alpha
    product: platform
  - name: beta
    path: $TMP/beta
    product: platform
  - name: gamma
    path: $TMP/gamma
    product: web
YAML
}

teardown() { rm -rf "$TMP"; }

# mkplan <repo-path> <slug> <frontmatter-repo> <depends_on-yaml>
mkplan() {
  cat > "$1/docs/plans/$2.md" <<MD
---
repo: $3
status: draft
depends_on: $4
feature_id:
---
# $2
MD
}

@test "in-product depends_on passes (exit 0)" {
  mkplan "$TMP/beta"  feat-b beta  "[]"
  mkplan "$TMP/alpha" feat-a alpha "[feat-b]"
  run cfg_check_depends feat-a
  [ "$status" -eq 0 ]
}

@test "a dependency that has moved to completed/ still resolves (exit 0)" {
  # A done dependency lives at <plans_dir>/completed/<slug>.md, not the active dir.
  mkdir -p "$TMP/beta/docs/plans/completed"
  cat > "$TMP/beta/docs/plans/completed/done-b.md" <<MD
---
repo: beta
status: done
depends_on: []
feature_id:
---
# done-b
MD
  mkplan "$TMP/alpha" needs-done alpha "[done-b]"
  run cfg_check_depends needs-done
  [ "$status" -eq 0 ]
}

@test "cross-product depends_on is rejected (non-zero)" {
  mkplan "$TMP/gamma" feat-g gamma "[]"
  mkplan "$TMP/alpha" feat-x alpha "[feat-g]"
  run cfg_check_depends feat-x
  [ "$status" -ne 0 ]
}

@test "empty depends_on passes (exit 0)" {
  mkplan "$TMP/alpha" feat-solo alpha "[]"
  run cfg_check_depends feat-solo
  [ "$status" -eq 0 ]
}

@test "absent depends_on key passes (exit 0)" {
  cat > "$TMP/alpha/docs/plans/feat-bare.md" <<MD
---
repo: alpha
status: draft
---
# feat-bare
MD
  run cfg_check_depends feat-bare
  [ "$status" -eq 0 ]
}

@test "unresolved dependency is rejected (non-zero)" {
  mkplan "$TMP/alpha" feat-dangling alpha "[does-not-exist]"
  run cfg_check_depends feat-dangling
  [ "$status" -ne 0 ]
}

@test "ambiguous slug (found in 2+ repos) is rejected (non-zero)" {
  mkplan "$TMP/alpha" dup alpha "[]"
  mkplan "$TMP/beta"  dup beta  "[]"
  run cfg_check_depends dup
  [ "$status" -ne 0 ]
}

@test "unresolved slug (found in 0 repos) is rejected (non-zero)" {
  run cfg_check_depends nowhere
  [ "$status" -ne 0 ]
}

@test "a same-product dependency in a third repo of the product passes (exit 0)" {
  # alpha depends on a beta plan; both are product `platform`.
  mkplan "$TMP/beta"  shared beta  "[]"
  mkplan "$TMP/alpha" consumer alpha "[shared]"
  run cfg_check_depends consumer
  [ "$status" -eq 0 ]
}

@test "dependency whose frontmatter repo is absent from config is rejected (non-zero)" {
  mkplan "$TMP/alpha" ghost-dep ghost "[]"        # located in alpha, but names repo `ghost`
  mkplan "$TMP/alpha" needs-ghost alpha "[ghost-dep]"
  run cfg_check_depends needs-ghost
  [ "$status" -ne 0 ]
}
