#!/usr/bin/env bash
# lib/kit-setup.sh — wire the starter kit's hooks and status line into
# settings.json. Copied files do nothing until settings.json points to them.
set -euo pipefail

# _kit_bun — path to bun, empty if not installed (the installer puts it in ~/.bun)
_kit_bun() {
  if command -v bun &>/dev/null; then
    command -v bun
  elif [[ -x "$HOME/.bun/bin/bun" ]]; then
    printf '%s' "$HOME/.bun/bin/bun"
  fi
}

# _kit_trash_cmd — the trash command rm_to_trash.py will use, empty if none
_kit_trash_cmd() {
  local c
  for c in trash trash-put; do
    command -v "$c" &>/dev/null && { printf '%s' "$c"; return 0; }
  done
  command -v gio &>/dev/null && printf 'gio trash'
  return 0
}

# _kit_trash_help — how to get a trash command on this OS
_kit_trash_help() {
  if is_macos; then
    printf 'brew install trash   (macOS 15+ already has /usr/bin/trash)'
  elif command -v apt-get &>/dev/null; then
    printf 'sudo apt install trash-cli'
  elif command -v dnf &>/dev/null; then
    printf 'sudo dnf install trash-cli'
  elif command -v pacman &>/dev/null; then
    printf 'sudo pacman -S trash-cli'
  else
    printf 'install trash-cli (https://github.com/andreafrancia/trash-cli)'
  fi
}

# ---------------------------------------------------------------------------
# _kit_entries — one line per kit component present in CLAUDE_HOME:
#   <kind>\t<key>\t<command>
# kind: hook (PreToolUse/Bash) or statusline; key identifies it in settings.json
# ---------------------------------------------------------------------------
_kit_entries() {
  local bun
  bun="$(_kit_bun)"
  if [[ -f "$CLAUDE_HOME/hooks/rm_to_trash.py" ]] && command -v python3 &>/dev/null; then
    printf 'hook\trm_to_trash.py\tpython3 "%s/hooks/rm_to_trash.py"\n' "$CLAUDE_HOME"
  fi
  [[ -n "$bun" ]] || return 0
  if [[ -f "$CLAUDE_HOME/scripts/command-validator/src/cli.ts" ]]; then
    printf 'hook\tcommand-validator/src/cli.ts\t"%s" "%s/scripts/command-validator/src/cli.ts"\n' "$bun" "$CLAUDE_HOME"
  fi
  if [[ -f "$CLAUDE_HOME/scripts/statusline/src/index.ts" ]]; then
    printf 'statusline\tstatusline/src/index.ts\t"%s" "%s/scripts/statusline/src/index.ts"\n' "$bun" "$CLAUDE_HOME"
  fi
}

# _kit_print_manual — the settings.json snippet and requirements, for users
# who wire things themselves
_kit_print_manual() {
  local ch="$CLAUDE_HOME"
  cat >&2 <<EOF

  Starter kit — add this to $ch/settings.json (merge with what is there):

  {
    "hooks": {
      "PreToolUse": [
        { "matcher": "Bash", "hooks": [
          { "type": "command", "command": "python3 \"$ch/hooks/rm_to_trash.py\"" },
          { "type": "command", "command": "bun \"$ch/scripts/command-validator/src/cli.ts\"" }
        ] }
      ]
    },
    "statusLine": { "type": "command", "command": "bun \"$ch/scripts/statusline/src/index.ts\"", "padding": 0 }
  }

  Requirements:
    - rm_to_trash.py      python3 and a trash command — $(_kit_trash_help)
    - command-validator   Bun — curl -fsSL https://bun.sh/install | bash
    - statusline          Bun
  Or let kitsync do it: claude-kitsync setup-kit

EOF
}

