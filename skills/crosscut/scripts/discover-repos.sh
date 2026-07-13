#!/usr/bin/env bash
# discover-repos.sh — scan ROOT's immediate subdirs for git repos, detect kind.
# Output: TSV name<TAB>abspath<TAB>kind<TAB>monorepo_tool
#   kind: python|nodejs|go|other
#   monorepo_tool: nx|lerna|pnpm|turbo|-
set -euo pipefail
ROOT="${1:-$PWD}"

for d in "$ROOT"/*/; do
  d="${d%/}"
  [ -d "$d/.git" ] || continue
  name="$(basename "$d")"
  abspath="$(cd "$d" && pwd)"
  if [ -f "$d/pyproject.toml" ] || [ -f "$d/requirements.txt" ] || [ -f "$d/setup.py" ]; then
    kind="python"
  elif [ -f "$d/package.json" ]; then
    kind="nodejs"
  elif [ -f "$d/go.mod" ]; then
    kind="go"
  else
    kind="other"
  fi
  mono="-"
  if [ -f "$d/nx.json" ]; then mono="nx"
  elif [ -f "$d/lerna.json" ]; then mono="lerna"
  elif [ -f "$d/pnpm-workspace.yaml" ]; then mono="pnpm"
  elif [ -f "$d/turbo.json" ]; then mono="turbo"
  fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$abspath" "$kind" "$mono"
done
