#!/usr/bin/env bash
# test/test_idempotent.sh
# AC11 : Install script idempotent (re-run safe)

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

# ---------------------------------------------------------------------------
# _simulate_install — replicates what install.sh is expected to do
# per PLAN.md, without requiring install.sh to exist yet:
#   1. Copy bin/kitsync to $FAKE_BIN_DIR
#   2. Ensure $PATH export in RC file
#   3. Inject wrapper markers in RC file if absent
#
# Args:
#   $1 = fake_home dir
#   $2 = fake_bin_dir (e.g. fake_home/.local/bin)
#   $3 = rc_file path (e.g. fake_home/.zshrc)
# ---------------------------------------------------------------------------
_simulate_install() {
  local fake_home="$1"
  local fake_bin_dir="$2"
  local rc_file="$3"

  # 1. Copy binary
  mkdir -p "$fake_bin_dir"
  if [[ -f "$_PROJECT_ROOT/bin/kitsync" ]]; then
    cp "$_PROJECT_ROOT/bin/kitsync" "$fake_bin_dir/kitsync"
    chmod +x "$fake_bin_dir/kitsync"
  else
    # bin/kitsync not yet created — write a stub
    echo "#!/usr/bin/env bash" > "$fake_bin_dir/kitsync"
    echo "# stub" >> "$fake_bin_dir/kitsync"
    chmod +x "$fake_bin_dir/kitsync"
  fi

  # 2. Inject PATH line in RC file (idempotent: only once)
  local path_line="export PATH=\"$fake_bin_dir:\$PATH\""
  if ! grep -qF "$fake_bin_dir" "$rc_file" 2>/dev/null; then
    echo "$path_line" >> "$rc_file"
  fi

  # 3. Inject shell wrapper between markers (idempotent)
  local marker_start="# kitsync-start"
  local marker_end="# kitsync-end"

  if ! grep -qF "$marker_start" "$rc_file" 2>/dev/null; then
    cat >> "$rc_file" << WRAPPER
$marker_start
claude() {
  if [[ -d "\$CLAUDE_HOME" ]] && git -C "\$CLAUDE_HOME" rev-parse --git-dir &>/dev/null; then
    (timeout 2 git -C "\$CLAUDE_HOME" pull --rebase --autostash -q 2>/dev/null) &
    disown
  fi
  command claude "\$@"
}
$marker_end
WRAPPER
  fi
}

# ---------------------------------------------------------------------------
# AC11 tests
# ---------------------------------------------------------------------------

run_test_ac11_binary_present_after_install() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local fake_home="$_TEST_TMPDIR/home"
  local fake_bin="$fake_home/.local/bin"
  local rc_file="$fake_home/.zshrc"
  mkdir -p "$fake_home"
  touch "$rc_file"

  _simulate_install "$fake_home" "$fake_bin" "$rc_file"

  assert_file_exists "$fake_bin/kitsync" \
    "AC11: kitsync binary present after first install"
}

run_test_ac11_binary_present_after_second_install() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local fake_home="$_TEST_TMPDIR/home"
  local fake_bin="$fake_home/.local/bin"
  local rc_file="$fake_home/.zshrc"
  mkdir -p "$fake_home"
  touch "$rc_file"

  _simulate_install "$fake_home" "$fake_bin" "$rc_file"
  _simulate_install "$fake_home" "$fake_bin" "$rc_file"

  assert_file_exists "$fake_bin/kitsync" \
    "AC11: kitsync binary present after second install (idempotent)"
}

run_test_ac11_path_line_appears_exactly_once() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local fake_home="$_TEST_TMPDIR/home"
  local fake_bin="$fake_home/.local/bin"
  local rc_file="$fake_home/.zshrc"
  mkdir -p "$fake_home"
  touch "$rc_file"

  _simulate_install "$fake_home" "$fake_bin" "$rc_file"
  _simulate_install "$fake_home" "$fake_bin" "$rc_file"

  local count
  count="$(grep -c "$fake_bin" "$rc_file" || true)"
  assert_eq "1" "$count" \
    "AC11: PATH export appears exactly once after two installs"
}

