#!/usr/bin/env bash
# install.sh — curl -fsSL https://raw.githubusercontent.com/charliinew/claude-kitsync/main/install.sh | bash
#
# One command = fully configured:
#   curl -fsSL .../install.sh | bash
#   # or with a known remote (variables go on the bash side of the pipe):
#   curl -fsSL .../install.sh | KITSYNC_REMOTE=git@github.com:you/claude-config.git bash
#
# Environment:
#   KITSYNC_REMOTE   git URL of your config repo (skips the storage question)
#   KITSYNC_VERSION  tag to install (e.g. v1.1.6) or "main"; default: latest release
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
  local default="${2:-}"
  local reply=""

  if [[ -n "$default" ]]; then
    printf "  ${_c_cyan}◆${_c_reset}  %s ${_c_bold}(%s)${_c_reset}: " "$prompt" "$default" >/dev/tty
  else
    printf "  ${_c_cyan}◆${_c_reset}  %s: " "$prompt" >/dev/tty
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

# Arrow-key select menu via /dev/tty — works inside $(...) and curl|bash
_select_tty() {
  local prompt="$1"
  shift
  local options=("$@")
  local n=${#options[@]}
  local selected=0

  # Hide cursor; on Ctrl+C restore it and abort (never return the highlighted option)
  printf '\033[?25l' >/dev/tty
  trap 'printf "\033[?25h\n" >/dev/tty; exit 130' INT TERM

  # Print header + initial menu
  printf "\n" >/dev/tty
  printf "  ${_c_bold}%s${_c_reset}\n" "$prompt" >/dev/tty
  printf "\n" >/dev/tty
  local i
  for (( i=0; i<n; i++ )); do
    if [[ $i -eq $selected ]]; then
      printf "  ${_c_cyan}${_c_bold}❯${_c_reset}  ${_c_cyan}%s${_c_reset}\n" "${options[$i]}" >/dev/tty
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
        printf "  ${_c_cyan}${_c_bold}❯${_c_reset}  ${_c_cyan}%s${_c_reset}\n" "${options[$i]}" >/dev/tty
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
  printf "  ${_c_cyan}◆${_c_reset}  ${_c_bold}%s${_c_reset}  ${_c_cyan}%s${_c_reset}\n" \
    "$prompt" "${options[$selected]}" >/dev/tty

  # Restore cursor
  printf '\033[?25h' >/dev/tty
  trap - INT TERM

  printf '%s' "$(( selected + 1 ))"
}

# _gh_clone_url <owner/repo> — URL matching the git protocol configured in gh
# (SSH only if the user chose it; HTTPS pushes go through gh's credential helper)
_gh_clone_url() {
  local proto
  proto="$(gh config get git_protocol -h github.com 2>/dev/null || true)"
  if [[ "$proto" == "ssh" ]]; then
    printf 'git@github.com:%s.git' "$1"
  else
    printf 'https://github.com/%s.git' "$1"
  fi
}

# Create a new GitHub repo via gh CLI, return its clone URL
_gh_create_repo_tty() {
  local repo_name
  repo_name="$(_read_tty "Repo name" "claude-config")"
  local vis_choice
  vis_choice="$(_select_tty "Visibility?" "Private  (recommended)" "Public")" || _die "Installation aborted."
  local vis_flag="--private"
  [[ "$vis_choice" == "2" ]] && vis_flag="--public"

  _step "Creating GitHub repo: $repo_name..."
  if gh repo create "$repo_name" "$vis_flag" --description "Claude Code config sync" >/dev/null 2>&1; then
    local gh_login
    gh_login="$(gh api user -q .login 2>/dev/null)"
    local result_url
    result_url="$(_gh_clone_url "${gh_login}/${repo_name}")"
    _ok "Repo created: github.com/${gh_login}/${repo_name}"
    printf '%s' "$result_url"
  else
    _warn "gh repo create failed — enter URL manually."
    printf '%s' "$(_read_tty "Git URL (SSH or HTTPS, blank to skip)" "")"
  fi
}

# Browse existing GitHub repos via gh CLI, return the selected clone URL
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
  choice="$(_select_tty "Select a repository:" "${options[@]}")" || _die "Installation aborted."

  local selected="${options[$((choice - 1))]}"
  _gh_clone_url "$selected"
}

# GitHub sub-menu: create new or connect existing
_gh_repo_flow_tty() {
  local action
  action="$(_select_tty "GitHub repository:" \
    "Create a new repo" \
    "Connect to an existing repo")" || _die "Installation aborted."

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
  choice="$(_select_tty "Where should your Claude config be stored?" "${options[@]}")" || _die "Installation aborted."

  local actions=()
  [[ "$has_gh" == "true" ]] && actions+=("github")
  actions+=("url_input")
  actions+=("skip")
  local action="${actions[$((choice - 1))]}"

  case "$action" in
    github)
      _gh_repo_flow_tty || exit 1
      ;;
    url_input)
      printf '%s' "$(_read_tty "Git URL (SSH or HTTPS, blank to skip)" "")"
      ;;
    skip)
      printf ''
      ;;
  esac
}

