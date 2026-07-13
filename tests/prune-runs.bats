#!/usr/bin/env bats
#
# prune-runs.sh — retention GC for executor run records.

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$DIR/../skills/crosscut/scripts/prune-runs.sh"
  TMP="$(mktemp -d)"
  RUNS="$TMP/runs"
  mkdir -p "$RUNS"
  export CROSSCUT_CONFIG="$TMP/crosscut.config.yaml"
  _write_config 0
}

teardown() { rm -rf "$TMP"; }

# _write_config <retention> — point config at the temp runs_dir with a given retention.
_write_config() {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
repos: []
executor_options:
  runs_dir: $RUNS
  runs_retention_days: $1
YAML
}

# _mk_run <repo> <slug> <run_id> — make a run dir with a terminal run.json; echo its path.
_mk_run() {
  local d="$RUNS/$1/$2/$3"
  mkdir -p "$d"
  echo '{"status":"completed"}' > "$d/run.json"
  echo "$d"
}

# _backdate <dir> <days> — set mtime N days in the past (portable, via python os.utime).
_backdate() {
  python3 - "$1" "$2" <<'PY'
import os, sys, time
d, days = sys.argv[1], int(sys.argv[2])
t = time.time() - days * 86400
os.utime(d, (t, t))
PY
}

@test "event prune removes a plan's run dirs and is idempotent" {
  _mk_run repoA slugX 20260101T010101-111 >/dev/null
  _mk_run repoA slugX 20260102T020202-222 >/dev/null
  [ -d "$RUNS/repoA/slugX" ]
  run bash "$SCRIPT" --repo repoA --plan slugX
  [ "$status" -eq 0 ]
  [ ! -d "$RUNS/repoA/slugX/20260101T010101-111" ]
  [ ! -d "$RUNS/repoA/slugX/20260102T020202-222" ]
  [ ! -d "$RUNS/repoA/slugX" ]   # empty slug dir removed
  # idempotent: a second call on the absent tree still succeeds
  run bash "$SCRIPT" --repo repoA --plan slugX
  [ "$status" -eq 0 ]
}

@test "event prune never deletes a worktree sibling" {
  _mk_run repoA slugX 20260101T010101-111 >/dev/null
  mkdir -p "$RUNS/repoA/slugX/worktree"; touch "$RUNS/repoA/slugX/worktree/keep"
  run bash "$SCRIPT" --repo repoA --plan slugX
  [ "$status" -eq 0 ]
  [ ! -d "$RUNS/repoA/slugX/20260101T010101-111" ]   # run dir gone
  [ -f "$RUNS/repoA/slugX/worktree/keep" ]           # worktree preserved
  [ -d "$RUNS/repoA/slugX" ]                          # slug dir kept (worktree remains)
}

@test "event prune never deletes a live run dir" {
  _mk_run repoA slugX 20260101T010101-111 >/dev/null       # terminal run.json -> deletable
  live="$RUNS/repoA/slugX/20260102T020202-$$"              # running.json, no run.json, pid alive
  mkdir -p "$live"; echo '{}' > "$live/running.json"
  run bash "$SCRIPT" --repo repoA --plan slugX
  [ "$status" -eq 0 ]
  [ ! -d "$RUNS/repoA/slugX/20260101T010101-111" ]         # terminal run pruned
  [ -d "$live" ]                                            # live run preserved (executor still running)
  [ -d "$RUNS/repoA/slugX" ]                                # slug dir kept (live remains)
}

@test "event prune rejects unsafe repo/plan components without deleting" {
  _mk_run repoA slugX 20260101T010101-111 >/dev/null
  run bash "$SCRIPT" --repo repoA --plan ../evil
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" --repo "a/b" --plan slugX
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" --repo repoA --plan .
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" --repo "" --plan slugX
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" --repo repoA --plan ""
  [ "$status" -ne 0 ]
  [ -d "$RUNS/repoA/slugX/20260101T010101-111" ]   # nothing deleted
}

@test "prune refuses a runs_dir of / or ." {
  cat > "$CROSSCUT_CONFIG" <<'YAML'
version: 1
repos: []
executor_options:
  runs_dir: /
  runs_retention_days: 0
YAML
  run bash "$SCRIPT" --repo repoA --plan slugX
  [ "$status" -ne 0 ]
  cat > "$CROSSCUT_CONFIG" <<'YAML'
version: 1
repos: []
executor_options:
  runs_dir: .
  runs_retention_days: 5
YAML
  run bash "$SCRIPT" --sweep
  [ "$status" -ne 0 ]
}

@test "sweep is a no-op when runs_retention_days is 0" {
  _write_config 0
  d="$(_mk_run repoA slugX 20260101T010101-111)"
  _backdate "$d" 100
  run bash "$SCRIPT" --sweep
  [ "$status" -eq 0 ]
  [ -d "$d" ]   # kept — retention 0 sweep does nothing
}

@test "sweep removes terminal run dirs older than retention, keeps young ones" {
  _write_config 7
  old="$(_mk_run repoA slugX 20260101T010101-111)"; _backdate "$old" 10
  young="$(_mk_run repoA slugY 20260201T020202-222)"; _backdate "$young" 2
  run bash "$SCRIPT" --sweep
  [ "$status" -eq 0 ]
  [ ! -d "$old" ]
  [ -d "$young" ]
}

