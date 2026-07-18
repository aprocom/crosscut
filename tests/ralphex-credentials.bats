#!/usr/bin/env bats
# Tests for ralphex credential auto-mount and preparation logic.
#
# Docker is NOT launched. Dry-run tests verify command assembly; non-dry-run tests
# that reach the docker invocation use a stub on PATH that prints its args.
#
# Every test sets CROSSCUT_UNAME explicitly so results are identical on macOS and Linux CI.

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$DIR/../skills/crosscut/scripts/run-executor.sh"
  TMP="$(mktemp -d)"

  # PyYAML may live in user-site-packages (HOME/.local/…). Capture its location
  # before we redirect HOME so python3 can still import it inside the script.
  local _site
  _site="$(python3 -c \
    "import yaml, os; print(os.path.dirname(os.path.dirname(yaml.__file__)))" \
    2>/dev/null || true)"
  if [ -n "$_site" ]; then
    export PYTHONPATH="${_site}${PYTHONPATH:+:$PYTHONPATH}"
  fi

  # Fake HOME so we control ~/.claude without polluting the real one.
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude"
  # Credential file stub — present for tests that reach the Linux credential check.
  touch "$HOME/.claude/.credentials.json"

  # Fake repo with one commit — required for non-dry-run tests that reach begin_run.
  mkdir -p "$TMP/repo/docs/plans"
  echo "# plan" > "$TMP/repo/docs/plans/feat.md"
  (
    cd "$TMP/repo" && git init -q \
      && git config user.email t@t && git config user.name t \
      && git add -A && git commit -q -m init
  )

  # Fake PATH bin dir for stubs.
  mkdir -p "$TMP/bin"
  export PATH="$TMP/bin:$PATH"

  # Docker stub: prints its arguments, exits 0.
  cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@"
exit 0
SH
  chmod +x "$TMP/bin/docker"

  # Minimal config pointing at our fake repo and runs_dir.
  export CROSSCUT_CONFIG="$TMP/config.yaml"
}

teardown() { rm -rf "$TMP"; }