# _resolve_ref — what to install: $KITSYNC_VERSION, else the latest release
# (same channel as `claude-kitsync upgrade`), else the highest tag, else main
_resolve_ref() {
  if [[ -n "${KITSYNC_VERSION:-}" ]]; then
    printf '%s' "$KITSYNC_VERSION"
    return 0
  fi
  local tag=""
  if command -v curl &>/dev/null; then
    tag="$(curl -fsSL "https://api.github.com/repos/charliinew/claude-kitsync/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
  fi
  if [[ -z "$tag" ]]; then
    tag="$(git ls-remote --tags --sort=-v:refname "$KITSYNC_REPO" 'refs/tags/v*' 2>/dev/null \
      | grep -v '\^{}' | head -1 | sed 's|.*refs/tags/||' || true)"
  fi
  printf '%s' "${tag:-main}"
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
else
  local ref git_out
  ref="$(_resolve_ref)"
  if [[ -d "$install_dir/.git" ]]; then
    _step "Updating kitsync to $ref..."
    # Managed clone: move it to the requested ref (a pull --rebase would fail
    # if upstream history was ever rewritten)
    if git_out="$(git -C "$install_dir" fetch -q --depth 1 origin "$ref" 2>&1 && \
                  git -C "$install_dir" reset -q --hard FETCH_HEAD 2>&1)"; then
      _ok "kitsync $ref ready"
    else
      _warn "Update failed, keeping current version:"
      printf '%s\n' "$git_out" | sed 's/^/      /' >&2
    fi
  else
    _step "Installing kitsync $ref..."
    [[ -d "$install_dir" ]] && rm -rf "$install_dir"
    if ! git_out="$(git -c advice.detachedHead=false clone -q --depth 1 \
                    --branch "$ref" "$KITSYNC_REPO" "$install_dir" 2>&1)"; then
      printf '%s\n' "$git_out" | sed 's/^/      /' >&2
      _die "Clone failed (see git output above)."
    fi
    _ok "kitsync $ref installed"
  fi
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

# ---------------------------------------------------------------------------
# Step 4b: Shell completions — loaded from the install dir by the rc file
# (a directory zsh really searches; nothing written into Homebrew's prefix)
# ---------------------------------------------------------------------------
local comp_dir="$install_dir/completions"

# Drop links left by older installers (brew prefix / ~/.zsh/completions)
local _brew_prefix _old_link
_brew_prefix="$(brew --prefix 2>/dev/null || true)"
for _old_link in \
    "$_brew_prefix/share/zsh/site-functions/_claude-kitsync" \
    "$_brew_prefix/etc/bash_completion.d/claude-kitsync" \
    "${ZDOTDIR:-$HOME}/.zsh/completions/_claude-kitsync"; do
  # Any link into a script-installed kitsync (incl. dangling ones from a moved
  # or deleted install); Homebrew's own links point into its Cellar instead
  if [[ -L "$_old_link" ]] && [[ "$(readlink "$_old_link")" == */kitsync/completions/* ]]; then
    rm -f "$_old_link"
  fi
done

if [[ -n "$rc_file" ]] && [[ -d "$comp_dir" ]] && \
   ! grep -qF "# claude-kitsync completion" "$rc_file" 2>/dev/null; then
  case "$current_shell" in
    zsh)
      {
        printf '\n# claude-kitsync completion\n'
        printf 'fpath=("%s" $fpath)\n' "$comp_dir"
        # shellcheck disable=SC2016
        printf '(( $+functions[compdef] )) && { autoload -Uz _claude-kitsync && compdef _claude-kitsync claude-kitsync; }\n'
        printf '# claude-kitsync completion end\n'
      } >> "$rc_file"
      _ok "Zsh completion enabled"
      ;;
    bash)
      {
        printf '\n# claude-kitsync completion\n'
        printf '[ -f "%s/claude-kitsync.bash" ] && . "%s/claude-kitsync.bash"\n' "$comp_dir" "$comp_dir"
        printf '# claude-kitsync completion end\n'
      } >> "$rc_file"
      _ok "Bash completion enabled"
      ;;
  esac
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

if [[ -f "$claude_home/.kitsync/config" ]]; then
  _ok "$claude_home is already set up by kitsync — keeping your configuration."
  # Still ensure wrapper is installed
  "$kitsync_dest" _install-wrapper 2>/dev/null || true
else
  if git -C "$claude_home" rev-parse --git-dir &>/dev/null; then
    _warn "$claude_home is a git repo not set up by kitsync — running init on it."
  fi

  # Get the remote URL (not asked when the existing repo already has one)
  local remote_url="${KITSYNC_REMOTE:-}"

  if [[ -z "$remote_url" ]] && git -C "$claude_home" remote get-url origin &>/dev/null; then
    _log "Keeping existing remote: $(git -C "$claude_home" remote get-url origin)"
  elif [[ -z "$remote_url" ]]; then
    remote_url="$(_select_remote_tty)" || exit 1
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
