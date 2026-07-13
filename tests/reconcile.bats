#!/usr/bin/env bats
#
# reconcile.sh — activation-settle: status resolution, ROADMAP write, JSON, retention.

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$DIR/../skills/crosscut/scripts/reconcile.sh"
  TMP="$(mktemp -d)"
  REPO="$TMP/backend"
  RUNS="$TMP/runs"
  mkdir -p "$REPO/docs/plans/completed" "$REPO/docs/plans/rejected" "$RUNS"
  export CROSSCUT_CONFIG="$TMP/crosscut.config.yaml"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@t
  git -C "$REPO" config user.name t
  echo base > "$REPO/f"; git -C "$REPO" add -A; git -C "$REPO" commit -qm base
  BASE="$(git -C "$REPO" rev-parse HEAD)"
  _write_config
}

teardown() { rm -rf "$TMP"; }

_write_config() {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - name: backend
    path: $REPO
    kind: python
    plans_dir: docs/plans
executor_options:
  runs_dir: $RUNS
  runs_retention_days: 0
YAML
}

# _roadmap <row-line...> — write a ROADMAP with the given table rows (each a full '| ... |').
_roadmap() {
  {
    echo "# ROADMAP — plan index"
    echo
    echo "## Product: backend (repos: backend)"
    echo
    echo "| slug | repo | status | depends_on | feature_id |"
    echo "|------|------|--------|------------|------------|"
    for r in "$@"; do echo "$r"; done
  } > "$TMP/ROADMAP.md"
}

# _completed_run <slug> <run_id> <head> — write a completed run.json (head advanced).
_completed_run() {
  local d="$RUNS/backend/$1/$2"; mkdir -p "$d"
  cat > "$d/run.json" <<EOF
{"run_id":"$2","repo":"backend","plan":"docs/plans/$1.md","branch":"$1","base_sha":"$BASE","head_sha":"$3","status":"completed","started_at":"2026-01-01T01:01:01Z"}
EOF
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

# status of a slug in the rewritten ROADMAP (3rd table cell).
_status_of() {
  awk -F'|' -v s="$1" '$2 ~ "^ *"s" *$" {gsub(/ /,"",$4); print $4}' "$TMP/ROADMAP.md"
}

@test "no-ff merge: completed head reachable -> done, ROADMAP rewritten, runs pruned" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"
  git -C "$REPO" branch -D slug1 >/dev/null      # Phase 6 deletes the branch
  _completed_run slug1 20260101T010101-111 "$head"
  _roadmap "| slug1 | backend | review_pending | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "done" ]
  [[ "$output" == *'"to": "done"'* ]]
  [ ! -d "$RUNS/backend/slug1/20260101T010101-111" ]   # done -> run records event-pruned
}

@test "fast-forward merge (no merge commit): head reachable -> done" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --ff-only -q slug1        # fast-forward: no merge commit
  git -C "$REPO" branch -D slug1 >/dev/null
  _completed_run slug1 20260101T010101-111 "$head"
  _roadmap "| slug1 | backend | review_pending | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "done" ]
}

@test "completed run, branch unmerged, plan in completed/ -> review_pending (not done)" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main                # NOT merged
  _completed_run slug1 20260101T010101-111 "$head"
  touch "$REPO/docs/plans/completed/slug1.md"
  _roadmap "| slug1 | backend | running | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "review_pending" ]
}

@test "failed no-op run (head==base) never reads as merged" {
  local d="$RUNS/backend/slug1/20260101T010101-111"; mkdir -p "$d"
  cat > "$d/run.json" <<EOF
{"run_id":"20260101T010101-111","repo":"backend","plan":"docs/plans/slug1.md","branch":"slug1","base_sha":"$BASE","head_sha":"$BASE","status":"failed","started_at":"2026-01-01T01:01:01Z"}
EOF
  _roadmap "| slug1 | backend | running | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" != "done" ]            # base is trivially reachable, but not completed
  [ "$(_status_of slug1)" = "failed" ]           # running + terminal failed -> failed
}

