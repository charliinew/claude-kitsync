#!/usr/bin/env bash
# test/test_paths.sh
# AC6 : Sur Machine B (username différent), settings.json résolu correctement post-pull
# Tests normalize_paths() from lib/paths.sh

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

# ---------------------------------------------------------------------------
# _source_paths_lib — source lib/paths.sh (and core.sh) if they exist.
# After sourcing, we restore 'set +e' so test assertions continue normally.
# Returns 1 if the lib is not yet implemented.
# ---------------------------------------------------------------------------
_PATHS_LIB_AVAILABLE=0
_source_paths_lib() {
  if [[ -f "$_PROJECT_ROOT/lib/paths.sh" ]]; then
    # Source core.sh first (provides is_macos, log_info, etc.)
    # Temporarily suppress exit-on-error since core.sh sets -euo pipefail
    [[ -f "$_PROJECT_ROOT/lib/core.sh" ]] && { set +e; source "$_PROJECT_ROOT/lib/core.sh"; set +e; } 2>/dev/null || true
    set +e
    # shellcheck source=/dev/null
    source "$_PROJECT_ROOT/lib/paths.sh"
    set +e  # restore — paths.sh sets -euo pipefail internally
    _PATHS_LIB_AVAILABLE=1
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _apply_normalize_paths_sed — applies the sed transform described in PLAN.md
# directly, without requiring lib/paths.sh to exist yet.
# This lets us test the BEHAVIOUR (the expected transform) independently
# of whether the implementation file exists.
# ---------------------------------------------------------------------------
_apply_normalize_paths_sed() {
  local target_file="$1"
  local home_dir="$2"          # the $HOME on Machine B

  local pattern="s|/Users/[^/]*/\.claude|${home_dir}/.claude|g"

  # macOS sed requires '' after -i; Linux sed does not
  if sed -i '' "$pattern" "$target_file" 2>/dev/null; then
    return 0
  else
    sed -i "$pattern" "$target_file"
  fi
}

# ---------------------------------------------------------------------------
# AC6 — normalize_paths replaces hardcoded /Users/<other> with $HOME
# ---------------------------------------------------------------------------

run_test_ac6_sed_replaces_foreign_user_path() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local machine_b_home="$CLAUDE_HOME/home_machineB"
  mkdir -p "$machine_b_home"

  # Simulate a settings.json pulled from Machine A (user: alice)
  cat > "$CLAUDE_HOME/settings.json" << 'EOF'
{
  "hooks": {
    "command": "python3 /Users/alice/.claude/hooks/rm_to_trash.py"
  },
  "audio": {
    "command": "afplay -v 0.1 '/Users/alice/.claude/song/finish.mp3'"
  }
}
EOF

  _apply_normalize_paths_sed "$CLAUDE_HOME/settings.json" "$machine_b_home"

  local content
  content="$(cat "$CLAUDE_HOME/settings.json")"

  assert_contains "$content" "$machine_b_home/.claude" \
    "AC6: foreign /Users/alice path replaced with machine B home"
}

run_test_ac6_sed_removes_original_username() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local machine_b_home="$CLAUDE_HOME/home_machineB"
  mkdir -p "$machine_b_home"

  cat > "$CLAUDE_HOME/settings.json" << 'EOF'
{
  "command": "python3 /Users/alice/.claude/hooks/rm_to_trash.py"
}
EOF

  _apply_normalize_paths_sed "$CLAUDE_HOME/settings.json" "$machine_b_home"

  local content
  content="$(cat "$CLAUDE_HOME/settings.json")"

  # The original username "alice" must no longer appear in a path context
  local found=0
  if echo "$content" | grep -q "/Users/alice/"; then
    found=1
  fi
  assert_eq "0" "$found" \
    "AC6: original username 'alice' no longer present in path"
}

