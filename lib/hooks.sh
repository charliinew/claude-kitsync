#!/usr/bin/env bash
# lib/hooks.sh — sync triggered by Claude Code itself (hooks in settings.json)
#
# Claude Code fires the same hook events in the terminal, IDE extensions and
# the desktop app, so these replace the claude() shell wrapper:
#   SessionStart (startup|resume)  pull in the background + show notices
#   SessionEnd                     push in the background (end_of_session mode)
#   Stop                           push at most every N minutes (timer mode)
# Each hook only launches a detached job and returns: SessionEnd hooks get a
# 1.5 s budget, and Claude must never wait on the network.
set -euo pipefail

readonly KITSYNC_HOOK_MARK="claude-kitsync _hook"

# _hook_command <event> — the hook's shell command. GUI-launched Claude
# (IDE, desktop) may not have the user's PATH, hence the usual install dirs;
# `|| true` keeps a machine without kitsync (synced settings.json) quiet.
_hook_command() {
  # shellcheck disable=SC2016  # $HOME/$PATH expand when Claude Code runs it
  printf 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"; command -v claude-kitsync >/dev/null 2>&1 && claude-kitsync _hook %s 2>/dev/null || true' "$1"
}

# _hooks_py <mode> — run the settings.json editor
#   check   exit 0 when the hooks for the current push mode are all present
#   add     install them (replacing older kitsync entries); prints "changed"
#   remove  remove every kitsync entry; prints "changed" when something went
_hooks_py() {
  local push
  push="$(_cfg_get KITSYNC_PUSH_MODE || true)"
  KS_MARK="$KITSYNC_HOOK_MARK" KS_PUSH="${push:-end_of_session}" \
  KS_START="$(_hook_command session-start)" KS_END="$(_hook_command session-end)" \
  KS_STOP="$(_hook_command stop)" \
  python3 - "$CLAUDE_HOME/settings.json" "$1" <<'PY'
import json, os, sys
path, mode = sys.argv[1], sys.argv[2]
mark = os.environ["KS_MARK"]
try:
    with open(path) as f:
        s = json.load(f)
except FileNotFoundError:
    s = {}

want = {
    "SessionStart": {"matcher": "startup|resume",
                     "hooks": [{"type": "command", "command": os.environ["KS_START"], "timeout": 10}]},
    "SessionEnd": {"hooks": [{"type": "command", "command": os.environ["KS_END"], "timeout": 5}]},
}
if os.environ["KS_PUSH"] == "timer":
    want["Stop"] = {"hooks": [{"type": "command", "command": os.environ["KS_STOP"], "timeout": 5}]}

hooks = s.get("hooks", {})

def ours():
    return {ev: [g for g in groups if any(mark in h.get("command", "") for h in g.get("hooks", []))]
            for ev, groups in hooks.items()}

def strip():
    changed = False
    for ev in list(hooks):
        kept = []
        for g in hooks[ev]:
            hs = [h for h in g.get("hooks", []) if mark not in h.get("command", "")]
            if len(hs) != len(g.get("hooks", [])):
                changed = True
            if hs:
                g["hooks"] = hs
                kept.append(g)
        if kept:
            hooks[ev] = kept
        else:
            del hooks[ev]
    return changed

current = {ev: gs for ev, gs in ours().items() if gs}
desired = {ev: [g] for ev, g in want.items()}
if mode == "check":
    sys.exit(0 if current == desired else 1)

if mode == "add":
    if current == desired:
        sys.exit(0)
    strip()
    for ev, g in want.items():
        hooks.setdefault(ev, []).append(g)
else:
    if not strip():
        sys.exit(0)

if hooks:
    s["hooks"] = hooks
else:
    s.pop("hooks", None)
with open(path, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
print("changed")
PY
}

# _settings_canonical — settings JSON (stdin) normalised for comparison:
# sorted keys, fixed indentation, kitsync's own hook entries left out
_settings_canonical() {
  KS_MARK="$KITSYNC_HOOK_MARK" python3 -c '
import json, os, sys
mark = os.environ["KS_MARK"]
s = json.load(sys.stdin)
h = s.get("hooks", {})
for ev in list(h):
    gs = []
    for g in h[ev]:
        g["hooks"] = [x for x in g.get("hooks", []) if mark not in x.get("command", "")]
        if g["hooks"]:
            gs.append(g)
    if gs:
        h[ev] = gs
    else:
        del h[ev]
if not h:
    s.pop("hooks", None)
print(json.dumps(s, sort_keys=True, indent=2))'
}

# hooks_installed — true when settings.json holds the sync hooks
hooks_installed() {
  command -v python3 &>/dev/null && _hooks_py check 2>/dev/null
}

# _hooks_backup — keep settings.json before editing it
_hooks_backup() {
  [[ -f "$CLAUDE_HOME/settings.json" ]] || return 0
  mkdir -p "$CLAUDE_HOME/.kitsync/backups"
  cp "$CLAUDE_HOME/settings.json" \
    "$CLAUDE_HOME/.kitsync/backups/settings.json.$(date '+%Y%m%dT%H%M%S').bak"
}

# hooks_install — add (or update) the sync hooks; 1 without python3 or on error
hooks_install() {
  command -v python3 &>/dev/null || return 1
  hooks_installed && return 0
  _hooks_backup
  local out
  out="$(_hooks_py add)" || { log_error "Could not update $CLAUDE_HOME/settings.json (is it valid JSON?)"; return 1; }
  [[ "$out" == changed ]] && log_success "Sync hooks installed in $CLAUDE_HOME/settings.json"
  return 0
}

# hooks_remove — remove the sync hooks (backup first)
hooks_remove() {
  command -v python3 &>/dev/null || return 0
  [[ -f "$CLAUDE_HOME/settings.json" ]] || return 0
  grep -qF "$KITSYNC_HOOK_MARK" "$CLAUDE_HOME/settings.json" 2>/dev/null || return 0
  _hooks_backup
  [[ "$(_hooks_py remove 2>/dev/null || true)" == changed ]] && \
    log_success "Sync hooks removed from $CLAUDE_HOME/settings.json"
  return 0
}

# _wrapper_rc_files — rc files that still hold the claude() wrapper
_wrapper_rc_files() {
  local rc
  for rc in "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.bashrc"; do
    grep -qxF "$WRAPPER_START_MARKER" "$rc" 2>/dev/null && printf '%s\n' "$rc"
  done
  return 0
}

# ---------------------------------------------------------------------------
# sync_trigger_setup — sync through Claude Code hooks; the shell wrapper is
# only a fallback when settings.json can't be edited (no python3). Moving to
# hooks removes the wrapper, so a session never syncs twice.
# ---------------------------------------------------------------------------
sync_trigger_setup() {
  if hooks_install; then
    local rc
    while IFS= read -r rc; do
      [[ -n "$rc" ]] || continue
      _remove_from_rc "$rc"
      log_success "Removed the claude() wrapper from $rc — Claude Code's hooks sync instead (terminal, IDE, desktop)."
    done < <(_wrapper_rc_files)
    return 0
  fi
  log_warn "python3 not found — can't add hooks to settings.json; using the shell wrapper instead."
  log_info "  (It syncs only when you run 'claude' in a terminal.)"
  install_wrapper_auto
}

# ---------------------------------------------------------------------------
# Hook runtime — `claude-kitsync _hook <event>`, run by Claude Code
# ---------------------------------------------------------------------------

# _detach <cmd...> — run fully detached: survives the hook and Claude exiting
_detach() {
  ( "$@" </dev/null >/dev/null 2>&1 & )
}

# _json_str <text> — JSON string literal
_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/ }"
  printf '"%s"' "$s"
}