@test "multi-run: newer live rerun wins over older completed terminal" {
  # older: completed, unmerged head
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  _completed_run slug1 20260101T010101-111 "$head"
  # newer: live running.json (this shell's PID is alive), no run.json
  local nd="$RUNS/backend/slug1/20260102T020202-$$"; mkdir -p "$nd"
  echo '{"started_at":"2026-01-02T02:02:02Z"}' > "$nd/running.json"
  _roadmap "| slug1 | backend | running | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "running" ]          # newer live run decides
}

@test "accepted + branch present -> resume Phase 6, stays accepted" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  git -C "$REPO" checkout -q main                # branch exists, unmerged
  _roadmap "| slug1 | backend | accepted | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "accepted" ]         # reconcile never finalizes
  [[ "$output" == *'"resume_phase6": true'* ]]
}

@test "running with dead pid and no terminal run.json -> stalled (repair-gate)" {
  local dead; dead="$(sh -c 'echo $$')"          # a pid that has already exited
  local d="$RUNS/backend/slug1/20260101T010101-$dead"; mkdir -p "$d"
  echo '{"started_at":"2026-01-01T01:01:01Z"}' > "$d/running.json"
  _roadmap "| slug1 | backend | running | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "stalled" ]
}

@test "ready = todo whose depends_on all resolve to done" {
  _roadmap \
    "| base1 | backend | done | - | - |" \
    "| next1 | backend | todo | base1 | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"slug": "next1"'* ]]
  # next1 must appear in the ready set
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert any(r["slug"]=="next1" for r in d["ready"]), d["ready"]'
}

@test "--dry-run writes nothing and prunes nothing" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"
  git -C "$REPO" branch -D slug1 >/dev/null
  _completed_run slug1 20260101T010101-111 "$head"
  _roadmap "| slug1 | backend | review_pending | - | - |"
  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "review_pending" ]         # ROADMAP untouched
  [ -d "$RUNS/backend/slug1/20260101T010101-111" ]     # runs untouched
  [[ "$output" == *'"dry_run": true'* ]]
  [[ "$output" == *'"to": "done"'* ]]                  # but the intended change is reported
}

@test "plan in rejected/ -> rejected" {
  touch "$REPO/docs/plans/rejected/slug1.md"
  _roadmap "| slug1 | backend | validated | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "rejected" ]
}

@test "unchanged rows keep their exact bytes (only the changed status cell is rewritten)" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"
  git -C "$REPO" branch -D slug1 >/dev/null
  _completed_run slug1 20260101T010101-111 "$head"
  # slug2 is untouched and written with deliberately odd spacing
  _roadmap \
    "| slug1 | backend | review_pending | - | - |" \
    "|slug2|backend|todo|-|-|"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "done" ]
  grep -qxF "|slug2|backend|todo|-|-|" "$TMP/ROADMAP.md"   # odd-spaced row byte-preserved
}

@test "stale todo row with a live run settles to running (run truth outranks ROADMAP)" {
  local nd="$RUNS/backend/slug1/20260101T010101-$$"; mkdir -p "$nd"
  echo '{"started_at":"2026-01-01T01:01:01Z"}' > "$nd/running.json"
  _roadmap "| slug1 | backend | todo | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "running" ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not any(r["slug"]=="slug1" for r in d["ready"]), d["ready"]'
}

@test "stale validated row with a newest failed run settles to failed" {
  local d="$RUNS/backend/slug1/20260101T010101-111"; mkdir -p "$d"
  echo '{"status":"failed","started_at":"2026-01-01T01:01:01Z"}' > "$d/run.json"
  _roadmap "| slug1 | backend | validated | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "failed" ]
}

@test "newest completed run without head_sha does not fall back to an older merged head" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"   # older head IS merged
  git -C "$REPO" branch -D slug1 >/dev/null
  _completed_run slug1 20260101T010101-111 "$head"          # older completed WITH merged head
  local nd="$RUNS/backend/slug1/20260102T020202-222"; mkdir -p "$nd"   # newer completed, NO head
  echo '{"status":"completed","started_at":"2026-01-02T02:02:02Z"}' > "$nd/run.json"
  _roadmap "| slug1 | backend | review_pending | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" != "done" ]     # newest completed lacks a head -> merge not inferred
}