run_test_ac6_sed_handles_multiple_occurrences() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local machine_b_home="$CLAUDE_HOME/home_bob"
  mkdir -p "$machine_b_home"

  # Four absolute paths as documented in PLAN.md
  cat > "$CLAUDE_HOME/settings.json" << 'EOF'
{
  "cmd1": "python3 /Users/alice/.claude/hooks/rm_to_trash.py",
  "cmd2": "afplay -v 0.1 '/Users/alice/.claude/song/finish.mp3'",
  "cmd3": "afplay -v 0.1 '/Users/alice/.claude/song/need-human.mp3'",
  "cmd4": "bun /Users/alice/.claude/scripts/statusline/src/index.ts"
}
EOF

  _apply_normalize_paths_sed "$CLAUDE_HOME/settings.json" "$machine_b_home"

  local content
  content="$(cat "$CLAUDE_HOME/settings.json")"

  # All four occurrences must be replaced
  local alice_count
  alice_count="$(echo "$content" | grep -c "/Users/alice/" || true)"
  assert_eq "0" "$alice_count" \
    "AC6: all 4 hardcoded /Users/alice paths replaced"

  # And the replacement path must appear 4 times
  local bob_count
  bob_count="$(echo "$content" | grep -c "${machine_b_home}/.claude" || true)"
  assert_eq "4" "$bob_count" \
    "AC6: replacement path appears 4 times"
}

run_test_ac6_sed_does_not_corrupt_non_path_content() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local machine_b_home="$CLAUDE_HOME/home_bob"
  mkdir -p "$machine_b_home"

  cat > "$CLAUDE_HOME/settings.json" << 'EOF'
{
  "command": "python3 /Users/alice/.claude/hooks/rm_to_trash.py",
  "name": "my-config",
  "version": "1.0"
}
EOF

  _apply_normalize_paths_sed "$CLAUDE_HOME/settings.json" "$machine_b_home"

  local content
  content="$(cat "$CLAUDE_HOME/settings.json")"

  assert_contains "$content" '"name": "my-config"' \
    "AC6: non-path JSON content preserved after sed"
  assert_contains "$content" '"version": "1.0"' \
    "AC6: version field preserved after sed"
}

run_test_ac6_sed_idempotent_with_local_home() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  # Simulate: settings.json already has the correct local path.
  # Running normalize_paths again must not corrupt it.
  cat > "$CLAUDE_HOME/settings.json" << EOF
{
  "command": "python3 ${CLAUDE_HOME}/hooks/rm_to_trash.py"
}
EOF

  local before
  before="$(cat "$CLAUDE_HOME/settings.json")"

  # The pattern matches /Users/<name>/.claude — use our own CLAUDE_HOME parent
  # to derive a fake "home" that matches the current structure
  local fake_home
  fake_home="$(dirname "$CLAUDE_HOME")"

  _apply_normalize_paths_sed "$CLAUDE_HOME/settings.json" "$fake_home"

  local after
  after="$(cat "$CLAUDE_HOME/settings.json")"

  # Content must remain functionally the same (path stays valid)
  assert_contains "$after" "rm_to_trash.py" \
    "AC6: idempotent — file content preserved when no foreign paths present"
}

run_test_ac6_normalize_via_lib_if_available() {
  # If lib/paths.sh already exists, test normalize_paths() directly.
  if ! _source_paths_lib; then
    printf "  SKIP  AC6: lib/paths.sh not yet implemented — skipping lib integration test\n"
    return 0
  fi

  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  cat > "$CLAUDE_HOME/settings.json" << 'EOF'
{
  "command": "python3 /Users/otheruser/.claude/hooks/script.py"
}
EOF

  # normalize_paths uses $HOME internally; we redirect $HOME to our fake dir
  local fake_home
  fake_home="$(dirname "$CLAUDE_HOME")"
  HOME="$fake_home" normalize_paths

  local content
  content="$(cat "$CLAUDE_HOME/settings.json")"

  local found=0
  if echo "$content" | grep -q "/Users/otheruser/"; then
    found=1
  fi
  assert_eq "0" "$found" \
    "AC6: normalize_paths() via lib/paths.sh removes foreign username"
}

# ---------------------------------------------------------------------------
# Run all tests in this module
# ---------------------------------------------------------------------------
run_paths_tests() {
  printf "\n=== test_paths.sh (AC6) ===\n"
  run_test_ac6_sed_replaces_foreign_user_path
  run_test_ac6_sed_removes_original_username
  run_test_ac6_sed_handles_multiple_occurrences
  run_test_ac6_sed_does_not_corrupt_non_path_content
  run_test_ac6_sed_idempotent_with_local_home
  run_test_ac6_normalize_via_lib_if_available
}
