#!/usr/bin/env bash
# install.sh — curl -fsSL https://raw.githubusercontent.com/charliinew/claude-kitsync/main/install.sh | bash
#
# One command = fully configured:
#   curl -fsSL .../install.sh | bash
#   # or with a known remote:
#   KITSYNC_REMOTE=git@github.com:you/claude-config.git curl -fsSL .../install.sh | bash
#
# Protection against partial download: entire body is wrapped in install()
# and called at the very end. If the download is truncated, the function
# never gets invoked and the user's system is untouched.

set -euo pipefail

# ---------------------------------------------------------------------------
# install — the full installation logic
# ---------------------------------------------------------------------------
install() {

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly KITSYNC_REPO="https://github.com/charliinew/claude-kitsync"
readonly INSTALL_DIR_USER="$HOME/.local/share/kitsync"
readonly BIN_DIR_USER="$HOME/.local/bin"
readonly BIN_DIR_SYSTEM="/usr/local/bin"

# ---------------------------------------------------------------------------
# Inline color helpers (core.sh not available yet)
# ---------------------------------------------------------------------------
_c_reset='\033[0m'
_c_green='\033[0;32m'
_c_yellow='\033[0;33m'
_c_red='\033[0;31m'
_c_cyan='\033[0;36m'
_c_blue='\033[0;34m'
_c_bold='\033[1m'

_log()    { printf "${_c_cyan}[kitsync]${_c_reset}  %s\n"                          "$*" >&2; }
_ok()     { printf "${_c_green}[kitsync]${_c_reset}  ${_c_green}✓${_c_reset}  %s\n" "$*" >&2; }
_warn()   { printf "${_c_yellow}[kitsync]${_c_reset}  ${_c_yellow}!${_c_reset}  %s\n" "$*" >&2; }
_step()   { printf "${_c_bold}[kitsync]${_c_reset}  ${_c_cyan}→${_c_reset}  %s\n"  "$*" >&2; }
_die()    { printf "${_c_red}[kitsync]${_c_reset}  ${_c_red}✗${_c_reset}  %s\n"    "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_detect_shell() { basename "${SHELL:-/bin/bash}"; }
_is_macos()     { [[ "$(uname)" == "Darwin" ]]; }

# Read from /dev/tty — works even when stdin is piped (curl | bash)
_read_tty() {
  local prompt="$1"
  local var_name="$2"
  local default="${3:-}"
  local reply=""

  if [[ -n "$default" ]]; then
    printf "%s [%s]: " "$prompt" "$default" >/dev/tty
  else
    printf "%s: " "$prompt" >/dev/tty
  fi

  read -r reply </dev/tty || true
  reply="${reply:-$default}"
  printf '%s' "$reply"
}

_confirm_tty() {
  local prompt="$1"
  local default="${2:-n}"
  local hint
  if [[ "$default" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
  printf "%s [%s] " "$prompt" "$hint" >/dev/tty
  local reply
  read -r reply </dev/tty || true
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Numbered select menu via /dev/tty — works inside $(...) and curl|bash
_select_tty() {
  local prompt="$1"
  shift
  local n=$#

  printf "\n" >/dev/tty
  printf "  ${_c_bold}%s${_c_reset}\n\n" "$prompt" >/dev/tty
  local i=1
  for opt in "$@"; do
    printf "  ${_c_cyan}%d${_c_reset}  %s\n" "$i" "$opt" >/dev/tty
    i=$((i + 1))
  done
  printf "\n" >/dev/tty

  local choice=""
  while true; do
    printf "  ${_c_bold}›${_c_reset} " >/dev/tty
    read -r choice </dev/tty || true
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
      break
    fi
    printf "  Please enter a number between 1 and %d\n" "$n" >/dev/tty
  done
  printf '%s' "$choice"
}

# Create a new GitHub repo via gh CLI, return SSH URL
_gh_create_repo_tty() {
  local repo_name
  repo_name="$(_read_tty "Repo name" "" "claude-config")"
  local vis_choice
  vis_choice="$(_select_tty "Visibility?" "Private  (recommended)" "Public")"
  local vis_flag="--private"
  [[ "$vis_choice" == "2" ]] && vis_flag="--public"

  _step "Creating GitHub repo: $repo_name..."
  if gh repo create "$repo_name" "$vis_flag" --description "Claude Code config sync" >/dev/null 2>&1; then
    local gh_login
    gh_login="$(gh api user -q .login 2>/dev/null)"
    local result_url="git@github.com:${gh_login}/${repo_name}.git"
    _ok "Repo created: github.com/${gh_login}/${repo_name}"
    printf '%s' "$result_url"
  else
    _warn "gh repo create failed — enter URL manually."
    printf '%s' "$(_read_tty "Git URL (SSH or HTTPS, blank to skip)" "")"
  fi
}

# Browse existing GitHub repos via gh CLI, return selected SSH URL
_gh_connect_repo_tty() {
  _step "Fetching your GitHub repos..."

  local repo_lines
  repo_lines="$(gh repo list --limit 30 2>/dev/null | awk '{print $1}' || true)"

  if [[ -z "$repo_lines" ]]; then
    _warn "No repos found — enter URL manually."
    printf '%s' "$(_read_tty "Git URL (SSH or HTTPS, blank to skip)" "")"
    return
  fi

  local options=()
  while IFS= read -r repo; do
    [[ -n "$repo" ]] && options+=("$repo")
  done <<< "$repo_lines"

  local choice
  choice="$(_select_tty "Select a repository:" "${options[@]}")"

  local selected="${options[$((choice - 1))]}"
  printf 'git@github.com:%s.git' "$selected"
}

# GitHub sub-menu: create new or connect existing
_gh_repo_flow_tty() {
  local action
  action="$(_select_tty "GitHub repository:" \
    "Create a new repo" \
    "Connect to an existing repo")"

  case "$action" in
    1) _gh_create_repo_tty ;;
    2) _gh_connect_repo_tty ;;
  esac
}

# Build remote menu, return URL
_select_remote_tty() {
  local options=()
  local has_gh=false
  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    has_gh=true
    options+=("GitHub  (create new or connect existing)")
  fi
  options+=("Enter a URL  (SSH or HTTPS)")
  options+=("Skip — configure later")

  local choice
  choice="$(_select_tty "Where should your Claude config be stored?" "${options[@]}")"

  local actions=()
  [[ "$has_gh" == "true" ]] && actions+=("github")
  actions+=("url_input")
  actions+=("skip")
  local action="${actions[$((choice - 1))]}"

  case "$action" in
    github)
      _gh_repo_flow_tty
      ;;
    url_input)
      printf '%s' "$(_read_tty "Git URL (SSH or HTTPS, blank to skip)" "")"
      ;;
    skip)
      printf ''
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
printf "\n" >&2
printf "  ${_c_bold}${_c_cyan}◆ claude-kitsync${_c_reset}  —  sync your Claude config across machines\n" >&2
printf "  ${_c_bold}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_c_reset}\n" >&2
printf "\n" >&2

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! command -v git &>/dev/null; then
  _die "git is required but not found. Install git first."
fi

# ---------------------------------------------------------------------------
# Step 1: Determine install directory
# ---------------------------------------------------------------------------
local install_dir="$INSTALL_DIR_USER"
local bin_dir="$BIN_DIR_USER"

if [[ "${KITSYNC_SYSTEM_INSTALL:-}" == "1" ]] && [[ -w "$BIN_DIR_SYSTEM" ]]; then
  bin_dir="$BIN_DIR_SYSTEM"
fi

# ---------------------------------------------------------------------------
# Step 2: Clone or update the kitsync repo
# ---------------------------------------------------------------------------
if [[ -n "${KITSYNC_INSTALL_DIR:-}" ]]; then
  # Dev/test override: use an existing local directory, skip clone
  install_dir="$KITSYNC_INSTALL_DIR"
  _log "Using local install dir: $install_dir"
elif [[ -d "$install_dir/.git" ]]; then
  _step "Updating kitsync..."
  git -C "$install_dir" pull --rebase -q 2>/dev/null || _warn "Update failed, keeping current version."
  _ok "kitsync up to date"
else
  _step "Installing kitsync..."
  [[ -d "$install_dir" ]] && rm -rf "$install_dir"
  git clone --depth 1 -q "$KITSYNC_REPO" "$install_dir" 2>/dev/null || \
    _die "Clone failed — check your network connection."
  _ok "kitsync installed"
fi

# ---------------------------------------------------------------------------
# Step 3: Symlink binary
# ---------------------------------------------------------------------------
mkdir -p "$bin_dir"
local kitsync_bin="$install_dir/bin/claude-kitsync"
local kitsync_dest="$bin_dir/claude-kitsync"

[[ -f "$kitsync_bin" ]] || _die "Binary not found at $kitsync_bin — repo may be corrupt."
chmod +x "$kitsync_bin"

if [[ -L "$kitsync_dest" ]] && [[ "$(readlink "$kitsync_dest")" == "$kitsync_bin" ]]; then
  true  # already linked
else
  ln -sf "$kitsync_bin" "$kitsync_dest"
fi
_ok "Binary ready at $kitsync_dest"

# ---------------------------------------------------------------------------
# Step 4: Inject PATH into shell rc (idempotent)
# ---------------------------------------------------------------------------
local current_shell rc_file=""
current_shell="$(_detect_shell)"

case "$current_shell" in
  zsh)  rc_file="${ZDOTDIR:-$HOME}/.zshrc" ;;
  bash) _is_macos && rc_file="$HOME/.bash_profile" || rc_file="$HOME/.bashrc" ;;
  *)    _warn "Unrecognised shell '$current_shell' — add manually: export PATH=\"$bin_dir:\$PATH\"" ;;