# Write a config with optional executor_options.mounts entries.
_write_config() {
  # $@ = zero or more mount lines (already formatted "- path:target")
  cat > "$CROSSCUT_CONFIG" <<EOF
version: 1
repos:
  - name: repo
    path: $TMP/repo
    kind: generic
executor: ralphex
executor_options:
  runs_dir: $TMP/runs
  image: ghcr.io/umputun/ralphex:latest
EOF
  if [ $# -gt 0 ]; then
    printf '  mounts:\n' >> "$CROSSCUT_CONFIG"
    for m in "$@"; do
      printf '    - %s\n' "$m" >> "$CROSSCUT_CONFIG"
    done
  fi
}

# --- Test 1: deduplication ---------------------------------------------------

@test "1: user mount to /mnt/claude deduplicates with default cred mount" {
  _write_config "$HOME/.claude:/mnt/claude"
  run env CROSSCUT_UNAME=Linux EXECUTOR_DRYRUN=1 \
    bash "$SCRIPT" --repo repo --plan docs/plans/feat.md
  [ "$status" -eq 0 ]
  # /mnt/claude appears exactly once in the output (grep on full mount spec avoids
  # false matches against the /mnt/claude-credentials.json prefix)
  count="$(printf '%s\n' "$output" | grep -oF "$HOME/.claude:/mnt/claude" | wc -l)"
  [ "$count" -eq 1 ]
  # The source is the user-supplied value (HOME expanded)
  [[ "$output" == *"$HOME/.claude:/mnt/claude"* ]]
}

# --- Test 2: default (no mounts) --------------------------------------------

@test "2: default (no mounts) includes cred mount for Linux" {
  _write_config
  run env CROSSCUT_UNAME=Linux EXECUTOR_DRYRUN=1 \
    bash "$SCRIPT" --repo repo --plan docs/plans/feat.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.claude:/mnt/claude"* ]]
  # Only the one credential mount — no darwin extra on Linux
  [[ "$output" != *"/mnt/claude-credentials.json"* ]]
}

# --- Test 3: additional mounts preserved ------------------------------------

@test "3: additional user mounts present alongside cred mounts" {
  _write_config "$HOME/.gitconfig:/home/app/.gitconfig:ro"
  run env CROSSCUT_UNAME=Linux EXECUTOR_DRYRUN=1 \
    bash "$SCRIPT" --repo repo --plan docs/plans/feat.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.claude:/mnt/claude"* ]]
  [[ "$output" == *"$HOME/.gitconfig:/home/app/.gitconfig:ro"* ]]
}

# --- Test 4: missing creds stops run ----------------------------------------

@test "4: missing credentials file stops run before creating run dir" {
  # Remove the credential stub so the Linux check fails.
  rm "$HOME/.claude/.credentials.json"
  _write_config
  run env CROSSCUT_UNAME=Linux \
    bash "$SCRIPT" --repo repo --plan docs/plans/feat.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude /login"* ]]
  # begin_run never ran: no run dir created
  [ ! -d "$TMP/runs/repo/feat" ]
}

# --- Test 5: secrets not in output ------------------------------------------

@test "5: credential file contents never appear in stdout or stderr" {
  local marker="SUPERSECRET_MARKER_DO_NOT_LOG_12345"
  printf '%s\n' "$marker" > "$HOME/.claude/.credentials.json"
  _write_config
  run env CROSSCUT_UNAME=Linux EXECUTOR_DRYRUN=1 \
    bash "$SCRIPT" --repo repo --plan docs/plans/feat.md
  [ "$status" -eq 0 ]
  [[ "$output" != *"$marker"* ]]
}

# --- Test 6: dry-run creates no files (Darwin) ------------------------------

@test "6: dry-run with Darwin does not call security or create cred file" {
  # security stub that marks itself as called
  cat > "$TMP/bin/security" <<SH
#!/usr/bin/env bash
touch "$TMP/security_called"
printf 'fakecred\n'
exit 0
SH
  chmod +x "$TMP/bin/security"

  _write_config
  run env CROSSCUT_UNAME=Darwin EXECUTOR_DRYRUN=1 \
    bash "$SCRIPT" --repo repo --plan docs/plans/feat.md
  [ "$status" -eq 0 ]
  # security must NOT have been called
  [ ! -f "$TMP/security_called" ]
  # No credential file created
  [ ! -f "$HOME/.claude/claude-credentials.json" ]
  # Both credential mount specs appear in the printed command
  [[ "$output" == *"$HOME/.claude:/mnt/claude"* ]]
  [[ "$output" == *"/mnt/claude-credentials.json"* ]]
}

# --- Test 7: user declares /mnt/claude-credentials.json → no auto-prep ------

@test "7: user mount to /mnt/claude-credentials.json disables auto-prep on Darwin" {
  local user_cred="$TMP/mycreds.json"
  printf 'usercred\n' > "$user_cred"

  cat > "$TMP/bin/security" <<SH
#!/usr/bin/env bash
touch "$TMP/security_called"
printf 'fakecred\n'
exit 0
SH
  chmod +x "$TMP/bin/security"

  _write_config "$user_cred:/mnt/claude-credentials.json"
  run env CROSSCUT_UNAME=Darwin \
    bash "$SCRIPT" --repo repo --plan docs/plans/feat.md
  [ "$status" -eq 0 ]
  # security must NOT have been called (auto-prep was skipped)
  [ ! -f "$TMP/security_called" ]
  # Docker was invoked and executor.log contains the user's cred mount.
  # (docker stdout → executor.log; the stub prints one arg per line)
  local log
  log="$(find "$TMP/runs" -name executor.log 2>/dev/null | head -1)"
  [ -f "$log" ]
  grep -qF "$user_cred:/mnt/claude-credentials.json" "$log"
  # The /mnt/claude directory mount must still be present
  grep -qF "$HOME/.claude:/mnt/claude" "$log"
}

# --- Test 7a: overriding /mnt/claude does NOT disable Darwin extraction ------

@test "7a: overriding /mnt/claude only does not disable Darwin cred extraction" {
  local user_dir="$TMP/mydir"
  mkdir -p "$user_dir"

  cat > "$TMP/bin/security" <<SH
#!/usr/bin/env bash
touch "$TMP/security_called"
printf 'fakecred\n'
exit 0
SH
  chmod +x "$TMP/bin/security"

  _write_config "$user_dir:/mnt/claude"
  run env CROSSCUT_UNAME=Darwin \
    bash "$SCRIPT" --repo repo --plan docs/plans/feat.md
  [ "$status" -eq 0 ]
  # security MUST have been called
  [ -f "$TMP/security_called" ]
  # The extracted file must exist
  [ -f "$HOME/.claude/claude-credentials.json" ]
}

# --- Test 7b: Linux user overrides /mnt/claude → no cred-file check --------

@test "7b: Linux user mount to /mnt/claude suppresses missing-creds error" {
  # Remove creds so the default Linux check would fail.
  rm "$HOME/.claude/.credentials.json"
  local user_dir="$TMP/mydir"
  mkdir -p "$user_dir"

  _write_config "$user_dir:/mnt/claude"
  # Run without DRYRUN: must reach docker without error.
  run env CROSSCUT_UNAME=Linux \
    bash "$SCRIPT" --repo repo --plan docs/plans/feat.md
  [ "$status" -eq 0 ]
  # No credential error
  [[ "$output" != *"claude /login"* ]]
  # Docker was invoked (run dir created)
  local log
  log="$(find "$TMP/runs" -name executor.log 2>/dev/null | head -1)"
  [ -f "$log" ]
}

# --- Test 8: Darwin extracts creds, sets 600, no secrets in output ----------

@test "8: Darwin branch extracts creds, sets 600 perms, leaks no secret" {
  local marker="SECRET_CRED_CONTENT_ABC987"

  cat > "$TMP/bin/security" <<SH
#!/usr/bin/env bash
printf '%s\n' "$marker"
exit 0
SH
  chmod +x "$TMP/bin/security"

  _write_config
  run env CROSSCUT_UNAME=Darwin \
    bash "$SCRIPT" --repo repo --plan docs/plans/feat.md
  [ "$status" -eq 0 ]

  # File created
  [ -f "$HOME/.claude/claude-credentials.json" ]
  # Permissions are 600
  local perms
  perms="$(stat -c '%a' "$HOME/.claude/claude-credentials.json" 2>/dev/null \
           || stat -f '%A' "$HOME/.claude/claude-credentials.json" 2>/dev/null)"
  [ "$perms" = "600" ]
  # Secret not in stdout or stderr
  [[ "$output" != *"$marker"* ]]
}

# --- Test 9: mount_target parsing -------------------------------------------

@test "9: mount_target extracts second colon-separated field" {
  # Extract just the mount_target function body so we can call it without
  # triggering the script's arg-parse exit.
  local fn_src
  fn_src="$(sed -n '/^mount_target() {/,/^}/p' "$SCRIPT")"

  [ "$(bash -c "$fn_src; mount_target /src:/mnt/x")" = "/mnt/x" ]
  [ "$(bash -c "$fn_src; mount_target /src:/mnt/x:ro")" = "/mnt/x" ]
  [ "$(bash -c "$fn_src; mount_target /src:/mnt/creds.json:cached")" = "/mnt/creds.json" ]
}

# --- Test 10: Darwin Keychain miss -------------------------------------------

@test "10: Darwin: Keychain miss aborts run with login hint" {
  cat > "$TMP/bin/security" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$TMP/bin/security"
  _write_config
  run env CROSSCUT_UNAME=Darwin \
    bash "$SCRIPT" --repo repo --plan docs/plans/feat.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude /login"* ]]
  # Run dir must not have been created
  [ ! -d "$TMP/runs/repo/feat" ]
}

# --- Test 11: Darwin empty credential ----------------------------------------

@test "11: Darwin: empty Keychain entry aborts run" {
  cat > "$TMP/bin/security" <<'SH'
#!/usr/bin/env bash
printf ''
exit 0
SH
  chmod +x "$TMP/bin/security"
  _write_config
  run env CROSSCUT_UNAME=Darwin \
    bash "$SCRIPT" --repo repo --plan docs/plans/feat.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty credential"* ]]
  # Run dir must not have been created
  [ ! -d "$TMP/runs/repo/feat" ]
}
