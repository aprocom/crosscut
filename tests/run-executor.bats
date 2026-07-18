#!/usr/bin/env bats

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$DIR/../skills/crosscut/scripts/run-executor.sh"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/backend/docs/plans"
  ( cd "$TMP/backend" && git init -q )
  echo "# plan" > "$TMP/backend/docs/plans/x.md"
  # rewrite fixture path to the temp backend, generated entirely inside $TMP
  export CROSSCUT_CONFIG="$TMP/config.yaml"
  sed "s#__BACKEND__#$TMP/backend#" "$DIR/fixtures/exec.config.template.yaml" > "$CROSSCUT_CONFIG"
}

teardown() { rm -rf "$TMP"; }

@test "dryrun prints docker command with resolved image and repo path" {
  run env EXECUTOR_DRYRUN=1 CROSSCUT_UNAME=Linux bash "$SCRIPT" --repo backend --plan docs/plans/x.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker run"* ]]
  [[ "$output" == *"ghcr.io/umputun/ralphex:latest"* ]]
  [[ "$output" == *"$TMP/backend"* ]]
  [[ "$output" == *"--worktree"* ]]
  [[ "$output" == *"--branch x"* ]]
  [[ "$output" == *":/mnt/claude"* ]]
}

@test "dryrun keeps a space-containing repo path as one token" {
  mkdir -p "$TMP/back end/docs/plans"
  ( cd "$TMP/back end" && git init -q )
  echo "# plan" > "$TMP/back end/docs/plans/x.md"
  export CROSSCUT_CONFIG="$TMP/space.yaml"
  sed "s#__BACKEND__#$TMP/back end#" "$DIR/fixtures/exec.config.template.yaml" > "$CROSSCUT_CONFIG"
  run env EXECUTOR_DRYRUN=1 CROSSCUT_UNAME=Linux bash "$SCRIPT" --repo backend --plan docs/plans/x.md
  [ "$status" -eq 0 ]
  [[ "$output" == *'back\ end:/project'* ]]
  [[ "$output" == *"--worktree"* ]]
  [[ "$output" == *":/mnt/claude"* ]]
}

@test "unknown repo errors" {
  run env EXECUTOR_DRYRUN=1 bash "$SCRIPT" --repo nope --plan docs/plans/x.md
  [ "$status" -eq 2 ]
}

@test "unknown executor kind exits non-zero" {
  # Repo/plan resolution is shared and now runs before dispatch, so point at the
  # real temp backend; the rejection must still come from the executor dispatch.
  cat > "$TMP/bogus.yaml" <<EOF
version: 1
repos:
  - name: backend
    path: $TMP/backend
    kind: python
executor: bogus
EOF
  export CROSSCUT_CONFIG="$TMP/bogus.yaml"
  run env EXECUTOR_DRYRUN=1 bash "$SCRIPT" --repo backend --plan docs/plans/x.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"not implemented"* ]]
}

@test "executor claude exits non-zero (dispatched in-session, not here)" {
  cat > "$TMP/claude.yaml" <<EOF
version: 1
repos:
  - name: backend
    path: $TMP/backend
    kind: python
executor: claude
EOF
  export CROSSCUT_CONFIG="$TMP/claude.yaml"
  run env EXECUTOR_DRYRUN=1 bash "$SCRIPT" --repo backend --plan docs/plans/x.md
  [ "$status" -ne 0 ]
}

@test "dryrun (codex) builds a workspace-write codex invocation on the slug worktree" {
  cat > "$TMP/codex.yaml" <<EOF
version: 1
repos:
  - name: backend
    path: $TMP/backend
    kind: python
executor: codex
executor_options:
  runs_dir: $TMP/runs
EOF
  export CROSSCUT_CONFIG="$TMP/codex.yaml"
  run env EXECUTOR_DRYRUN=1 bash "$SCRIPT" --repo backend --plan docs/plans/x.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex exec"* ]]
  [[ "$output" == *"--sandbox workspace-write"* ]]
  [[ "$output" != *"read-only"* ]]
  [[ "$output" == *"--skip-git-repo-check"* ]]
  [[ "$output" == *"/runs/backend/x/worktree"* ]]
  # No side effects in dryrun: the worktree must not exist.
  [ ! -d "$TMP/runs/backend/x/worktree" ]
}