@test "sweep keeps a live run, sweeps a dead-pid run and a terminal+running run" {
  _write_config 7
  # live: running.json, no run.json, pid = $$ (this shell — alive)
  live="$RUNS/repoA/slugLive/20260101T010101-$$"
  mkdir -p "$live"; echo '{}' > "$live/running.json"; _backdate "$live" 30
  # dead: pid of a shell that has already exited
  dead_pid="$(sh -c 'echo $$')"
  dead="$RUNS/repoA/slugDead/20260101T010101-$dead_pid"
  mkdir -p "$dead"; echo '{}' > "$dead/running.json"; _backdate "$dead" 30
  # both: running.json AND a terminal run.json → not live → swept
  both="$RUNS/repoA/slugBoth/20260101T010101-$$"
  mkdir -p "$both"; echo '{}' > "$both/running.json"; echo '{"status":"completed"}' > "$both/run.json"; _backdate "$both" 30
  run bash "$SCRIPT" --sweep
  [ "$status" -eq 0 ]
  [ -d "$live" ]     # live pid → kept regardless of age
  [ ! -d "$dead" ]   # dead pid → swept
  [ ! -d "$both" ]   # terminal sibling → not live → swept
}

@test "sweep ignores directories whose basename is not a run-id" {
  _write_config 7
  garbage="$RUNS/repoA/slugX/garbage"; mkdir -p "$garbage"; _backdate "$garbage" 100
  wt="$RUNS/repoA/slugX/worktree"; mkdir -p "$wt"; _backdate "$wt" 100
  run bash "$SCRIPT" --sweep
  [ "$status" -eq 0 ]
  [ -d "$garbage" ]   # non-run-id basename → ignored
  [ -d "$wt" ]        # worktree → ignored
}

@test "sweep preserves run dirs listed in --preserve-file regardless of age" {
  _write_config 7
  keep="$(_mk_run repoA slugX 20260101T010101-111)"; _backdate "$keep" 30
  drop="$(_mk_run repoA slugX 20260101T000000-100)"; _backdate "$drop" 30
  pf="$TMP/preserve.txt"; echo "$keep" > "$pf"
  run bash "$SCRIPT" --sweep --preserve-file "$pf"
  [ "$status" -eq 0 ]
  [ -d "$keep" ]      # listed -> kept despite age
  [ ! -d "$drop" ]    # not listed, old -> swept
}

@test "--preserve-file is rejected in event mode" {
  run bash "$SCRIPT" --repo repoA --plan slugX --preserve-file "$TMP/x"
  [ "$status" -ne 0 ]
}

@test "sweep fails closed on an unreadable --preserve-file (deletes nothing)" {
  _write_config 7
  old="$(_mk_run repoA slugX 20260101T010101-111)"; _backdate "$old" 30
  run bash "$SCRIPT" --sweep --preserve-file "$TMP/does-not-exist.txt"
  [ "$status" -ne 0 ]        # fail closed rather than sweep with a lost preserve set
  [ -d "$old" ]              # nothing deleted
}

@test "sweep with an empty --preserve-file sweeps old runs normally" {
  _write_config 7
  old="$(_mk_run repoA slugX 20260101T010101-111)"; _backdate "$old" 30
  pf="$TMP/empty.txt"; : > "$pf"       # empty (valid) preserve file
  run bash "$SCRIPT" --sweep --preserve-file "$pf"
  [ "$status" -eq 0 ]
  [ ! -d "$old" ]                      # empty list -> ordinary sweep (distinct from unreadable)
}

@test "sweep never rmdir's the per-repo executor.lock dir (even when empty/in-flight)" {
  _write_config 7
  old="$(_mk_run repoA slugX 20260101T010101-111)"; _backdate "$old" 30
  lock="$RUNS/repoA/executor.lock"; mkdir -p "$lock"     # empty lock dir (mkdir'd, owner not yet written)
  run bash "$SCRIPT" --sweep
  [ "$status" -eq 0 ]
  [ ! -d "$old" ]                                          # sweep still ages out the old run
  [ -d "$lock" ]                                           # lock dir preserved -> mutex intact
}

@test "sweep keeps a live run even with --preserve-file set" {
  _write_config 7
  live="$RUNS/repoA/slugX/20260101T010101-$$"; mkdir -p "$live"; echo '{}' > "$live/running.json"; _backdate "$live" 30
  pf="$TMP/empty.txt"; : > "$pf"
  run bash "$SCRIPT" --sweep --preserve-file "$pf"
  [ "$status" -eq 0 ]
  [ -d "$live" ]                       # live guard still applies alongside preserve-file
}

@test "sweep refuses an invalid hand-written runs_retention_days" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
repos: []
executor_options:
  runs_dir: $RUNS
  runs_retention_days: banana
YAML
  d="$(_mk_run repoA slugX 20260101T010101-111)"; _backdate "$d" 100
  run bash "$SCRIPT" --sweep
  [ "$status" -ne 0 ]
  [ -d "$d" ]   # nothing deleted before the validation failure
}

@test "--dry-run and EXECUTOR_DRYRUN delete nothing but report candidates" {
  _write_config 7
  old="$(_mk_run repoA slugX 20260101T010101-111)"; _backdate "$old" 10
  run bash "$SCRIPT" --sweep --dry-run
  [ "$status" -eq 0 ]
  [ -d "$old" ]                               # not deleted
  [[ "$output" == *"would prune 1"* ]]
  run env EXECUTOR_DRYRUN=1 bash "$SCRIPT" --repo repoA --plan slugX
  [ "$status" -eq 0 ]
  [ -d "$old" ]                               # env-var dry-run also deletes nothing
}
