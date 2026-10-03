#!/usr/bin/env bash
# test/test_autosync.sh
# What the claude() wrapper triggers: pull --auto (never touches uncommitted
# edits, honours selective pull), push guard against half-merged files,
# per-machine lock, and a wrapper that parses in bash and zsh.

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

# _as_setup — machines A and B initialised on the same bare remote.
# Sets: _AS_ROOT, _AS_A, _AS_B (homes)
_as_setup() {
  _AS_ROOT="$(mktemp -d)"
  _AS_A="$_AS_ROOT/a"; _AS_B="$_AS_ROOT/b"
  git init -q --bare "$_AS_ROOT/remote.git"
  git -C "$_AS_ROOT/remote.git" symbolic-ref HEAD refs/heads/main
  mkdir -p "$_AS_A/.claude" "$_AS_B/.claude"
  printf '{\n  "model": "opus"\n}\n' > "$_AS_A/.claude/settings.json"
  printf '# shared\n' > "$_AS_A/.claude/CLAUDE.md"
  _as "$_AS_A" init --remote "$_AS_ROOT/remote.git" >/dev/null
  _as "$_AS_B" init --remote "$_AS_ROOT/remote.git" >/dev/null
}

# _as <home> <cli args...> — the CLI as the user of <home>, no terminal
_as() {
  local h="$1"; shift
  HOME="$h" ZDOTDIR="$h" CLAUDE_HOME="$h/.claude" XDG_STATE_HOME="$h/.state" \
    KITSYNC_NO_TTY=1 KITSYNC_ROOT="" bash "$_PROJECT_ROOT/bin/claude-kitsync" "$@" </dev/null 2>&1
}

_as_remote_file() { git -C "$_AS_ROOT/remote.git" show "main:$1" 2>/dev/null; }

run_test_as_wrapper_parses() {
  local w
  w="$(mktemp)"
  bash -c "source '$_PROJECT_ROOT/lib/core.sh'; source '$_PROJECT_ROOT/lib/wrapper.sh'; generate_wrapper" > "$w"
  bash -n "$w" 2>/dev/null
  assert_zero "$?" "AS: wrapper parses in bash"
  if command -v zsh &>/dev/null; then
    zsh -n "$w" 2>/dev/null
    assert_zero "$?" "AS: wrapper parses in zsh"
  fi
  rm -f "$w"
}

run_test_as_pull_keeps_uncommitted() {
  _as_setup
  # B edits settings.json without pushing; A changes the same line remotely
  printf '{\n  "model": "haiku"\n}\n' > "$_AS_B/.claude/settings.json"
  printf '{\n  "model": "sonnet"\n}\n' > "$_AS_A/.claude/settings.json"
  _as "$_AS_A" push -m remote >/dev/null

  _as "$_AS_B" pull --auto >/dev/null
  assert_contains "$(cat "$_AS_B/.claude/settings.json")" '"haiku"' \
    "AS: pull --auto leaves uncommitted edits alone"
  assert_eq "0" "$(grep -c '^<<<<<<<' "$_AS_B/.claude/settings.json")" \
    "AS: no conflict markers written by pull --auto"
  rm -rf "$_AS_ROOT"
}

run_test_as_pull_applies_and_filters() {
  _as_setup
  # B does not pull CLAUDE.md
  local cfg="$_AS_B/.claude/.kitsync/local"   # per-machine, never synced
  sed -i.bak 's/^KITSYNC_PULL_ITEMS=.*/KITSYNC_PULL_ITEMS=agents,settings.json/' "$cfg" && rm -f "$cfg.bak"
  printf '{\n  "model": "sonnet"\n}\n' > "$_AS_A/.claude/settings.json"
  printf '# changed on A\n' > "$_AS_A/.claude/CLAUDE.md"
  _as "$_AS_A" push -m remote >/dev/null

  _as "$_AS_B" pull --auto >/dev/null
  assert_contains "$(cat "$_AS_B/.claude/settings.json")" '"sonnet"' "AS: pull --auto applies remote changes"
  assert_eq "# shared" "$(cat "$_AS_B/.claude/CLAUDE.md")" "AS: pull --auto honours the pull selection"
  assert_file_exists "$_AS_B/.claude/.kitsync/pending-notice" "AS: new commits leave a notice for next launch"
  rm -rf "$_AS_ROOT"
}

