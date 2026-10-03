#!/usr/bin/env bash
# test/test_kit.sh
# Starter kit: rm_to_trash.py rewrites only real rm commands and picks the
# trash command of the platform, setup-kit wires settings.json idempotently,
# and the kit ships no dev artifacts or personal paths.

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

_KIT_PY="$(command -v python3 || true)"

# _kit_fakebin <names...> — dir with stub executables. Sets: _KIT_BIN
_kit_fakebin() {
  _KIT_BIN="$(mktemp -d)"
  local n
  for n in "$@"; do
    printf '#!/bin/sh\nexit 0\n' > "$_KIT_BIN/$n"
    chmod +x "$_KIT_BIN/$n"
  done
}

# _kit_hook <command> — the hook's rewritten command ("" if untouched,
# "DENY" if blocked), with only $_KIT_BIN on PATH
_kit_hook() {
  local in out
  in="$("$_KIT_PY" -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1],"description":"d"}}))' "$1")"
  out="$(PATH="$_KIT_BIN" "$_KIT_PY" "$_PROJECT_ROOT/kit/hooks/rm_to_trash.py" <<< "$in")"
  "$_KIT_PY" -c '
import json,sys
o=json.loads(sys.argv[1]).get("hookSpecificOutput",{})
if o.get("permissionDecision")=="deny": print("DENY")
else: print(o.get("updatedInput",{}).get("command",""))' "$out"
}

run_test_kit_hook() {
  if [[ -z "$_KIT_PY" ]]; then
    printf "  SKIP  KIT: rm_to_trash.py (python3 not installed)\n"
    return 0
  fi
  _kit_fakebin trash
  local r="rm"   # keeps literal rm commands out of this file's own test runner line
  assert_eq "trash build" "$(_kit_hook "$r -rf build")" "KIT: rm -rf → trash"
  assert_eq "cd x && trash a b" "$(_kit_hook "cd x && $r a b")" "KIT: rm after && rewritten"
  assert_eq "sudo trash /tmp/a" "$(_kit_hook "sudo $r -f /tmp/a")" "KIT: sudo rm rewritten"
  assert_eq "find . -name '*.o' | xargs trash" "$(_kit_hook "find . -name '*.o' | xargs $r")" \
    "KIT: xargs rm at end of command rewritten"
  assert_eq "trash a" "$(_kit_hook "$r --recursive --force a")" \
    "KIT: long rm options dropped"
  assert_eq "" "$(_kit_hook "git $r --cached a.txt")" "KIT: git rm left alone"
  assert_eq "" "$(_kit_hook "terraform state $r x")" "KIT: terraform state rm left alone"
  assert_eq "" "$(_kit_hook "rmdir build && echo $r")" "KIT: rmdir and echo rm left alone"
  rm -rf "$_KIT_BIN"

  _kit_fakebin trash-put
  assert_eq "trash-put -- -weird" "$(_kit_hook "$r -f -- -weird")" "KIT: Linux trash-put keeps --"
  rm -rf "$_KIT_BIN"

  _kit_fakebin gio
  assert_eq "gio trash a" "$(_kit_hook "$r a")" "KIT: gio trash fallback"
  rm -rf "$_KIT_BIN"

  _kit_fakebin
  assert_eq "DENY" "$(_kit_hook "$r -rf a")" "KIT: no trash command → blocked, never a real rm"
  rm -rf "$_KIT_BIN"
}

# _kit_setup_run — setup-kit as a fake user whose ~/.claude holds the kit
_kit_setup_run() {
  HOME="$_KIT_HOME" ZDOTDIR="$_KIT_HOME" CLAUDE_HOME="$_KIT_HOME/.claude" \
    XDG_STATE_HOME="$_KIT_HOME/.state" KITSYNC_NO_TTY=1 KITSYNC_ROOT="" \
    PATH="$_KIT_BIN:$(dirname "$_KIT_PY"):/usr/bin:/bin" \
    bash "$_PROJECT_ROOT/bin/claude-kitsync" setup-kit </dev/null >/dev/null 2>&1
}

run_test_kit_setup() {
  if [[ -z "$_KIT_PY" ]]; then
    printf "  SKIP  KIT: setup-kit (python3 not installed)\n"
    return 0
  fi
  _KIT_HOME="$(mktemp -d)"
  local ch="$_KIT_HOME/.claude" s
  mkdir -p "$ch"
  cp -R "$_PROJECT_ROOT/kit/hooks" "$_PROJECT_ROOT/kit/scripts" "$ch/"
  printf '{"model":"opus","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"say done"}]}]}}\n' \
    > "$ch/settings.json"
  _kit_fakebin bun trash

  _kit_setup_run
  s="$(cat "$ch/settings.json")"
  assert_contains "$s" "hooks/rm_to_trash.py" "KIT: setup-kit wires rm_to_trash.py"
  assert_contains "$s" "command-validator/src/cli.ts" "KIT: setup-kit wires the command validator"
  assert_contains "$s" "statusline/src/index.ts" "KIT: setup-kit wires the status line"
  assert_contains "$s" '"model": "opus"' "KIT: setup-kit keeps existing settings"
  assert_contains "$s" "say done" "KIT: setup-kit keeps existing hooks"
  assert_nonzero "$(ls -A "$ch/.kitsync/backups/" 2>/dev/null | grep -c settings.json || true)" \
    "KIT: settings.json backed up before edit"

  _kit_setup_run
  assert_eq "1" "$(grep -c 'rm_to_trash.py' "$ch/settings.json")" "KIT: setup-kit is idempotent"

  # A status line of the user's own is never replaced
  printf '{"statusLine":{"type":"command","command":"my-line"}}\n' > "$ch/settings.json"
  _kit_setup_run
  assert_contains "$(cat "$ch/settings.json")" '"command": "my-line"' "KIT: user's status line kept"
  assert_eq "0" "$(grep -c 'statusline/src/index.ts' "$ch/settings.json")" "KIT: kit status line not forced"

  # No bun: only the python hook is wired
  printf '{}\n' > "$ch/settings.json"
  rm -f "$_KIT_BIN/bun"
  _kit_setup_run
  assert_contains "$(cat "$ch/settings.json")" "rm_to_trash.py" "KIT: without bun the python hook is still wired"
  assert_eq "0" "$(grep -c 'command-validator' "$ch/settings.json")" "KIT: without bun, bun scripts not wired"

  rm -rf "$_KIT_BIN" "$_KIT_HOME"
}

run_test_kit_contents() {
  local junk
  junk="$(cd "$_PROJECT_ROOT/kit" && find . \( -name '__tests__' -o -name 'fixtures' -o -name 'bun.lockb' \
    -o -name 'biome.json' -o -path './scripts/*CLAUDE.md' -o -name '*.test.ts' \) -print)"
  assert_eq "" "$junk" "KIT: no dev artifacts shipped in kit/"
  assert_eq "" "$(grep -rIlE '/(Users|home)/[a-z]' "$_PROJECT_ROOT/kit" | grep -v '/Users/test\|/home/test' || true)" \
    "KIT: no personal home paths in kit/"
  assert_eq "0" "$(grep -c '`/push`' "$_PROJECT_ROOT/kit/CLAUDE.md")" "KIT: CLAUDE.md names no missing skill"
}

run_kit_tests() {
  printf "\n=== test_kit.sh (starter kit) ===\n"
  run_test_kit_hook
  run_test_kit_setup
  run_test_kit_contents
}