esac

if [[ -n "$rc_file" ]]; then
  touch "$rc_file"
  if ! grep -qF "claude-kitsync PATH" "$rc_file" 2>/dev/null && \
     ! grep -qF "kitsync PATH" "$rc_file" 2>/dev/null; then
    printf '\n# claude-kitsync PATH\nexport PATH="%s:$PATH"\n' "$bin_dir" >> "$rc_file"
  fi
fi

# Make binary available in the current process immediately
export PATH="$bin_dir:$PATH"
export KITSYNC_ROOT="$install_dir"

# ---------------------------------------------------------------------------
# Step 5: Run kitsync init
# ---------------------------------------------------------------------------
printf "\n" >&2
_step "Setting up ~/.claude sync..."
printf "\n" >&2

local claude_home="${CLAUDE_HOME:-$HOME/.claude}"
local already_init=false
git -C "$claude_home" rev-parse --git-dir &>/dev/null 2>&1 && already_init=true

if [[ "$already_init" == true ]]; then
  _ok "~/.claude is already a git repo — skipping git init."
  # Still ensure wrapper is installed
  "$kitsync_dest" _install-wrapper 2>/dev/null || true
else
  # Get the remote URL
  local remote_url="${KITSYNC_REMOTE:-}"

  if [[ -z "$remote_url" ]]; then
    remote_url="$(_select_remote_tty)"
  else
    _log "Using remote: $remote_url"
  fi

  # Run kitsync init
  if [[ -n "$remote_url" ]]; then
    KITSYNC_ROOT="$install_dir" "$kitsync_dest" init --remote "$remote_url"
  else
    _warn "No remote URL provided — running init without remote."
    _warn "Run 'claude-kitsync init --remote <url>' later to configure sync."
    KITSYNC_ROOT="$install_dir" "$kitsync_dest" init
  fi