@test "dependency readiness is product-scoped (a done slug in another product doesn't satisfy)" {
  local REPO2="$TMP/frontend"; mkdir -p "$REPO2/docs/plans"
  git -C "$REPO2" init -q -b main; git -C "$REPO2" config user.email t@t; git -C "$REPO2" config user.name t
  echo base > "$REPO2/f"; git -C "$REPO2" add -A; git -C "$REPO2" commit -qm base
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - name: backend
    path: $REPO
    kind: python
    plans_dir: docs/plans
  - name: frontend
    path: $REPO2
    kind: nodejs
    plans_dir: docs/plans
executor_options:
  runs_dir: $RUNS
  runs_retention_days: 0
YAML
  {
    echo "# ROADMAP"; echo
    echo "## Product: backend (repos: backend)"; echo
    echo "| slug | repo | status | depends_on | feature_id |"
    echo "|------|------|--------|------------|------------|"
    echo "| shared | backend | done | - | - |"; echo
    echo "## Product: frontend (repos: frontend)"; echo
    echo "| slug | repo | status | depends_on | feature_id |"
    echo "|------|------|--------|------------|------------|"
    echo "| fe-next | frontend | todo | shared | - |"
  } > "$TMP/ROADMAP.md"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not any(r["slug"]=="fe-next" for r in d["ready"]), d["ready"]'
}

@test "accepted with a dirty integration tree reports resume_phase6 false" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  git -C "$REPO" checkout -q main
  echo dirty > "$REPO/uncommitted"          # dirty the integration tree
  _roadmap "| slug1 | backend | accepted | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "accepted" ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); p=[x for x in d["plans"] if x["slug"]=="slug1"][0]; assert p["resume_phase6"] is False, p'
}

@test "accepted plan in a non-git repo path warns and stays accepted (no false branch-deleted)" {
  local NOGIT="$TMP/nogit"; mkdir -p "$NOGIT/docs/plans"
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - name: backend
    path: $NOGIT
    kind: other
    plans_dir: docs/plans
executor_options:
  runs_dir: $RUNS
  runs_retention_days: 0
YAML
  _roadmap "| slug1 | backend | accepted | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "accepted" ]
  [[ "$output" == *"unavailable"* ]]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); p=[x for x in d["plans"] if x["slug"]=="slug1"][0]; assert p["resume_phase6"] is False, p'
}

@test "a changed row preserves its non-status bytes (only the status token swaps)" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"
  git -C "$REPO" branch -D slug1 >/dev/null
  _completed_run slug1 20260101T010101-111 "$head"
  _roadmap "|  slug1  | backend |  review_pending  | dep-a, dep-b | feat-9 |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "|  slug1  | backend |  done  | dep-a, dep-b | feat-9 |" "$TMP/ROADMAP.md"
}

@test "status cell is header-driven: reordered columns still rewrite the right cell" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"
  git -C "$REPO" branch -D slug1 >/dev/null
  _completed_run slug1 20260101T010101-111 "$head"
  {
    echo "# ROADMAP"; echo
    echo "## Product: backend (repos: backend)"; echo
    echo "| status | slug | repo | depends_on | feature_id |"   # status is column 0
    echo "|--------|------|------|------------|------------|"
    echo "| review_pending | slug1 | backend | - | - |"
  } > "$TMP/ROADMAP.md"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "| done | slug1 | backend | - | - |" "$TMP/ROADMAP.md"   # col 0 rewritten, not col 2
}

@test "--dry-run does not reclaim a stale executor lock (writes nothing)" {
  local dead; dead="$(sh -c 'echo $$')"          # a pid that has already exited
  local lock="$RUNS/backend/executor.lock"; mkdir -p "$lock"
  echo "$dead sometoken" > "$lock/owner"
  _roadmap "| slug1 | backend | todo | - | - |"
  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [ -d "$lock" ]                                  # stale lock left intact under --dry-run
}

