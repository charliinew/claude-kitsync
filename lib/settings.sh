#!/usr/bin/env bash
# lib/settings.sh — interactive multi-category settings menu
set -euo pipefail

# ---------------------------------------------------------------------------
# _settings_remote — view and change the git remote
# ---------------------------------------------------------------------------
_settings_remote() {
  local current
  current="$(git -C "$CLAUDE_HOME" remote get-url origin 2>/dev/null || echo '(none)')"

  printf "\n" >&2
  log_info "Current remote: $current"

  local opts=()
  local actions=()
  local has_gh=false
  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    has_gh=true
    opts+=("Create a new GitHub repo")
    opts+=("Connect to an existing GitHub repo")
    actions+=("new") actions+=("connect")
  fi
  opts+=("Enter a URL manually")
  opts+=("Back")
  actions+=("url") actions+=("back")

  local choice
  choice="$(_select_menu "Remote & Repository" "${opts[@]}")"
  local action="${actions[$((choice - 1))]}"

  local new_url=""
  case "$action" in
    new)
      _INIT_REMOTE_MODE="new"
      new_url="$(_create_repo_via_gh)"
      ;;
    connect)
      _INIT_REMOTE_MODE="connect"
      new_url="$(_connect_repo_via_gh)"
      ;;
    url)
      new_url="$(_read_tty "Git URL (SSH or HTTPS, blank to cancel)")"
      ;;
    back)
      return 0
      ;;
  esac

  if [[ -n "$new_url" ]]; then
    if git -C "$CLAUDE_HOME" remote get-url origin &>/dev/null 2>&1; then
      git -C "$CLAUDE_HOME" remote set-url origin "$new_url"
      log_success "Remote updated: $new_url"
    else
      git -C "$CLAUDE_HOME" remote add origin "$new_url"
      log_success "Remote added: $new_url"
    fi
  fi
}

# ---------------------------------------------------------------------------
# _settings_profiles — manage named sync profiles
# ---------------------------------------------------------------------------
_settings_profiles() {
  local current_active
  current_active="$(_profile_get_active)"

  printf "\n" >&2
  if [[ -n "$current_active" ]]; then
    local current_url
    current_url="$(_profile_get_url "$current_active")"
    log_info "Active profile: $current_active  ($current_url)"
  else
    log_info "Active profile: none  (single-remote mode)"
  fi

  local choice
  choice="$(_select_menu "Profiles — manage work/perso remotes" \
    "List profiles" \
    "Add a profile" \
    "Switch profile" \
    "Remove a profile" \
    "Back")"

  case "$choice" in
    1) _profile_list_all_display ;;
    2) _profile_add ;;
    3)
      local names_list
      names_list="$(_profile_list_names)"
      if [[ -z "$names_list" ]]; then
        log_warn "No profiles configured. Add one first."
        return 0
      fi
      local options=()
      while IFS= read -r n; do
        [[ -n "$n" ]] && options+=("$n")
      done <<< "$names_list"
      options+=("Back")
      local sw_choice
      sw_choice="$(_select_menu "Switch to profile:" "${options[@]}")"
      local idx=$(( sw_choice - 1 ))
      if [[ "${options[$idx]}" != "Back" ]]; then
        _profile_switch "${options[$idx]}"
      fi
      ;;
    4) _profile_remove ;;
    5) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# _settings_sync — pull/push timing preferences
# ---------------------------------------------------------------------------
_settings_sync() {
  local cfg="$CLAUDE_HOME/.kitsync/config"
  if [[ -f "$cfg" ]]; then
    local pull_mode push_mode push_timer
    pull_mode="$(grep '^KITSYNC_PULL_MODE=' "$cfg" 2>/dev/null | cut -d= -f2- || echo auto)"
    push_mode="$(grep '^KITSYNC_PUSH_MODE=' "$cfg" 2>/dev/null | cut -d= -f2- || echo end_of_session)"
    push_timer="$(grep '^KITSYNC_PUSH_TIMER=' "$cfg" 2>/dev/null | cut -d= -f2- || echo 15)"
    printf "\n" >&2
    log_info "Current: pull=$pull_mode  push=${push_mode}$( [[ "$push_mode" == "timer" ]] && printf " (every %sm)" "$push_timer" || true)"
  fi

  _prompt_sync_preferences
}