fi

# ---------------------------------------------------------------------------
# Step 6: Final summary — single activation command
# ---------------------------------------------------------------------------
printf "\n" >&2
printf "  ${_c_green}${_c_bold}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_c_reset}\n" >&2
printf "  ${_c_green}${_c_bold}  ✓  claude-kitsync ready!${_c_reset}\n" >&2
printf "  ${_c_green}${_c_bold}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_c_reset}\n" >&2
printf "\n" >&2
printf "  ${_c_bold}One last step — activate in this shell:${_c_reset}\n" >&2
printf "\n" >&2

local source_cmd
case "$current_shell" in
  zsh)  source_cmd="source ${rc_file:-~/.zshrc}" ;;
  bash) source_cmd="source ${rc_file:-~/.bashrc}" ;;
  *)    source_cmd="source ~/.zshrc" ;;
esac

printf "  ${_c_cyan}${_c_bold}  %s${_c_reset}\n" "$source_cmd" >&2
printf "\n" >&2
printf "  Then just use ${_c_bold}claude${_c_reset} normally — sync happens silently in the background.\n" >&2
printf "\n" >&2

} # end install()

# ---------------------------------------------------------------------------
# Entry point — only reached when the full script has been downloaded.
# ---------------------------------------------------------------------------
install "$@"