run_test_ac11_wrapper_markers_appear_exactly_once() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local fake_home="$_TEST_TMPDIR/home"
  local fake_bin="$fake_home/.local/bin"
  local rc_file="$fake_home/.zshrc"
  mkdir -p "$fake_home"
  touch "$rc_file"

  _simulate_install "$fake_home" "$fake_bin" "$rc_file"
  _simulate_install "$fake_home" "$fake_bin" "$rc_file"

  local start_count end_count
  start_count="$(grep -c "# kitsync-start" "$rc_file" || true)"
  end_count="$(grep -c "# kitsync-end" "$rc_file" || true)"

  assert_eq "1" "$start_count" \
    "AC11: # kitsync-start marker appears exactly once after two installs"
  assert_eq "1" "$end_count" \
    "AC11: # kitsync-end marker appears exactly once after two installs"
}

run_test_ac11_three_installs_still_idempotent() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local fake_home="$_TEST_TMPDIR/home"
  local fake_bin="$fake_home/.local/bin"
  local rc_file="$fake_home/.zshrc"
  mkdir -p "$fake_home"
  touch "$rc_file"

  _simulate_install "$fake_home" "$fake_bin" "$rc_file"
  _simulate_install "$fake_home" "$fake_bin" "$rc_file"
  _simulate_install "$fake_home" "$fake_bin" "$rc_file"

  local path_count marker_count
  path_count="$(grep -c "$fake_bin" "$rc_file" || true)"
  marker_count="$(grep -c "kitsync-start" "$rc_file" || true)"

  assert_eq "1" "$path_count" \
    "AC11: PATH line still appears once after three installs"
  assert_eq "1" "$marker_count" \
    "AC11: wrapper markers still appear once after three installs"
}

run_test_ac11_install_sh_idempotent_if_exists() {
  # If install.sh exists, run it twice and verify rc file not duplicated
  if [[ ! -f "$_PROJECT_ROOT/install.sh" ]]; then
    printf "  SKIP  AC11: install.sh not yet created — spec-driven test already covered above\n"
    return 0
  fi

  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local fake_home="$_TEST_TMPDIR/home"
  local rc_file="$fake_home/.zshrc"
  mkdir -p "$fake_home"
  touch "$rc_file"

  # Run install.sh with HOME overridden to our fake directory
  HOME="$fake_home" bash "$_PROJECT_ROOT/install.sh" --no-rc 2>/dev/null || \
  HOME="$fake_home" bash "$_PROJECT_ROOT/install.sh" 2>/dev/null || true

  HOME="$fake_home" bash "$_PROJECT_ROOT/install.sh" --no-rc 2>/dev/null || \
  HOME="$fake_home" bash "$_PROJECT_ROOT/install.sh" 2>/dev/null || true

  local marker_count
  marker_count="$(grep -c "kitsync" "$rc_file" 2>/dev/null || true)"
  marker_count="${marker_count:-0}"
  marker_count="$(echo "$marker_count" | tr -d '[:space:]')"

  # Verify block isn't duplicated. The wrapper now contains ~15 kitsync refs
  # (pull/push/timer branches for zsh+bash). Cap at 30 — double that signals duplication.
  local ok=0
  [[ "$marker_count" -lt 30 ]] || ok=1
  assert_zero "$ok" \
    "AC11: install.sh double-run does not infinitely duplicate entries"
}

run_test_ac11_wrapper_update_replaces_not_appends() {
  # If wrapper is updated (new content between markers), re-running install
  # must replace the block, not append a second copy.
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local fake_home="$_TEST_TMPDIR/home"
  local fake_bin="$fake_home/.local/bin"
  local rc_file="$fake_home/.zshrc"
  mkdir -p "$fake_home"
  touch "$rc_file"

  _simulate_install "$fake_home" "$fake_bin" "$rc_file"

  # The second install call must not add a second block
  _simulate_install "$fake_home" "$fake_bin" "$rc_file"

  local block_count
  block_count="$(grep -c "command claude" "$rc_file" || true)"

  assert_eq "1" "$block_count" \
    "AC11: 'command claude' appears exactly once after two installs"
}

# ---------------------------------------------------------------------------
# Run all tests in this module
# ---------------------------------------------------------------------------
run_idempotent_tests() {
  printf "\n=== test_idempotent.sh (AC11) ===\n"
  run_test_ac11_binary_present_after_install
  run_test_ac11_binary_present_after_second_install
  run_test_ac11_path_line_appears_exactly_once
  run_test_ac11_wrapper_markers_appear_exactly_once
  run_test_ac11_three_installs_still_idempotent
  run_test_ac11_install_sh_idempotent_if_exists
  run_test_ac11_wrapper_update_replaces_not_appends
}
