#!/usr/bin/env bats
# executor_lock_acquire / executor_lock_release / executor_active_for_repo —
# atomic per-repo executor lock (filesystem only; no PyYAML).

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  source "$DIR/../skills/crosscut/scripts/lib/config.sh"
  TMP="$(mktemp -d)"
  export CROSSCUT_CONFIG="$TMP/config.yaml"
  cat > "$CROSSCUT_CONFIG" <<EOF
version: 1
executor_options:
  runs_dir: $TMP/runs
EOF
  LOCK="$TMP/runs/backend/executor.lock"
}

teardown() { rm -rf "$TMP"; }

# Seed a held lock owned by <pid> with <token>, bypassing acquire.
seed_lock() {
  local repo="$1" pid="$2" token="$3"
  mkdir -p "$TMP/runs/$repo/executor.lock"
  printf '%s %s\n' "$pid" "$token" > "$TMP/runs/$repo/executor.lock/owner"
}

@test "acquire on a free repo: exit 0, lock dir exists, token printed" {
  run executor_lock_acquire backend
  [ "$status" -eq 0 ]
  [ -n "$output" ]                 # a token was printed
  [ -d "$LOCK" ]
  [ -f "$LOCK/owner" ]
  # owner records this shell's pid + the printed token
  run cat "$LOCK/owner"
  [[ "$output" == "$$ "* ]]
}

@test "acquire honours a caller-supplied token" {
  run executor_lock_acquire backend my-token-123
  [ "$status" -eq 0 ]
  [ "$output" = "my-token-123" ]
  run cat "$LOCK/owner"
  [ "$output" = "$$ my-token-123" ]
}

@test "second acquire while held by a LIVE pid is busy (non-zero)" {
  # $$ is the (alive) bats process.
  seed_lock backend "$$" live-token
  run executor_lock_acquire backend
  [ "$status" -ne 0 ]
  # the live owner's lock is untouched
  run cat "$LOCK/owner"
  [ "$output" = "$$ live-token" ]
}

@test "active_for_repo reports busy for a LIVE owner; --print echoes owner" {
  seed_lock backend "$$" live-token
  run executor_active_for_repo backend
  [ "$status" -eq 0 ]
  run executor_active_for_repo --print backend
  [ "$status" -eq 0 ]
  [ "$output" = "$$ live-token" ]
}

@test "DEAD-pid lock: active_for_repo reports free and reclaims it" {
  seed_lock backend 999999 dead-token
  [ -d "$LOCK" ]
  run executor_active_for_repo backend
  [ "$status" -ne 0 ]           # free
  [ ! -d "$LOCK" ]              # stale lock reclaimed
}

@test "DEAD-pid lock: acquire reclaims and succeeds" {
  seed_lock backend 999999 dead-token
  run executor_lock_acquire backend fresh-token
  [ "$status" -eq 0 ]
  [ "$output" = "fresh-token" ]
  run cat "$LOCK/owner"
  [ "$output" = "$$ fresh-token" ]
}

@test "release with the matching token frees the repo" {
  tok="$(executor_lock_acquire backend)"
  [ -d "$LOCK" ]
  run executor_lock_release backend "$tok"
  [ "$status" -eq 0 ]
  [ ! -d "$LOCK" ]
  run executor_active_for_repo backend
  [ "$status" -ne 0 ]           # free
}

@test "release with a NON-matching token leaves the lock intact" {
  # Owner is $$ (alive) so the surviving lock still reads as busy.
  seed_lock backend "$$" real-token
  run executor_lock_release backend wrong-token
  [ "$status" -ne 0 ]           # refused
  [ -d "$LOCK" ]
  run cat "$LOCK/owner"
  [ "$output" = "$$ real-token" ]
  run executor_active_for_repo backend
  [ "$status" -eq 0 ]           # still busy
}

@test "release on a repo with no lock is idempotent (exit 0)" {
  run executor_lock_release backend any-token
  [ "$status" -eq 0 ]
}

@test "a lock under a DIFFERENT repo does not make this repo busy" {
  seed_lock web "$$" web-token
  run executor_active_for_repo backend
  [ "$status" -ne 0 ]           # backend is free
  # and backend can be acquired while web is held
  run executor_lock_acquire backend
  [ "$status" -eq 0 ]
  # web's lock is untouched
  run executor_active_for_repo web
  [ "$status" -eq 0 ]
}

