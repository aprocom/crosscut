#!/usr/bin/env bats
# cfg_product_kb — knowledge-base resolver (mcp-else-path, with a path fallback field).

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  source "$DIR/../skills/crosscut/scripts/lib/config.sh"
}

@test "cfg_product_kb: per-product mcp wins; third field is the ~-expanded per-product path" {
  export CROSSCUT_CONFIG="$DIR/fixtures/kb.config.yaml"
  run cfg_product_kb alpha
  [ "$status" -eq 0 ]
  [ "$output" = "mcp"$'\t'"kb://alpha-mcp"$'\t'"$HOME/kb/alpha" ]
}

@test "cfg_product_kb: global mcp wins when no per-product mcp, even with a per-product path" {
  export CROSSCUT_CONFIG="$DIR/fixtures/kb.config.yaml"
  run cfg_product_kb beta
  [ "$status" -eq 0 ]
  [ "$output" = "mcp"$'\t'"kb://global"$'\t'"$HOME/kb/beta-custom" ]
}

@test "cfg_product_kb: per-product mcp:\"\" opts out to path even when a global mcp is set" {
  export CROSSCUT_CONFIG="$DIR/fixtures/kb.config.yaml"
  run cfg_product_kb gamma
  [ "$status" -eq 0 ]
  # present-but-empty per-product mcp is an explicit opt-out: the path form, NOT kb://global.
  [ "$output" = "path"$'\t'"$HOME/kb/gamma" ]
}

@test "cfg_product_kb: no per-product mcp key inherits the global mcp (with global-base fallback)" {
  export CROSSCUT_CONFIG="$DIR/fixtures/kb.config.yaml"
  run cfg_product_kb iota
  [ "$status" -eq 0 ]
  # no per-product mcp key → inherit global mcp; fallback path is <global-base>/<product>.
  [ "$output" = "mcp"$'\t'"kb://global"$'\t'"$HOME/kb-base/iota" ]
}

@test "cfg_product_kb: empty-string mcp (per-product and global) falls through to path" {
  export CROSSCUT_CONFIG="$DIR/fixtures/kb-empty-mcp.config.yaml"
  run cfg_product_kb delta
  [ "$status" -eq 0 ]
  [ "$output" = "path"$'\t'"$HOME/kb/delta" ]
}

@test "cfg_product_kb: per-product path returned verbatim, ~ expanded" {
  export CROSSCUT_CONFIG="$DIR/fixtures/kb-empty-mcp.config.yaml"
  run cfg_product_kb theta
  [ "$status" -eq 0 ]
  [ "$output" = "path"$'\t'"$HOME/custom/theta-kb" ]
}

@test "cfg_product_kb: no per-product path uses shared <global-base>/<product>" {
  export CROSSCUT_CONFIG="$DIR/fixtures/kb-empty-mcp.config.yaml"
  run cfg_product_kb epsilon
  [ "$status" -eq 0 ]
  [ "$output" = "path"$'\t'"$HOME/kb-base/epsilon" ]
}

@test "cfg_product_kb: built-in default base ~/.crosscut/knowledge when no global path" {
  export CROSSCUT_CONFIG="$DIR/fixtures/kb-default.config.yaml"
  run cfg_product_kb zeta
  [ "$status" -eq 0 ]
  [ "$output" = "path"$'\t'"$HOME/.crosscut/knowledge/zeta" ]
}
