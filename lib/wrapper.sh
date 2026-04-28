#!/usr/bin/env bash
# lib/wrapper.sh — Shell wrapper generator and installer for ~/.zshrc / ~/.bashrc
set -euo pipefail

readonly WRAPPER_START_MARKER="# kitsync-start"
readonly WRAPPER_END_MARKER="# kitsync-end"

# ---------------------------------------------------------------------------
# generate_wrapper — outputs the claude() shell function text.
# Reads KITSYNC_PULL_MODE / KITSYNC_PUSH_MODE / KITSYNC_PUSH_TIMER from
# $CLAUDE_HOME/.kitsync/config at runtime — no re-install needed after
# changing sync preferences.
# ---------------------------------------------------------------------------
generate_wrapper() {
  cat <<'WRAPPER_BODY'
# kitsync-start
# This block is managed by claude-kitsync — do not edit manually.
# To update: run `claude-kitsync init` again or edit ~/.zshrc after this block.
claude() {
  local _ks_home="${CLAUDE_HOME:-$HOME/.claude}"
  local _ks_cfg="$_ks_home/.kitsync/config"

  # Load sync preferences (defaults: auto pull, end-of-session push)
  local _ks_pull="auto"
  local _ks_push="end_of_session"
  local _ks_timer="15"
  if [[ -f "$_ks_cfg" ]]; then
    local _v
    _v="$(grep '^KITSYNC_PULL_MODE=' "$_ks_cfg" 2>/dev/null | cut -d= -f2-)" && [[ -n "$_v" ]] && _ks_pull="$_v"
    _v="$(grep '^KITSYNC_PUSH_MODE=' "$_ks_cfg" 2>/dev/null | cut -d= -f2-)" && [[ -n "$_v" ]] && _ks_push="$_v"
    _v="$(grep '^KITSYNC_PUSH_TIMER=' "$_ks_cfg" 2>/dev/null | cut -d= -f2-)" && [[ -n "$_v" ]] && _ks_timer="$_v"
  fi

  local _ks_is_repo=false
  [[ -d "$_ks_home" ]] && git -C "$_ks_home" rev-parse --git-dir &>/dev/null 2>&1 && _ks_is_repo=true

  # Auto-pull on launch (background, non-blocking)
  if [[ "$_ks_is_repo" == true ]] && [[ "$_ks_pull" == "auto" ]]; then
    (
      timeout "${KITSYNC_TIMEOUT:-2}" git -C "$_ks_home" pull --rebase --autostash -q 2>/dev/null
      command -v claude-kitsync &>/dev/null && claude-kitsync _post-pull-hook 2>/dev/null || true
    ) &
    disown
  fi

  # Timer-based push: sentinel file controls loop lifetime
  local _ks_sentinel=""
  if [[ "$_ks_is_repo" == true ]] && [[ "$_ks_push" == "timer" ]]; then
    _ks_sentinel="$(mktemp /tmp/kitsync-XXXX 2>/dev/null || true)"
    (
      while [[ -f "$_ks_sentinel" ]]; do
        sleep "${_ks_timer}m"
        [[ -f "$_ks_sentinel" ]] || break
        command -v claude-kitsync &>/dev/null && \
          claude-kitsync push "kitsync: auto-push $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || true
      done
    ) &
    disown
  fi

  # Run the real claude binary
  command claude "$@"
  local _ks_exit=$?

  # Stop timer loop
  [[ -n "$_ks_sentinel" ]] && rm -f "$_ks_sentinel" 2>/dev/null || true

  # End-of-session push (background, non-blocking)
  if [[ "$_ks_is_repo" == true ]] && [[ "$_ks_push" == "end_of_session" ]]; then
    (
      command -v claude-kitsync &>/dev/null && \
        claude-kitsync push "kitsync: auto-push $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || true
    ) &
    disown
  fi

  return $_ks_exit
}
# kitsync-end
WRAPPER_BODY
}

# ---------------------------------------------------------------------------
# _render_wrapper — returns the wrapper text
# ---------------------------------------------------------------------------
_render_wrapper() {
  generate_wrapper
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
  log_success "Shell wrapper removed from rc files."
}

# ---------------------------------------------------------------------------
# _remove_path_from_rc — remove the PATH injection line added by install.sh
# Handles both old marker (# kitsync PATH) and new (# claude-kitsync PATH)
# ---------------------------------------------------------------------------
_remove_path_from_rc() {
  local rc_file="$1"
  if [[ ! -f "$rc_file" ]]; then return 0; fi
  if ! grep -qF "kitsync PATH" "$rc_file" 2>/dev/null; then return 0; fi

  local tmp_file
  tmp_file="$(mktemp)"
  # Remove the marker line and the export PATH line that follows it
  awk '/^# kitsync PATH$|^# claude-kitsync PATH$/{skip=1; next} skip{skip=0; next} {print}' \
    "$rc_file" > "$tmp_file"
  mv "$tmp_file" "$rc_file"
  log_info "Removed PATH entry from $rc_file"
}
