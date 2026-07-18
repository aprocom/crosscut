#!/usr/bin/env bash
# run-executor.sh — config-driven headless executor adapter.
# Reads crosscut.config.yaml; emits machine-readable run.json under runs_dir.
# Shared setup (repo/plan resolution + run.json/running.json bookkeeping) runs for
# any external executor; then dispatch on the `executor` scalar:
#   ralphex — Docker path (reference).
#   codex   — host git-worktree adapter driving `codex exec`.
#   claude  — dispatched in-session, not here (exits non-zero).
# EXECUTOR_DRYRUN=1 prints the intended command instead of running it (no side effects).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

# ---- arg parse (shared) ----
REPO="" PLAN="" EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --plan) PLAN="$2"; shift 2;;
    *) EXTRA+=("$1"); shift;;
  esac
done
[ -n "$REPO" ] && [ -n "$PLAN" ] || { echo "usage: run-executor.sh --repo <name> --plan <rel-path> [extra...]" >&2; exit 2; }

# ---- repo/plan resolution (shared for any external executor) ----
EXECUTOR="$(cfg_get executor ralphex)"

REPO_DIR="$(cfg_repo_field "$REPO" path "")"
[ -n "$REPO_DIR" ] || { echo "unknown repo: $REPO" >&2; exit 2; }
[ -d "$REPO_DIR" ] || { echo "repo dir not found: $REPO_DIR" >&2; exit 2; }
[ -f "$REPO_DIR/$PLAN" ] || { echo "plan not found: $REPO_DIR/$PLAN" >&2; exit 2; }

RUNS_DIR_BASE="$(cfg_get executor_options.runs_dir "$HOME/.cache/crosscut-runs")"
RUNS_DIR_BASE="${RUNS_DIR_BASE/#\~/$HOME}"   # expand a leading ~
SLUG="$(basename "$PLAN" .md)"
BRANCH="$SLUG"
DRYRUN="${EXECUTOR_DRYRUN:-0}"

# ---- shared bookkeeping ----
# INTERRUPT_STATUS is set to "interrupted" only by the INT/TERM signal handler; the
# EXIT cleanup defaults an unfinished run to "failed", so a deterministic command
# failure before finish_run is recorded as `failed`, not `interrupted`.
RUN_ID="" RUN_DIR="" BASE_SHA="" STARTED="" RUN_JSON_DONE=0 WORKTREE="" INTERRUPT_STATUS=""
# LOCK_TOKEN — per-repo executor lock owner token (empty until begin_run acquires it).
# Acquired at the top of begin_run (the shared non-dryrun path for every adapter) and
# released in _cleanup, so at most one executor runs per repo at a time.
LOCK_TOKEN=""

# Signal handler (armed on INT/TERM only): a real signal means the run was
# interrupted. Setting the status here and exiting lets the shared EXIT cleanup
# below distinguish a genuine interruption from an ordinary command failure.
_on_signal() { INTERRUPT_STATUS="interrupted"; exit 130; }

# EXIT cleanup covers success, failure, and interruption: always drop a dangling
# codex worktree (the branch persists) and, if we die before run.json, leave a
# terminal record where a running.json was — `interrupted` for an actual signal,
# otherwise `failed` (a deterministic command failure / non-zero exit).
_cleanup() {
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
    git -C "$REPO_DIR" worktree remove "$WORKTREE" --force >/dev/null 2>&1 || true
  fi
  if [ "$RUN_JSON_DONE" = "0" ] && [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ]; then
    local status="${INTERRUPT_STATUS:-failed}"
    cat > "$RUN_DIR/run.json.tmp" 2>/dev/null <<EOF || true
{"run_id":"$RUN_ID","repo":"$REPO","plan":"$PLAN","branch":"$BRANCH","status":"$status","run_dir":"$RUN_DIR"}
EOF
    mv "$RUN_DIR/run.json.tmp" "$RUN_DIR/run.json" 2>/dev/null || true
    rm -f "$RUN_DIR/running.json" 2>/dev/null || true
  fi
  # Release the per-repo lock on success, failure, AND interrupt. Guarded on
  # LOCK_TOKEN so a run that never acquired (dryrun, or a lock-busy skip) is a no-op.
  if [ -n "$LOCK_TOKEN" ]; then
    executor_lock_release "$REPO" "$LOCK_TOKEN" >/dev/null 2>&1 || true
  fi
}