# ---------------------------------------------------------------------------
# kit_setup — merge the kit's entries into settings.json (backup first).
# Idempotent: an entry already pointing to the same script is left alone,
# and an existing status line of your own is never replaced.
# ---------------------------------------------------------------------------
kit_setup() {
  local entries
  entries="$(_kit_entries)"

  if ! command -v python3 &>/dev/null; then
    log_warn "python3 not found — can't edit settings.json automatically."
    _kit_print_manual
    return 0
  fi

  if [[ -n "$entries" ]]; then
    local settings="$CLAUDE_HOME/settings.json"
    [[ -f "$settings" ]] || printf '{}\n' > "$settings"
    local backup_dir="$CLAUDE_HOME/.kitsync/backups"
    mkdir -p "$backup_dir"
    cp "$settings" "$backup_dir/settings.json.$(date '+%Y%m%dT%H%M%S').bak"

    local report
    report="$(KIT_ENTRIES="$entries" python3 - "$settings" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    s = json.load(f)
added, kept = [], []
for line in os.environ["KIT_ENTRIES"].splitlines():
    kind, key, cmd = line.split("\t", 2)
    if kind == "hook":
        groups = s.setdefault("hooks", {}).setdefault("PreToolUse", [])
        if any(key in h.get("command", "") for g in groups for h in g.get("hooks", [])):
            kept.append(key); continue
        group = next((g for g in groups if g.get("matcher") == "Bash"), None)
        if group is None:
            group = {"matcher": "Bash", "hooks": []}
            groups.append(group)
        group.setdefault("hooks", []).append({"type": "command", "command": cmd})
        added.append(key)
    else:
        cur = s.get("statusLine", {}).get("command", "")
        if cur:
            kept.append(key if key in cur else "statusline (yours kept)"); continue
        s["statusLine"] = {"type": "command", "command": cmd, "padding": 0}
        added.append(key)
if added:
    with open(path, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
print("added: " + ", ".join(added) if added else "added: nothing")
print("kept: " + ", ".join(kept) if kept else "kept: nothing")
PY
)" || { log_error "Could not update $settings (is it valid JSON?)"; return 1; }
    log_success "settings.json — $(sed -n 1p <<< "$report")"
    [[ "$(sed -n 2p <<< "$report")" == "kept: nothing" ]] || log_info "settings.json — $(sed -n 2p <<< "$report")"
  fi

  # Dependencies (node_modules is ignored by scripts/.gitignore, never synced)
  local bun
  bun="$(_kit_bun)"
  if [[ -n "$bun" && -f "$CLAUDE_HOME/scripts/package.json" ]]; then
    if "$bun" install --cwd "$CLAUDE_HOME/scripts" --production >/dev/null 2>&1; then
      log_success "Script dependencies installed (bun)"
    else
      log_warn "bun install failed in $CLAUDE_HOME/scripts — the scripts may not start."
    fi
  fi

  # What is still missing on this machine
  if [[ -f "$CLAUDE_HOME/hooks/rm_to_trash.py" ]]; then
    if ! command -v python3 &>/dev/null; then
      log_warn "rm_to_trash.py needs python3."
    elif [[ -z "$(_kit_trash_cmd)" ]]; then
      log_warn "No trash command: Claude's rm commands will be blocked until you run: $(_kit_trash_help)"
    else
      log_info "Claude's rm commands go to the trash ($(_kit_trash_cmd))."
    fi
  fi
  if [[ -z "$bun" && -d "$CLAUDE_HOME/scripts" ]]; then
    log_warn "Bun not found — the status line and command validator are not wired."
    log_info "  Install Bun (curl -fsSL https://bun.sh/install | bash), then run: claude-kitsync setup-kit"
  fi
}

# cmd_setup_kit — `claude-kitsync setup-kit [--print]`
cmd_setup_kit() {
  case "${1:-}" in
    --print) _kit_print_manual ;;
    "")      kit_setup ;;
    *)       die "Unknown option: $1 (usage: claude-kitsync setup-kit [--print])" ;;
  esac
}

# _kit_setup_prompt — after init imported hooks/ or scripts/
_kit_setup_prompt() {
  local choice
  choice="$(_select_menu "The kit's hooks and scripts only run once settings.json points to them" \
    "Set them up now  (recommended — settings.json is backed up)" \
    "Show me how instead")"
  if [[ "$choice" == "1" ]]; then
    kit_setup
  else
    _kit_print_manual
  fi
}
