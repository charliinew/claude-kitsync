#!/usr/bin/env bash
# test/test_consult.sh
# status / log / diff: tell what the next push sends, what is incoming, and
# which machine sent what.

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"
source "$_HELPERS_DIR/test_autosync.sh"   # _as_setup / _as / _as_remote_file

_co_plain() { sed 's/\x1b\[[0-9;]*m//g'; }

run_test_co_log() {
  _as_setup
  local i out
  printf 'KITSYNC_MACHINE_NAME=work-laptop\n' >> "$_AS_B/.claude/.kitsync/local"
  for i in 1 2 3; do echo "# v$i" > "$_AS_B/.claude/CLAUDE.md"; _as "$_AS_B" push >/dev/null; done
  out="$(_as "$_AS_B" log -n 2 | _co_plain)"
  assert_eq "2" "$(grep -c '  kitsync: sync ' <<< "$out")" "CO: log -n 2 shows two syncs"
  assert_contains "$out" "(work-laptop)" "CO: log says which machine sent each sync"
  assert_contains "$out" "CLAUDE.md" "CO: log lists the files of each sync"
  rm -rf "$_AS_ROOT"
}

run_test_co_status_and_diff() {
  _as_setup
  local out
  echo "# local edit" > "$_AS_B/.claude/CLAUDE.md"
  mkdir -p "$_AS_A/.claude/agents" && echo x > "$_AS_A/.claude/agents/a.md"
  _as "$_AS_A" push -m fromA >/dev/null

  out="$(_as "$_AS_B" status | _co_plain)"
  assert_contains "$out" "modified:  CLAUDE.md" "CO: status shows what the next push sends"
  assert_contains "$out" "1 commit(s) to pull" "CO: status checks the remote for incoming commits"
  assert_contains "$out" "agents/a.md" "CO: status lists incoming files"
  assert_eq "0" "$(grep -c 'In sync' <<< "$out")" "CO: status never says in sync with pending work"

  out="$(_as "$_AS_B" diff | _co_plain)"
  assert_contains "$out" "Not committed yet" "CO: diff includes what is not committed yet"
  assert_eq "0" "$(grep -c '^diff --git' <<< "$out")" "CO: diff never dumps the full diff without a terminal"

  echo "# shared" > "$_AS_B/.claude/CLAUDE.md"
  _as "$_AS_B" pull >/dev/null
  out="$(_as "$_AS_B" status | _co_plain)"
  assert_contains "$out" "In sync" "CO: status says in sync when it is"
  rm -rf "$_AS_ROOT"
}

run_consult_tests() {
  printf "\n=== test_consult.sh (status / log / diff) ===\n"
  export GIT_AUTHOR_NAME=kitsync-test GIT_AUTHOR_EMAIL=t@kitsync.local
  export GIT_COMMITTER_NAME=kitsync-test GIT_COMMITTER_EMAIL=t@kitsync.local
  run_test_co_log
  run_test_co_status_and_diff
}