@test "codex adapter (non-dryrun) commits in a worktree, advances the branch, cleans up" {
  # Real target repo with a committed plan.
  mkdir -p "$TMP/cx/docs/plans"
  echo "# plan" > "$TMP/cx/docs/plans/feat.md"
  (
    cd "$TMP/cx" && git init -q \
      && git config user.email t@t && git config user.name t \
      && git add -A && git commit -q -m init
  )
  # Fake `codex` early on PATH: given `-C <dir>`, drop a file into <dir> so the
  # worktree has an uncommitted change.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C) dir="$2"; shift 2;;
    *) shift;;
  esac
done
printf 'change\n' > "$dir/CODEX_CHANGED.txt"
exit 0
SH
  chmod +x "$TMP/bin/codex"

  cat > "$TMP/codex.yaml" <<EOF
version: 1
repos:
  - name: cx
    path: $TMP/cx
    kind: generic
executor: codex
executor_options:
  runs_dir: $TMP/runs
EOF
  export CROSSCUT_CONFIG="$TMP/codex.yaml"

  run env PATH="$TMP/bin:$PATH" bash "$SCRIPT" --repo cx --plan docs/plans/feat.md
  [ "$status" -eq 0 ]

  runjson="$(ls "$TMP"/runs/cx/feat/*/run.json)"
  [ -f "$runjson" ]
  grep -q '"status":"completed"' "$runjson"

  base="$(grep -o '"base_sha":"[0-9a-f]*"' "$runjson")"
  head="$(grep -o '"head_sha":"[0-9a-f]*"' "$runjson")"
  [ -n "$base" ] && [ -n "$head" ]
  [ "$base" != "$head" ]

  # Branch persists in the target repo; worktree is gone.
  ( cd "$TMP/cx" && git rev-parse --verify feat )
  [ ! -d "$TMP/runs/cx/feat/worktree" ]
}

@test "codex rerun no-op → failed (this run added no commits)" {
  # Target repo with a committed plan, then a pre-existing branch <slug> whose tip
  # already differs from integration HEAD (as a prior run would leave it).
  mkdir -p "$TMP/nx/docs/plans"
  echo "# plan" > "$TMP/nx/docs/plans/feat.md"
  (
    cd "$TMP/nx" && git init -q \
      && git config user.email t@t && git config user.name t \
      && git add -A && git commit -q -m init \
      && git branch feat \
      && git worktree add -q "$TMP/nx-seed" feat \
      && cd "$TMP/nx-seed" && echo prior > PRIOR.txt && git add -A && git commit -q -m prior
  )
  ( cd "$TMP/nx" && git worktree remove "$TMP/nx-seed" --force )

  # Fake codex that changes NOTHING in the worktree.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$TMP/bin/codex"

  cat > "$TMP/codex.yaml" <<EOF
version: 1
repos:
  - name: nx
    path: $TMP/nx
    kind: generic
executor: codex
executor_options:
  runs_dir: $TMP/runs
EOF
  export CROSSCUT_CONFIG="$TMP/codex.yaml"

  run env PATH="$TMP/bin:$PATH" bash "$SCRIPT" --repo nx --plan docs/plans/feat.md

  runjson="$(ls "$TMP"/runs/nx/feat/*/run.json)"
  [ -f "$runjson" ]
  grep -q '"status":"failed"' "$runjson"
  ! grep -q '"status":"completed"' "$runjson"
}

