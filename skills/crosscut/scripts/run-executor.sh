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

  # Assemble config-declared extra mounts (executor_options.mounts is a YAML list of "src:dst").
  local EXTRA_MOUNTS=()
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    m="${m/#\~/$HOME}"
    EXTRA_MOUNTS+=(-v "$m")
  done < <(cfg_list executor_options.mounts)

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