@test "a live settle reclaims a stale executor lock" {
  local dead; dead="$(sh -c 'echo $$')"
  local lock="$RUNS/backend/executor.lock"; mkdir -p "$lock"
  echo "$dead sometoken" > "$lock/owner"
  _roadmap "| slug1 | backend | todo | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -d "$lock" ]                                # dead-owner lock reclaimed on a live settle
}

@test "--dry-run does not rewrite the git index even when status would refresh it" {
  git -C "$REPO" branch slug1                     # branch present so git_clean() runs
  _roadmap "| slug1 | backend | accepted | - | - |"
  touch "$REPO/f"                                 # bump a tracked file's mtime: a plain
                                                  # `git status` would refresh/rewrite .git/index
  local before after
  before="$(md5 -q "$REPO/.git/index" 2>/dev/null || md5sum "$REPO/.git/index" | cut -d' ' -f1)"
  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  after="$(md5 -q "$REPO/.git/index" 2>/dev/null || md5sum "$REPO/.git/index" | cut -d' ' -f1)"
  [ "$before" = "$after" ]                        # --no-optional-locks -> index untouched
}

@test "a live rerun of an already-merged plan stays running (not done); live run kept" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"   # older run IS merged
  git -C "$REPO" branch -D slug1 >/dev/null
  _completed_run slug1 20260101T010101-111 "$head"
  local nd="$RUNS/backend/slug1/20260102T020202-$$"; mkdir -p "$nd"   # newer LIVE run
  echo '{"started_at":"2026-01-02T02:02:02Z"}' > "$nd/running.json"
  _roadmap "| slug1 | backend | review_pending | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "running" ]   # live rerun outranks the older merged head
  [ -d "$nd" ]                            # live run dir NOT pruned out from under the executor
}

@test "a merged head does not clear a human 'blocked' status" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"
  git -C "$REPO" branch -D slug1 >/dev/null
  _completed_run slug1 20260101T010101-111 "$head"
  _roadmap "| slug1 | backend | blocked | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "blocked" ]   # human escalation preserved, not auto-done
}

@test "a running row with no run records at all settles to stalled (repair-gate)" {
  _roadmap "| slug1 | backend | running | - | - |"   # no run dir
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "stalled" ]
}

@test "completed/ + branch present + unmerged + NO run records -> review_pending (P5)" {
  git -C "$REPO" branch slug1                          # branch present, unmerged
  touch "$REPO/docs/plans/completed/slug1.md"
  _roadmap "| slug1 | backend | validated | - | - |"   # no run dir -> exercises P5, not P4
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "review_pending" ]
}

@test "a repo with an empty path does not flip status from reconcile's own CWD" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - name: backend
    kind: python
    plans_dir: docs/plans
executor_options:
  runs_dir: $RUNS
  runs_retention_days: 0
YAML
  local decoy="$TMP/decoy"; mkdir -p "$decoy/docs/plans/rejected"
  touch "$decoy/docs/plans/rejected/slug1.md"           # a matching file in the CWD
  _roadmap "| slug1 | backend | validated | - | - |"
  run bash -c "cd '$decoy' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "validated" ]               # NOT flipped to rejected by the decoy
}

@test "a ROADMAP write failure warns, exits 0, and does NOT prune (signal kept)" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"
  git -C "$REPO" branch -D slug1 >/dev/null
  _completed_run slug1 20260101T010101-111 "$head"
  _roadmap "| slug1 | backend | review_pending | - | - |"
  chmod a-w "$TMP"                                       # workspace read-only -> temp create fails
  run bash "$SCRIPT"
  chmod u+w "$TMP"                                       # restore for teardown
  [ "$status" -eq 0 ]                                    # clean exit, not a traceback/exit 1
  [[ "$output" == *"could not write ROADMAP"* ]]
  [ -d "$RUNS/backend/slug1/20260101T010101-111" ]       # write failed -> runs NOT pruned
}

