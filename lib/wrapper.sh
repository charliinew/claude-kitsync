#!/usr/bin/env bash
# lib/wrapper.sh — Shell wrapper generator and installer for ~/.zshrc / ~/.bashrc
set -euo pipefail

readonly WRAPPER_START_MARKER="# kitsync-start"
readonly WRAPPER_END_MARKER="# kitsync-end"

# ---------------------------------------------------------------------------
# generate_wrapper — outputs the claude() shell function text.
# Uses CLAUDE_HOME and KITSYNC_TIMEOUT (defaults to 2).
# ---------------------------------------------------------------------------
generate_wrapper() {
  local kitsync_timeout="${KITSYNC_TIMEOUT:-2}"

  cat <<'WRAPPER_BODY'
# kitsync-start
# This block is managed by kitsync — do not edit manually.
# To update: run `kitsync init` again or edit ~/.zshrc after this block.
claude() {
  local _claude_home="${CLAUDE_HOME:-$HOME/.claude}"
  if [[ -d "$_claude_home" ]] && git -C "$_claude_home" rev-parse --git-dir &>/dev/null 2>&1; then
    (
      timeout KITSYNC_TIMEOUT_PLACEHOLDER git -C "$_claude_home" pull --rebase --autostash -q 2>/dev/null
      if command -v kitsync &>/dev/null; then
        kitsync _post-pull-hook 2>/dev/null || true
      fi
    ) &
    disown
  fi
  command claude "$@"
}
# kitsync-end
WRAPPER_BODY
  # Replace the placeholder with actual timeout value
}

# ---------------------------------------------------------------------------
# _render_wrapper — returns the wrapper text with the timeout substituted
# ---------------------------------------------------------------------------
_render_wrapper() {
  local kitsync_timeout="${KITSYNC_TIMEOUT:-2}"
  # Validate timeout is a positive integer to prevent sed corruption of rc file
  [[ "$kitsync_timeout" =~ ^[0-9]+$ ]] || kitsync_timeout=2
  generate_wrapper | sed "s|KITSYNC_TIMEOUT_PLACEHOLDER|${kitsync_timeout}|g"
}

# ---------------------------------------------------------------------------
# _inject_into_rc — idempotent injection of wrapper block into a rc file
#
# If markers already exist: replaces the block between them.
# If markers do not exist: appends at the end.
# ---------------------------------------------------------------------------
_inject_into_rc() {
  local rc_file="$1"

  # Create the file if it doesn't exist
  if [[ ! -f "$rc_file" ]]; then
    touch "$rc_file"
    log_info "Created $rc_file"
  fi

  local wrapper_text
  wrapper_text="$(_render_wrapper)"

  if grep -qF "$WRAPPER_START_MARKER" "$rc_file" 2>/dev/null; then
    # Markers exist — replace the block between them (inclusive)
    log_info "Updating existing kitsync block in $rc_file"

    # We need a temp file for safe in-place editing
    local tmp_file
    tmp_file="$(mktemp)"

    # Use awk to replace the block between markers
    awk -v start="$WRAPPER_START_MARKER" -v end="$WRAPPER_END_MARKER" \
        -v new_block="$wrapper_text" \
    '
    $0 == start { in_block=1; print new_block; next }
    in_block && $0 == end { in_block=0; next }
    !in_block { print }
    ' "$rc_file" > "$tmp_file"

    # Replace original with modified version
    mv "$tmp_file" "$rc_file"
  else
    # No markers — append block at end of file
    log_info "Adding kitsync wrapper to $rc_file"
    printf '\n%s\n' "$wrapper_text" >> "$rc_file"
  fi
}

# ---------------------------------------------------------------------------
# _remove_from_rc — remove the kitsync block from a rc file
# ---------------------------------------------------------------------------
_remove_from_rc() {
  local rc_file="$1"

  if [[ ! -f "$rc_file" ]]; then
    return 0
  fi

  if ! grep -qF "$WRAPPER_START_MARKER" "$rc_file" 2>/dev/null; then
    return 0
  fi

  log_info "Removing kitsync block from $rc_file"

  local tmp_file
  tmp_file="$(mktemp)"

  awk -v start="$WRAPPER_START_MARKER" -v end="$WRAPPER_END_MARKER" \
  '
  $0 == start { in_block=1; next }
  in_block && $0 == end { in_block=0; next }
  !in_block { print }
  ' "$rc_file" > "$tmp_file"

  mv "$tmp_file" "$rc_file"
}

# ---------------------------------------------------------------------------
# install_wrapper_zsh — install wrapper into ~/.zshrc
# ---------------------------------------------------------------------------
install_wrapper_zsh() {
  local zshrc="${ZDOTDIR:-$HOME}/.zshrc"
  _inject_into_rc "$zshrc"
  log_success "Wrapper installed in $zshrc"
}

# ---------------------------------------------------------------------------
# install_wrapper_bash — install wrapper into ~/.bashrc
# ---------------------------------------------------------------------------
install_wrapper_bash() {
  local bashrc="$HOME/.bashrc"
  _inject_into_rc "$bashrc"
  log_success "Wrapper installed in $bashrc"
}

# ---------------------------------------------------------------------------
# install_wrapper_auto — detect current shell and install accordingly
# ---------------------------------------------------------------------------
install_wrapper_auto() {
  local current_shell
  current_shell="$(basename "${SHELL:-/bin/bash}")"

  case "$current_shell" in
    zsh)
      install_wrapper_zsh
      ;;
    bash)
      install_wrapper_bash
      ;;
    *)
      log_warn "Unrecognised shell: $current_shell — installing in both ~/.zshrc and ~/.bashrc"
      install_wrapper_zsh
      install_wrapper_bash
      ;;
  esac
}

# ---------------------------------------------------------------------------
# remove_wrapper — remove wrapper from both rc files
# ---------------------------------------------------------------------------
remove_wrapper() {
  _remove_from_rc "${ZDOTDIR:-$HOME}/.zshrc"
  _remove_from_rc "$HOME/.bashrc"
  log_success "kitsync wrapper removed from shell rc files."
}
