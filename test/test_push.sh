#!/usr/bin/env bash
# test/test_push.sh
# push: deletions, per-machine preferences, secrets, dry run; and pull --auto
# no longer blocked by local edits the remote didn't touch.

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"
source "$_HELPERS_DIR/test_autosync.sh"   # _as_setup / _as / _as_remote_file

# A fake token of the given format, built at run time so no literal secret
# sits in this repository (hosts scan pushed code for them)
_ps_fake_github_token() { printf 'gh%s_%s' p "$(printf 'x%.0s' $(seq 1 36))"; }

run_test_ps_deletions() {
  _as_setup
  local ch="$_AS_B/.claude"
  mkdir -p "$ch/rules" && echo "# r" > "$ch/rules/r.md"
  _as "$_AS_B" push -m add >/dev/null
  rm -f "$ch/CLAUDE.md"
  rm -rf "$ch/rules"
  _as "$_AS_B" push -m del >/dev/null
  assert_eq "" "$(_as_remote_file CLAUDE.md)" "PS: deleted top-level file is deleted on the remote"
  assert_eq "" "$(_as_remote_file rules/r.md)" "PS: deleted folder is deleted on the remote"
  assert_eq "" "$(git -C "$ch" status --porcelain --untracked-files=no)" "PS: nothing left pending after a deletion push"
  rm -rf "$_AS_ROOT"
}

run_test_ps_pull_with_unrelated_edits() {
  _as_setup
  local ch="$_AS_B/.claude"
  # B never pushes settings.json; Claude Code rewrites it locally
  sed -i.bak 's/^KITSYNC_PUSH_ITEMS=.*/KITSYNC_PUSH_ITEMS=agents,CLAUDE.md/' "$ch/.kitsync/local" && rm -f "$ch/.kitsync/local.bak"
  printf '{\n  "model": "local-only"\n}\n' > "$ch/settings.json"
  _as "$_AS_B" push --auto x >/dev/null

  mkdir -p "$_AS_A/.claude/agents"
  echo "# new" > "$_AS_A/.claude/agents/new.md"
  _as "$_AS_A" push -m agent >/dev/null
  _as "$_AS_B" pull --auto >/dev/null
  assert_file_exists "$ch/agents/new.md" "PS: pull --auto not blocked by an unrelated local edit"
  assert_contains "$(cat "$ch/settings.json")" "local-only" "PS: the unrelated local edit is kept"
  rm -rf "$_AS_ROOT"
}

run_test_ps_machine_prefs() {
  _as_setup
  local cb="$_AS_B/.claude" ca="$_AS_A/.claude"
  sed -i.bak 's/^KITSYNC_PUSH_ITEMS=.*/KITSYNC_PUSH_ITEMS=agents/' "$cb/.kitsync/local" && rm -f "$cb/.kitsync/local.bak"
  _as "$_AS_B" push -m prefs >/dev/null
  _as "$_AS_A" pull >/dev/null
  assert_eq "0" "$(grep -c '^KITSYNC_PUSH_ITEMS=agents$' "$ca/.kitsync/local")" \
    "PS: one machine's push selection never reaches another"
  assert_eq "" "$(_as_remote_file .kitsync/local)" "PS: .kitsync/local is never pushed"

  # Setup from before 1.2.1: per-machine keys in the synced file
  git -C "$ca" rm -q --cached --ignore-unmatch .kitsync/local
  printf 'KITSYNC_PULL_MODE=manual\nKITSYNC_UPGRADE_CHANNEL=dev\n' >> "$ca/.kitsync/config"
  : > "$ca/.kitsync/local"
  git -C "$ca" commit -q -am "old config"
  _as "$_AS_A" push -m old >/dev/null
  assert_contains "$(cat "$ca/.kitsync/local")" "KITSYNC_PULL_MODE=manual" "PS: migration keeps this machine's values"
  assert_eq "0" "$(_as_remote_file .kitsync/config | grep -c 'PULL_MODE\|UPGRADE_CHANNEL')" \
    "PS: migration takes per-machine keys out of the synced file"
  rm -rf "$_AS_ROOT"
}

run_test_ps_secrets() {
  _as_setup
  local ch="$_AS_B/.claude" out
  mkdir -p "$ch/hooks" "$ch/agents"
  printf '#!/bin/sh\nTOKEN=%s\n' "$(_ps_fake_github_token)" > "$ch/hooks/notify.sh"
  echo "# fine" > "$ch/agents/fine.md"
  out="$(_as "$_AS_B" push -m s)"
  assert_eq "" "$(_as_remote_file hooks/notify.sh)" "PS: file adding a token is not pushed"
  assert_eq "# fine" "$(_as_remote_file agents/fine.md)" "PS: other files still pushed"
  assert_contains "$out" "GitHub token" "PS: warning names the kind of secret"
  assert_eq "0" "$(grep -c "$(_ps_fake_github_token)" <<< "$out")" "PS: warning never prints the secret"

  _as "$_AS_B" push --allow-secret hooks/notify.sh -m allowed >/dev/null
  assert_contains "$(_as_remote_file hooks/notify.sh)" "TOKEN=" "PS: --allow-secret lets that file through"
  rm -rf "$_AS_ROOT"
}

run_test_ps_dry_run() {
  _as_setup
  local ch="$_AS_B/.claude" gd idx_before out
  gd="$ch/.git"
  echo "# changed" > "$ch/CLAUDE.md"
  mkdir -p "$ch/hooks"
  printf 'K=%s\n' "$(_ps_fake_github_token)" > "$ch/hooks/k.sh"
  idx_before="$(cksum < "$gd/index")"
  out="$(_as "$_AS_B" push --dry-run)"
  assert_contains "$out" "modified:  CLAUDE.md" "PS: dry run lists the change"
  assert_contains "$out" "hooks/k.sh (looks like a secret" "PS: dry run shows what would be left out"
  assert_eq "$idx_before" "$(cksum < "$gd/index")" "PS: dry run leaves the git index untouched"
  assert_eq "" "$(_as_remote_file CLAUDE.md | grep changed)" "PS: dry run pushes nothing"

  # Under encryption the preview includes the encrypted settings, and the
  # derived .enc file is put back byte for byte
  if command -v openssl &>/dev/null; then
    _as "$_AS_B" encrypt enable >/dev/null
    _as "$_AS_B" push -m enc >/dev/null
    local enc_before
    enc_before="$(cksum < "$ch/settings.json.enc")"
    printf '{\n  "model": "secret-change"\n}\n' > "$ch/settings.json"
    out="$(_as "$_AS_B" push --dry-run)"
    assert_contains "$out" "modified:  settings.json.enc" "PS: dry run previews encrypted settings"
    assert_eq "$enc_before" "$(cksum < "$ch/settings.json.enc")" "PS: dry run restores settings.json.enc"
  fi
  rm -rf "$_AS_ROOT"
}

run_push_tests() {
  printf "\n=== test_push.sh (push) ===\n"
  export GIT_AUTHOR_NAME=kitsync-test GIT_AUTHOR_EMAIL=t@kitsync.local
  export GIT_COMMITTER_NAME=kitsync-test GIT_COMMITTER_EMAIL=t@kitsync.local
  run_test_ps_deletions
  run_test_ps_pull_with_unrelated_edits
  run_test_ps_machine_prefs
  run_test_ps_secrets
  run_test_ps_dry_run
}