# ---------------------------------------------------------------------------
# _settings_wrapper — reinstall or remove the shell wrapper
# ---------------------------------------------------------------------------
_settings_wrapper() {
  local zshrc="${ZDOTDIR:-$HOME}/.zshrc"
  local bashrc="$HOME/.bashrc"
  local installed_in=()
  { [[ -f "$zshrc" ]] && grep -qF "# kitsync-start" "$zshrc" 2>/dev/null; } && installed_in+=("$zshrc")
  { [[ -f "$bashrc" ]] && grep -qF "# kitsync-start" "$bashrc" 2>/dev/null; } && installed_in+=("$bashrc")

  printf "\n" >&2
  if [[ ${#installed_in[@]} -gt 0 ]]; then
    for _f in "${installed_in[@]}"; do
      log_info "Wrapper installed in: $_f"
    done
  else
    log_warn "Wrapper not found in any rc file"
  fi

  local choice
  choice="$(_select_menu "Shell wrapper" \
    "Reinstall  (update to latest version)" \
    "Remove wrapper" \
    "Back")"

  case "$choice" in
    1)
      log_step "Reinstalling shell wrapper..."
      install_wrapper_auto
      _print_reload_notice
      ;;
    2)
      if confirm "Remove the claude() wrapper from your shell?"; then
        remove_wrapper
        log_success "Wrapper removed."
        log_info "Run 'claude-kitsync init' to reinstall."
      fi
      ;;
    3) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# _settings_security — toggle encryption, show status
# ---------------------------------------------------------------------------
_settings_security() {
  printf "\n" >&2
  if _crypto_is_enabled 2>/dev/null; then
    log_success "Encryption: enabled  (AES-256-CBC)"
    local _kf; _kf="$(_crypto_key_path)"
    [[ -f "$_kf" ]] && log_info "Key file: $_kf" || log_warn "Key file: MISSING"
  else
    log_info "Encryption: disabled"
  fi

  local choice
  choice="$(_select_menu "Security & Encryption" \
    "Enable encryption  — encrypt settings.json before push" \
    "Disable encryption — commit settings.json in plaintext" \
    "Rotate key         — generate a new encryption key" \
    "Status" \
    "Back")"

  case "$choice" in
    1) cmd_encrypt enable ;;
    2) cmd_encrypt disable ;;
    3) cmd_encrypt rotate ;;
    4) cmd_encrypt status ;;
    5) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# _settings_about — show current config, version, and run doctor
# ---------------------------------------------------------------------------
_settings_about() {
  local choice
  choice="$(_select_menu "Status & info" \
    "Show current config" \
    "Run doctor" \
    "Back")"

  case "$choice" in
    1)
      printf "\n" >&2
      log_info "Version:     ${KITSYNC_VERSION:-dev}"
      log_info "CLAUDE_HOME: $CLAUDE_HOME"
      local remote
      remote="$(git -C "$CLAUDE_HOME" remote get-url origin 2>/dev/null || echo '(none)')"
      log_info "Remote:      $remote"

      local _active_prof
      _active_prof="$(_profile_get_active)"
      if [[ -n "$_active_prof" ]]; then
        log_info "Profile:     $_active_prof"
      fi

      local cfg="$CLAUDE_HOME/.kitsync/config"
      if [[ -f "$cfg" ]]; then
        local pull_mode push_mode push_timer
        pull_mode="$(grep '^KITSYNC_PULL_MODE=' "$cfg" 2>/dev/null | cut -d= -f2- || echo auto)"
        push_mode="$(grep '^KITSYNC_PUSH_MODE=' "$cfg" 2>/dev/null | cut -d= -f2- || echo end_of_session)"
        push_timer="$(grep '^KITSYNC_PUSH_TIMER=' "$cfg" 2>/dev/null | cut -d= -f2- || echo 15)"
        log_info "Pull mode:   $pull_mode"
        if [[ "$push_mode" == "timer" ]]; then
          log_info "Push mode:   $push_mode (every ${push_timer}m)"
        else
          log_info "Push mode:   $push_mode"
        fi
      else
        log_info "Sync config: (no config file — defaults apply)"
      fi

      local zshrc="${ZDOTDIR:-$HOME}/.zshrc"
      if [[ -f "$zshrc" ]] && grep -qF "# kitsync-start" "$zshrc" 2>/dev/null; then
        log_info "Wrapper:     installed in $zshrc"
      else
        log_warn "Wrapper:     not found — run: claude-kitsync init"
      fi
      printf "\n" >&2
      ;;
    2)
      printf "\n" >&2
      cmd_doctor
      ;;
    3) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# cmd_settings — main settings loop with category navigation
# ---------------------------------------------------------------------------
cmd_settings() {
  require_git_repo

  local _first=true
  while true; do
    # After each iteration _select_menu leaves cursor at summary+1.
    # Go back up 1 so the next menu overwrites the previous summary
    # instead of drifting down. Skip on first iteration.
    if [[ "$_first" == false ]]; then
      printf "\033[1A" >/dev/tty 2>/dev/null || true
    fi
    _first=false

    local choice
    choice="$(_select_menu "claude-kitsync settings" \
      "Remote & Repository  — change sync target" \
      "Profiles             — manage work/perso remotes" \
      "Security             — encryption for API keys" \
      "Sync timing          — pull / push modes" \
      "Shell wrapper        — reinstall or remove" \
      "Status & info        — config, version, doctor" \
      "Exit")"

    case "$choice" in
      1) _settings_remote ;;
      2) _settings_profiles ;;
      3) _settings_security ;;
      4) _settings_sync ;;
      5) _settings_wrapper ;;
      6) _settings_about ;;
      7) break ;;
    esac
  done
}
