#!/usr/bin/env bash
# test/test_hooks.sh
# Sync through Claude Code hooks: settings.json entries (idempotent, user
# hooks kept, Stop only in timer mode), the hook runtime, the command string
# as Claude Code runs it, and the migration away from the claude() wrapper.

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

# _hk_setup — fake $HOME: ~/.claude git repo (no remote), kitsync on ~/.local/bin
_hk_setup() {
  _HK_HOME="$(mktemp -d)"
  _HK_CH="$_HK_HOME/.claude"
  mkdir -p "$_HK_CH/.kitsync" "$_HK_HOME/.local/bin"
  git -C "$_HK_CH" init -q -b main
  ln -s "$_PROJECT_ROOT/bin/claude-kitsync" "$_HK_HOME/.local/bin/claude-kitsync"
  printf 'KITSYNC_PULL_MODE=auto\nKITSYNC_PUSH_MODE=end_of_session\n' > "$_HK_CH/.kitsync/config"
}

# _hk_lib <code> — bash code with the libs loaded, as the fake user
_hk_lib() {
  HOME="$_HK_HOME" ZDOTDIR="$_HK_HOME" CLAUDE_HOME="$_HK_CH" XDG_STATE_HOME="$_HK_HOME/.state" \
    KITSYNC_ROOT="$_PROJECT_ROOT" KITSYNC_NO_TTY=1 bash -c '
      for l in core paths profiles crypto sync wrapper init hooks upgrade; do source "$KITSYNC_ROOT/lib/$l.sh"; done
      KITSYNC_VERSION="$(cat "$KITSYNC_ROOT/VERSION")"
      set +e
      '"$1" </dev/null 2>&1
}

_hk_events() {
  python3 -c '
import json,sys
s=json.load(open(sys.argv[1]))
print(" ".join(sorted(ev for ev,gs in s.get("hooks",{}).items()
  if any("claude-kitsync _hook" in h.get("command","") for g in gs for h in g.get("hooks",[])))))' "$_HK_CH/settings.json"
}

run_test_hk_install() {
  _hk_setup
  printf '{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-validator"}]}]}}\n' \
    > "$_HK_CH/settings.json"
  _hk_lib 'hooks_install' >/dev/null
  assert_eq "SessionEnd SessionStart" "$(_hk_events)" "HK: start and end hooks installed"
  assert_contains "$(cat "$_HK_CH/settings.json")" "my-validator" "HK: user hooks kept"
  assert_contains "$(cat "$_HK_CH/settings.json")" '"model": "opus"' "HK: other settings kept"

  local before
  before="$(cat "$_HK_CH/settings.json")"
  _hk_lib 'hooks_install' >/dev/null
  assert_eq "$before" "$(cat "$_HK_CH/settings.json")" "HK: install is idempotent"

  sed -i.bak 's/end_of_session/timer/' "$_HK_CH/.kitsync/config" && rm -f "$_HK_CH/.kitsync/config.bak"
  _hk_lib 'hooks_install' >/dev/null
  assert_eq "SessionEnd SessionStart Stop" "$(_hk_events)" "HK: timer mode adds the Stop hook"
  sed -i.bak 's/timer/manual/' "$_HK_CH/.kitsync/config" && rm -f "$_HK_CH/.kitsync/config.bak"
  _hk_lib 'hooks_install' >/dev/null
  assert_eq "SessionEnd SessionStart" "$(_hk_events)" "HK: leaving timer mode removes the Stop hook"

  _hk_lib 'hooks_remove' >/dev/null
  assert_eq "" "$(_hk_events)" "HK: remove takes every kitsync hook out"
  assert_contains "$(cat "$_HK_CH/settings.json")" "my-validator" "HK: remove keeps user hooks"
  rm -rf "$_HK_HOME"
}

