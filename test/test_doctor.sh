#!/usr/bin/env bash
# test/test_doctor.sh
# doctor: detects a broken sync (unreachable remote, unpushed commits, stuck
# rebase) and leaks (non-allowlist .gitignore, excluded files tracked)

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

# _doc_setup — fake $HOME: ~/.claude pushed to a local bare remote
# Sets: _DOC_HOME, _DOC_CH
_doc_setup() {
  _DOC_HOME="$(mktemp -d)"
  _DOC_CH="$_DOC_HOME/.claude"
  git init -q --bare "$_DOC_HOME/remote.git"
  git -C "$_DOC_HOME/remote.git" symbolic-ref HEAD refs/heads/main
  mkdir -p "$_DOC_CH/.kitsync"
  git -C "$_DOC_CH" init -q -b main
  cp "$_PROJECT_ROOT/templates/.gitignore.template" "$_DOC_CH/.gitignore"
  echo "# me" > "$_DOC_CH/CLAUDE.md"
  git -C "$_DOC_CH" add -A
  git -C "$_DOC_CH" commit -q -m init
  git -C "$_DOC_CH" remote add origin "$_DOC_HOME/remote.git"
  git -C "$_DOC_CH" push -q -u origin main 2>/dev/null
  git -C "$_DOC_CH" config filter.kitsync-paths.clean cat
}

# _doc_run — doctor output (no colours) followed by "rc=<exit code>"
_doc_run() {
  local out rc
  out="$(HOME="$_DOC_HOME" ZDOTDIR="$_DOC_HOME" CLAUDE_HOME="$_DOC_CH" \
    XDG_STATE_HOME="$_DOC_HOME/.state" KITSYNC_OFFLINE=1 KITSYNC_ROOT="" \
    bash "$_PROJECT_ROOT/bin/claude-kitsync" doctor </dev/null 2>&1)"
  rc=$?
  printf '%s\nrc=%s\n' "$(sed 's/\x1b\[[0-9;]*m//g' <<< "$out")" "$rc"
}

run_test_doc_healthy() {
  _doc_setup
  local out
  out="$(_doc_run)"
  assert_contains "$out" "rc=0" "DOC: healthy setup exits 0"
  assert_contains "$out" "Remote reachable" "DOC: reachable remote reported"
  assert_contains "$out" "In sync with the remote" "DOC: in-sync state reported"
  assert_eq "0" "$(grep -c 'ERROR' <<< "$out")" "DOC: healthy setup has no error"
  rm -rf "$_DOC_HOME"
}

run_test_doc_broken_sync() {
  _doc_setup
  local out
  # Unpushed commit, then a remote that no longer exists
  echo "# more" >> "$_DOC_CH/CLAUDE.md"
  git -C "$_DOC_CH" commit -q -am local
  out="$(_doc_run)"
  assert_contains "$out" "1 local commit(s) not pushed" "DOC: unpushed commits reported"

  mv "$_DOC_HOME/remote.git" "$_DOC_HOME/gone.git"
  out="$(_doc_run)"
  assert_contains "$out" "Remote unreachable" "DOC: unreachable remote is an error"
  assert_contains "$out" "rc=1" "DOC: unreachable remote exits 1"
  mv "$_DOC_HOME/gone.git" "$_DOC_HOME/remote.git"

  mkdir -p "$_DOC_CH/.git/rebase-merge"
  out="$(_doc_run)"
  assert_contains "$out" "rebase is stuck" "DOC: stuck rebase reported"
  assert_contains "$out" "rebase --abort" "DOC: stuck rebase comes with its fix"
  rm -rf "$_DOC_HOME"
}

run_test_doc_leaks() {
  _doc_setup
  local out
  # Excluded file forced in, then the allowlist replaced
  mkdir -p "$_DOC_CH/projects/p"
  echo '{"chat":"secret"}' > "$_DOC_CH/projects/p/s.jsonl"
  git -C "$_DOC_CH" add -f projects/p/s.jsonl
  git -C "$_DOC_CH" commit -q -m oops
  out="$(_doc_run)"
  assert_contains "$out" "should not be synced, e.g.: projects/p/s.jsonl" \
    "DOC: tracked excluded file reported"

  printf 'node_modules/\n' > "$_DOC_CH/.gitignore"
  out="$(_doc_run)"
  assert_contains "$out" "not kitsync's allowlist" "DOC: non-allowlist .gitignore reported"
  assert_contains "$out" "rc=1" "DOC: leaks exit 1"
  rm -rf "$_DOC_HOME"
}

run_doctor_tests() {
  printf "\n=== test_doctor.sh (doctor) ===\n"
  export GIT_AUTHOR_NAME=kitsync-test GIT_AUTHOR_EMAIL=t@kitsync.local
  export GIT_COMMITTER_NAME=kitsync-test GIT_COMMITTER_EMAIL=t@kitsync.local
  run_test_doc_healthy
  run_test_doc_broken_sync
  run_test_doc_leaks
}