# begin_run — acquire the per-repo lock, allocate the run dir, record base_sha, arm the
# trap, write running.json. This is the shared non-dryrun path for every external adapter,
# so acquiring here (before any run.json/worktree side effect) serializes per repo without
# duplicating the logic in each adapter, and keeps EXECUTOR_DRYRUN lock-free (dryrun exits
# before begin_run). A repo already owned by a live executor is skipped with no side effects.
begin_run() {
  LOCK_TOKEN="$(executor_lock_acquire "$REPO")" || {
    echo "run-executor: repo '$REPO' already has an active executor; skipping" >&2
    exit 1
  }
  # Arm the cleanup trap IMMEDIATELY after acquiring the lock, before any command that
  # could fail (mkdir, git rev-parse, …). _cleanup is guarded on LOCK_TOKEN/RUN_DIR/
  # WORKTREE, so arming it this early is safe: a failure in the setup below still runs
  # _cleanup, which releases the lock (and, once RUN_DIR exists, records a terminal
  # run.json) instead of leaking the lock. The busy-skip above exits before this point,
  # so it never releases a lock it does not own and leaves no run.json/worktree.
  trap _cleanup EXIT
  trap _on_signal INT TERM
  RUN_ID="$(date -u +%Y%m%dT%H%M%S)-$$"
  RUN_DIR="$RUNS_DIR_BASE/$REPO/$SLUG/$RUN_ID"
  mkdir -p "$RUN_DIR"
  BASE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
  STARTED="$(date -u +%FT%TZ)"
  cat > "$RUN_DIR/running.json.tmp" <<EOF
{"run_id":"$RUN_ID","repo":"$REPO","plan":"$PLAN","branch":"$BRANCH","base_sha":"$BASE_SHA","started_at":"$STARTED"}
EOF
  mv "$RUN_DIR/running.json.tmp" "$RUN_DIR/running.json"
}

# finish_run <exit_code> <head_sha> [compare_base] — write the terminal run.json and
# print its path. completed requires exit 0 AND head_sha advanced past compare_base
# (did THIS run add commits). compare_base defaults to BASE_SHA (integration HEAD) so
# the ralphex path is unchanged; the codex path passes RUN_BASE (this run's start head)
# so a no-op rerun on a pre-existing branch is correctly `failed`, not `completed`.
finish_run() {
  local exit_code="$1" head_sha="$2" compare_base="${3:-$BASE_SHA}" status finished
  finished="$(date -u +%FT%TZ)"
  if [ "$exit_code" -ne 0 ]; then status="failed"
  elif [ "$head_sha" = "$compare_base" ]; then status="failed"
  else status="completed"; fi
  cat > "$RUN_DIR/run.json.tmp" <<EOF
{"run_id":"$RUN_ID","repo":"$REPO","plan":"$PLAN","branch":"$BRANCH","base_sha":"$BASE_SHA","head_sha":"$head_sha","started_at":"$STARTED","finished_at":"$finished","exit_code":$exit_code,"status":"$status","run_dir":"$RUN_DIR"}
EOF
  mv "$RUN_DIR/run.json.tmp" "$RUN_DIR/run.json"
  RUN_JSON_DONE=1
  rm -f "$RUN_DIR/running.json"
  echo "$RUN_DIR/run.json"
}

