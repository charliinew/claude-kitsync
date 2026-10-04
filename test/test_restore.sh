#!/usr/bin/env bash
# test/test_restore.sh
# restore: every backup goes back where it came from — never a guessed path
# in $HOME — and nothing is picked without a choice.

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

_rs_cli() {
  HOME="$_RS_HOME" ZDOTDIR="$_RS_HOME" CLAUDE_HOME="$_RS_HOME/.claude" XDG_STATE_HOME="$_RS_HOME/.state" \
    KITSYNC_NO_TTY=1 KITSYNC_ROOT="" bash "$_PROJECT_ROOT/bin/claude-kitsync" "$@" </dev/null 2>&1
}

run_test_rs_targets() {
  _RS_HOME="$(mktemp -d)"
  local b="$_RS_HOME/.claude/.kitsync/backups" out
  mkdir -p "$b"
  git -C "$_RS_HOME/.claude" init -q
  echo "user global excludes" > "$_RS_HOME/.gitignore"
  echo '{"model":"now"}' > "$_RS_HOME/.claude/settings.json"
  echo '{"model":"before"}' > "$b/settings.json.20260101T000000.bak"
  echo 'old allowlist' > "$b/.gitignore.20260101T000000.bak"
  echo 'alias old=1' > "$b/.zshrc.20260101T000000.bak"

  out="$(_rs_cli restore)"
  assert_contains "$out" "Name it" "RS: without a terminal nothing is restored by default"

  _rs_cli restore settings.json.20260101T000000.bak >/dev/null
  assert_eq '{"model":"before"}' "$(cat "$_RS_HOME/.claude/settings.json")" "RS: settings.json goes back to ~/.claude"
  assert_file_not_exists "$_RS_HOME/settings.json" "RS: never written to ~/settings.json"
  assert_eq '{"model":"now"}' "$(cat "$(ls "$b"/settings.json.*.bak | grep -v 20260101 | head -1)")" \
    "RS: the replaced version is backed up first"

  _rs_cli restore .gitignore.20260101T000000.bak >/dev/null
  assert_eq "user global excludes" "$(cat "$_RS_HOME/.gitignore")" "RS: ~/.gitignore is never touched"
  assert_eq "old allowlist" "$(cat "$_RS_HOME/.claude/.gitignore")" "RS: the allowlist goes back to ~/.claude"

  _rs_cli restore .zshrc.20260101T000000.bak >/dev/null
  assert_eq "alias old=1" "$(cat "$_RS_HOME/.zshrc")" "RS: rc backups go back to the rc file"

  out="$(_rs_cli restore ../../../etc/passwd)"
  assert_contains "$out" "Not a kitsync backup" "RS: only kitsync backups can be restored"
  rm -rf "$_RS_HOME"
}

run_restore_tests() {
  printf "\n=== test_restore.sh (restore) ===\n"
  run_test_rs_targets
}
