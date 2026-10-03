#!/usr/bin/env bash
# test/test_selective.sh
# Selective sync: a category this machine doesn't pull is a local version on
# purpose — never overwritten, never pushed, never blocking the rest.

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"
source "$_HELPERS_DIR/test_autosync.sh"   # _as_setup / _as / _as_remote_file

# _sel_set <home> <PULL_ITEMS|PUSH_ITEMS> <value>
_sel_set() {
  local f="$1/.claude/.kitsync/local"
  sed -i.bak "s/^KITSYNC_$2=.*/KITSYNC_$2=$3/" "$f" && rm -f "$f.bak"
}
_sel_model() { printf '{\n  "model": "%s"\n}\n' "$2" > "$1/.claude/settings.json"; }

run_test_sel_not_pulled_not_pushed() {
  _as_setup
  _sel_set "$_AS_B" PULL_ITEMS agents,CLAUDE.md   # B still "pushes" settings.json
  _sel_model "$_AS_A" from-A
  _as "$_AS_A" push -m a >/dev/null
  _as "$_AS_B" pull --auto >/dev/null
  _as "$_AS_B" push --auto x >/dev/null
  assert_contains "$(_as_remote_file settings.json)" "from-A" \
    "SEL: a category not pulled is never pushed back over the others' changes"
  assert_contains "$(cat "$_AS_B/.claude/settings.json")" '"opus"' "SEL: B keeps its own version"
  rm -rf "$_AS_ROOT"
}

run_test_sel_never_blocks() {
  _as_setup
  _sel_set "$_AS_B" PULL_ITEMS agents,CLAUDE.md
  _sel_set "$_AS_B" PUSH_ITEMS agents,CLAUDE.md
  _sel_model "$_AS_A" v2; _as "$_AS_A" push -m a1 >/dev/null
  _as "$_AS_B" pull --auto >/dev/null
  _sel_model "$_AS_A" v3
  mkdir -p "$_AS_A/.claude/agents" && echo "# new" > "$_AS_A/.claude/agents/n.md"
  _as "$_AS_A" push -m a2 >/dev/null
  _as "$_AS_B" pull --auto >/dev/null
  assert_file_exists "$_AS_B/.claude/agents/n.md" "SEL: a non-pulled category never blocks the pull"
  assert_contains "$(cat "$_AS_B/.claude/settings.json")" '"opus"' "SEL: non-pulled file left as it is"
  assert_eq "no" "$([[ -d "$_AS_B/.claude/.git/kitsync-hold" ]] && echo yes || echo no)" "SEL: nothing left held aside"
  rm -rf "$_AS_ROOT"
}

run_test_sel_encrypted() {
  command -v openssl &>/dev/null || { printf "  SKIP  SEL: encryption (openssl missing)\n"; return 0; }
  _as_setup
  _as "$_AS_A" encrypt enable >/dev/null
  _as "$_AS_A" push -m enc >/dev/null
  cp "$_AS_A/.claude/.kitsync/encryption.key" "$_AS_B/.claude/.kitsync/"
  _as "$_AS_B" pull >/dev/null
  _sel_model "$_AS_B" mine
  _sel_set "$_AS_B" PULL_ITEMS agents,CLAUDE.md
  _sel_set "$_AS_B" PUSH_ITEMS agents,CLAUDE.md
  _sel_model "$_AS_A" from-A
  _as "$_AS_A" push -m a >/dev/null
  _as "$_AS_B" pull >/dev/null
  assert_contains "$(cat "$_AS_B/.claude/settings.json")" '"mine"' \
    "SEL: encrypted settings not decrypted over a non-pulled version"
  rm -rf "$_AS_ROOT"
}

run_test_sel_blocked_pull_reported() {
  _as_setup
  _sel_set "$_AS_B" PUSH_ITEMS agents,CLAUDE.md   # pulls settings.json, doesn't push it
  _sel_model "$_AS_B" local-edit
  _sel_model "$_AS_A" from-A
  _as "$_AS_A" push -m a >/dev/null
  _as "$_AS_B" pull --auto >/dev/null
  assert_contains "$(cat "$_AS_B/.claude/.kitsync/conflict_pending" 2>/dev/null)" "settings.json" \
    "SEL: a pull blocked by a local edit is reported, not skipped silently"
  assert_contains "$(cat "$_AS_B/.claude/settings.json")" "local-edit" "SEL: the local edit is untouched"
  rm -rf "$_AS_ROOT"
}

run_test_sel_same_new_file() {
  _as_setup
  mkdir -p "$_AS_A/.claude/agents" "$_AS_B/.claude/agents"
  echo "# A's review" > "$_AS_A/.claude/agents/review.md"
  _as "$_AS_A" push -m a >/dev/null
  echo "# B's review" > "$_AS_B/.claude/agents/review.md"   # not pushed yet
  _as "$_AS_B" pull --auto >/dev/null
  assert_contains "$(cat "$_AS_B/.claude/.kitsync/conflict_pending" 2>/dev/null)" "agents/review.md" \
    "SEL: same new file on both machines is reported as a conflict"
  _as "$_AS_B" pull --force >/dev/null
  assert_eq "# A's review" "$(cat "$_AS_B/.claude/agents/review.md")" "SEL: --force takes the remote's new file"
  assert_eq "# B's review" "$(cat "$_AS_B"/.claude/.kitsync/backups/pull-*/agents/review.md 2>/dev/null)" \
    "SEL: --force backs up the local new file"
  rm -rf "$_AS_ROOT"
}

run_test_sel_interrupted_hold() {
  _as_setup
  local ch="$_AS_B/.claude"
  _sel_set "$_AS_B" PULL_ITEMS agents,CLAUDE.md
  _sel_set "$_AS_B" PUSH_ITEMS agents,CLAUDE.md
  # A run killed while B's version was held aside in .git/
  mkdir -p "$ch/.git/kitsync-hold"
  _sel_model "$_AS_B" held
  mv "$ch/settings.json" "$ch/.git/kitsync-hold/settings.json"
  git -C "$ch" checkout -q HEAD -- settings.json
  _as "$_AS_B" pull --auto >/dev/null
  assert_contains "$(cat "$ch/settings.json")" '"held"' "SEL: a version held by an interrupted run is restored"
  rm -rf "$_AS_ROOT"
}

run_selective_tests() {
  printf "\n=== test_selective.sh (selective sync) ===\n"
  export GIT_AUTHOR_NAME=kitsync-test GIT_AUTHOR_EMAIL=t@kitsync.local
  export GIT_COMMITTER_NAME=kitsync-test GIT_COMMITTER_EMAIL=t@kitsync.local
  run_test_sel_not_pulled_not_pushed
  run_test_sel_never_blocks
  run_test_sel_encrypted
  run_test_sel_blocked_pull_reported
  run_test_sel_same_new_file
  run_test_sel_interrupted_hold
}
