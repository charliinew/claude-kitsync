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

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
printf "\n" >&2
printf "  ${_c_bold}claude-kitsync${_c_reset} — sync your Claude config across machines\n" >&2
printf "  %s\n" "$KITSYNC_REPO" >&2
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
local kitsync_bin="$install_dir/bin/kitsync"
local kitsync_dest="$bin_dir/kitsync"

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
  if ! grep -qF "# kitsync PATH" "$rc_file" 2>/dev/null; then
    printf '\n# kitsync PATH\nexport PATH="%s:$PATH"\n' "$bin_dir" >> "$rc_file"
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
    printf "  Where should your Claude config be stored?\n" >&2
    printf "  (Create a private GitHub repo first, e.g. github.com/new)\n\n" >&2
    remote_url="$(_read_tty "  Git remote URL (SSH or HTTPS, blank to skip)" "")"
  else
    _log "Using remote: $remote_url"
  fi

  # Run kitsync init
  if [[ -n "$remote_url" ]]; then
    KITSYNC_ROOT="$install_dir" "$kitsync_dest" init --remote "$remote_url"
  else
    _warn "No remote URL provided — running init without remote."
    _warn "Run 'kitsync init --remote <url>' later to configure sync."
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
