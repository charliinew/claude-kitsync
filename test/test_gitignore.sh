#!/usr/bin/env bash
# test/test_gitignore.sh
# AC2 : kitsync init configure ~/.claude comme repo git avec .gitignore allowlist correct
# AC5 : .credentials.json et projects/ n'apparaissent jamais dans git status

# Source helpers (path relative to this file's directory)
_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_HELPERS_DIR/helpers.sh"

# ---------------------------------------------------------------------------
# Helpers local to this module
# ---------------------------------------------------------------------------

# _git_would_track <file_path_relative_to_CLAUDE_HOME>
# Returns 0 if git would track the file (i.e. it is NOT ignored), 1 if ignored.
_git_would_track() {
  local rel="$1"
  # git check-ignore exits 0 when the path IS ignored, 1 when it is not ignored
  git -C "$CLAUDE_HOME" check-ignore -q "$rel" 2>/dev/null
  # invert: we want 0 = tracked, 1 = ignored  — so negate
  local rc=$?
  return $(( 1 - rc ))  # 0 → not ignored (tracked), 1 → ignored
}

# _git_is_ignored <file_path_relative_to_CLAUDE_HOME>
# Returns 0 if the file is ignored by git.
_git_is_ignored() {
  local rel="$1"
  git -C "$CLAUDE_HOME" check-ignore -q "$rel" 2>/dev/null
}

# ---------------------------------------------------------------------------
# AC2 — repo git correctly initialised with allowlist .gitignore
# ---------------------------------------------------------------------------
run_test_ac2_gitignore_exists() {
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  assert_file_exists "$CLAUDE_HOME/.gitignore" \
    "AC2: .gitignore exists after setup_git_claude_home"
}

run_test_ac2_is_git_repo() {
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  git -C "$CLAUDE_HOME" rev-parse --git-dir &>/dev/null
  assert_zero $? "AC2: CLAUDE_HOME is a git repository"
}

run_test_ac2_gitignore_has_allowlist_pattern() {
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  local content
  content="$(cat "$CLAUDE_HOME/.gitignore")"

  assert_contains "$content" "!settings.json" \
    "AC2: .gitignore allows settings.json"

  assert_contains "$content" "!agents/" \
    "AC2: .gitignore allows agents/"

  assert_contains "$content" "!skills/" \
    "AC2: .gitignore allows skills/"

  assert_contains "$content" "!hooks/" \
    "AC2: .gitignore allows hooks/"

  assert_contains "$content" "!scripts/" \
    "AC2: .gitignore allows scripts/"

  assert_contains "$content" "!.gitignore" \
    "AC2: .gitignore allows itself (.gitignore)"
}

run_test_ac2_allowlist_wildcard_present() {
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  local content
  content="$(cat "$CLAUDE_HOME/.gitignore")"

  # The allowlist pattern must start with "*" to deny all by default
  assert_contains "$content" "*" \
    "AC2: .gitignore starts with deny-all wildcard (*)"
}

# ---------------------------------------------------------------------------
# AC5 — .credentials.json never appears in git status
# ---------------------------------------------------------------------------
run_test_ac5_credentials_ignored() {
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  # Create the file as if Claude wrote it
  echo '{"token":"secret"}' > "$CLAUDE_HOME/.credentials.json"

  _git_is_ignored ".credentials.json"
  assert_zero $? "AC5: .credentials.json is ignored by git"
}

run_test_ac5_credentials_not_in_status() {
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  echo '{"token":"secret"}' > "$CLAUDE_HOME/.credentials.json"

  local status_output
  status_output="$(git -C "$CLAUDE_HOME" status --short 2>&1)"

  # .credentials.json must not appear in git status output
  local found=0
  if echo "$status_output" | grep -q ".credentials.json"; then
    found=1
  fi
  assert_eq "0" "$found" \
    "AC5: .credentials.json absent from git status output"
}

run_test_ac5_projects_dir_ignored() {
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  mkdir -p "$CLAUDE_HOME/projects/my-session"
  echo "session data" > "$CLAUDE_HOME/projects/my-session/data.json"

  _git_is_ignored "projects/"
  assert_zero $? "AC5: projects/ directory is ignored by git"
}

run_test_ac5_projects_not_in_status() {
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  mkdir -p "$CLAUDE_HOME/projects/session-1"
  echo "{}" > "$CLAUDE_HOME/projects/session-1/data.json"

  local status_output
  status_output="$(git -C "$CLAUDE_HOME" status --short 2>&1)"

  local found=0
  if echo "$status_output" | grep -q "projects"; then
    found=1
  fi
  assert_eq "0" "$found" \
    "AC5: projects/ absent from git status output"
}

run_test_ac5_other_runtime_dirs_ignored() {
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  local ignored_items=(
    "backups/"
    "cache/"
    "file-history/"
    "paste-cache/"
    "shell-snapshots/"
    "session-env/"
    "sessions/"
    "tasks/"
    "telemetry/"
    "history.jsonl"
    "stats-cache.json"
  )

  for item in "${ignored_items[@]}"; do
    # Create the file/dir
    if [[ "$item" == */ ]]; then
      mkdir -p "$CLAUDE_HOME/${item%/}"
      echo "data" > "$CLAUDE_HOME/${item%/}/dummy.txt"
    else
      echo "data" > "$CLAUDE_HOME/$item"
    fi

    _git_is_ignored "$item"
    assert_zero $? "AC5: '$item' is ignored by git"
  done
}

run_test_ac5_settings_json_not_ignored() {
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  # settings.json must NOT be ignored (it is whitelisted)
  echo '{}' > "$CLAUDE_HOME/settings.json"

  _git_is_ignored "settings.json"
  local rc=$?
  assert_eq "1" "$rc" \
    "AC5: settings.json is NOT ignored (must be tracked)"
}

run_test_ac5_agents_dir_not_ignored() {
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  mkdir -p "$CLAUDE_HOME/agents"
  echo "# agent" > "$CLAUDE_HOME/agents/my-agent.md"

  _git_is_ignored "agents/my-agent.md"
  local rc=$?
  assert_eq "1" "$rc" \
    "AC5: agents/ content is NOT ignored (must be tracked)"
}

# ---------------------------------------------------------------------------
# Run all tests in this module
# ---------------------------------------------------------------------------
run_gitignore_tests() {
  printf "\n=== test_gitignore.sh (AC2, AC5) ===\n"
  run_test_ac2_gitignore_exists
  run_test_ac2_is_git_repo
  run_test_ac2_gitignore_has_allowlist_pattern
  run_test_ac2_allowlist_wildcard_present
  run_test_ac5_credentials_ignored
  run_test_ac5_credentials_not_in_status
  run_test_ac5_projects_dir_ignored
  run_test_ac5_projects_not_in_status
  run_test_ac5_other_runtime_dirs_ignored
  run_test_ac5_settings_json_not_ignored
  run_test_ac5_agents_dir_not_ignored
}
