#!/usr/bin/env bash
# test/test_profiles.sh
# Profiles: switching swaps this machine's synced config for the profile's —
# never pushes one profile's files into another's repository.

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"
source "$_HELPERS_DIR/test_autosync.sh"   # _as_setup / _as / _as_remote_file

# _pr_setup — A on the "perso" remote (as profile "default") with a personal
# agent; a "work" remote set up from a work laptop. Sets: _PR_WORK
_pr_setup() {
  _as_setup
  mkdir -p "$_AS_A/.claude/agents"
  echo "# perso agent" > "$_AS_A/.claude/agents/perso.md"
  _as "$_AS_A" push -m perso >/dev/null
  _PR_WORK="$_AS_ROOT/work.git"
  git init -q --bare "$_PR_WORK"
  git -C "$_PR_WORK" symbolic-ref HEAD refs/heads/main
  mkdir -p "$_AS_ROOT/wl/.claude"
  echo "# work rules" > "$_AS_ROOT/wl/.claude/CLAUDE.md"
  _as "$_AS_ROOT/wl" init --remote "$_PR_WORK" >/dev/null
}

_pr_work_files() { git -C "$_PR_WORK" ls-tree -r --name-only main 2>/dev/null; }

run_test_pr_switch_swaps_config() {
  _pr_setup
  local ca="$_AS_A/.claude" out
  out="$(_as "$_AS_A" profile add work "$_PR_WORK")"
  assert_contains "$out" "profile switch work" "PR: profile add without a terminal does not switch"
  assert_contains "$(_as "$_AS_A" profile list)" "default" "PR: still on the first profile"

  _as "$_AS_A" profile switch work >/dev/null
  _as "$_AS_A" pull --auto >/dev/null
  _as "$_AS_A" push --auto x >/dev/null
  assert_eq "0" "$(_pr_work_files | grep -c 'perso.md')" "PR: personal files never reach the work repository"
  assert_eq "# work rules" "$(cat "$ca/CLAUDE.md")" "PR: this machine now has the work config"
  assert_eq "no" "$([[ -f "$ca/agents/perso.md" ]] && echo yes || echo no)" "PR: the personal agent left the working copy"
  assert_file_exists "$(ls -d "$ca"/.kitsync/backups/profile-default-*/agents/perso.md 2>/dev/null | head -1)" \
    "PR: previous profile's files backed up"
  assert_contains "$(_as "$_AS_A" profile list)" "work" "PR: profile registry survives the switch"

  _as "$_AS_A" profile switch default >/dev/null
  assert_file_exists "$ca/agents/perso.md" "PR: switching back brings the personal config back"
  rm -rf "$_AS_ROOT"
}

run_test_pr_empty_profile_seeded() {
  _pr_setup
  local fresh="$_AS_ROOT/fresh.git"
  git init -q --bare "$fresh"
  _as "$_AS_A" profile add fresh "$fresh" >/dev/null
  _as "$_AS_A" profile switch fresh >/dev/null
  assert_eq "# perso agent" "$(git -C "$fresh" show main:agents/perso.md 2>/dev/null)" \
    "PR: an empty profile starts with this machine's config"
  rm -rf "$_AS_ROOT"
}

run_profiles_tests() {
  printf "\n=== test_profiles.sh (profiles) ===\n"
  export GIT_AUTHOR_NAME=kitsync-test GIT_AUTHOR_EMAIL=t@kitsync.local
  export GIT_COMMITTER_NAME=kitsync-test GIT_COMMITTER_EMAIL=t@kitsync.local
  run_test_pr_switch_swaps_config
  run_test_pr_empty_profile_seeded
}
