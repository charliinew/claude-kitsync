#!/usr/bin/env bash
# install.sh — curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash
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
readonly KITSYNC_REPO_RAW="https://raw.githubusercontent.com/charliinew/claude-kitsync/main"
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
_c_bold='\033[1m'

_log()    { printf "${_c_cyan}[install]${_c_reset}  %s\n" "$*" >&2; }
_ok()     { printf "${_c_green}[install]${_c_reset}  ${_c_green}OK${_c_reset}    %s\n" "$*" >&2; }
_warn()   { printf "${_c_yellow}[install]${_c_reset}  ${_c_yellow}WARN${_c_reset}  %s\n" "$*" >&2; }
_err()    { printf "${_c_red}[install]${_c_reset}  ${_c_red}ERROR${_c_reset} %s\n" "$*" >&2; }
_die()    { _err "$*"; exit 1; }
_step()   { printf "${_c_bold}[install]${_c_reset}  ${_c_cyan}-->${_c_reset}   %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# Detect OS and shell
# ---------------------------------------------------------------------------
_detect_os() {
  uname
}

_detect_shell() {
  basename "${SHELL:-/bin/bash}"
}

_is_macos() {
  [[ "$(_detect_os)" == "Darwin" ]]
}

# ---------------------------------------------------------------------------
# Require git
# ---------------------------------------------------------------------------
if ! command -v git &>/dev/null; then
  _die "git is required but not found. Please install git and re-run."
fi

printf "\n"
_log "Installing ${_c_bold}kitsync${_c_reset} — Claude config sync tool"
_log "Source: $KITSYNC_REPO"
printf "\n"

# ---------------------------------------------------------------------------
# Step 1: Determine install directory
# ---------------------------------------------------------------------------
local install_dir="$INSTALL_DIR_USER"
local bin_dir="$BIN_DIR_USER"

# If user has write access to /usr/local/bin and prefers system-wide install
if [[ "${KITSYNC_SYSTEM_INSTALL:-}" == "1" ]] && [[ -w "$BIN_DIR_SYSTEM" ]]; then
  bin_dir="$BIN_DIR_SYSTEM"
  _log "System-wide install requested."
fi

# ---------------------------------------------------------------------------
# Step 2: Clone or update the kitsync repo
# ---------------------------------------------------------------------------
if [[ -d "$install_dir/.git" ]]; then
  _step "Updating existing kitsync installation..."
  git -C "$install_dir" pull --rebase -q 2>/dev/null || \
    _warn "Update failed — keeping existing version."
else
  _step "Cloning kitsync into $install_dir..."
  # Remove stale non-git directory if present
  if [[ -d "$install_dir" ]]; then
    rm -rf "$install_dir"
  fi
  git clone --depth 1 "$KITSYNC_REPO" "$install_dir" 2>/dev/null || \
    _die "Failed to clone from $KITSYNC_REPO — check your network connection."
fi

_ok "kitsync source installed at $install_dir"

# ---------------------------------------------------------------------------
# Step 3: Create bin directory and symlink/copy the binary
# ---------------------------------------------------------------------------
mkdir -p "$bin_dir"

local kitsync_bin="$install_dir/bin/kitsync"
local kitsync_dest="$bin_dir/kitsync"

if [[ ! -f "$kitsync_bin" ]]; then
  _die "Binary not found at $kitsync_bin — installation may be corrupt."
fi

chmod +x "$kitsync_bin"

# Idempotent: only create symlink if it doesn't already point to the right place
if [[ -L "$kitsync_dest" ]] && [[ "$(readlink "$kitsync_dest")" == "$kitsync_bin" ]]; then
  _log "Symlink already up to date: $kitsync_dest -> $kitsync_bin"
else
  ln -sf "$kitsync_bin" "$kitsync_dest"
  _ok "Installed: $kitsync_dest -> $kitsync_bin"
fi

# ---------------------------------------------------------------------------
# Step 4: Detect shell and inject PATH into rc file (idempotent)
# ---------------------------------------------------------------------------
local current_shell
current_shell="$(_detect_shell)"
local rc_file=""

case "$current_shell" in
  zsh)
    rc_file="${ZDOTDIR:-$HOME}/.zshrc"
    ;;
  bash)
    # On macOS bash uses .bash_profile for login shells; on Linux .bashrc
    if _is_macos; then
      rc_file="$HOME/.bash_profile"
    else
      rc_file="$HOME/.bashrc"
    fi
    ;;
  *)
    _warn "Unrecognised shell: $current_shell — cannot auto-configure PATH."
    _warn "Manually add to your rc file: export PATH=\"$bin_dir:\$PATH\""
    ;;
esac

if [[ -n "$rc_file" ]]; then
  # Create rc file if it doesn't exist
  touch "$rc_file"

  local path_export="export PATH=\"$bin_dir:\$PATH\""
  local path_comment="# kitsync PATH"

  if grep -qF "$path_comment" "$rc_file" 2>/dev/null; then
    _log "PATH already configured in $rc_file — skipping."
  else
    _step "Adding $bin_dir to PATH in $rc_file..."
    printf '\n%s\n%s\n' "$path_comment" "$path_export" >> "$rc_file"
    _ok "PATH configured in $rc_file"
  fi
fi

# ---------------------------------------------------------------------------
# Step 5: Verify installation
# ---------------------------------------------------------------------------
# Export PATH immediately so we can test the binary
export PATH="$bin_dir:$PATH"

if command -v kitsync &>/dev/null; then
  local installed_version
  installed_version="$(kitsync --version 2>/dev/null || echo "unknown")"
  _ok "kitsync is ready: $installed_version"
else
  _warn "kitsync binary not found in PATH yet — reload your shell after install."
fi

printf "\n"
_ok "Installation complete!"
printf "\n"
printf "  ${_c_cyan}Next steps:${_c_reset}\n" >&2
printf "  1. Reload your shell:  source %s\n" "${rc_file:-~/.zshrc}" >&2
printf "  2. Initialise sync:    kitsync init --remote <your-git-remote-url>\n" >&2
printf "  3. Invoke Claude:      claude (wrapper installed automatically by init)\n" >&2
printf "\n"

} # end install()

# ---------------------------------------------------------------------------
# Entry point — called only when the full script has been downloaded.
# This is the partial-download protection.
# ---------------------------------------------------------------------------
install "$@"
