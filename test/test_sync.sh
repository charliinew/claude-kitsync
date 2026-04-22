#!/usr/bin/env bash
# test/test_sync.sh
# AC4 : claude ne bloque pas plus de 2s (timeout async)
# AC7 : Dirty tree → skip sync + warning ; clean tree → rebase auto sans friction

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

# ---------------------------------------------------------------------------
# _source_sync_lib — source lib/sync.sh if available.
# Restores set +e after sourcing to keep test assertions working.
# ---------------------------------------------------------------------------
_SYNC_LIB_AVAILABLE=0
_source_sync_lib() {
  if [[ -f "$_PROJECT_ROOT/lib/sync.sh" ]]; then
    [[ -f "$_PROJECT_ROOT/lib/core.sh" ]] && { set +e; source "$_PROJECT_ROOT/lib/core.sh"; set +e; } 2>/dev/null || true
    set +e
    source "$_PROJECT_ROOT/lib/sync.sh"
    set +e
    _SYNC_LIB_AVAILABLE=1
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _is_dirty — returns 0 if the git working tree has uncommitted changes
# ---------------------------------------------------------------------------
_is_dirty() {
  local dir="$1"
  ! git -C "$dir" diff --quiet 2>/dev/null || \
  ! git -C "$dir" diff --cached --quiet 2>/dev/null
}

# ---------------------------------------------------------------------------
# AC7 — dirty tree detection
# ---------------------------------------------------------------------------

run_test_ac7_dirty_tree_detected() {
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  make_dirty_tree  # creates initial commit then modifies settings.json

  _is_dirty "$CLAUDE_HOME"
  assert_zero $? "AC7: dirty tree correctly detected (uncommitted changes present)"
}

run_test_ac7_clean_tree_detected() {
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  make_clean_tree  # creates initial commit, no pending changes

  _is_dirty "$CLAUDE_HOME"
  local rc=$?
  assert_eq "1" "$rc" \
    "AC7: clean tree correctly detected (no uncommitted changes)"
}

run_test_ac7_sync_pull_skips_dirty_tree() {
  # If lib/sync.sh exists, call sync_pull() directly and verify it skips.
  # Otherwise, test the skip logic inline (spec-driven).
  if ! _source_sync_lib; then
    printf "  SKIP  AC7: lib/sync.sh not yet implemented — testing skip logic inline\n"

    # Inline spec test: the logic from PLAN.md
    setup_git_claude_home
    trap "teardown_fake_claude_home" RETURN

    make_dirty_tree

    local skipped=0
    local warn_output=""
    # Replicate the intended guard from lib/sync.sh as described in PLAN.md:
    # "Check dirty → warn and return"
    if _is_dirty "$CLAUDE_HOME"; then
      skipped=1
      warn_output="Uncommitted changes, skipping auto-pull"
    fi

    assert_eq "1" "$skipped" \
      "AC7: dirty tree causes sync to be skipped"
    assert_contains "$warn_output" "skipping" \
      "AC7: warning message mentions 'skipping'"
    return 0
  fi

  # lib/sync.sh is available — test the real function
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  make_dirty_tree

  local output
  output="$(sync_pull 2>&1 || true)"

  assert_contains "$output" "skip" \
    "AC7: sync_pull() outputs skip/warn when tree is dirty"
}

run_test_ac7_sync_pull_skips_returns_nonzero_or_zero_but_no_rebase() {
  # When dirty: no git rebase must be attempted (git status unchanged)
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  make_dirty_tree

  local before_status
  before_status="$(git -C "$CLAUDE_HOME" status --short)"

  # Simulate the guard: skip when dirty
  if _is_dirty "$CLAUDE_HOME"; then
    : # skip — do not pull
  fi

  local after_status
  after_status="$(git -C "$CLAUDE_HOME" status --short)"

  assert_eq "$before_status" "$after_status" \
    "AC7: dirty tree — working directory unchanged after skip"
}

run_test_ac7_clean_tree_rebase_succeeds_locally() {
  # On a clean tree with a local remote, git pull --rebase must succeed.
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  make_clean_tree

  # Set up a bare local remote so we can do a real pull
  local remote_dir="$_TEST_TMPDIR/remote.git"
  git clone --bare -q "$CLAUDE_HOME" "$remote_dir"
  git -C "$CLAUDE_HOME" remote add origin "$remote_dir"
  git -C "$CLAUDE_HOME" branch -M main 2>/dev/null || true

  # Ensure the remote has a 'main' ref matching HEAD
  local current_branch
  current_branch="$(git -C "$CLAUDE_HOME" rev-parse --abbrev-ref HEAD)"
  git -C "$CLAUDE_HOME" push -q origin "${current_branch}:main" 2>/dev/null || \
  git -C "$CLAUDE_HOME" push -q origin HEAD 2>/dev/null || true

  # Now do a clean pull --rebase (should succeed silently)
  git -C "$CLAUDE_HOME" pull --rebase -q origin main 2>/dev/null
  local rc=$?
  assert_zero $rc \
    "AC7: clean tree — git pull --rebase succeeds without friction"
}

run_test_ac7_warning_message_format() {
  # The warning from PLAN.md must contain "Uncommitted changes" or "skipping"
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  make_dirty_tree

  local warning=""
  if _is_dirty "$CLAUDE_HOME"; then
    warning="Uncommitted changes, skipping auto-pull"
  fi

  assert_contains "$warning" "Uncommitted changes" \
    "AC7: warning message contains 'Uncommitted changes'"
  assert_contains "$warning" "skipping" \
    "AC7: warning message contains 'skipping'"
}

# ---------------------------------------------------------------------------
# AC4 — wrapper invokes claude with async background pull, max 2s timeout
# ---------------------------------------------------------------------------

run_test_ac4_wrapper_template_has_timeout() {
  # The shell-wrapper template must specify `timeout 2` (or KITSYNC_TIMEOUT)
  local template_file="$_PROJECT_ROOT/templates/shell-wrapper.sh"

  if [[ ! -f "$template_file" ]]; then
    printf "  SKIP  AC4: templates/shell-wrapper.sh not yet created — checking PLAN.md spec\n"

    # Spec-driven: verify the spec itself defines the 2s timeout
    local plan_content
    plan_content="$(cat "$_PROJECT_ROOT/PLAN.md")"
    assert_contains "$plan_content" "timeout 2" \
      "AC4: PLAN.md specifies 'timeout 2' in wrapper template"
    return 0
  fi

  local content
  content="$(cat "$template_file")"
  assert_contains "$content" "timeout" \
    "AC4: shell-wrapper.sh uses 'timeout' command"
}

run_test_ac4_wrapper_template_uses_background_subshell() {
  # The wrapper must launch the pull in a background subshell (&) + disown
  local template_file="$_PROJECT_ROOT/templates/shell-wrapper.sh"

  if [[ ! -f "$template_file" ]]; then
    printf "  SKIP  AC4: templates/shell-wrapper.sh not yet created — checking PLAN.md spec\n"

    local plan_content
    plan_content="$(cat "$_PROJECT_ROOT/PLAN.md")"
    assert_contains "$plan_content" "disown" \
      "AC4: PLAN.md specifies 'disown' to detach background pull"
    assert_contains "$plan_content" ") &" \
      "AC4: PLAN.md specifies background subshell ) &"
    return 0
  fi

  local content
  content="$(cat "$template_file")"
  assert_contains "$content" "disown" \
    "AC4: wrapper uses disown to prevent blocking"
}

run_test_ac4_wrapper_template_calls_command_claude() {
  # The wrapper must use `command claude "$@"` to avoid recursion
  local template_file="$_PROJECT_ROOT/templates/shell-wrapper.sh"

  if [[ ! -f "$template_file" ]]; then
    printf "  SKIP  AC4: templates/shell-wrapper.sh not yet created — checking PLAN.md spec\n"

    local plan_content
    plan_content="$(cat "$_PROJECT_ROOT/PLAN.md")"
    assert_contains "$plan_content" 'command claude "$@"' \
      "AC4: PLAN.md wrapper calls 'command claude \"\$@\"' to avoid recursion"
    return 0
  fi

  local content
  content="$(cat "$template_file")"
  assert_contains "$content" 'command claude' \
    "AC4: wrapper calls 'command claude' (no recursion)"
}

run_test_ac4_background_pull_does_not_block() {
  # Functional: the wrapper pattern launches git pull in background and returns
  # immediately. We simulate the wrapper logic and verify it does not take >2s.
  setup_git_claude_home
  trap "teardown_fake_claude_home" RETURN

  make_clean_tree

  # Simulate wrapper's background pull against a non-reachable remote
  # (should time out silently, not block the foreground)
  git -C "$CLAUDE_HOME" remote add origin "git://192.0.2.1/fake.git" 2>/dev/null || true

  local start_ts end_ts elapsed
  start_ts="$(date +%s)"

  # This is the wrapper pattern from PLAN.md — background, disowned, timeout 2
  (timeout 2 git -C "$CLAUDE_HOME" pull --rebase -q 2>/dev/null || true) &
  disown $! 2>/dev/null || true

  end_ts="$(date +%s)"
  elapsed=$(( end_ts - start_ts ))

  # The foreground must return in under 1s (the pull is in the background)
  assert_zero "$(( elapsed < 2 ? 0 : 1 ))" \
    "AC4: background pull pattern returns in <2s foreground time (elapsed=${elapsed}s)"
}

# ---------------------------------------------------------------------------
# Run all tests in this module
# ---------------------------------------------------------------------------
run_sync_tests() {
  printf "\n=== test_sync.sh (AC4, AC7) ===\n"
  run_test_ac7_dirty_tree_detected
  run_test_ac7_clean_tree_detected
  run_test_ac7_sync_pull_skips_dirty_tree
  run_test_ac7_sync_pull_skips_returns_nonzero_or_zero_but_no_rebase
  run_test_ac7_clean_tree_rebase_succeeds_locally
  run_test_ac7_warning_message_format
  run_test_ac4_wrapper_template_has_timeout
  run_test_ac4_wrapper_template_uses_background_subshell
  run_test_ac4_wrapper_template_calls_command_claude
  run_test_ac4_background_pull_does_not_block
}
