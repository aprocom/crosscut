#!/usr/bin/env bash
# check-no-pii.sh — fail if any git-tracked file carries personal paths or
# origin markers that must not appear in the public repo.
#
# Forbidden patterns live in pii-patterns.txt (next to this script), which holds
# only generic shape patterns and is git-tracked. Machine-/project-specific
# literals live in an untracked overlay — pii-patterns.local.txt beside this
# script, and/or the file named by $CROSSCUT_PII_EXTRA — loaded in addition, so
# those literals are never published. The tracked pii-patterns.txt necessarily
# contains the patterns it defines, so it is the single file excluded from the
# scan. Every other tracked file — including tests — is scanned; test fixtures
# build match strings at runtime so they stay clean.
#
# Uses `git grep --cached` so odd filenames (leading dash, spaces) are handled
# safely by git itself. The -I (skip-binary) flag is deliberately NOT used:
# without it, a match inside a binary blob prints "Binary file <path>
# matches" (rc 0), which this gate treats as a FAIL — so a forbidden literal
# embedded in a tracked screenshot/PDF/build artifact is still caught. git
# grep, however, unconditionally skips symlinks (mode 120000) — verified
# against git 2.50.1:
# no combination of -a/--textconv/pathspec makes it look inside a symlink
# blob. So a symlink's own stored target path (which can itself be a personal
# path) is scanned separately below, straight from the index. The scan covers
# staged/committed content, i.e. exactly what would be published — run it
# after staging.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERNS_FILE="$SCRIPT_DIR/pii-patterns.txt"
ROOT="${1:-.}"
cd "$ROOT"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "check-no-pii: '$ROOT' is not a git working tree" >&2
  exit 2
}
[ -f "$PATTERNS_FILE" ] || {
  echo "check-no-pii: patterns file missing: $PATTERNS_FILE" >&2
  exit 2
}

# Repo-relative path of this tool's own pattern list; excluded so the gate never
# flags its own definitions. A harmless no-op when scanning any other repo.
# Single source of truth: both the git-grep exclude pathspec below and the
# symlink-loop skip reference this one variable.
PATTERNS_REL='skills/crosscut/scripts/lib/pii-patterns.txt'
EXCLUDE=":(exclude)$PATTERNS_REL"

# Collect patterns from the tracked list plus any private overlays. The tracked
# pii-patterns.txt holds only generic shape patterns; machine-/project-specific
# literals live in an untracked overlay (pii-patterns.local.txt beside this
# script, and/or the file named by $CROSSCUT_PII_EXTRA) so they are never
# published. Comments and blank lines are stripped here, once. The final-line
# guard (`|| [ -n "$pat" ]`) reads a last line that lacks a trailing newline.
PATTERNS=()
load_patterns() {
  local file="$1" pat
  [ -f "$file" ] || return 0
  while IFS= read -r pat || [ -n "$pat" ]; do
    [ -n "$pat" ] || continue
    case "$pat" in \#*) continue;; esac
    PATTERNS+=("$pat")
  done < "$file"
}
load_patterns "$PATTERNS_FILE"
load_patterns "$SCRIPT_DIR/pii-patterns.local.txt"
[ -n "${CROSSCUT_PII_EXTRA:-}" ] && load_patterns "$CROSSCUT_PII_EXTRA"

if [ "${#PATTERNS[@]}" -eq 0 ]; then
  echo "check-no-pii: no patterns loaded from $PATTERNS_FILE" >&2
  exit 2
fi

if [ -z "$(git ls-files)" ]; then
  echo "check-no-pii: no tracked files"
  exit 0
fi

status=0
for pat in "${PATTERNS[@]}"; do
  matches="$(git grep --cached -nE -e "$pat" -- . "$EXCLUDE" 2>/dev/null)" && rc=0 || rc=$?
  case "$rc" in
    0)
      echo "FAIL: forbidden pattern '$pat':"
      printf '%s\n' "$matches"
      status=1
      ;;
    1) : ;;  # no match — clean for this pattern
    *)
      echo "check-no-pii: git grep error (rc=$rc) on pattern '$pat'" >&2
      exit 2
      ;;
  esac
done

# git grep never looks inside symlink blobs, so check each tracked symlink's
# stored target text against every pattern directly from the index.
while IFS= read -r -d '' entry; do
  meta="${entry%%$'\t'*}"          # "<mode> <sha> <stage>"
  path="${entry#*$'\t'}"
  mode="${meta%% *}"
  sha="${meta#* }"
  sha="${sha%% *}"                 # strip trailing " <stage>"
  [ "$mode" = "120000" ] || continue
  [ "$path" = "$PATTERNS_REL" ] && continue
  target="$(git cat-file -p "$sha" 2>/dev/null || true)"
  [ -n "$target" ] || continue
  for pat in "${PATTERNS[@]}"; do
    if printf '%s\n' "$target" | grep -qE "$pat"; then
      echo "FAIL: forbidden pattern '$pat' in symlink target:"
      echo "$path -> $target"
      status=1
    fi
  done
done < <(git ls-files -s -z)

[ "$status" -eq 0 ] && echo "check-no-pii: clean"
exit "$status"
