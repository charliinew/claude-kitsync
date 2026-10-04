#!/usr/bin/env bash
# lib/profiles.sh — multi-remote profile management for claude-kitsync
set -euo pipefail

# ---------------------------------------------------------------------------
# _profile_get_active — return the active profile name (or empty string)
# ---------------------------------------------------------------------------
_profile_get_active() {
  local cfg="$CLAUDE_HOME/.kitsync/local"
  [[ -f "$cfg" ]] || { printf ''; return 0; }
  grep '^KITSYNC_PROFILE=' "$cfg" 2>/dev/null | cut -d= -f2- || printf ''
}

# ---------------------------------------------------------------------------
# _profile_list_names — return newline-separated list of profile names (lowercase)
# ---------------------------------------------------------------------------
_profile_list_names() {
  local cfg="$CLAUDE_HOME/.kitsync/local"
  [[ -f "$cfg" ]] || { printf ''; return 0; }
  grep '^KITSYNC_PROFILES_[A-Z0-9_]*_URL=' "$cfg" 2>/dev/null \
    | sed 's/^KITSYNC_PROFILES_//;s/_URL=.*//' \
    | tr '[:upper:]' '[:lower:]' \
    || printf ''
}

# ---------------------------------------------------------------------------
# _profile_get_url <name> — return the URL for a profile (or empty string)
# ---------------------------------------------------------------------------
_profile_get_url() {
  local name="${1:-}"
  [[ -n "$name" ]] || { printf ''; return 0; }
  local upper_name
  upper_name="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
  local cfg="$CLAUDE_HOME/.kitsync/local"
  [[ -f "$cfg" ]] || { printf ''; return 0; }
  grep "^KITSYNC_PROFILES_${upper_name}_URL=" "$cfg" 2>/dev/null \
    | cut -d= -f2- || printf ''
}

# ---------------------------------------------------------------------------
# _profile_rewrite_config <active_profile> <name> <url>
# Atomically rewrites .kitsync/local (the profile registry is per machine):
#   - Filters out KITSYNC_PROFILE= and KITSYNC_PROFILES_<NAME>_URL= lines
#   - Appends updated KITSYNC_PROFILE=<active_profile>
#   - Appends updated KITSYNC_PROFILES_<NAME>_URL=<url>
# Pass empty active_profile to clear active profile.
# Pass empty name/url to only update active profile marker.
# ---------------------------------------------------------------------------
_profile_rewrite_config() {
  local active_profile="${1:-}"
  local name="${2:-}"
  local url="${3:-}"

  local cfg="$CLAUDE_HOME/.kitsync/local"
  mkdir -p "$CLAUDE_HOME/.kitsync"
  [[ -f "$cfg" ]] || touch "$cfg"

  local upper_name=""
  [[ -n "$name" ]] && upper_name="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"

  local tmp
  tmp="$(mktemp "${cfg}.XXXXXX")"

  # Filter out the lines we're updating
  grep -v '^KITSYNC_PROFILE=' "$cfg" 2>/dev/null \
    | { [[ -n "$upper_name" ]] && grep -v "^KITSYNC_PROFILES_${upper_name}_URL=" || cat; } \
    > "$tmp" || true

  # Append updated values
  if [[ -n "$active_profile" ]]; then
    printf 'KITSYNC_PROFILE=%s\n' "$active_profile" >> "$tmp"
  else
    printf 'KITSYNC_PROFILE=\n' >> "$tmp"
  fi

  if [[ -n "$upper_name" ]] && [[ -n "$url" ]]; then
    printf 'KITSYNC_PROFILES_%s_URL=%s\n' "$upper_name" "$url" >> "$tmp"
  fi

  mv "$tmp" "$cfg"
}

# ---------------------------------------------------------------------------
# _profile_delete_config <name> — remove a profile from config
# If the deleted profile was active, clears KITSYNC_PROFILE=
# ---------------------------------------------------------------------------
_profile_delete_config() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 1

  local upper_name
  upper_name="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
  local cfg="$CLAUDE_HOME/.kitsync/local"
  [[ -f "$cfg" ]] || return 0

  local tmp
  tmp="$(mktemp "${cfg}.XXXXXX")"

  # Remove the profile URL line
  grep -v "^KITSYNC_PROFILES_${upper_name}_URL=" "$cfg" 2>/dev/null > "$tmp" || true

  # If this was the active profile, clear the active marker
  local current_active
  current_active="$(_profile_get_active)"
  if [[ "$current_active" == "$name" ]]; then
    local tmp2
    tmp2="$(mktemp "${cfg}.XXXXXX")"
    grep -v '^KITSYNC_PROFILE=' "$tmp" 2>/dev/null > "$tmp2" || true
    printf 'KITSYNC_PROFILE=\n' >> "$tmp2"
    mv "$tmp2" "$tmp"
  fi

  mv "$tmp" "$cfg"
}