@test "ROADMAP rewrite preserves the original file mode" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"
  git -C "$REPO" branch -D slug1 >/dev/null
  _completed_run slug1 20260101T010101-111 "$head"
  _roadmap "| slug1 | backend | review_pending | - | - |"
  chmod 0664 "$TMP/ROADMAP.md"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "done" ]
  local mode; mode="$(stat -f '%Lp' "$TMP/ROADMAP.md" 2>/dev/null || stat -c '%a' "$TMP/ROADMAP.md")"
  [ "$mode" = "664" ]
}

@test "a CRLF ROADMAP keeps its CRLF line endings on rewrite" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"
  git -C "$REPO" branch -D slug1 >/dev/null
  _completed_run slug1 20260101T010101-111 "$head"
  _roadmap "| slug1 | backend | review_pending | - | - |"
  python3 -c 'p="'"$TMP"'/ROADMAP.md"; d=open(p,"rb").read().replace(b"\n",b"\r\n"); open(p,"wb").write(d)'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "done" ]
  python3 -c 'd=open("'"$TMP"'/ROADMAP.md","rb").read(); assert b"\r\n" in d and d.count(b"\n")==d.count(b"\r\n"), "CRLF not preserved"'
}

@test "a live run does not resurrect a human-rejected plan" {
  local nd="$RUNS/backend/slug1/20260101T010101-$$"; mkdir -p "$nd"
  echo '{}' > "$nd/running.json"                        # bare running.json, pid alive ($$)
  touch "$REPO/docs/plans/rejected/slug1.md"
  _roadmap "| slug1 | backend | rejected | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "rejected" ]               # P0a keeps it; not flipped to running
}

@test "a stale rejected/ file does not downgrade a done plan" {
  touch "$REPO/docs/plans/rejected/slug1.md"
  _roadmap "| slug1 | backend | done | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "done" ]                   # P3 guarded on cur != done
}

@test "a run-id with pid 0 is not treated as live (running -> stalled)" {
  local nd="$RUNS/backend/slug1/20260101T010101-0"; mkdir -p "$nd"
  echo '{}' > "$nd/running.json"
  _roadmap "| slug1 | backend | running | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "stalled" ]                # os.kill(0,0) must not read as alive
}

@test "an oversized pid in a run-id does not crash the pass" {
  local nd="$RUNS/backend/slug1/20260101T010101-99999999999999999999"; mkdir -p "$nd"
  echo '{}' > "$nd/running.json"
  _roadmap "| slug1 | backend | running | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]                                   # OverflowError caught, no traceback
  [ "$(_status_of slug1)" = "stalled" ]
}

@test "done with an OLDER live run keeps that live dir (reconcile->prune is_live guard)" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"
  git -C "$REPO" branch -D slug1 >/dev/null
  local old="$RUNS/backend/slug1/20260101T010101-$$"; mkdir -p "$old"   # OLDER, live
  echo '{}' > "$old/running.json"
  _completed_run slug1 20260102T020202-222 "$head"                       # NEWER, completed+merged
  _roadmap "| slug1 | backend | review_pending | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "done" ]                    # newest (completed, merged) decides
  [ -d "$old" ]                                          # older LIVE run preserved by is_live guard
  [ ! -d "$RUNS/backend/slug1/20260102T020202-222" ]     # completed run pruned
}

@test "a corrupt run.json (non-string head_sha) does not crash and is not read as merged" {
  local d="$RUNS/backend/slug1/20260101T010101-111"; mkdir -p "$d"
  echo '{"status":"completed","head_sha":12345}' > "$d/run.json"   # head_sha is a number
  _roadmap "| slug1 | backend | review_pending | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]                                # no traceback
  [ "$(_status_of slug1)" != "done" ]               # non-str head_sha ignored -> not merged
}

@test "a non-string repo path in config does not crash reconcile" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - name: backend
    path: 12345
    kind: python
    plans_dir: docs/plans
executor_options:
  runs_dir: $RUNS
  runs_retention_days: 0
