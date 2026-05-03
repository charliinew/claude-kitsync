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
  # Suppress job PID/Done notifications for background sync ops.
  # LOCAL_OPTIONS scopes the change to this function only (zsh restores on exit).
  [[ -n "${ZSH_VERSION:-}" ]] && setopt LOCAL_OPTIONS NO_MONITOR NO_NOTIFY 2>/dev/null || true

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

  # _ks_bg — launch subshell silently in background (no job notification)
  # zsh: &! disowns atomically without printing PID; bash: & + disown
  _ks_bg() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
      ("$@") &!
    else
      ("$@") &
      disown
    fi
  }

  # Auto-pull on launch (background, non-blocking)
  if [[ "$_ks_is_repo" == true ]] && [[ "$_ks_pull" == "auto" ]]; then
    if [[ -n "${ZSH_VERSION:-}" ]]; then
      (timeout "${KITSYNC_TIMEOUT:-2}" git -C "$_ks_home" pull --rebase --autostash -q 2>/dev/null
       command -v claude-kitsync &>/dev/null && claude-kitsync _post-pull-hook 2>/dev/null || true) &!
    else
      (timeout "${KITSYNC_TIMEOUT:-2}" git -C "$_ks_home" pull --rebase --autostash -q 2>/dev/null
       command -v claude-kitsync &>/dev/null && claude-kitsync _post-pull-hook 2>/dev/null || true) &
      disown
    fi
  fi

  # Timer-based push: sentinel file controls loop lifetime
  local _ks_sentinel=""
  if [[ "$_ks_is_repo" == true ]] && [[ "$_ks_push" == "timer" ]]; then
    _ks_sentinel="$(mktemp /tmp/kitsync-XXXX 2>/dev/null || true)"
    if [[ -n "${ZSH_VERSION:-}" ]]; then
      (while [[ -f "$_ks_sentinel" ]]; do
         sleep "${_ks_timer}m"
         [[ -f "$_ks_sentinel" ]] || break
         command -v claude-kitsync &>/dev/null && \
           claude-kitsync push --auto "kitsync: auto-push $(date '+%Y-%m-%d %H:%M')" >/dev/null || true
       done) &!
    else
      (while [[ -f "$_ks_sentinel" ]]; do
         sleep "${_ks_timer}m"
         [[ -f "$_ks_sentinel" ]] || break
         command -v claude-kitsync &>/dev/null && \
           claude-kitsync push --auto "kitsync: auto-push $(date '+%Y-%m-%d %H:%M')" >/dev/null || true
       done) &
      disown
    fi
  fi

  # Run the real claude binary
  command claude "$@"
  local _ks_exit=$?

  # Stop timer loop
  [[ -n "$_ks_sentinel" ]] && rm -f "$_ks_sentinel" 2>/dev/null || true

  # End-of-session push (background, non-blocking)
  if [[ "$_ks_is_repo" == true ]] && [[ "$_ks_push" == "end_of_session" ]]; then
    if [[ -n "${ZSH_VERSION:-}" ]]; then
      (command -v claude-kitsync &>/dev/null && \
        claude-kitsync push --auto "kitsync: auto-push $(date '+%Y-%m-%d %H:%M')" >/dev/null || true) &!
    else
      (command -v claude-kitsync &>/dev/null && \
        claude-kitsync push --auto "kitsync: auto-push $(date '+%Y-%m-%d %H:%M')" >/dev/null || true) &
      disown
    fi
  fi

  unset -f _ks_bg
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
# cmd_restore — interactively restore a rc file from a kitsync backup
# ---------------------------------------------------------------------------
cmd_restore() {
  local backup_dir="${CLAUDE_HOME:-$HOME/.claude}/.kitsync/backups"

  if [[ ! -d "$backup_dir" ]]; then
    log_error "No backup directory found: $backup_dir"
    log_info  "Backups are created automatically when claude-kitsync modifies your rc file."
    return 1
  fi

  local backups=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && backups+=("$f")
  done < <(ls -t "$backup_dir"/*.bak 2>/dev/null || true)

  if [[ ${#backups[@]} -eq 0 ]]; then
    log_error "No backups found in $backup_dir"
    return 1
  fi

  # Build human-readable labels: ".zshrc  —  2026-05-03 13:11:21"
  local labels=()
  for f in "${backups[@]}"; do
    local bn stem ts_raw rc_name ts_fmt
    bn="$(basename "$f")"          # .zshrc.20260503T131121.bak
    stem="${bn%.bak}"              # .zshrc.20260503T131121
    ts_raw="${stem##*.}"           # 20260503T131121
    rc_name="${stem%.*}"           # .zshrc
    ts_fmt="${ts_raw:0:4}-${ts_raw:4:2}-${ts_raw:6:2} ${ts_raw:9:2}:${ts_raw:11:2}:${ts_raw:13:2}"
    labels+=("${rc_name}  —  ${ts_fmt}")
  done

  local idx
  idx="$(_select_menu "Select a backup to restore" "${labels[@]}")"
  local selected="${backups[$((idx - 1))]}"

  # Derive target rc path from backup filename
  local bn stem rc_name target_rc
  bn="$(basename "$selected")"
  stem="${bn%.bak}"
  rc_name="${stem%.*}"
  case "$rc_name" in
    .zshrc)  target_rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
    .bashrc) target_rc="$HOME/.bashrc" ;;
    *)       target_rc="$HOME/$rc_name" ;;
  esac

  log_info "Restoring $target_rc from $(basename "$selected")..."
  _backup_rc "$target_rc"
  cp "$selected" "$target_rc"
  log_success "Restored: $target_rc"
  log_info "Run 'source $target_rc' or open a new terminal to apply."
}

# ---------------------------------------------------------------------------
# _backup_rc — snapshot a rc file into ~/.claude/.kitsync/backups/
#
# Keeps the 5 most recent backups per rc file. Silently skips if the
# backup directory cannot be created (non-fatal).
# ---------------------------------------------------------------------------
_backup_rc() {
  local rc_file="$1"
  [[ -f "$rc_file" ]] || return 0

  local backup_dir="${CLAUDE_HOME:-$HOME/.claude}/.kitsync/backups"
  mkdir -p "$backup_dir" 2>/dev/null || return 0

  local basename timestamp backup_path
  basename="$(basename "$rc_file")"
  timestamp="$(date '+%Y%m%dT%H%M%S')"
  backup_path="$backup_dir/${basename}.${timestamp}.bak"

  cp "$rc_file" "$backup_path" || return 0

  # Prune: keep only the 5 most recent backups for this rc file
  ls -t "$backup_dir/${basename}".*.bak 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

  log_info "Backed up $rc_file → $backup_path"
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

  _backup_rc "$rc_file"

  local wrapper_text
  wrapper_text="$(_render_wrapper)"

  if grep -qF "$WRAPPER_START_MARKER" "$rc_file" 2>/dev/null; then
    # Markers exist — replace the block between them (inclusive)
    log_info "Updating existing kitsync block in $rc_file"

    # We need a temp file for safe in-place editing
    local tmp_file
    tmp_file="$(mktemp)"

    # Write wrapper to a temp file so awk can read it via getline
    # (awk -v doesn't support multi-line strings)
    local new_block_file
    new_block_file="$(mktemp)"
    printf '%s\n' "$wrapper_text" > "$new_block_file"

    awk -v start="$WRAPPER_START_MARKER" -v end="$WRAPPER_END_MARKER" \
        -v nbf="$new_block_file" \
    '
    $0 == start { while ((getline line < nbf) > 0) print line; in_block=1; next }
    in_block && $0 == end { in_block=0; next }
    !in_block { print }
    ' "$rc_file" > "$tmp_file"

    rm -f "$new_block_file"
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

  _backup_rc "$rc_file"
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