# Container target of a "src:target[:options]" mount spec.
#
# The second colon-separated field. executor_options.mounts is documented as
# "src:target[:options]", and within that format -v splits on colons into two or three
# fields — so a source path containing a colon is not expressible at all (that is what
# --mount exists for) and field 2 is unambiguously the target.
#
# Scope note: this does NOT hold for every -v form docker accepts. "-v /container/cache"
# declares an anonymous volume whose target is field 1. crosscut does not support that
# form in executor_options.mounts; if it ever does, this function must be revisited.
mount_target() {
  printf '%s\n' "$1" | cut -d: -f2
}

# 0 when <needle> is among the remaining arguments.
#
# set -u safe by contract: callers pass arrays as ${arr[@]+"${arr[@]}"}, so an empty
# array expands to no arguments at all rather than to an empty string.
target_declared() {
  local needle="$1"
  shift
  local t
  for t in "$@"; do
    [ "$t" = "$needle" ] && return 0
  done
  return 1
}

# Prepare Claude credentials for the ralphex container.
#
# The ralphex image reads credentials from two places (see its /srv/init.sh):
#   /mnt/claude/.credentials.json      — present on Linux, where Claude Code stores
#                                        credentials as a file
#   /mnt/claude-credentials.json       — the macOS path, where credentials live in the
#                                        Keychain and must be extracted first
#
# Prints the path to mount at /mnt/claude-credentials.json, or nothing when the
# platform needs no separate file. Never prints credential material.
ralphex_prepare_credentials() {
  local dest="$HOME/.claude/claude-credentials.json"

  # Overridable so the platform branch stays testable on either OS (see Task 4).
  case "${CROSSCUT_UNAME:-$(uname -s)}" in
    Darwin)
      command -v security >/dev/null 2>&1 || {
        echo "run-executor: 'security' not found; cannot read the macOS Keychain" >&2
        return 1
      }
      mkdir -p "$HOME/.claude"

      # A unique temp file, not "$dest.tmp": runs proceed in parallel across repos, and
      # a shared temp name means one run's mv steals another's write — or finds the file
      # already gone. mktemp in the destination directory keeps the mv atomic.
      local tmp
      tmp="$(mktemp "$HOME/.claude/.claude-credentials.XXXXXX")" || {
        echo "run-executor: cannot create a temp file in ~/.claude" >&2
        return 1
      }
      # 600 before anything is written: a plain redirect would briefly leave the secret
      # world-readable under the default umask 022.
      chmod 600 "$tmp" || { rm -f "$tmp"; echo "run-executor: cannot set permissions on temp file" >&2; return 1; }

      # Redirect stderr: a Keychain miss must not leak into logs beyond our own message.
      if ! security find-generic-password -s "Claude Code-credentials" -w \
           > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "run-executor: no 'Claude Code-credentials' entry in the Keychain." >&2
        echo "  Run 'claude /login' on the host, then retry." >&2
        return 1
      fi
      # Guard against an empty read producing a valid-looking but useless file.
      [ -s "$tmp" ] || {
        rm -f "$tmp"
        echo "run-executor: Keychain returned an empty credential." >&2
        return 1
      }
      mv "$tmp" "$dest"
      ;;
    *)
      # Linux and friends: Claude Code writes ~/.claude/.credentials.json directly,
      # and the image picks it up from the /mnt/claude mount. No extra file needed.
      [ -f "$HOME/.claude/.credentials.json" ] || {
        echo "run-executor: ~/.claude/.credentials.json not found." >&2
        echo "  Run 'claude /login' on the host, then retry." >&2
        return 1
      }
      ;;
  esac
}

