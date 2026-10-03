#!/usr/bin/env bash
# lib/core.sh — Colors, logging, CLAUDE_HOME detection, shared utilities
set -euo pipefail

# ---------------------------------------------------------------------------
# CLAUDE_HOME — can be overridden via environment variable
# ---------------------------------------------------------------------------
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

# ---------------------------------------------------------------------------
# ANSI color codes
# ---------------------------------------------------------------------------
_CLR_RESET=$'\033[0m'
_CLR_RED=$'\033[0;31m'
_CLR_YELLOW=$'\033[0;33m'
_CLR_GREEN=$'\033[0;32m'
_CLR_CYAN=$'\033[0;36m'
_CLR_BOLD=$'\033[1m'

# ---------------------------------------------------------------------------
# Logging functions
# ---------------------------------------------------------------------------
log_info() {
  printf "${_CLR_CYAN}[kitsync]${_CLR_RESET}  %s\n" "$*" >&2
}

log_warn() {
  printf "${_CLR_YELLOW}[kitsync]${_CLR_RESET}  ${_CLR_YELLOW}WARN${_CLR_RESET}  %s\n" "$*" >&2
}

log_error() {
  printf "${_CLR_RED}[kitsync]${_CLR_RESET}  ${_CLR_RED}ERROR${_CLR_RESET} %s\n" "$*" >&2
}

log_success() {
  printf "${_CLR_GREEN}[kitsync]${_CLR_RESET}  ${_CLR_GREEN}OK${_CLR_RESET}    %s\n" "$*" >&2
}

log_step() {
  printf "${_CLR_BOLD}[kitsync]${_CLR_RESET}  ${_CLR_CYAN}-->${_CLR_RESET}   %s\n" "$*" >&2
}

# ---------------------------------------------------------------------------
# _print_reload_notice — prominent banner reminding user to reload their shell
# ---------------------------------------------------------------------------
_print_reload_notice() {
  local shell_name
  shell_name="$(basename "${SHELL:-zsh}")"
  local rc_file=".${shell_name}rc"

  printf "\n" >&2
  printf "  ${_CLR_YELLOW}${_CLR_BOLD}┌─────────────────────────────────────────────────────┐${_CLR_RESET}\n" >&2
  printf "  ${_CLR_YELLOW}${_CLR_BOLD}│  Reload your shell to activate the new wrapper      │${_CLR_RESET}\n" >&2
  printf "  ${_CLR_YELLOW}${_CLR_BOLD}│                                                     │${_CLR_RESET}\n" >&2
  printf "  ${_CLR_YELLOW}${_CLR_BOLD}│  ${_CLR_RESET}${_CLR_BOLD}source ~/%s${_CLR_RESET}${_CLR_YELLOW}${_CLR_BOLD}                                    │${_CLR_RESET}\n" "$rc_file" >&2
  printf "  ${_CLR_YELLOW}${_CLR_BOLD}│  ${_CLR_RESET}${_CLR_BOLD}or open a new terminal tab${_CLR_RESET}${_CLR_YELLOW}${_CLR_BOLD}                         │${_CLR_RESET}\n" >&2
  printf "  ${_CLR_YELLOW}${_CLR_BOLD}└─────────────────────────────────────────────────────┘${_CLR_RESET}\n" >&2
  printf "\n" >&2
}