YAML
  _roadmap "| slug1 | backend | todo | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]                                # coerced to "" -> unavailable, no TypeError
  [[ "$output" == *"unavailable"* ]]
}

@test "accepted + merged + a live newest run is not marked done (defers to Phase 2)" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"    # completed run's head IS merged
  _completed_run slug1 20260101T010101-111 "$head"
  local nd="$RUNS/backend/slug1/20260102T020202-$$"; mkdir -p "$nd"   # newer LIVE run
  echo '{}' > "$nd/running.json"
  _roadmap "| slug1 | backend | accepted | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" = "accepted" ]            # P1 skipped (live_now) -> not done
}

@test "a present-but-unparseable running.json newest run is still live (no false done)" {
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff -q slug1 -m "merge slug1"
  git -C "$REPO" branch -D slug1 >/dev/null
  _completed_run slug1 20260101T010101-111 "$head"                     # older completed+merged
  local nd="$RUNS/backend/slug1/20260102T020202-$$"; mkdir -p "$nd"    # newer, CORRUPT running.json
  printf '{not valid json' > "$nd/running.json"
  _roadmap "| slug1 | backend | review_pending | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(_status_of slug1)" != "done" ]     # existence-based liveness -> live -> running, not done
  [ -d "$nd" ]                            # live dir preserved
}

@test "a non-list repos: value does not crash reconcile" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos: 5
executor_options:
  runs_dir: $RUNS
  runs_retention_days: 0
YAML
  _roadmap "| slug1 | backend | todo | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]                      # non-list repos is inert, not a traceback
}

@test "retention>0 sweeps old runs but preserves a non-done plan's newest completed run" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - name: backend
    path: $REPO
    kind: python
    plans_dir: docs/plans
executor_options:
  runs_dir: $RUNS
  runs_retention_days: 7
YAML
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main                      # slug1 unmerged -> review_pending (non-done)
  _completed_run slug1 20260101T010101-111 "$head"     # newest completed = the head_sha signal
  local drop="$RUNS/backend/slug1/20260101T000000-100"; mkdir -p "$drop"
  echo '{"status":"failed","started_at":"2026-01-01T00:00:00Z"}' > "$drop/run.json"
  _backdate "$RUNS/backend/slug1/20260101T010101-111" 30   # both older than retention
  _backdate "$drop" 30
  _roadmap "| slug1 | backend | review_pending | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$RUNS/backend/slug1/20260101T010101-111" ]     # newest completed preserved (the signal)
  [ ! -d "$drop" ]                                      # old non-newest run swept
  [[ "$output" == *'"mode": "sweep"'* ]]
}

@test "retention>0 ages out a done plan's OLD run via sweep, not event-prune (young run kept)" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - {name: backend, path: $REPO, kind: python, plans_dir: docs/plans}
executor_options: {runs_dir: $RUNS, runs_retention_days: 7}
YAML
  # a done plan with an OLD run AND a YOUNG run. Under retention>0 the sweep ages out the OLD
  # one but keeps the YOUNG one; an immediate event-prune (the retention==0 path) would delete
  # BOTH — so the young run surviving proves the sweep ran, not event-prune.
  local old="$RUNS/backend/slug1/20260101T010101-111"; mkdir -p "$old"
  echo '{"status":"completed","head_sha":"abc","started_at":"2026-01-01T01:01:01Z"}' > "$old/run.json"; _backdate "$old" 30
  local young="$RUNS/backend/slug1/20260201T020202-222"; mkdir -p "$young"
  echo '{"status":"completed","head_sha":"def","started_at":"2026-02-01T02:02:02Z"}' > "$young/run.json"; _backdate "$young" 1
  _roadmap "| slug1 | backend | done | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -d "$old" ]                                      # old done run aged out by the sweep
  [ -d "$young" ]                                       # young run kept -> proves SWEEP not event-prune
}