@test "default runs_dir (~ expanded) is used when config omits runs_dir" {
  # No executor_options at all → default ~/.cache/crosscut-runs, HOME-expanded.
  home="$(mktemp -d)"
  cat > "$CROSSCUT_CONFIG" <<EOF
version: 1
EOF
  run env HOME="$home" bash -c '
    source "'"$DIR"'/../skills/crosscut/scripts/lib/config.sh"
    executor_lock_acquire backend tok
  '
  [ "$status" -eq 0 ]
  [ -d "$home/.cache/crosscut-runs/backend/executor.lock" ]
  rm -rf "$home"
}

# ---- P4 concurrency / ownership safety ------------------------------------------

@test "concurrent acquire on a free repo: exactly one winner, rest busy" {
  # N racers mkdir-contend for the same free lock. mkdir(2) is atomic, so exactly one
  # creates the dir; the losers see either the winner's live owner (this bats pid,
  # which is alive throughout) or an in-flight (owner-not-yet-published) lock — both
  # BUSY, never a reclaim. Success is defined as acquire returning 0 (token printed).
  local n=20 i
  mkdir -p "$TMP/res"
  for i in $(seq 1 "$n"); do
    (
      if tok="$(executor_lock_acquire backend 2>/dev/null)"; then
        printf '%s' "$tok" > "$TMP/res/$i"   # non-empty file = winner
      else
        : > "$TMP/res/$i"                     # empty file = busy
      fi
    ) &
  done
  wait

  local wins=0 f
  for f in "$TMP"/res/*; do [ -s "$f" ] && wins=$((wins+1)); done
  [ "$wins" -eq 1 ]
  # Exactly one live lock remains.
  [ -d "$LOCK" ]
  [ -f "$LOCK/owner" ]
}

@test "in-flight lock (missing owner) is BUSY and is not stolen" {
  # A lock dir with NO owner file models the window after mkdir, before owner is
  # published. It must read BUSY and must NOT be reclaimed.
  mkdir -p "$LOCK"
  [ ! -f "$LOCK/owner" ]

  run executor_active_for_repo backend
  [ "$status" -eq 0 ]              # busy (in-flight)
  [ -d "$LOCK" ]                   # not reclaimed
  [ ! -f "$LOCK/owner" ]

  run executor_lock_acquire backend
  [ "$status" -ne 0 ]             # acquire refuses — did not steal the in-flight lock
  [ -d "$LOCK" ]
  [ ! -f "$LOCK/owner" ]           # still no owner: acquire never wrote one
}

@test "in-flight lock (empty owner) is BUSY and is not stolen" {
  mkdir -p "$LOCK"
  : > "$LOCK/owner"                # owner present but empty

  run executor_active_for_repo backend
  [ "$status" -eq 0 ]              # busy (in-flight)
  [ -d "$LOCK" ]                   # not reclaimed

  run executor_lock_acquire backend
  [ "$status" -ne 0 ]             # acquire refuses
  [ -d "$LOCK" ]
}

@test "ownership-safe stale reclaim: two concurrent acquirers, only one holds" {
  # Seed a stale lock (present owner, DEAD pid). Two racers reclaim it. Capture-by-
  # rename + post-capture re-validation guarantee a slow racer never deletes the
  # winner's freshly-acquired live lock: exactly one ends up holding.
  seed_lock backend 999999 dead-token
  mkdir -p "$TMP/res"
  local i
  for i in 1 2; do
    (
      if tok="$(executor_lock_acquire backend 2>/dev/null)"; then
        printf '%s' "$tok" > "$TMP/res/$i"
      else
        : > "$TMP/res/$i"
      fi
    ) &
  done
  wait

  local wins=0 f
  for f in "$TMP"/res/*; do [ -s "$f" ] && wins=$((wins+1)); done
  [ "$wins" -eq 1 ]

  # A single live lock survives and it is NOT the dead seed.
  [ -d "$LOCK" ]
  run cat "$LOCK/owner"
  [[ "$output" != "999999 "* ]]
  [[ "$output" == "$$ "* ]]        # owned by the (alive) bats process = the winner
}