run_test_hk_runtime() {
  _hk_setup
  local f="$_HK_CH/.kitsync" out
  printf 'files:agents/"x".md\n' > "$f/conflict_pending"
  printf 'Not pushed — fix: settings.json\n' > "$f/sync-warning"
  printf 'updated\n' > "$f/pending-notice"
  out="$(_hk_lib 'cmd_hook session-start <<< "{}"')"
  assert_zero "$(python3 -c 'import json,sys; json.loads(sys.argv[1])["systemMessage"]' "$out" >/dev/null 2>&1; echo $?)" \
    "HK: session-start prints a valid systemMessage"
  assert_contains "$out" "sync conflict pending" "HK: conflict shown at session start"
  assert_contains "$out" "Not pushed" "HK: push warning shown at session start"
  assert_contains "$out" "updated from your other machines" "HK: pulled-changes notice shown"
  assert_eq "no no yes" "$([[ -f $f/sync-warning ]] && echo yes || echo no) $([[ -f $f/pending-notice ]] && echo yes || echo no) $([[ -f $f/conflict_pending ]] && echo yes || echo no)" \
    "HK: one-shot notices cleared, conflict kept until resolved"

  out="$(_hk_lib 'cmd_hook session-start <<< "{}"')"
  assert_contains "$out" "sync conflict pending" "HK: pending conflict shown again until resolved"
  out="$(_hk_lib 'cmd_hook session-end <<< "{}"')"
  assert_eq "" "$out" "HK: session-end prints nothing"

  # Timer mode: the Stop hook pushes at most once per period
  sed -i.bak 's/end_of_session/timer/' "$f/config" && rm -f "$f/config.bak"
  printf 'KITSYNC_PUSH_TIMER=30\n' >> "$f/config"
  local stamp="$_HK_CH/.git/kitsync-last-push"
  _hk_lib 'cmd_hook session-start <<< "{}"' >/dev/null
  assert_file_exists "$stamp" "HK: timer starts counting at session start"
  touch -t 202001010000 "$stamp"
  _hk_lib 'cmd_hook stop <<< "{}"' >/dev/null
  assert_eq "" "$(find "$stamp" -mmin +30)" "HK: Stop pushes once the period has passed"
  rm -rf "$_HK_HOME"
}

run_test_hk_command_string() {
  _hk_setup
  local cmd out
  cmd="$(_hk_lib '_hook_command session-start')"
  printf 'updated\n' > "$_HK_CH/.kitsync/pending-notice"
  # As Claude Code runs it: a shell, minimal PATH (GUI apps), JSON on stdin
  out="$(echo '{}' | env -i HOME="$_HK_HOME" PATH=/usr/bin:/bin CLAUDE_HOME="$_HK_CH" sh -c "$cmd")"
  assert_contains "$out" "systemMessage" "HK: hook command finds kitsync without the user's PATH"

  local empty
  empty="$(mktemp -d)"
  out="$(echo '{}' | env -i HOME="$empty" PATH=/usr/bin:/bin sh -c "$cmd"; echo "rc=$?")"
  rmdir "$empty"
  assert_eq "rc=0" "$out" "HK: machine without kitsync: silent, exit 0"
  rm -rf "$_HK_HOME"
}

run_test_hk_migration() {
  _hk_setup
  local rc="$_HK_HOME/.zshrc"
  _hk_lib 'install_wrapper_zsh' >/dev/null
  printf 'alias ll="ls -l"\n' >> "$rc"
  _hk_lib 'post_upgrade' >/dev/null
  assert_eq "0" "$(grep -c '^# kitsync-start$' "$rc")" "HK: upgrade removes the claude() wrapper"
  assert_eq "1" "$(grep -c '^alias ll=' "$rc")" "HK: rest of the rc kept"
  assert_eq "SessionEnd SessionStart" "$(_hk_events)" "HK: upgrade installs the hooks instead"
  rm -rf "$_HK_HOME"
}

run_hooks_tests() {
  printf "\n=== test_hooks.sh (sync through Claude Code hooks) ===\n"
  if ! command -v python3 &>/dev/null; then
    printf "  SKIP  HK: python3 not installed\n"
    return 0
  fi
  export GIT_AUTHOR_NAME=kitsync-test GIT_AUTHOR_EMAIL=t@kitsync.local
  export GIT_COMMITTER_NAME=kitsync-test GIT_COMMITTER_EMAIL=t@kitsync.local
  run_test_hk_install
  run_test_hk_runtime
  run_test_hk_command_string
  run_test_hk_migration
}