@test "codex commit failure → failed and worktree preserved" {
  mkdir -p "$TMP/cf/docs/plans"
  echo "# plan" > "$TMP/cf/docs/plans/feat.md"
  (
    cd "$TMP/cf" && git init -q \
      && git config user.email t@t && git config user.name t \
      && git add -A && git commit -q -m init
  )
  # Install a pre-commit hook that always rejects — AFTER the initial commit so the
  # worktree's auto-commit fails deterministically. Linked worktrees share this hook.
  cat > "$TMP/cf/.git/hooks/pre-commit" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$TMP/cf/.git/hooks/pre-commit"

  # Fake codex writes an (uncommittable) change.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C) dir="$2"; shift 2;;
    *) shift;;
  esac
done
printf 'change\n' > "$dir/CODEX_CHANGED.txt"
exit 0
SH
  chmod +x "$TMP/bin/codex"

  cat > "$TMP/codex.yaml" <<EOF
version: 1
repos:
  - name: cf
    path: $TMP/cf
    kind: generic
executor: codex
executor_options:
  runs_dir: $TMP/runs
EOF
  export CROSSCUT_CONFIG="$TMP/codex.yaml"

  run env PATH="$TMP/bin:$PATH" bash "$SCRIPT" --repo cf --plan docs/plans/feat.md

  runjson="$(ls "$TMP"/runs/cf/feat/*/run.json)"
  [ -f "$runjson" ]
  grep -q '"status":"failed"' "$runjson"
  # The worktree with codex's only copy is preserved, not force-removed.
  [ -d "$TMP/runs/cf/feat/worktree" ]
  [ -f "$TMP/runs/cf/feat/worktree/CODEX_CHANGED.txt" ]
}

@test "codex deterministic pre-codex error → failed not interrupted" {
  mkdir -p "$TMP/de/docs/plans"
  echo "# plan" > "$TMP/de/docs/plans/feat.md"
  (
    cd "$TMP/de" && git init -q \
      && git config user.email t@t && git config user.name t \
      && git add -A && git commit -q -m init
  )
  # Pre-create the worktree destination as a non-empty dir so `git worktree add`
  # fails deterministically before codex ever runs.
  mkdir -p "$TMP/runs/de/feat/worktree"
  touch "$TMP/runs/de/feat/worktree/blocker"

  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$TMP/bin/codex"

  cat > "$TMP/codex.yaml" <<EOF
version: 1
repos:
  - name: de
    path: $TMP/de
    kind: generic
executor: codex
executor_options:
  runs_dir: $TMP/runs
EOF
  export CROSSCUT_CONFIG="$TMP/codex.yaml"

  run env PATH="$TMP/bin:$PATH" bash "$SCRIPT" --repo de --plan docs/plans/feat.md

  runjson="$(ls "$TMP"/runs/de/feat/*/run.json)"
  [ -f "$runjson" ]
  grep -q '"status":"failed"' "$runjson"
  ! grep -q '"status":"interrupted"' "$runjson"
}

# ---- P4: per-repo serialization -------------------------------------------------

# Build a codex-executor repo <name> under $TMP with a committed plan and (optionally)
# a fake `codex` on PATH that writes a distinct file into the -C worktree.
_mk_codex_repo() {
  local name="$1"
  mkdir -p "$TMP/$name/docs/plans"
  echo "# plan" > "$TMP/$name/docs/plans/feat.md"
  (
    cd "$TMP/$name" && git init -q \
      && git config user.email t@t && git config user.name t \
      && git add -A && git commit -q -m init
  )
  cat > "$TMP/$name.yaml" <<EOF
version: 1
repos:
  - name: $name
    path: $TMP/$name
    kind: generic
executor: codex
executor_options:
  runs_dir: $TMP/runs
EOF
}

_mk_fake_codex() {
  # $1 = unique marker filename dropped into the worktree so a commit is created.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/codex" <<SH
#!/usr/bin/env bash
dir=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -C) dir="\$2"; shift 2;;
    *) shift;;
  esac
