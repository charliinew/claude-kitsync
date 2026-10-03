#!/usr/bin/env bash
# test/test_pull.sh
# pull: a change that never reached the remote is never dropped without
# asking — background pull, no-terminal pull, file-by-file choices, --force.

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"
source "$_HELPERS_DIR/test_autosync.sh"   # _as_setup / _as / _as_remote_file

# _pl_tty <home> <answer> <cli args...> — the CLI with a "terminal" that
# answers <answer> (r/l) at every conflict prompt
_pl_tty() {
  local h="$1" ans="$2"; shift 2
  HOME="$h" ZDOTDIR="$h" CLAUDE_HOME="$h/.claude" XDG_STATE_HOME="$h/.state" \
    KITSYNC_ROOT="$_PROJECT_ROOT" _PL_ANS="$ans" bash -c '
      for l in core paths profiles crypto sync wrapper init hooks; do source "$KITSYNC_ROOT/lib/$l.sh"; done
      _has_tty() { return 0; }
      _init_read_choice() { printf "%s" "$_PL_ANS"; }
      set +e
      "$@"
    ' _ "$@" </dev/null 2>&1
}

# _pl_conflict — A and B change the same line of CLAUDE.md; A pushes first,
# B commits locally (its push hit the conflict)
_pl_conflict() {
  _as_setup
  printf '# shared\nrule: A\n' > "$_AS_A/.claude/CLAUDE.md"
  _as "$_AS_A" push -m a >/dev/null
  printf '# shared\nrule: B\n' > "$_AS_B/.claude/CLAUDE.md"
  _as "$_AS_B" push --auto b >/dev/null
}

run_test_pl_auto_keeps_unpushed() {
  _pl_conflict
  local cb="$_AS_B/.claude"
  _as "$_AS_B" pull --auto >/dev/null
  assert_eq "rule: B" "$(tail -1 "$cb/CLAUDE.md")" "PL: background pull keeps a commit that failed to push"
  assert_contains "$(cat "$cb/.kitsync/conflict_pending" 2>/dev/null)" "CLAUDE.md" \
    "PL: the conflict stays reported until resolved"
  assert_eq "rule: A" "$(_as_remote_file CLAUDE.md | tail -1)" "PL: remote untouched"
  rm -rf "$_AS_ROOT"
}

run_test_pl_merges_different_lines() {
  _as_setup
  printf '# shared\nline2\nline3\n' > "$_AS_A/.claude/CLAUDE.md"
  _as "$_AS_A" push -m base >/dev/null
  _as "$_AS_B" pull --auto >/dev/null
  printf '# shared (A)\nline2\nline3\n' > "$_AS_A/.claude/CLAUDE.md"
  _as "$_AS_A" push -m a >/dev/null
  printf '# shared\nline2\nline3 (B)\n' > "$_AS_B/.claude/CLAUDE.md"
  git -C "$_AS_B/.claude" commit -qam b
  _as "$_AS_B" pull --auto >/dev/null
  assert_eq "# shared (A)|line3 (B)" "$(sed -n '1p;3p' "$_AS_B/.claude/CLAUDE.md" | paste -sd'|' -)" \
    "PL: changes to different lines of one file merge"
  rm -rf "$_AS_ROOT"
}

run_test_pl_choices() {
  _pl_conflict
  local out
  out="$(_pl_tty "$_AS_B" l sync_pull)"
  assert_contains "$out" "Conflict: CLAUDE.md" "PL: conflict shown with its diff"
  assert_eq "rule: B" "$(_as_remote_file CLAUDE.md | tail -1)" "PL: local choice is pushed right away"
  assert_eq "no" "$([[ -f "$_AS_B/.claude/.kitsync/conflict_pending" ]] && echo yes || echo no)" \
    "PL: resolved conflict no longer reported"
  rm -rf "$_AS_ROOT"

  _pl_conflict
  _pl_tty "$_AS_B" r sync_pull >/dev/null
  assert_eq "rule: A" "$(tail -1 "$_AS_B/.claude/CLAUDE.md")" "PL: remote choice applied"
  assert_eq "rule: B" "$(tail -1 "$_AS_B"/.claude/.kitsync/backups/pull-*/CLAUDE.md 2>/dev/null)" \
    "PL: remote choice backs up the local version"
  rm -rf "$_AS_ROOT"
}

