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
_CLR_RESET='\033[0m'
_CLR_RED='\033[0;31m'
_CLR_YELLOW='\033[0;33m'
_CLR_GREEN='\033[0;32m'
_CLR_CYAN='\033[0;36m'
_CLR_BOLD='\033[1m'

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
# require_git_repo — verifies that $CLAUDE_HOME is a git repository
# Exits with error if not.
# ---------------------------------------------------------------------------
require_git_repo() {
  if [[ ! -d "$CLAUDE_HOME" ]]; then
    log_error "CLAUDE_HOME does not exist: $CLAUDE_HOME"
    log_error "Run 'kitsync init' to initialise it."
    exit 1
  fi

  if ! git -C "$CLAUDE_HOME" rev-parse --git-dir &>/dev/null; then
    log_error "$CLAUDE_HOME is not a git repository."
    log_error "Run 'kitsync init' to initialise it."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# confirm — interactive yes/no prompt
# Usage: confirm "Question?" && do_something
# ---------------------------------------------------------------------------
confirm() {
  local prompt="${1:-Are you sure?}"
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
