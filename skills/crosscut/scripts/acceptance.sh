#!/usr/bin/env bash
# acceptance.sh — run (or, with ACCEPT_DRYRUN=1, print) the acceptance commands
# for a configured repo.
#
# Flat repos run `lint_cmd` then `test_cmd` (unchanged behavior). Monorepo repos
# (repos[].monorepo.tool set) delegate to the tool's affected targets against a
# base ref — substituting the `{base}` token — and fall back to the full-suite
# targets when no base ref is available. Command strings come from the operator's
# own config (trusted), so each is run via `eval`, like `pre_run_hook`. The
# `{base}` value comes from the untrusted `--base` CLI arg, though, so it is
# validated against a git-ref-safe charset before substitution (see below).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

REPO="" BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || { echo "usage: acceptance.sh --repo <name> [--base <ref>]" >&2; exit 2; }; REPO="$2"; shift 2;;
    --base) [ $# -ge 2 ] || { echo "usage: acceptance.sh --repo <name> [--base <ref>]" >&2; exit 2; }; BASE="$2"; shift 2;;
    *) echo "acceptance: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$REPO" ] || { echo "usage: acceptance.sh --repo <name> [--base <ref>]" >&2; exit 2; }

case "$BASE" in
  "") : ;;  # empty is fine (no base)
  *[!A-Za-z0-9._@/^~-]*)
    echo "acceptance: --base has unsafe characters: $BASE" >&2
    exit 2
    ;;
esac

REPO_DIR="$(cfg_repo_field "$REPO" path "")"
[ -n "$REPO_DIR" ] || { echo "acceptance: unknown repo: $REPO" >&2; exit 2; }
[ -d "$REPO_DIR" ] || { echo "acceptance: repo dir not found: $REPO_DIR" >&2; exit 2; }

CMDS=()
MONO_TOOL="$(cfg_repo_monorepo "$REPO" tool "")"
if [ -n "$MONO_TOOL" ]; then
  a_build="$(cfg_repo_monorepo "$REPO" affected_build "")"
  a_lint="$(cfg_repo_monorepo "$REPO" affected_lint "")"
  a_test="$(cfg_repo_monorepo "$REPO" affected_test "")"
  f_build="$(cfg_repo_monorepo "$REPO" full_build "")"
  f_lint="$(cfg_repo_monorepo "$REPO" full_lint "")"
  f_test="$(cfg_repo_monorepo "$REPO" full_test "")"
  if [ -n "$BASE" ] && { [ -n "$a_build" ] || [ -n "$a_lint" ] || [ -n "$a_test" ]; }; then
    for c in "$a_build" "$a_lint" "$a_test"; do
      [ -n "$c" ] && CMDS+=("${c//\{base\}/$BASE}")
    done
  else
    for c in "$f_build" "$f_lint" "$f_test"; do
      [ -n "$c" ] && CMDS+=("$c")
    done
  fi
else
  l="$(cfg_repo_field "$REPO" lint_cmd "")"
  t="$(cfg_repo_field "$REPO" test_cmd "")"
  [ -n "$l" ] && CMDS+=("$l")
  [ -n "$t" ] && CMDS+=("$t")
fi

[ "${#CMDS[@]}" -gt 0 ] || { echo "acceptance: no commands configured for repo '$REPO'" >&2; exit 2; }

if [ "${ACCEPT_DRYRUN:-0}" = "1" ]; then
  printf '%s\n' "${CMDS[@]}"
  exit 0
fi

cd "$REPO_DIR"
status=0
for c in "${CMDS[@]}"; do
  echo "-- acceptance: $c"
  if ! eval "$c"; then
    echo "acceptance: command failed: $c" >&2
    status=1
    break
  fi
done
exit "$status"