# ---------------------------------------------------------------------------
# require_git_repo — verifies that $CLAUDE_HOME is a git repository
# Exits with error if not.
# ---------------------------------------------------------------------------
require_git_repo() {
  if [[ ! -d "$CLAUDE_HOME" ]]; then
    log_error "CLAUDE_HOME does not exist: $CLAUDE_HOME"
    log_error "Run 'claude-kitsync init' to initialise it."
    exit 1
  fi

  if ! git -C "$CLAUDE_HOME" rev-parse --git-dir &>/dev/null; then
    log_error "$CLAUDE_HOME is not a git repository."
    log_error "Run 'claude-kitsync init' to initialise it."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# confirm — interactive yes/no prompt
# Usage: confirm "Question?" && do_something
# ---------------------------------------------------------------------------
confirm() {
  local prompt="${1:-Are you sure?}"
  # Non-interactive context (pipe, script, no TTY) → default to No
  if [[ ! -t 0 ]]; then
    return 1
  fi
  local reply
  printf "${_CLR_CYAN}[kitsync]${_CLR_RESET}  %s [y/N] " "$prompt" >&2
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# _has_tty — true when a terminal can be prompted (menus read /dev/tty, so
# `curl | bash` is interactive while CI and cron are not)
# ---------------------------------------------------------------------------
_has_tty() {
  [[ "${KITSYNC_NO_TTY:-}" != 1 ]] && { : </dev/tty; } 2>/dev/null
}

# ---------------------------------------------------------------------------
# Preferences live in two files under .kitsync/:
#   config  synced — what every machine must agree on (encryption, profiles)
#   local   never synced — this machine's choices (modes, categories, timer,
#           upgrade channel); a work laptop can sync less than a personal one
# ---------------------------------------------------------------------------
KITSYNC_LOCAL_KEYS="KITSYNC_PULL_MODE KITSYNC_PUSH_MODE KITSYNC_PUSH_TIMER KITSYNC_PUSH_ITEMS KITSYNC_PULL_ITEMS KITSYNC_UPGRADE_CHANNEL"

_is_local_key() { [[ " $KITSYNC_LOCAL_KEYS " == *" $1 "* ]]; }

# _cfg_file <key> — the file that holds <key>
_cfg_file() {
  if _is_local_key "$1"; then
    printf '%s/.kitsync/local' "$CLAUDE_HOME"
  else
    printf '%s/.kitsync/config' "$CLAUDE_HOME"
  fi
}

# _cfg_get <key> — value of <key> (empty if unset). A local key still found
# only in the synced file (setup older than 1.2.1) is read from there.
_cfg_get() {
  local v
  v="$(grep "^$1=" "$(_cfg_file "$1")" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
  if [[ -z "$v" ]] && _is_local_key "$1"; then
    v="$(grep "^$1=" "$CLAUDE_HOME/.kitsync/config" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
  fi
  printf '%s' "$v"
}

# _config_set <key> <value> — set one key in the file it belongs to, keeping the rest
_config_set() {
  local cfg tmp
  cfg="$(_cfg_file "$1")"
  mkdir -p "$(dirname "$cfg")"
  if [[ ! -f "$cfg" ]]; then
    if _is_local_key "$1"; then
      printf '# claude-kitsync — preferences of this machine (never synced)\n# Edit manually or run: claude-kitsync settings\n' > "$cfg"
    else
      printf '# claude-kitsync — shared by all your machines\n' > "$cfg"
    fi
  fi
  tmp="$(mktemp "${cfg}.XXXXXX")"
  grep -v "^$1=" "$cfg" > "$tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  mv "$tmp" "$cfg"
}

# _config_migrate_local — move this machine's keys out of the synced file
# (each machine keeps the values it had). Returns 0 when the synced file changed.
_config_migrate_local() {
  local cfg="$CLAUDE_HOME/.kitsync/config" key val moved=1
  [[ -f "$cfg" ]] || return 1
  for key in $KITSYNC_LOCAL_KEYS; do
    grep -q "^$key=" "$cfg" 2>/dev/null || continue
    val="$(grep "^$key=" "$cfg" | tail -1 | cut -d= -f2-)"
    grep -q "^$key=" "$CLAUDE_HOME/.kitsync/local" 2>/dev/null || _config_set "$key" "$val"
    moved=0
  done
  [[ $moved -eq 0 ]] || return 1
  local tmp
  tmp="$(mktemp "${cfg}.XXXXXX")"
  grep -vE "^($(tr ' ' '|' <<< "$KITSYNC_LOCAL_KEYS"))=" "$cfg" > "$tmp" || true
  sed -i.bak 's/^# claude-kitsync sync preferences$/# claude-kitsync — shared by all your machines (per-machine choices: .kitsync\/local)/' "$tmp" && rm -f "$tmp.bak"
  mv "$tmp" "$cfg"
  return 0
}


# ---------------------------------------------------------------------------
# _with_timeout <seconds> <cmd...> — timeout(1) is missing on stock macOS
_with_timeout() {
  local secs="$1"; shift
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
  fi
}

# _git_net <git args...> — network git call that can't hang on a prompt
_git_net() {
  (
    export GIT_TERMINAL_PROMPT=0
    # BatchMode: fail instead of asking for a passphrase/host key — unless the
    # user already drives ssh through core.sshCommand / GIT_SSH_COMMAND
    if [[ -z "${GIT_SSH_COMMAND:-}" ]] && \
       ! git -C "$CLAUDE_HOME" config --get core.sshCommand &>/dev/null; then
      export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
    fi
    _with_timeout "${KITSYNC_NET_TIMEOUT:-15}" git -C "$CLAUDE_HOME" "$@"
  )
}

# ---------------------------------------------------------------------------
# die — log error and exit
# ---------------------------------------------------------------------------
die() {
  log_error "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# is_macos — returns 0 on macOS, 1 otherwise
# ---------------------------------------------------------------------------
is_macos() {
  [[ "$(uname)" == "Darwin" ]]
}

# ---------------------------------------------------------------------------
# command_exists — check if a command is available
# ---------------------------------------------------------------------------
command_exists() {
  command -v "$1" &>/dev/null
}

# ---------------------------------------------------------------------------
# require_command — die if a required command is not available
# ---------------------------------------------------------------------------
require_command() {
  local cmd="$1"
  if ! command_exists "$cmd"; then
    die "Required command not found: $cmd"
  fi
}

# ---------------------------------------------------------------------------
# _select_menu — numbered interactive menu via /dev/tty
# Usage: choice=$(_select_menu "Prompt text" "Option A" "Option B" "Option C")
# Returns the selected index (1-based) on stdout.
# Writes prompt and options to /dev/tty — works even inside $(...).
# ---------------------------------------------------------------------------
_select_menu() {
  local prompt="$1"
  shift
  local options=("$@")
  local n=${#options[@]}
  local selected=0

  # No terminal: first option (the default)
  if ! _has_tty; then printf '1'; return 0; fi

  # Hide cursor; restore on interrupt
  printf '\033[?25l' >/dev/tty
  trap 'printf "\033[?25h" >/dev/tty' INT TERM

  # Print header + initial menu
  printf "\n" >/dev/tty
  printf "  ${_CLR_BOLD}%s${_CLR_RESET}\n" "$prompt" >/dev/tty
  printf "\n" >/dev/tty
  local i
  for (( i=0; i<n; i++ )); do
    if [[ $i -eq $selected ]]; then
      printf "  ${_CLR_CYAN}${_CLR_BOLD}❯${_CLR_RESET}  ${_CLR_CYAN}%s${_CLR_RESET}\n" "${options[$i]}" >/dev/tty
    else
      printf "    %s\n" "${options[$i]}" >/dev/tty
    fi
  done

  while true; do
    local key=""
    IFS= read -rsn1 key </dev/tty || break

    if [[ "$key" == $'\x1b' ]]; then
      # Arrow keys send ESC [ A/B — integer timeout required for bash 3.2 compat
      local s1=""
      IFS= read -rsn1 -t 1 s1 </dev/tty 2>/dev/null || true
      if [[ "$s1" == '[' ]]; then
        local s2=""
        IFS= read -rsn1 -t 1 s2 </dev/tty 2>/dev/null || true
        if [[ "$s2" == 'A' ]] && [[ $selected -gt 0 ]]; then
          selected=$(( selected - 1 ))
        elif [[ "$s2" == 'B' ]] && [[ $selected -lt $(( n - 1 )) ]]; then
          selected=$(( selected + 1 ))
        fi
      fi
    elif [[ -z "$key" || "$key" == $'\r' || "$key" == $'\n' ]]; then
      break
    fi

    # Redraw options in place
    printf "\033[%dA" "$n" >/dev/tty
    for (( i=0; i<n; i++ )); do
      printf "\033[2K\r" >/dev/tty
      if [[ $i -eq $selected ]]; then
        printf "  ${_CLR_CYAN}${_CLR_BOLD}❯${_CLR_RESET}  ${_CLR_CYAN}%s${_CLR_RESET}\n" "${options[$i]}" >/dev/tty
      else
        printf "    %s\n" "${options[$i]}" >/dev/tty
      fi
    done
  done

  # Replace entire block with a compact summary line
  # Block height: \n (1) + prompt\n (1) + \n (1) + n options = n+3
  local total=$(( n + 3 ))
  printf "\033[%dA" "$total" >/dev/tty
  for (( i=0; i<total; i++ )); do
    printf "\033[2K\r\n" >/dev/tty
  done
  printf "\033[%dA" "$total" >/dev/tty
  printf "  ${_CLR_CYAN}◆${_CLR_RESET}  ${_CLR_BOLD}%s${_CLR_RESET}  ${_CLR_CYAN}%s${_CLR_RESET}\n" \
    "$prompt" "${options[$selected]}" >/dev/tty

  # Restore cursor
  printf '\033[?25h' >/dev/tty
  trap - INT TERM

  printf '%s' "$(( selected + 1 ))"
}

# ---------------------------------------------------------------------------
# _select_multi — checkbox multi-select menu via /dev/tty
# Usage: indices=$(_select_multi "Prompt" "opt1" "opt2" "opt3")
# Returns space-separated 1-based indices of selected items on stdout.
# All items selected by default; Space to toggle, Enter to confirm.
# ---------------------------------------------------------------------------
_select_multi() {
  local prompt="$1"
  shift
  local options=("$@")
  local n=${#options[@]}
  local cur=0
  local i

  # All selected by default; _SELECT_MULTI_DEFAULT=0 starts with none
  local def="${_SELECT_MULTI_DEFAULT:-1}"
  local sel=()
  for (( i=0; i<n; i++ )); do sel+=("$def"); done

  # No terminal: the default
  if ! _has_tty; then
    local all=""
    if [[ "$def" == 1 ]]; then
      for (( i=1; i<=n; i++ )); do all+="$i "; done
    fi
    printf '%s' "${all% }"
    return 0
  fi

  printf '\033[?25l' >/dev/tty
  trap 'printf "\033[?25h" >/dev/tty' INT TERM

  # Initial render
  # Block layout: \n(1) + prompt\n(1) + \n(1) + n options + \n+hint\n(2) = n+5 total
  printf "\n" >/dev/tty
  printf "  ${_CLR_BOLD}%s${_CLR_RESET}\n" "$prompt" >/dev/tty
  printf "\n" >/dev/tty
  for (( i=0; i<n; i++ )); do
    local mark; [[ "${sel[$i]}" == "1" ]] && mark="${_CLR_CYAN}◉${_CLR_RESET}" || mark="○"
    if [[ $i -eq $cur ]]; then
      printf "  ${_CLR_CYAN}${_CLR_BOLD}❯${_CLR_RESET}  %s  ${_CLR_CYAN}%s${_CLR_RESET}\n" "$mark" "${options[$i]}" >/dev/tty
    else
      printf "     %s  %s\n" "$mark" "${options[$i]}" >/dev/tty
    fi
  done
  printf "\n  ${_CLR_BOLD}↑↓${_CLR_RESET} navigate · ${_CLR_BOLD}Space${_CLR_RESET} toggle · ${_CLR_BOLD}Enter${_CLR_RESET} confirm\n" >/dev/tty

  while true; do
    local key=""
    IFS= read -rsn1 key </dev/tty || break

    if [[ "$key" == $'\x1b' ]]; then
      local s1=""
      IFS= read -rsn1 -t 1 s1 </dev/tty 2>/dev/null || true
      if [[ "$s1" == '[' ]]; then
        local s2=""
        IFS= read -rsn1 -t 1 s2 </dev/tty 2>/dev/null || true
        if [[ "$s2" == 'A' ]] && [[ $cur -gt 0 ]]; then
          cur=$(( cur - 1 ))
        elif [[ "$s2" == 'B' ]] && [[ $cur -lt $(( n - 1 )) ]]; then
          cur=$(( cur + 1 ))
        fi
      fi
    elif [[ "$key" == ' ' ]]; then
      [[ "${sel[$cur]}" == "1" ]] && sel[$cur]="0" || sel[$cur]="1"
    elif [[ -z "$key" || "$key" == $'\r' || "$key" == $'\n' ]]; then
      break
    fi

    # Redraw: n options + blank + hint = n+2 lines to go up and reprint
    printf "\033[%dA" "$(( n + 2 ))" >/dev/tty
    for (( i=0; i<n; i++ )); do
      printf "\033[2K\r" >/dev/tty
      local mark; [[ "${sel[$i]}" == "1" ]] && mark="${_CLR_CYAN}◉${_CLR_RESET}" || mark="○"
      if [[ $i -eq $cur ]]; then
        printf "  ${_CLR_CYAN}${_CLR_BOLD}❯${_CLR_RESET}  %s  ${_CLR_CYAN}%s${_CLR_RESET}\n" "$mark" "${options[$i]}" >/dev/tty
      else
        printf "     %s  %s\n" "$mark" "${options[$i]}" >/dev/tty
      fi
    done
    printf "\033[2K\r\n" >/dev/tty
    printf "\033[2K\r  ${_CLR_BOLD}↑↓${_CLR_RESET} navigate · ${_CLR_BOLD}Space${_CLR_RESET} toggle · ${_CLR_BOLD}Enter${_CLR_RESET} confirm\n" >/dev/tty
  done

  # Clear entire block and show summary (n+5 total lines)
  local total=$(( n + 5 ))
  printf "\033[%dA" "$total" >/dev/tty
  for (( i=0; i<total; i++ )); do
    printf "\033[2K\r\n" >/dev/tty
  done
  printf "\033[%dA" "$total" >/dev/tty
  local count=0
  for (( i=0; i<n; i++ )); do
    [[ "${sel[$i]}" == "1" ]] && count=$(( count + 1 ))
  done
  printf "  ${_CLR_CYAN}◆${_CLR_RESET}  ${_CLR_BOLD}%s${_CLR_RESET}  ${_CLR_CYAN}%d/%d selected${_CLR_RESET}\n" \
    "$prompt" "$count" "$n" >/dev/tty

  printf '\033[?25h' >/dev/tty
  trap - INT TERM

  # Output: space-separated 1-based indices of selected items
  local result=""
  for (( i=0; i<n; i++ )); do
    [[ "${sel[$i]}" == "1" ]] && result+="$(( i + 1 )) "
  done
  printf '%s' "${result% }"
}

# ---------------------------------------------------------------------------
# _read_tty — read a value from /dev/tty (works in $(...) and curl|bash)
# Usage: value=$(_read_tty "Prompt" "default")
# ---------------------------------------------------------------------------
_read_tty() {
  local prompt="$1"
  local default="${2:-}"
  local reply=""

  if ! _has_tty; then printf '%s' "$default"; return 0; fi

  if [[ -n "$default" ]]; then
    printf "  ${_CLR_CYAN}◆${_CLR_RESET}  %s ${_CLR_BOLD}(%s)${_CLR_RESET}: " "$prompt" "$default" >/dev/tty
  else
    printf "  ${_CLR_CYAN}◆${_CLR_RESET}  %s: " "$prompt" >/dev/tty
  fi

  read -r reply </dev/tty || true
  reply="${reply:-$default}"
  printf '%s' "$reply"
}