# ---- adapter: ralphex (Docker; reference path, unchanged) ----
adapter_ralphex() {
  local IMAGE IDLE VENV_ISO VENV_CACHE PRE_HOOK VENV_KEY
  IMAGE="$(cfg_get executor_options.image 'ghcr.io/umputun/ralphex:latest')"
  IDLE="$(cfg_get executor_options.idle_timeout '10m')"
  VENV_ISO="$(cfg_repo_field "$REPO" venv_isolation false)"
  VENV_CACHE="$(cfg_get executor_options.venv_cache "$HOME/.cache/crosscut-venv")"
  PRE_HOOK="$(cfg_get executor_options.pre_run_hook '')"
  VENV_CACHE="${VENV_CACHE/#\~/$HOME}"
  VENV_KEY="$REPO"

  # Assemble optional venv-isolation mount (python only).
  local VENV_MOUNT=()
  if [ "$VENV_ISO" = "true" ]; then
    mkdir -p "$VENV_CACHE/$VENV_KEY"
    VENV_MOUNT=(-v "$VENV_CACHE/$VENV_KEY":/project/.venv)
  fi

  # Collect user mounts first so credential mounts can defer to any user-declared target.
  local -a USER_MOUNTS=()
  local -a USER_TARGETS=()
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    m="${m/#\~/$HOME}"
    USER_MOUNTS+=(-v "$m")
    USER_TARGETS+=("$(mount_target "$m")")
  done < <(cfg_list executor_options.mounts)

  # Add credential mounts only when the user has not claimed the same container target.
  # NEEDS_CRED_PREP=1 when the platform-specific credential target was not overridden,
  # meaning we own that mount and must prepare the credential file before the run.
  local -a CRED_MOUNTS=()
  local NEEDS_CRED_PREP=0
  case "${CROSSCUT_UNAME:-$(uname -s)}" in
    Darwin)
      target_declared "/mnt/claude" ${USER_TARGETS[@]+"${USER_TARGETS[@]}"} \
        || CRED_MOUNTS+=(-v "$HOME/.claude:/mnt/claude")
      if ! target_declared "/mnt/claude-credentials.json" ${USER_TARGETS[@]+"${USER_TARGETS[@]}"}; then
        CRED_MOUNTS+=(-v "$HOME/.claude/claude-credentials.json:/mnt/claude-credentials.json")
        NEEDS_CRED_PREP=1
      fi
      ;;
    *)
      if ! target_declared "/mnt/claude" ${USER_TARGETS[@]+"${USER_TARGETS[@]}"}; then
        CRED_MOUNTS+=(-v "$HOME/.claude:/mnt/claude")
        NEEDS_CRED_PREP=1
      fi
      ;;
  esac

  local -a EXTRA_MOUNTS=(${CRED_MOUNTS[@]+"${CRED_MOUNTS[@]}"} ${USER_MOUNTS[@]+"${USER_MOUNTS[@]}"})

  local DOCKER_CMD=(docker run --rm -e "APP_UID=$(id -u)" -v "$REPO_DIR:/project")
  DOCKER_CMD+=(${VENV_MOUNT[@]+"${VENV_MOUNT[@]}"})
  DOCKER_CMD+=(${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"})
  DOCKER_CMD+=(-w /project "$IMAGE" /srv/ralphex --worktree --branch "$BRANCH" --idle-timeout "$IDLE")
  DOCKER_CMD+=(${EXTRA[@]+"${EXTRA[@]}"})
  DOCKER_CMD+=("$PLAN")

  if [ "$DRYRUN" = "1" ]; then
    printf '%q ' "${DOCKER_CMD[@]}"
    printf '\n'
    exit 0
  fi

  # Only now, past the dry-run exit: credential preparation is a side effect and must
  # not happen while merely printing the command.
  #
  # NEEDS_CRED_PREP was set during mount assembly: 1 when our default credential mount
  # survived (user did not override the platform-specific target), 0 when the user owns
  # that target and their setup provides the file.
  if [ "$NEEDS_CRED_PREP" = "1" ]; then
    ralphex_prepare_credentials || return 1
  fi

  begin_run
  cd "$REPO_DIR"
  if [ -n "$PRE_HOOK" ]; then
    eval "$PRE_HOOK" || echo "run-executor: pre_run_hook failed (rc=$?); continuing" >&2
  fi

  local EXIT
  set +e
  "${DOCKER_CMD[@]}" > "$RUN_DIR/executor.log" 2> "$RUN_DIR/stderr.log"
  EXIT=$?
  set -e

  local HEAD_SHA
  HEAD_SHA="$(git rev-parse --verify --quiet "${BRANCH}^{commit}" || echo "$BASE_SHA")"
  finish_run "$EXIT" "$HEAD_SHA"
}

# ---- adapter: codex (host git-worktree; drives `codex exec`) ----
adapter_codex() {
  local CODEX_ARGS PROMPT WT
  CODEX_ARGS="$(cfg_get executor_options.codex_args '--skip-git-repo-check')"
  WT="$RUNS_DIR_BASE/$REPO/$SLUG/worktree"
  PROMPT="Implement the plan described in the file $PLAN. Follow it exactly and commit your work."

  # executor_options.codex_args is trusted shell-ish config: the space/glob word-split
  # here is intentional (a string of extra flags), not verbatim structured args.
  # shellcheck disable=SC2206
  local CODEX_ARGS_ARR=($CODEX_ARGS)
  local CODEX_CMD=(codex exec -C "$WT" --sandbox workspace-write)
  CODEX_CMD+=(${CODEX_ARGS_ARR[@]+"${CODEX_ARGS_ARR[@]}"})
  CODEX_CMD+=(${EXTRA[@]+"${EXTRA[@]}"})
  CODEX_CMD+=("$PROMPT")

  if [ "$DRYRUN" = "1" ]; then
    printf 'worktree: %s\n' "$WT"
    printf '%q ' "${CODEX_CMD[@]}"
    printf '< /dev/null\n'
    exit 0
  fi

  begin_run
  WORKTREE="$WT"   # arm cleanup

  # Materialize the worktree at the repo's current HEAD (base_sha). On a rerun the
  # branch already exists → reuse it (no -b); otherwise cut a fresh branch off base.
  mkdir -p "$(dirname "$WT")"
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$REPO_DIR" worktree add "$WT" "$BRANCH" >/dev/null 2>&1
  else
    git -C "$REPO_DIR" worktree add -b "$BRANCH" "$WT" "$BASE_SHA" >/dev/null 2>&1
  fi

  # Capture THIS run's starting head (branch tip on a rerun, base_sha on a fresh cut)
  # right after checkout and before codex runs; completed/failed is decided against it.
  local RUN_BASE
  RUN_BASE="$(git -C "$WT" rev-parse HEAD)"

  local EXIT
  set +e
  "${CODEX_CMD[@]}" > "$RUN_DIR/executor.log" 2> "$RUN_DIR/stderr.log" < /dev/null
  EXIT=$?
  set -e

  # Advance the branch head if codex left uncommitted work. A commit failure (missing
  # git identity, a rejecting hook, an index error) must NOT destroy codex's only copy:
  # mark the run failed and preserve the worktree so the work is recoverable.
  if [ -n "$(git -C "$WT" status --porcelain)" ]; then
    git -C "$WT" add -A
    if ! git -C "$WT" commit -q -m "crosscut($EXECUTOR): $SLUG"; then
      echo "run-executor: auto-commit failed; preserving worktree $WT for recovery" >&2
      WORKTREE=""   # disarm the trap's worktree cleanup so the work is kept
      finish_run 1 "$RUN_BASE" "$RUN_BASE"
      return
    fi
  fi

  local HEAD_SHA
  HEAD_SHA="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${BRANCH}^{commit}" || echo "$RUN_BASE")"

  # Drop the worktree (branch persists); disarm the trap's worktree cleanup.
  git -C "$REPO_DIR" worktree remove "$WT" --force >/dev/null 2>&1 || true
  WORKTREE=""

  finish_run "$EXIT" "$HEAD_SHA" "$RUN_BASE"
}

# ---- dispatch ----
case "$EXECUTOR" in
  ralphex) adapter_ralphex ;;
  codex)   adapter_codex ;;
  claude)  echo "executor kind 'claude' is dispatched in-session, not by run-executor.sh" >&2; exit 2 ;;
  *)       echo "executor kind '$EXECUTOR' not implemented" >&2; exit 2 ;;
esac
