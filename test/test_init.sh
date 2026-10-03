#!/usr/bin/env bash
# test/test_init.sh
# init: re-run keeps .kitsync/config, no starter kit without a terminal,
# non-allowlist .gitignore replaced, LOCAL choices survive the first push,
# gh URL protocol, git errors shown

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

# _ini_setup — fake $HOME and an empty bare remote. Sets: _INI_HOME, _INI_CH, _INI_REMOTE
_ini_setup() {
  _INI_HOME="$(mktemp -d)"
  _INI_CH="$_INI_HOME/.claude"
  _INI_REMOTE="$_INI_HOME/remote.git"
  git init -q --bare "$_INI_REMOTE"
  git -C "$_INI_REMOTE" symbolic-ref HEAD refs/heads/main
}

# _ini_env <cmd...> — run as the fake user, never prompting
_ini_env() {
  HOME="$_INI_HOME" ZDOTDIR="$_INI_HOME" CLAUDE_HOME="$_INI_CH" \
    XDG_STATE_HOME="$_INI_HOME/.state" KITSYNC_NO_TTY=1 KITSYNC_ROOT="" "$@" </dev/null
}

# _ini_cli <args...> — the CLI, output without colours
_ini_cli() {
  _ini_env bash "$_PROJECT_ROOT/bin/claude-kitsync" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}

# _ini_lib <script> — run bash code with every lib loaded (to stub a function)
_ini_lib() {
  _ini_env env KITSYNC_ROOT="$_PROJECT_ROOT" bash -c '
    for _l in core paths sync wrapper init install-kit publish settings profiles crypto upgrade doctor; do
      source "$KITSYNC_ROOT/lib/$_l.sh"
    done
    KITSYNC_VERSION="$(cat "$KITSYNC_ROOT/VERSION")"
    '"$1" 2>&1
}

run_test_ini_rerun_keeps_config() {
  _ini_setup
  _ini_cli init --remote "$_INI_REMOTE" >/dev/null
  local cfg="$_INI_CH/.kitsync/config"
  printf 'KITSYNC_ENCRYPT=true\nKITSYNC_UPGRADE_CHANNEL=dev\nKITSYNC_PROFILES_WORK_URL=git@example.com:w.git\n' >> "$cfg"

  _ini_cli init >/dev/null
  assert_contains "$(cat "$cfg")" "KITSYNC_ENCRYPT=true" "INI: re-run keeps the encryption flag"
  assert_contains "$(cat "$cfg")" "KITSYNC_UPGRADE_CHANNEL=dev" "INI: re-run keeps the upgrade channel"
  assert_contains "$(cat "$cfg")" "KITSYNC_PROFILES_WORK_URL=" "INI: re-run keeps other profiles"
  assert_eq "1" "$(grep -c '^KITSYNC_PULL_MODE=' "$cfg")" "INI: re-run keeps a single pull mode"
  rm -rf "$_INI_HOME"
}

run_test_ini_no_kit_without_tty() {
  _ini_setup
  local out
  out="$(_ini_cli init --remote "$_INI_REMOTE")"
  assert_contains "$out" "starter config not imported" "INI: no terminal, no starter kit"
  assert_eq "no" "$([[ -d "$_INI_CH/agents" ]] && echo yes || echo no)" \
    "INI: no kit agents copied without a terminal"
  rm -rf "$_INI_HOME"
}

run_test_ini_replaces_open_gitignore() {
  _ini_setup
  # ~/.claude versioned by hand: permissive .gitignore, a conversation committed
  mkdir -p "$_INI_CH/projects/p"
  git -C "$_INI_CH" init -q -b main
  printf 'node_modules/\n' > "$_INI_CH/.gitignore"
  echo '{"chat":"secret"}' > "$_INI_CH/projects/p/s.jsonl"
  echo "# me" > "$_INI_CH/CLAUDE.md"
  git -C "$_INI_CH" add -A
  git -C "$_INI_CH" commit -q -m manual

  _ini_cli init --remote "$_INI_REMOTE" >/dev/null
  assert_eq "*" "$(grep -v '^[[:space:]]*\(#\|$\)' "$_INI_CH/.gitignore" | head -1)" \
    "INI: permissive .gitignore replaced by the allowlist"
  assert_contains "$(cat "$_INI_CH"/.kitsync/backups/.gitignore.*.bak 2>/dev/null)" "node_modules/" \
    "INI: previous .gitignore backed up"
  assert_eq "" "$(git -C "$_INI_CH" ls-files projects)" "INI: excluded files untracked"
  assert_file_exists "$_INI_CH/projects/p/s.jsonl" "INI: untracked files kept on disk"
  assert_eq "" "$(git -C "$_INI_REMOTE" ls-tree -r --name-only main -- projects 2>/dev/null)" \
    "INI: conversations never reach the remote"
  rm -rf "$_INI_HOME"
}