# ---------------------------------------------------------------------------
# _profile_switch <name> — switch active profile
# ---------------------------------------------------------------------------
# _sync_switch_remote <url> <from-label> <to-label> — make this machine sync
# with another repository without mixing two configs:
#   1. the current config is pushed to its own repository first
#   2. every synced file is backed up as it is on disk
#   3. a repository with content gives this machine its config; an empty one
#      starts with this machine's config
# Changing only the remote URL would merge one config into the other.
# ---------------------------------------------------------------------------
_sync_switch_remote() {
  local url="$1" current="$2" name="$3"
  # 1. The current profile's pending changes go to its own remote first
  if _has_remote && git -C "$CLAUDE_HOME" rev-parse -q --verify HEAD >/dev/null; then
    log_step "Saving ${current:-the current config} to its remote first..."
    if ! sync_push "$(_sync_commit_msg "before switching to $name:")"; then
      log_error "Could not push ${current:-the current config} — nothing was switched. Check: claude-kitsync status"
      return 1
    fi
  fi
  _sync_lock 30 || die "Another kitsync sync is running on this machine — try again in a moment."

  # 2. Keep a copy of every synced file as it is on disk (local-only edits too)
  local bak f
  bak="$CLAUDE_HOME/.kitsync/backups/switch-$(date '+%Y%m%dT%H%M%S')"
  while IFS= read -r -d '' f; do
    [[ -f "$CLAUDE_HOME/$f" ]] || continue
    mkdir -p "$(dirname "$bak/$f")"
    cp -p "$CLAUDE_HOME/$f" "$bak/$f"
  done < <(git -C "$CLAUDE_HOME" ls-files -z 2>/dev/null)

  # 3. Point origin to the profile's remote; forget the old remote's branches
  local old_url
  old_url="$(git -C "$CLAUDE_HOME" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$old_url" ]]; then
    git -C "$CLAUDE_HOME" remote set-url origin "$url"
  else
    git -C "$CLAUDE_HOME" remote add origin "$url"
  fi
  git -C "$CLAUDE_HOME" for-each-ref --format='%(refname)' refs/remotes/origin | \
    while IFS= read -r f; do git -C "$CLAUDE_HOME" update-ref -d "$f"; done
  local err
  if ! err="$(_git_net fetch -q origin 2>&1)"; then
    [[ -n "$old_url" ]] && git -C "$CLAUDE_HOME" remote set-url origin "$old_url"
    git -C "$CLAUDE_HOME" fetch -q origin 2>/dev/null || true
    log_error "Cannot reach $url — nothing was switched:"
    printf '%s\n' "$err" | head -3 | sed 's/^/    /' >&2
    return 1
  fi

  local branch
  branch="$(git -C "$CLAUDE_HOME" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  if git -C "$CLAUDE_HOME" rev-parse -q --verify "origin/$branch" >/dev/null; then
    # 4a. The profile exists: this machine takes its config
    git -C "$CLAUDE_HOME" reset -q --hard "origin/$branch"
    git -C "$CLAUDE_HOME" branch -q --set-upstream-to="origin/$branch" "$branch" 2>/dev/null || true
    _sync_prepare_repo
    _sync_after_pull
    log_success "Switched to $name: this machine now has its config."
  else
    # 4b. A new, empty profile starts from this machine's config
    if ! err="$(git -C "$CLAUDE_HOME" push -q -u origin "HEAD:$branch" 2>&1)"; then
      log_warn "Switched, but the first push to $name failed:"
      printf '%s\n' "$err" | head -3 | sed 's/^/    /' >&2
    fi
    log_success "Switched to $name (it was empty: it starts with this machine's config)."
  fi
  log_info "Files as they were before: $bak"

  # The new config's settings.json may lack the sync hooks
  if declare -F hooks_install >/dev/null && [[ -z "$(_wrapper_rc_files 2>/dev/null)" ]]; then
    hooks_install || true
  fi
}

# ---------------------------------------------------------------------------
_profile_switch() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    log_error "Profile name required."
    return 1
  fi

  local url
  url="$(_profile_get_url "$name")"
  if [[ -z "$url" ]]; then
    log_error "Profile not found: $name"
    log_info "Run: claude-kitsync profile list"
    return 1
  fi

  local current
  current="$(_profile_get_active)"
  if [[ "$current" == "$name" ]]; then
    log_info "Already on profile: $name"
    return 0
  fi

  _sync_switch_remote "$url" "profile '${current:-current}'" "profile '$name'" || return 1
  _profile_rewrite_config "$name" "" ""
}

