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
  printf "  ${_CLR_YELLOW}${_CLR_BOLD}│  ${_CLR_RESET}${_CLR_BOLD}source ~/%s${_CLR_RESET}${_CLR_YELLOW}${_CLR_BOLD}                              │${_CLR_RESET}\n" "$rc_file" >&2
  printf "  ${_CLR_YELLOW}${_CLR_BOLD}│  ${_CLR_RESET}${_CLR_BOLD}or open a new terminal tab${_CLR_RESET}${_CLR_YELLOW}${_CLR_BOLD}                   │${_CLR_RESET}\n" >&2
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

  # All selected by default
  local sel=()
  for (( i=0; i<n; i++ )); do sel+=("1"); done

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

  if [[ -n "$default" ]]; then
    printf "  ${_CLR_CYAN}◆${_CLR_RESET}  %s ${_CLR_BOLD}(%s)${_CLR_RESET}: " "$prompt" "$default" >/dev/tty
  else
    printf "  ${_CLR_CYAN}◆${_CLR_RESET}  %s: " "$prompt" >/dev/tty
  fi

  read -r reply </dev/tty || true
  reply="${reply:-$default}"
  printf '%s' "$reply"
}
