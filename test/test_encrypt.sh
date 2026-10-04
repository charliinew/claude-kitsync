#!/usr/bin/env bash
# test/test_encrypt.sh
# Encryption across machines: a machine without the current key is told,
# never overwrites the others' encrypted settings, and recovers once the key
# is copied.

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"
source "$_HELPERS_DIR/test_autosync.sh"   # _as_setup / _as / _as_remote_file

_en_model() { printf '{\n  "model": "%s"\n}\n' "$2" > "$1/.claude/settings.json"; }

run_test_en_rotation() {
  _as_setup
  local ca="$_AS_A/.claude" cb="$_AS_B/.claude" before
  _as "$_AS_A" encrypt enable >/dev/null
  _as "$_AS_A" push -m enc >/dev/null
  assert_contains "$(_as_remote_file .kitsync/config)" "KITSYNC_ENCRYPT_KEY_ID=" "EN: the key's fingerprint is shared"
  assert_eq "0" "$(_as_remote_file .kitsync/config | grep -c "$(cat "$ca/.kitsync/encryption.key")")" \
    "EN: the key itself never is"
  cp "$ca/.kitsync/encryption.key" "$cb/.kitsync/"
  _as "$_AS_B" pull >/dev/null

  _as "$_AS_A" encrypt rotate >/dev/null
  _en_model "$_AS_A" after-rotate
  _as "$_AS_A" push -m rot >/dev/null
  _as "$_AS_B" pull --auto >/dev/null
  assert_contains "$(cat "$cb/.kitsync/sync-warning" 2>/dev/null)" "key this machine doesn't have" \
    "EN: a machine with an old key is told at the next session"
  assert_contains "$(_as "$_AS_B" doctor)" "not the current one" "EN: doctor reports the wrong key"

  before="$(git -C "$_AS_ROOT/remote.git" log -1 --format=%H main -- settings.json.enc)"
  _en_model "$_AS_B" stale-on-B
  _as "$_AS_B" push --auto x >/dev/null
  assert_eq "$before" "$(git -C "$_AS_ROOT/remote.git" log -1 --format=%H main -- settings.json.enc)" \
    "EN: a machine with an old key never overwrites the encrypted settings"

  cp "$ca/.kitsync/encryption.key" "$cb/.kitsync/"
  git -C "$cb" checkout -q -- settings.json.enc 2>/dev/null
  _as "$_AS_B" pull >/dev/null
  assert_contains "$(cat "$cb/settings.json")" "after-rotate" "EN: once the key is copied, settings sync again"
  assert_contains "$(cat "$cb"/.kitsync/backups/settings.json.*.bak 2>/dev/null)" "stale-on-B" \
    "EN: the stale local settings are backed up"
  rm -rf "$_AS_ROOT"
}

run_test_en_legacy_setup() {
  _as_setup
  local ca="$_AS_A/.claude"
  _as "$_AS_A" encrypt enable >/dev/null
  # Setup from before 1.2.7: encrypted, no fingerprint recorded
  sed -i.bak '/^KITSYNC_ENCRYPT_KEY_ID=/d' "$ca/.kitsync/config" && rm -f "$ca/.kitsync/config.bak"
  _en_model "$_AS_A" legacy
  _as "$_AS_A" push -m legacy >/dev/null
  assert_contains "$(_as_remote_file .kitsync/config)" "KITSYNC_ENCRYPT_KEY_ID=" \
    "EN: existing encrypted setups record the fingerprint on their next push"
  rm -rf "$_AS_ROOT"
}

run_encrypt_tests() {
  printf "\n=== test_encrypt.sh (encryption across machines) ===\n"
  command -v openssl &>/dev/null || { printf "  SKIP  EN: openssl missing\n"; return 0; }
  export GIT_AUTHOR_NAME=kitsync-test GIT_AUTHOR_EMAIL=t@kitsync.local
  export GIT_COMMITTER_NAME=kitsync-test GIT_COMMITTER_EMAIL=t@kitsync.local
  run_test_en_rotation
  run_test_en_legacy_setup
}