run_test_pl_no_terminal_loses_nothing() {
  _as_setup
  local ca="$_AS_A/.claude" cb="$_AS_B/.claude"
  mkdir -p "$ca/agents"
  printf 'v1\n' > "$ca/agents/x.md"
  _as "$_AS_A" push -m x >/dev/null
  _as "$_AS_B" pull >/dev/null
  printf 'from A\n' > "$ca/agents/x.md"
  _as "$_AS_A" push -m a >/dev/null
  # B deletes x (conflicts with A's edit) and adds an unrelated agent
  git -C "$cb" rm -q agents/x.md && git -C "$cb" commit -qm "delete x"
  mkdir -p "$cb/agents" && printf 'B work\n' > "$cb/agents/y.md"
  git -C "$cb" add agents/y.md && git -C "$cb" commit -qm y
  _as "$_AS_B" pull >/dev/null
  assert_file_exists "$cb/agents/y.md" "PL: no-terminal pull never erases unpushed work"
  assert_contains "$(cat "$cb/.kitsync/conflict_pending" 2>/dev/null)" "agents/x.md" \
    "PL: no-terminal conflict is recorded"
  rm -rf "$_AS_ROOT"
}

run_test_pl_uncommitted_edits() {
  _as_setup
  local ca="$_AS_A/.claude" cb="$_AS_B/.claude" out
  printf '# from A\n' > "$ca/CLAUDE.md"
  _as "$_AS_A" push -m a >/dev/null

  # Unrelated uncommitted edit: the pull goes ahead and keeps it
  mkdir -p "$cb/rules" && printf 'x\n' > "$cb/rules/r.md"
  git -C "$cb" add rules/r.md && git -C "$cb" commit -qm r
  printf 'edited\n' > "$cb/rules/r.md"
  _as "$_AS_B" pull >/dev/null
  assert_eq "# from A" "$(cat "$cb/CLAUDE.md")" "PL: manual pull not blocked by an unrelated edit"
  assert_eq "edited" "$(cat "$cb/rules/r.md")" "PL: unrelated edit kept"

  # Uncommitted edit to a file the remote changed: refused, files named
  printf '# from A, again\n' > "$ca/CLAUDE.md"
  _as "$_AS_A" push -m a2 >/dev/null
  printf '# mine\n' > "$cb/CLAUDE.md"
  out="$(_as "$_AS_B" pull)"
  assert_contains "$out" "CLAUDE.md" "PL: overlapping edit names the file"
  assert_eq "# mine" "$(cat "$cb/CLAUDE.md")" "PL: overlapping edit untouched without --force"

  # --force: remote taken, edit backed up
  _as "$_AS_B" pull --force >/dev/null
  assert_eq "# from A, again" "$(cat "$cb/CLAUDE.md")" "PL: --force takes the remote"
  assert_eq "# mine" "$(cat "$cb"/.kitsync/backups/pull-*/CLAUDE.md 2>/dev/null)" "PL: --force backs up the edit"
  rm -rf "$_AS_ROOT"
}

run_pull_tests() {
  printf "\n=== test_pull.sh (pull) ===\n"
  export GIT_AUTHOR_NAME=kitsync-test GIT_AUTHOR_EMAIL=t@kitsync.local
  export GIT_COMMITTER_NAME=kitsync-test GIT_COMMITTER_EMAIL=t@kitsync.local
  run_test_pl_auto_keeps_unpushed
  run_test_pl_merges_different_lines
  run_test_pl_choices
  run_test_pl_no_terminal_loses_nothing
  run_test_pl_uncommitted_edits
}
