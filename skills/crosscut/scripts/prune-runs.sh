#!/usr/bin/env bash
# prune-runs.sh — retention GC for executor run records under runs_dir.
#
# Two modes:
#   --repo <name> --plan <slug>   event prune: remove every run-id dir for one plan
#                                 (called at Phase 6 when runs_retention_days == 0), EXCEPT
#                                 a live run (running.json, no run.json, PID alive) — never
#                                 delete a concurrent rerun's dir out from under the executor.
#   --sweep [--preserve-file <f>] age sweep: remove terminal run dirs older than
#                                 runs_retention_days (no-op when that is 0), keeping any run
#                                 that is young, live, or listed in --preserve-file. reconcile
#                                 drives this for retention>0 and passes each non-`done` plan's
#                                 newest `completed` run in the preserve file so the merged/done
#                                 head_sha signal is never aged out.
#
# A directory is only ever a deletion candidate when its basename matches the run-id
# pattern <UTCstamp>-<pid> (^[0-9]{8}T[0-9]{6}-[0-9]+$). This is what keeps prune from
# touching the codex worktree at <runs_dir>/<repo>/<slug>/worktree (run-executor.sh
# preserves it on auto-commit failure) or any other non-run sibling.
#
# Reuses lib/config.sh helpers (_crosscut_runs_dir for the ~-expanded base). The age,
# liveness, and path-safety logic runs in an embedded python3 block so mtime handling
# is portable across macOS/Linux (no `find -mtime` / `stat` flag differences).
# --dry-run (or EXECUTOR_DRYRUN=1) reports candidates without deleting.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

_usage() {
  cat >&2 <<'EOF'
usage: prune-runs.sh --repo <name> --plan <slug> [--dry-run]     # event prune one plan's runs
       prune-runs.sh --sweep [--preserve-file <f>] [--dry-run]   # age sweep (runs_retention_days>0)

Removes executor run directories under executor_options.runs_dir. Only directories whose
basename matches the run-id pattern <UTCstamp>-<pid> are ever deleted; a `worktree`
sibling or any other entry is never touched. --preserve-file (sweep only) names a file of
absolute run-dir paths (one per line) to keep regardless of age — reconcile writes each
non-`done` plan's newest `completed` run there (its head_sha is the merged/done signal).
EXECUTOR_DRYRUN=1 behaves like --dry-run.
EOF
}

MODE="" REPO="" PLAN="" PRESERVE_FILE="" DRYRUN="${EXECUTOR_DRYRUN:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    [ $# -ge 2 ] || { echo "prune-runs: --repo requires a value" >&2; exit 2; }; REPO="$2"; shift 2;;
    --plan)    [ $# -ge 2 ] || { echo "prune-runs: --plan requires a value" >&2; exit 2; }; PLAN="$2"; shift 2;;
    --sweep)   MODE="sweep"; shift;;
    --preserve-file) [ $# -ge 2 ] || { echo "prune-runs: --preserve-file requires a value" >&2; exit 2; }; PRESERVE_FILE="$2"; shift 2;;
    --dry-run) DRYRUN=1; shift;;
    -h|--help) _usage; exit 0;;
    *) echo "prune-runs: unknown argument: $1" >&2; _usage; exit 2;;
  esac
done

# --sweep is mutually exclusive with --repo/--plan; otherwise event prune needs both.
if [ "$MODE" = "sweep" ]; then
  { [ -z "$REPO" ] && [ -z "$PLAN" ]; } || { echo "prune-runs: --sweep takes no --repo/--plan" >&2; exit 2; }
else
  MODE="event"
  { [ -n "$REPO" ] && [ -n "$PLAN" ]; } || { _usage; exit 2; }
  [ -z "$PRESERVE_FILE" ] || { echo "prune-runs: --preserve-file is only valid with --sweep" >&2; exit 2; }
fi

RUNS_DIR="$(_crosscut_runs_dir)"
RETENTION="$(cfg_get executor_options.runs_retention_days 0)"

MODE="$MODE" REPO="$REPO" PLAN="$PLAN" PRESERVE_FILE="$PRESERVE_FILE" DRYRUN="$DRYRUN" \
RUNS_DIR="$RUNS_DIR" RETENTION="$RETENTION" python3 - <<'PY'
import os, re, shutil, sys, time

mode      = os.environ["MODE"]
repo      = os.environ.get("REPO", "")
plan      = os.environ.get("PLAN", "")
dryrun    = os.environ.get("DRYRUN", "0") == "1"
runs_dir  = os.environ.get("RUNS_DIR", "")
retention_raw = os.environ.get("RETENTION", "0").strip()
preserve_file = os.environ.get("PRESERVE_FILE", "")

RUN_ID_RE = re.compile(r'^[0-9]{8}T[0-9]{6}-[0-9]+$')

# Absolute run-dir paths the caller (reconcile) marked keep-regardless-of-age — each non-`done`
# plan's newest `completed` run, whose head_sha is the merged/done signal. Read once, compared
# by abspath in the sweep loop.
preserve = set()
if preserve_file:
    try:
        # surrogateescape matches how reconcile writes the file, so a run-dir path with a
        # non-UTF-8 byte round-trips instead of raising here.
        with open(preserve_file, encoding="utf-8", errors="surrogateescape") as _pf:
            for _line in _pf:
                _p = _line.strip()
                if _p:
                    preserve.add(os.path.abspath(_p))
    except OSError as _e:
        # FAIL CLOSED: a destructive sweep must NOT proceed after losing the caller's preserve
        # set — that would silently sweep the very runs it was told to keep (the head_sha
        # signals). An empty preserve set is only valid as an actually-empty preserve file.
        sys.stderr.write("prune-runs: cannot read --preserve-file %r: %s\n" % (preserve_file, _e))
        sys.exit(2)

