#!/usr/bin/env bash
# test/test_publish.sh
# publish: only what kitsync syncs, no secrets, no personal paths, private by
# default, and never without someone at the keyboard.

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

run_test_pb_publish() {
  local r h ch out kit
  r="$(mktemp -d)"; h="$r/home"; ch="$h/.claude"
  mkdir -p "$ch/skills/mine/node_modules/x" "$ch/skills/synced/account" "$ch/hooks" "$r/cwd"
  git -C "$ch" init -q
  cp "$_PROJECT_ROOT/templates/.gitignore.template" "$ch/.gitignore"
  echo "# mine" > "$ch/skills/mine/SKILL.md"
  echo "API_KEY=x" > "$ch/skills/mine/.env"
  echo dep > "$ch/skills/mine/node_modules/x/i.js"
  echo "# account skill" > "$ch/skills/synced/account/SKILL.md"
  printf 'python3 %s/.claude/hooks/x.py\n' "$h" > "$ch/hooks/run.sh"
  printf 'T=gh%s_%s\n' p "$(printf 'x%.0s' $(seq 1 36))" > "$ch/hooks/token.sh"

  out="$(cd "$r/cwd" && HOME="$h" CLAUDE_HOME="$ch" KITSYNC_NO_TTY=1 KITSYNC_ROOT="" \
    bash "$_PROJECT_ROOT/bin/claude-kitsync" publish </dev/null 2>&1)"
  assert_contains "$out" "needs a terminal" "PB: never publishes without someone at the keyboard"

  # A terminal that ticks everything, keeps the defaults and confirms (no gh)
  out="$(cd "$r/cwd" && HOME="$h" CLAUDE_HOME="$ch" PATH=/usr/bin:/bin KITSYNC_ROOT="$_PROJECT_ROOT" bash -c '
    for l in core paths sync init publish; do source "$KITSYNC_ROOT/lib/$l.sh"; done
    _has_tty() { return 0; }; _select_multi() { printf "1 2"; }; _select_menu() { printf 1; }
    _read_tty() { printf "%s" "$2"; }; confirm() { return 0; }
    set +e; cmd_publish' </dev/null 2>&1)"
  kit="$r/cwd/claude-kit"
  assert_contains "$out" "private repository" "PB: private unless public is chosen"
  assert_file_exists "$kit/skills/mine/SKILL.md" "PB: own skill published"
  assert_eq "" "$(cd "$kit" && find . -name .env -o -name node_modules -o -path '*synced*' | head -1)" \
    "PB: no secrets, dependencies or account skills"
  assert_eq "no" "$([[ -f "$kit/hooks/token.sh" ]] && echo yes || echo no)" "PB: a file holding a token is left out"
  assert_eq "python3 __CLAUDE_HOME__/hooks/x.py" "$(cat "$kit/hooks/run.sh")" "PB: personal paths never published"
  assert_contains "$(cat "$kit/README.md")" '- `skills/`' "PB: README lists the contents"
  rm -rf "$r"
}

run_publish_tests() {
  printf "\n=== test_publish.sh (publish) ===\n"
  export GIT_AUTHOR_NAME=kitsync-test GIT_AUTHOR_EMAIL=t@kitsync.local
  export GIT_COMMITTER_NAME=kitsync-test GIT_COMMITTER_EMAIL=t@kitsync.local
  run_test_pb_publish
}