run_test_as_push_guard() {
  _as_setup
  local ch="$_AS_B/.claude"
  mkdir -p "$ch/agents"
  printf 'a\n<<<<<<< Updated upstream\nx\n=======\ny\n>>>>>>> Stashed changes\n' > "$ch/agents/broken.md"
  printf '# fine\n' > "$ch/agents/ok.md"
  _as "$_AS_B" push --auto "t" >/dev/null
  assert_eq "" "$(_as_remote_file agents/broken.md)" "AS: file with new conflict markers not pushed"
  assert_eq "# fine" "$(_as_remote_file agents/ok.md)" "AS: other files still pushed"
  assert_file_exists "$ch/.kitsync/sync-warning" "AS: blocked push leaves a warning for next launch"

  # Markers already in the committed file (docs about merges) do not block edits
  printf 'Example:\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> branch\n' > "$ch/agents/doc.md"
  git -C "$ch" add agents/doc.md && git -C "$ch" commit -q -m doc
  printf 'more\n' >> "$ch/agents/doc.md"
  _as "$_AS_B" push --auto "t2" >/dev/null
  assert_contains "$(_as_remote_file agents/doc.md)" "more" "AS: documented markers do not block a push"

  printf '{ "model": ' > "$ch/settings.json"
  _as "$_AS_B" push --auto "t3" >/dev/null
  assert_contains "$(_as_remote_file settings.json)" '"opus"' "AS: invalid settings.json not pushed"
  rm -rf "$_AS_ROOT"
}

run_test_as_lock() {
  _as_setup
  local gd="$_AS_B/.claude/.git" sleeper
  printf '{\n  "model": "sonnet"\n}\n' > "$_AS_A/.claude/settings.json"
  _as "$_AS_A" push -m remote >/dev/null

  # Lock held by a live process: pull --auto does nothing
  sleep 30 & sleeper=$!
  mkdir "$gd/kitsync.lock" && echo "$sleeper" > "$gd/kitsync.lock/pid"
  _as "$_AS_B" pull --auto >/dev/null
  assert_contains "$(cat "$_AS_B/.claude/settings.json")" '"opus"' "AS: pull --auto skips while another sync runs"
  kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null

  # Holder gone: the stale lock is cleared
  _as "$_AS_B" pull --auto >/dev/null
  assert_contains "$(cat "$_AS_B/.claude/settings.json")" '"sonnet"' "AS: stale lock cleared"
  assert_eq "no" "$([[ -d "$gd/kitsync.lock" ]] && echo yes || echo no)" "AS: lock released after sync"
  rm -rf "$_AS_ROOT"
}

run_test_as_migrations() {
  _as_setup
  local ch="$_AS_B/.claude"
  # Pre-1.1.15 setup: .kitsync/config untracked on this machine, tracked on
  # the remote — the pull used to fail on "untracked files would be overwritten"
  git -C "$ch" rm -q --cached .kitsync/config && git -C "$ch" commit -q -m "old setup"
  printf '{\n  "model": "sonnet"\n}\n' > "$_AS_A/.claude/settings.json"
  _as "$_AS_A" push -m remote >/dev/null
  _as "$_AS_B" pull --auto >/dev/null
  assert_contains "$(cat "$ch/settings.json")" '"sonnet"' "AS: machine with untracked .kitsync/config still pulls"

  # Path-token migration commits the committed file only, never local edits
  printf '{"hook":"%s/x"}\n' "$_AS_B" > "$ch/settings.json"
  git -C "$ch" -c filter.kitsync-paths.clean=cat add settings.json
  git -C "$ch" commit -q -m "absolute paths"
  printf '{"hook":"%s/x","local":"edit"}\n' "$_AS_B" > "$ch/settings.json"
  HOME="$_AS_B" CLAUDE_HOME="$ch" _L="$_PROJECT_ROOT/lib" bash -c \
    'for l in core paths; do source "$_L/$l.sh"; done; paths_filter_setup' >/dev/null 2>&1
  assert_contains "$(git -C "$ch" show HEAD:settings.json)" "__HOME__/x" "AS: migration tokenizes the committed file"
  assert_eq "0" "$(git -C "$ch" show HEAD:settings.json | grep -c '"local"')" "AS: migration does not commit local edits"
  assert_contains "$(cat "$ch/settings.json")" '"local":"edit"' "AS: local edit kept on disk"
  rm -rf "$_AS_ROOT"
}

run_autosync_tests() {
  printf "\n=== test_autosync.sh (wrapper-triggered sync) ===\n"
  export GIT_AUTHOR_NAME=kitsync-test GIT_AUTHOR_EMAIL=t@kitsync.local
  export GIT_COMMITTER_NAME=kitsync-test GIT_COMMITTER_EMAIL=t@kitsync.local
  run_test_as_wrapper_parses
  run_test_as_pull_keeps_uncommitted
  run_test_as_pull_applies_and_filters
  run_test_as_push_guard
  run_test_as_lock
  run_test_as_migrations
}