@test "retention>0 sweeps an OLDER completed run but keeps the newest completed (non-done)" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - {name: backend, path: $REPO, kind: python, plans_dir: docs/plans}
executor_options: {runs_dir: $RUNS, runs_retention_days: 7}
YAML
  git -C "$REPO" checkout -q -b slug1
  echo w > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm w
  local head; head="$(git -C "$REPO" rev-parse HEAD)"; git -C "$REPO" checkout -q main
  _completed_run slug1 20260201T020202-222 "$head"     # NEWEST completed (the signal)
  local older="$RUNS/backend/slug1/20260101T010101-111"; mkdir -p "$older"
  echo '{"status":"completed","head_sha":"old","started_at":"2026-01-01T01:01:01Z"}' > "$older/run.json"
  _backdate "$RUNS/backend/slug1/20260201T020202-222" 30; _backdate "$older" 30
  _roadmap "| slug1 | backend | review_pending | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$RUNS/backend/slug1/20260201T020202-222" ]     # newest completed preserved
  [ ! -d "$older" ]                                     # older completed swept
}

@test "retention>0 preserves an ORPHAN tree's newest completed run (no ROADMAP row)" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - {name: backend, path: $REPO, kind: python, plans_dir: docs/plans}
executor_options: {runs_dir: $RUNS, runs_retention_days: 7}
YAML
  local oc="$RUNS/backend/slug-orphan/20260101T010101-111"; mkdir -p "$oc"
  echo '{"status":"completed","head_sha":"x","started_at":"2026-01-01T01:01:01Z"}' > "$oc/run.json"; _backdate "$oc" 30
  local of="$RUNS/backend/slug-orphan/20260101T000000-100"; mkdir -p "$of"
  echo '{"status":"failed","started_at":"2026-01-01T00:00:00Z"}' > "$of/run.json"; _backdate "$of" 30
  _roadmap "| slug1 | backend | todo | - | - |"        # slug-orphan is NOT in the ROADMAP
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$oc" ]                                          # orphan's newest completed preserved
  [ ! -d "$of" ]                                        # orphan's older failed swept
}

@test "retention>0 lets a rejected plan's newest completed run age out (not preserved)" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - {name: backend, path: $REPO, kind: python, plans_dir: docs/plans}
executor_options: {runs_dir: $RUNS, runs_retention_days: 7}
YAML
  touch "$REPO/docs/plans/rejected/slug1.md"
  local c="$RUNS/backend/slug1/20260101T010101-111"; mkdir -p "$c"
  echo '{"status":"completed","head_sha":"x","started_at":"2026-01-01T01:01:01Z"}' > "$c/run.json"; _backdate "$c" 30
  _roadmap "| slug1 | backend | rejected | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -d "$c" ]                                         # rejected is SWEEP_TERMINAL -> ages out
}

@test "--dry-run does not run the retention sweep (retention>0)" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - {name: backend, path: $REPO, kind: python, plans_dir: docs/plans}
executor_options: {runs_dir: $RUNS, runs_retention_days: 7}
YAML
  local old="$RUNS/backend/slug1/20260101T000000-100"; mkdir -p "$old"
  echo '{"status":"failed","started_at":"2026-01-01T00:00:00Z"}' > "$old/run.json"; _backdate "$old" 30
  _roadmap "| slug1 | backend | review_pending | - | - |"
  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [ -d "$old" ]                                  # dry-run -> no sweep
}

@test "retention>0 does not sweep when the ROADMAP is missing (no status-blind sweep)" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - {name: backend, path: $REPO, kind: python, plans_dir: docs/plans}
executor_options: {runs_dir: $RUNS, runs_retention_days: 7}
YAML
  rm -f "$TMP/ROADMAP.md"                         # no ROADMAP -> no plan status
  local old="$RUNS/backend/slug1/20260101T010101-111"; mkdir -p "$old"
  echo '{"status":"completed","head_sha":"x","started_at":"2026-01-01T01:01:01Z"}' > "$old/run.json"
  _backdate "$old" 30
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$old" ]                                  # have_roadmap gate -> sweep skipped, nothing lost
}