done
printf 'change\n' > "\$dir/$1"
exit 0
SH
  chmod +x "$TMP/bin/codex"
}

@test "held repo lock blocks a new executor (message, non-zero, no run.json)" {
  _mk_codex_repo lk
  _mk_fake_codex LK_CHANGED.txt
  export CROSSCUT_CONFIG="$TMP/lk.yaml"

  # Hold the lock in the live test process (owner PID = this shell, which is alive).
  source "$DIR/../skills/crosscut/scripts/lib/config.sh"
  tok="$(executor_lock_acquire lk)"
  [ -n "$tok" ]

  run env PATH="$TMP/bin:$PATH" bash "$SCRIPT" --repo lk --plan docs/plans/feat.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo 'lk' already has an active executor; skipping"* ]]
  # No run started: the slug run dir was never created.
  [ ! -d "$TMP/runs/lk/feat" ]

  executor_lock_release lk "$tok"
}

@test "different repos do not block each other (holding one lock lets another run)" {
  _mk_codex_repo ra
  _mk_codex_repo rb
  _mk_fake_codex RB_CHANGED.txt
  export CROSSCUT_CONFIG="$TMP/rb.yaml"

  # Hold ra's lock in the live test process; rb must still run to completion.
  # Both configs share runs_dir=$TMP/runs, so ra's lock path is the same regardless
  # of which config is loaded — acquire it while rb.yaml is the active config.
  source "$DIR/../skills/crosscut/scripts/lib/config.sh"
  tok="$(executor_lock_acquire ra)"
  [ -n "$tok" ]
  [ -d "$TMP/runs/ra/executor.lock" ]

  run env PATH="$TMP/bin:$PATH" bash "$SCRIPT" --repo rb --plan docs/plans/feat.md
  [ "$status" -eq 0 ]
  runjson="$(ls "$TMP"/runs/rb/feat/*/run.json)"
  grep -q '"status":"completed"' "$runjson"

  executor_lock_release ra "$tok"
}

@test "lock is released after a normal run completes" {
  _mk_codex_repo rc
  _mk_fake_codex RC_CHANGED.txt
  export CROSSCUT_CONFIG="$TMP/rc.yaml"

  run env PATH="$TMP/bin:$PATH" bash "$SCRIPT" --repo rc --plan docs/plans/feat.md
  [ "$status" -eq 0 ]
  runjson="$(ls "$TMP"/runs/rc/feat/*/run.json)"
  grep -q '"status":"completed"' "$runjson"

  # Release removes the lock directory; the repo is free afterward.
  [ ! -d "$TMP/runs/rc/executor.lock" ]
  source "$DIR/../skills/crosscut/scripts/lib/config.sh"
  ! executor_active_for_repo rc
}

@test "EXECUTOR_DRYRUN acquires no lock (repo stays free)" {
  _mk_codex_repo rd
  export CROSSCUT_CONFIG="$TMP/rd.yaml"

  run env EXECUTOR_DRYRUN=1 bash "$SCRIPT" --repo rd --plan docs/plans/feat.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex exec"* ]]
  # Dryrun took no lock: the lock directory was never created.
  [ ! -d "$TMP/runs/rd/executor.lock" ]
  source "$DIR/../skills/crosscut/scripts/lib/config.sh"
  ! executor_active_for_repo rd
}

@test "executor block absent → defaults to ralphex" {
  cat > "$TMP/no-executor-block.yaml" <<EOF
version: 1
repos:
  - name: backend
    path: $TMP/backend
    kind: python
EOF
  export CROSSCUT_CONFIG="$TMP/no-executor-block.yaml"
  run env EXECUTOR_DRYRUN=1 CROSSCUT_UNAME=Linux bash "$SCRIPT" --repo backend --plan docs/plans/x.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker run"* ]]
  [[ "$output" == *":/mnt/claude"* ]]
}