_hook_cfg() { _cfg_get "$1"; }

cmd_hook() {
  local ev="${1:-}"
  # Hook input (JSON on stdin) is not needed; don't leave the writer blocked
  [[ -t 0 ]] || cat >/dev/null 2>&1 || true
  [[ -d "$CLAUDE_HOME/.git" ]] || return 0

  local pull push timer stamp
  pull="$(_hook_cfg KITSYNC_PULL_MODE)";  pull="${pull:-auto}"
  push="$(_hook_cfg KITSYNC_PUSH_MODE)";  push="${push:-end_of_session}"
  timer="$(_hook_cfg KITSYNC_PUSH_TIMER)"
  [[ "$timer" =~ ^[0-9]+$ ]] && (( timer > 0 )) || timer=15
  local msg
  msg="$(_sync_commit_msg auto-push)"

  case "$ev" in
    session-start)
      local notes="" f="$CLAUDE_HOME/.kitsync"
      if [[ -f "$f/conflict_pending" ]]; then
        notes+="kitsync: sync conflict pending ($(grep '^files:' "$f/conflict_pending" | cut -d: -f2-)). Choose file by file: claude-kitsync pull — or take the remote for all (local versions backed up): claude-kitsync pull --force"$'\n'
      fi
      if [[ -f "$f/sync-warning" ]]; then
        notes+="kitsync: $(cat "$f/sync-warning")"$'\n'
        rm -f "$f/sync-warning"
      fi
      if [[ -f "$f/pending-notice" ]]; then
        notes+="kitsync: config updated from your other machines — settings or agents may have changed."$'\n'
        rm -f "$f/pending-notice"
      fi
      [[ "$pull" == auto ]] && _detach "$0" pull --auto
      # Timer mode: first push N minutes into the session, not after turn one
      [[ "$push" == timer ]] && touch "$(git -C "$CLAUDE_HOME" rev-parse --absolute-git-dir)/kitsync-last-push"
      [[ -n "$notes" ]] && printf '{"systemMessage": %s}\n' "$(_json_str "${notes%$'\n'}")"
      ;;
    session-end)
      [[ "$push" == end_of_session ]] && _detach "$0" push --auto "$msg"
      ;;
    stop)
      [[ "$push" == timer ]] || return 0
      stamp="$(git -C "$CLAUDE_HOME" rev-parse --absolute-git-dir)/kitsync-last-push"
      if [[ ! -f "$stamp" ]] || [[ -n "$(find "$stamp" -mmin +"$timer" 2>/dev/null)" ]]; then
        touch "$stamp"
        _detach "$0" push --auto "$msg"
      fi
      ;;
  esac
  return 0
}
