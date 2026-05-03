#!/usr/bin/env bash
# test/test_wrapper.sh — tests for lib/wrapper.sh (_backup_rc, _inject_into_rc)

_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$_PROJECT_ROOT/lib/core.sh"
source "$_PROJECT_ROOT/lib/wrapper.sh"

# ---------------------------------------------------------------------------
# _backup_rc tests
# ---------------------------------------------------------------------------

run_test_backup_creates_file() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local rc_file="$_TEST_TMPDIR/test_zshrc"
  echo "# test content" > "$rc_file"

  _backup_rc "$rc_file"

  local backup_dir="${CLAUDE_HOME}/.kitsync/backups"
  local found
  found="$(ls "$backup_dir"/test_zshrc.*.bak 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "1" "$found" "backup: creates one backup file"
}

run_test_backup_skips_nonexistent_file() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  _backup_rc "$_TEST_TMPDIR/does_not_exist" 2>/dev/null
  local rc=$?
  assert_zero "$rc" "backup: silently skips missing file"
}

run_test_backup_content_matches() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local rc_file="$_TEST_TMPDIR/test_zshrc"
  echo "# important config" > "$rc_file"

  _backup_rc "$rc_file"

  local backup_dir="${CLAUDE_HOME}/.kitsync/backups"
  local backup_file
  backup_file="$(ls -t "$backup_dir"/test_zshrc.*.bak 2>/dev/null | head -1)"
  local content
  content="$(cat "$backup_file")"
  assert_contains "$content" "# important config" "backup: content matches original"
}

run_test_backup_prunes_to_5() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local rc_file="$_TEST_TMPDIR/test_rc"
  local backup_dir="${CLAUDE_HOME}/.kitsync/backups"
  mkdir -p "$backup_dir"
  echo "content" > "$rc_file"

  # Pre-create 7 fake backups with distinct timestamps
  local i
  for i in $(seq 1 7); do
    touch "$backup_dir/test_rc.2026010${i}T120000.bak"
  done

  # _backup_rc creates an 8th then prunes → should keep 5
  _backup_rc "$rc_file"

  local count
  count="$(ls "$backup_dir"/test_rc.*.bak 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "5" "$count" "backup: prunes to 5 most recent"
}

# ---------------------------------------------------------------------------
# _inject_into_rc tests
# ---------------------------------------------------------------------------

run_test_inject_appends_when_no_markers() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local rc_file="$_TEST_TMPDIR/test_zshrc"
  echo "# existing config" > "$rc_file"

  _inject_into_rc "$rc_file"

  local content
  content="$(cat "$rc_file")"
  assert_contains "$content" "# existing config" "inject: preserves existing content"
  assert_contains "$content" "# kitsync-start"   "inject: adds start marker"
  assert_contains "$content" "# kitsync-end"     "inject: adds end marker"
  assert_contains "$content" "claude()"          "inject: adds wrapper function"
}

run_test_inject_replaces_existing_block() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local rc_file="$_TEST_TMPDIR/test_zshrc"
  cat > "$rc_file" <<'EOF'
# before
# kitsync-start
claude() { echo "old"; }
# kitsync-end
# after
EOF

  _inject_into_rc "$rc_file"

  local content
  content="$(cat "$rc_file")"
  assert_contains "$content" "# before"       "inject: preserves content before block"
  assert_contains "$content" "# after"        "inject: preserves content after block"
  if [[ "$content" == *'echo "old"'* ]]; then
    _fail "inject: replaces old block content"
  else
    _pass "inject: replaces old block content"
  fi
}

run_test_inject_is_idempotent() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local rc_file="$_TEST_TMPDIR/test_zshrc"
  echo "# base" > "$rc_file"

  _inject_into_rc "$rc_file"
  _inject_into_rc "$rc_file"
  _inject_into_rc "$rc_file"

  local count
  count="$(grep -c "kitsync-start" "$rc_file")"
  assert_eq "1" "$count" "inject: idempotent — only one kitsync block after 3 calls"
}

run_test_inject_multiline_no_corruption() {
  # Regression test for the BSD awk -v multiline bug that wiped .zshrc
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local rc_file="$_TEST_TMPDIR/test_zshrc"
  printf '# line1\n# line2\n# line3\n' > "$rc_file"

  _inject_into_rc "$rc_file"

  local content
  content="$(cat "$rc_file")"
  assert_contains "$content" "# line1"    "inject: multiline — line1 preserved"
  assert_contains "$content" "# line2"    "inject: multiline — line2 preserved"
  assert_contains "$content" "# line3"    "inject: multiline — line3 preserved"
  assert_contains "$content" "claude()"   "inject: multiline — wrapper inserted"
}

run_test_inject_update_creates_backup() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local rc_file="$_TEST_TMPDIR/test_zshrc"
  echo "# existing" > "$rc_file"

  # First inject (no markers → append, backup created for existing file)
  _inject_into_rc "$rc_file"
  # Second inject (markers exist → replace, backup created)
  _inject_into_rc "$rc_file"

  local backup_dir="${CLAUDE_HOME}/.kitsync/backups"
  local found
  found="$(ls "$backup_dir"/test_zshrc.*.bak 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$found" -ge 1 ]]; then
    _pass "inject: creates backup before modifying existing file"
  else
    _fail "inject: creates backup before modifying existing file" "no backup in $backup_dir"
  fi
}

# ---------------------------------------------------------------------------
# Test runner entry point
# ---------------------------------------------------------------------------
run_wrapper_tests() {
  printf "\n--- wrapper ---\n"
  run_test_backup_creates_file
  run_test_backup_skips_nonexistent_file
  run_test_backup_content_matches
  run_test_backup_prunes_to_5
  run_test_inject_appends_when_no_markers
  run_test_inject_replaces_existing_block
  run_test_inject_is_idempotent
  run_test_inject_multiline_no_corruption
  run_test_inject_update_creates_backup
}