@test "an invalid runs_retention_days warns and reclaims NOTHING (no event-prune of done)" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - {name: backend, path: $REPO, kind: python, plans_dir: docs/plans}
executor_options: {runs_dir: $RUNS, runs_retention_days: banana}
YAML
  local d="$RUNS/backend/slug1/20260101T010101-111"; mkdir -p "$d"
  echo '{"status":"completed","head_sha":"x","started_at":"2026-01-01T01:01:01Z"}' > "$d/run.json"
  _roadmap "| slug1 | backend | done | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a non-negative integer"* ]]
  [ -d "$d" ]                                          # invalid -> skip; a regressed treat-as-0 would delete this
}

@test "an explicit-null runs_retention_days defaults to 0 (event-prunes a done plan)" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - {name: backend, path: $REPO, kind: python, plans_dir: docs/plans}
executor_options:
  runs_dir: $RUNS
  runs_retention_days:
YAML
  local d="$RUNS/backend/slug1/20260101T010101-111"; mkdir -p "$d"
  echo '{"status":"completed","head_sha":"x","started_at":"2026-01-01T01:01:01Z"}' > "$d/run.json"
  _roadmap "| slug1 | backend | done | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"not a non-negative integer"* ]]    # null == default 0, not "invalid"
  [ ! -d "$d" ]                                         # default 0 -> event-prune the done plan
}

# _sweep_terminal_test <status> <expect: kept|gone> — a plan in <status> with one old completed run.
_retention_status_case() {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - {name: backend, path: $REPO, kind: python, plans_dir: docs/plans}
executor_options: {runs_dir: $RUNS, runs_retention_days: 7}
YAML
  local c="$RUNS/backend/slug1/20260101T010101-111"; mkdir -p "$c"
  echo '{"status":"completed","head_sha":"x","started_at":"2026-01-01T01:01:01Z"}' > "$c/run.json"
  _backdate "$c" 30
  [ "$1" = "rejected" ] && touch "$REPO/docs/plans/rejected/slug1.md"
  _roadmap "| slug1 | backend | $1 | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  if [ "$2" = "kept" ]; then [ -d "$c" ]; else [ ! -d "$c" ]; fi
}

@test "retention>0 skips the sweep (fail closed) when a runs_dir tree can't be enumerated" {
  cat > "$CROSSCUT_CONFIG" <<YAML
version: 1
workspace_root: $TMP
roadmap: ROADMAP.md
repos:
  - {name: backend, path: $REPO, kind: python, plans_dir: docs/plans}
executor_options: {runs_dir: $RUNS, runs_retention_days: 7}
YAML
  local old="$RUNS/backend/slug1/20260101T000000-100"; mkdir -p "$old"
  echo '{"status":"failed","started_at":"2026-01-01T00:00:00Z"}' > "$old/run.json"; _backdate "$old" 30
  local bad="$RUNS/badrepo"; mkdir -p "$bad/slugX"; chmod 000 "$bad"   # unreadable -> listdir raises
  _roadmap "| slug1 | backend | review_pending | - | - |"
  run bash "$SCRIPT"
  chmod 755 "$bad"                                        # restore for teardown
  [ "$status" -eq 0 ]
  [ -d "$old" ]                                           # fail closed -> nothing swept
  [[ "$output" == *"enumeration incomplete"* ]]
}

@test "retention>0: superseded ages out its newest completed run (SWEEP_TERMINAL)" {
  _retention_status_case superseded gone
}

@test "retention>0: accepted preserves its newest completed run (imminent merge signal)" {
  _retention_status_case accepted kept
}

@test "retention>0: blocked preserves its newest completed run (may resume)" {
  _retention_status_case blocked kept
}

@test "no config -> exit 3" {
  export CROSSCUT_CONFIG="$TMP/does-not-exist.yaml"
  HOME="$TMP/empty" run bash "$SCRIPT"
  [ "$status" -eq 3 ]
}

@test "unchanged ROADMAP is not rewritten (roadmap_written false)" {
  _roadmap "| solo1 | backend | todo | - | - |"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"roadmap_written": false'* ]]
}