run_test_ini_local_choice_survives_push() {
  _ini_setup
  # Remote already holds a config
  local other="$_INI_HOME/other"
  git clone -q "$_INI_REMOTE" "$other" 2>/dev/null
  printf 'line1\nREMOTE\n' > "$other/CLAUDE.md"
  git -C "$other" add -A && git -C "$other" commit -q -m remote
  git -C "$other" push -q origin HEAD:main 2>/dev/null

  # Fresh ~/.claude with its own CLAUDE.md; the user types "l" at the real
  # prompt (lowercase: the old ${x^^} crashed on macOS's bash 3.2)
  mkdir -p "$_INI_CH"
  printf 'line1\nLOCAL\n' > "$_INI_CH/CLAUDE.md"
  local out
  out="$(_ini_lib '
    _has_tty() { return 0; }
    _select_menu() { printf 1; }
    _select_multi() { printf ""; }
    _read_tty() { printf "%s" "${2:-}"; }
    _init_read_choice() { printf l; }
    set +e
    cmd_init --remote "'"$_INI_REMOTE"'"')"
  assert_contains "$out" "Conflict: CLAUDE.md" "INI: conflict prompt shown"
  assert_eq "0" "$(grep -c 'bad substitution' <<< "$out")" "INI: conflict prompt works on bash 3.2"

  assert_eq "LOCAL" "$(git -C "$_INI_REMOTE" show main:CLAUDE.md 2>/dev/null | tail -1)" \
    "INI: LOCAL choice reaches the remote"
  assert_eq "LOCAL" "$(tail -1 "$_INI_CH/CLAUDE.md")" "INI: LOCAL choice kept on disk"
  rm -rf "$_INI_HOME"
}

run_test_ini_conflicts_remote_side() {
  _ini_setup
  local a="$_INI_HOME/a" out
  # Machine A pushes a settings.json with its own paths, and a CLAUDE.md
  mkdir -p "$a/.claude"
  printf '{"hook":"%s/.claude/hooks/x.sh"}\n' "$a" > "$a/.claude/settings.json"
  printf 'from A\n' > "$a/.claude/CLAUDE.md"
  HOME="$a" ZDOTDIR="$a" CLAUDE_HOME="$a/.claude" XDG_STATE_HOME="$a/.state" KITSYNC_NO_TTY=1 \
    KITSYNC_ROOT="" bash "$_PROJECT_ROOT/bin/claude-kitsync" init --remote "$_INI_REMOTE" </dev/null >/dev/null 2>&1

  # Machine B: same settings (its own paths), different CLAUDE.md, no terminal
  mkdir -p "$_INI_CH"
  printf '{"hook":"%s/.claude/hooks/x.sh"}\n' "$_INI_HOME" > "$_INI_CH/settings.json"
  printf 'from B\n' > "$_INI_CH/CLAUDE.md"
  out="$(_ini_cli init --remote "$_INI_REMOTE")"

  assert_eq "0" "$(grep -c 'Conflict: settings.json' <<< "$out")" \
    "INI: same settings on two machines is not a conflict (path tokens)"
  assert_contains "$out" "Conflict: CLAUDE.md" "INI: real difference reported"
  assert_eq "from A" "$(cat "$_INI_CH/CLAUDE.md")" "INI: no terminal, remote version wins"
  assert_eq "from B" "$(cat "$_INI_CH"/.kitsync/backups/init-*/CLAUDE.md 2>/dev/null)" \
    "INI: local version backed up before the remote replaces it"
  assert_contains "$out" "--- remote: CLAUDE.md" "INI: diff labels the remote side"
  rm -rf "$_INI_HOME"
}

run_test_ini_gh_url_protocol() {
  _ini_setup
  local bin="$_INI_HOME/bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\n[ "$1 $2 $3" = "config get git_protocol" ] && echo "$GH_PROTO"\n' > "$bin/gh"
  chmod +x "$bin/gh"
  assert_eq "https://github.com/me/cfg.git" \
    "$(PATH="$bin:$PATH" GH_PROTO=https _ini_lib '_gh_clone_url me/cfg')" "INI: gh https → HTTPS URL"
  assert_eq "git@github.com:me/cfg.git" \
    "$(PATH="$bin:$PATH" GH_PROTO=ssh _ini_lib '_gh_clone_url me/cfg')" "INI: gh ssh → SSH URL"
  rm -rf "$_INI_HOME"
}

run_test_ini_push_error_shown() {
  _ini_setup
  local out
  out="$(_ini_cli init --remote "$_INI_HOME/missing.git")"
  assert_contains "$out" "Push failed" "INI: failed push reported"
  assert_contains "$out" "missing.git" "INI: git's own error shown on push failure"
  rm -rf "$_INI_HOME"
}

run_init_tests() {
  printf "\n=== test_init.sh (init) ===\n"
  export GIT_AUTHOR_NAME=kitsync-test GIT_AUTHOR_EMAIL=t@kitsync.local
  export GIT_COMMITTER_NAME=kitsync-test GIT_COMMITTER_EMAIL=t@kitsync.local
  run_test_ini_rerun_keeps_config
  run_test_ini_no_kit_without_tty
  run_test_ini_replaces_open_gitignore
  run_test_ini_local_choice_survives_push
  run_test_ini_conflicts_remote_side
  run_test_ini_gh_url_protocol
  run_test_ini_push_error_shown
}