def die(msg, code=2):
    sys.stderr.write("prune-runs: %s\n" % msg)
    sys.exit(code)

# --- runs_dir sanity: never operate on an empty/root/cwd base (destructive-script guard) ---
if not runs_dir.strip() or runs_dir.strip() in ("/", "."):
    die("refusing to run: runs_dir is empty, '/', or '.' (%r)" % runs_dir)
runs_abs = os.path.abspath(runs_dir)
if runs_abs == os.path.abspath(os.sep):
    die("refusing to run: runs_dir resolves to filesystem root")

def pid_from_runid(name):
    # RUN_ID = <UTCstamp>-<pid>; the pid is the trailing integer after the last '-'.
    return name.rsplit("-", 1)[-1]

def pid_alive(pid):
    # Mirror lib/config.sh _crosscut_pid_alive: existence regardless of owner. os.kill(pid,0)
    # raises ESRCH (dead) or EPERM (alive, owned by another user → treat as alive).
    if not pid or not pid.isdigit():
        return False
    n = int(pid)
    # pid<=0 never names a live run: os.kill(0,...) signals our OWN process group (always
    # "succeeds"), so a corrupt `...-0` run-id must not read as permanently live; too-large
    # a pid raises OverflowError before the syscall.
    if n <= 0:
        return False
    try:
        os.kill(n, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except (OSError, OverflowError):
        return False

def is_live(run_dir):
    # live = running.json present, NO terminal run.json sibling, and the run's PID alive.
    if not os.path.isfile(os.path.join(run_dir, "running.json")):
        return False
    if os.path.isfile(os.path.join(run_dir, "run.json")):
        return False
    return pid_alive(pid_from_runid(os.path.basename(run_dir)))

removed = []
def rm_dir(path):
    removed.append(path)
    if not dryrun:
        shutil.rmtree(path, ignore_errors=True)

if mode == "event":
    # --- path safety: repo/slug must each be a single, non-traversing path component ---
    for label, val in (("repo", repo), ("plan", plan)):
        s = val.strip()
        if not s or s in (".", "..") or "/" in val or "\\" in val or os.path.isabs(val):
            die("event prune: %s must be a single safe path component, got %r" % (label, val))
    target_abs = os.path.abspath(os.path.join(runs_abs, repo, plan))
    # target must be STRICTLY under runs_abs (commonpath is component-aware, unlike startswith)
    try:
        under = os.path.commonpath([runs_abs, target_abs]) == runs_abs
    except ValueError:
        under = False
    if target_abs == runs_abs or not under:
        die("event prune: target %r escapes runs_dir %r" % (target_abs, runs_abs))
    if os.path.isdir(target_abs):
        for child in sorted(os.listdir(target_abs)):
            cpath = os.path.join(target_abs, child)
            # Skip 'worktree'/non-run siblings AND a LIVE run: a concurrent rerun of this plan
            # (running.json, no terminal run.json, PID alive) must never have its directory
            # deleted out from under the executor -- same is_live guard the --sweep path uses.
            if os.path.isdir(cpath) and RUN_ID_RE.match(child) and not is_live(cpath):
                rm_dir(cpath)
        # remove the now-empty slug dir only if nothing (e.g. a preserved worktree) remains
        try:
            if not dryrun and not os.listdir(target_abs):
                os.rmdir(target_abs)
        except OSError:
            pass

elif mode == "sweep":
    # retention validated HERE, before any traversal (config may be hand-edited)
    if not retention_raw.isdigit():
        die("executor_options.runs_retention_days must be a non-negative integer, got %r"
            % retention_raw)
    retention = int(retention_raw)
    if retention > 0 and os.path.isdir(runs_abs):
        cutoff = time.time() - retention * 86400
        for repo_name in sorted(os.listdir(runs_abs)):
            repo_path = os.path.join(runs_abs, repo_name)
            if not os.path.isdir(repo_path):
                continue
            for slug in sorted(os.listdir(repo_path)):
                slug_path = os.path.join(repo_path, slug)
                if not os.path.isdir(slug_path):
                    continue
                for child in sorted(os.listdir(slug_path)):
                    cpath = os.path.join(slug_path, child)
                    if not os.path.isdir(cpath) or not RUN_ID_RE.match(child):
                        continue   # never touch 'worktree' or non-run dirs
                    if os.path.abspath(cpath) in preserve:
                        continue   # caller marked keep (a non-done plan's newest completed run)
                    try:
                        mtime = os.stat(cpath).st_mtime
                    except OSError:
                        continue
                    if mtime >= cutoff:
                        continue   # young enough — keep
                    if is_live(cpath):
                        continue   # live — keep regardless of age
                    rm_dir(cpath)
                # NOTE: sweep deliberately does NOT rmdir an emptied slug dir. The sweep
                # iterates ALL entries under <runs_dir>/<repo>/, which includes the per-repo
                # `executor.lock` mutex dir — an unconditional empty-dir rmdir here would delete
                # an in-flight (mkdir'd, owner-not-yet-written) lock and break mutual exclusion.
                # A leftover empty slug dir is harmless; event-prune (scoped to one plan) cleans up.
else:
    die("unknown mode: %r" % mode)

for p in removed:
    sys.stderr.write("  %s %s\n" % ("would-remove" if dryrun else "removed", p))
sys.stdout.write("%s %d run dir(s)\n" % ("would prune" if dryrun else "pruned", len(removed)))
PY