# ---------------------------------------------------------------------------
# _profile_add <name> <url> — register a new profile
# ---------------------------------------------------------------------------
_profile_add() {
  local name="${1:-}"
  local url="${2:-}"

  if [[ -z "$name" ]]; then
    name="$(_read_tty "Profile name (e.g. work, perso)")"
  fi
  if [[ -z "$name" ]]; then
    log_error "Profile name cannot be empty."
    return 1
  fi
  if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Invalid profile name: '$name' — only letters, digits, hyphens and underscores allowed."
    return 1
  fi

  # Check for collision
  local existing_url
  existing_url="$(_profile_get_url "$name")"
  if [[ -n "$existing_url" ]]; then
    log_error "Profile '$name' already exists: $existing_url"
    log_info "Use 'claude-kitsync profile remove $name' first to replace it."
    return 1
  fi

  if [[ -z "$url" ]]; then
    url="$(_read_tty "Git URL for profile '$name' (SSH or HTTPS)")"
  fi
  if [[ -z "$url" ]]; then
    log_error "URL cannot be empty."
    return 1
  fi

  local current_active
  current_active="$(_profile_get_active)"
  _profile_rewrite_config "${current_active:-}" "$name" "$url"
  log_success "Profile '$name' added."

  # Offer to switch — only to someone who can answer
  if _has_tty; then
    local switch_choice
    switch_choice="$(_select_menu "Switch to '$name' now? (this machine takes its config)" "No" "Yes")"
    [[ "$switch_choice" == "2" ]] && _profile_switch "$name"
  else
    log_info "Switch to it with: claude-kitsync profile switch $name"
  fi
}

# ---------------------------------------------------------------------------
# _profile_remove <name> — remove a profile from config
# ---------------------------------------------------------------------------
_profile_remove() {
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    local names_list
    names_list="$(_profile_list_names)"
    if [[ -z "$names_list" ]]; then
      log_warn "No profiles configured."
      return 0
    fi
    local options=()
    while IFS= read -r n; do
      [[ -n "$n" ]] && options+=("$n")
    done <<< "$names_list"
    options+=("Back")
    local choice
    choice="$(_select_menu "Remove which profile?" "${options[@]}")"
    local idx=$(( choice - 1 ))
    if [[ "${options[$idx]}" == "Back" ]]; then
      return 0
    fi
    name="${options[$idx]}"
  fi

  local current_active
  current_active="$(_profile_get_active)"
  if [[ "$current_active" == "$name" ]]; then
    log_error "Cannot remove active profile '$name' — switch to another profile first."
    return 1
  fi

  local url
  url="$(_profile_get_url "$name")"
  if [[ -z "$url" ]]; then
    log_error "Profile not found: $name"
    return 1
  fi

  if confirm "Remove profile '$name' ($url)?"; then
    _profile_delete_config "$name"
    log_success "Profile '$name' removed."
  fi
}

# ---------------------------------------------------------------------------
# _profile_list_all_display — print all profiles with active marker
# ---------------------------------------------------------------------------
_profile_list_all_display() {
  local names_list
  names_list="$(_profile_list_names)"

  if [[ -z "$names_list" ]]; then
    log_info "No profiles configured."
    log_info "Add one: claude-kitsync profile add <name> <url>"
    return 0
  fi

  local current_active
  current_active="$(_profile_get_active)"

  printf "\n" >&2
  log_info "Configured profiles:"; printf "\n" >&2
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    local u
    u="$(_profile_get_url "$n")"
    if [[ "$current_active" == "$n" ]]; then
      printf "  ${_CLR_CYAN}${_CLR_BOLD}❯  %-12s${_CLR_RESET}  %s\n" "$n" "$u" >&2
    else
      printf "     %-12s  %s\n" "$n" "$u" >&2
    fi
  done <<< "$names_list"
  printf "\n" >&2
}

# ---------------------------------------------------------------------------
# cmd_profile — top-level dispatcher for `claude-kitsync profile <subcommand>`
# ---------------------------------------------------------------------------
cmd_profile() {
  require_git_repo
  _config_migrate_local >/dev/null 2>&1 || true   # registry from before 1.2.8

  local sub="${1:-}"

  case "$sub" in
    list)
      _profile_list_all_display
      ;;
    add)
      shift
      _profile_add "${1:-}" "${2:-}"
      ;;
    switch)
      shift
      if [[ -z "${1:-}" ]]; then
        # Interactive: pick from list
        local names_list
        names_list="$(_profile_list_names)"
        if [[ -z "$names_list" ]]; then
          log_warn "No profiles configured. Add one first:"
          log_info "  claude-kitsync profile add <name> <url>"
          return 0
        fi
        local options=()
        while IFS= read -r n; do
          [[ -n "$n" ]] && options+=("$n")
        done <<< "$names_list"
        options+=("Back")
        local choice
        choice="$(_select_menu "Switch to profile:" "${options[@]}")"
        local idx=$(( choice - 1 ))
        if [[ "${options[$idx]}" == "Back" ]]; then
          return 0
        fi
        _profile_switch "${options[$idx]}"
      else
        _profile_switch "$1"
      fi
      ;;
    remove)
      shift
      _profile_remove "${1:-}"
      ;;
    "")
      # Interactive menu
      local choice
      choice="$(_select_menu "Profile management" \
        "List profiles" \
        "Add a profile" \
        "Switch profile" \
        "Remove a profile" \
        "Back")"
      case "$choice" in
        1) _profile_list_all_display ;;
        2) _profile_add ;;
        3) cmd_profile switch ;;
        4) _profile_remove ;;
        5) return 0 ;;
      esac
      ;;
    *)
      log_error "Unknown profile subcommand: $sub"
      log_info "Usage: claude-kitsync profile [list|add|switch|remove]"
      return 1
      ;;
  esac
}
