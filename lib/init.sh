#!/usr/bin/env bash
# lib/init.sh — `kitsync init` — full setup of ~/.claude as a git repository
set -euo pipefail

# ---------------------------------------------------------------------------
# _find_template — locate the .gitignore.template relative to this script
# ---------------------------------------------------------------------------
_find_template() {
  local script_dir
  # Resolve the directory containing the currently sourced/executed script
  # When sourced from bin/kitsync, KITSYNC_ROOT is set; fall back to relative paths.
  if [[ -n "${KITSYNC_ROOT:-}" ]]; then
    echo "${KITSYNC_ROOT}/templates/.gitignore.template"
  else
    # Try common locations
    local candidates=(
      "$(dirname "${BASH_SOURCE[0]}")/../templates/.gitignore.template"
      "$HOME/.local/share/kitsync/templates/.gitignore.template"
    )
    for c in "${candidates[@]}"; do
      if [[ -f "$c" ]]; then
        echo "$c"
        return 0
      fi
    done
    echo ""
  fi
}

# _gitignore_is_allowlist <file> — first rule denies everything
_gitignore_is_allowlist() {
  [[ "$(grep -v '^[[:space:]]*\(#\|$\)' "$1" 2>/dev/null | head -1 || true)" == "*" ]]
}

# ---------------------------------------------------------------------------
# _init_replace_gitignore <template> — an existing .gitignore that is not an
# allowlist lets everything else through (conversations, caches): back it up,
# install the allowlist, and stop tracking what it now excludes.
# ---------------------------------------------------------------------------
_init_replace_gitignore() {
  local template="$1" gi="$CLAUDE_HOME/.gitignore"
  log_warn "$gi is not an allowlist — anything it does not ignore would be pushed."
  local choice
  choice="$(_select_menu "Replace it with kitsync's allowlist?" \
    "Replace  (recommended — a backup is kept)" \
    "Keep it  (you manage what gets synced)")"
  if [[ "$choice" != "1" ]]; then
    log_warn "Keeping your .gitignore — 'claude-kitsync doctor' will keep flagging it."
    return 0
  fi

  local backup_dir="$CLAUDE_HOME/.kitsync/backups"
  local backup
  backup="$backup_dir/.gitignore.$(date '+%Y%m%dT%H%M%S').bak"
  mkdir -p "$backup_dir"
  cp "$gi" "$backup"
  cp "$template" "$gi"
  log_success ".gitignore replaced by the allowlist (backup: $backup)"

  # Files already tracked but now excluded: untrack them (they stay on disk)
  local excluded
  excluded="$(git -C "$CLAUDE_HOME" ls-files -ci --exclude-standard 2>/dev/null || true)"
  if [[ -n "$excluded" ]]; then
    printf '%s\n' "$excluded" | while IFS= read -r _f; do
      git -C "$CLAUDE_HOME" rm --cached -q -- "$_f" 2>/dev/null || true
    done
    log_info "Stopped tracking $(grep -c . <<< "$excluded") file(s) the allowlist excludes (kept on disk)."
  fi
}

# ---------------------------------------------------------------------------
# _generate_settings_template — replaces absolute paths in settings.json
# with $HOME/.claude placeholder and writes settings.template.json
# ---------------------------------------------------------------------------
_generate_settings_template() {
  local settings_src="$CLAUDE_HOME/settings.json"
  local settings_tpl="$CLAUDE_HOME/settings.template.json"

  if [[ ! -f "$settings_src" ]]; then
    log_info "No settings.json found — skipping template generation."
    return 0
  fi

  log_step "Generating settings.template.json from settings.json..."

  # Use anchored multi-user patterns — matches /Users/<any>/.claude (macOS)
  # and /home/<any>/.claude (Linux), regardless of who owns the settings file.
  # This ensures portability even if settings.json came from another machine.
  paths_tokenize_stream < "$settings_src" > "$settings_tpl"
  # Settings may have come from another machine — catch foreign home dirs too
  _sed_inplace "s|/Users/[^/]*/\.claude|__CLAUDE_HOME__|g" "$settings_tpl" 2>/dev/null || true
  _sed_inplace "s|/home/[^/]*/\.claude|__CLAUDE_HOME__|g"  "$settings_tpl" 2>/dev/null || true

  log_success "Created settings.template.json with tokenised paths."
}

# ---------------------------------------------------------------------------
# _INIT_REMOTE_MODE — set by _github_repo_flow / _prompt_remote_url
#   "new"     = created a fresh repo (remote will be empty)
#   "connect" = connected to an existing repo (remote has content)
#   "url"     = user entered a URL manually (auto-detect content later)
#   "none"    = no remote configured
# ---------------------------------------------------------------------------
_INIT_REMOTE_MODE=""
_INIT_BACKUP_DIR=""

# _init_remote_version <rel> — the remote's file as it would land on this
# machine (smudge filter applied: path tokens become this machine's paths)
_init_remote_version() {
  git -C "$CLAUDE_HOME" cat-file --filters "FETCH_HEAD:$1" 2>/dev/null
}

# _init_differs <rel> — true when the local file differs from the remote's
_init_differs() {
  diff -q "$CLAUDE_HOME/$1" <(_init_remote_version "$1") &>/dev/null && return 1
  # settings.json: formatting and kitsync's own hooks are not a difference
  if [[ "$1" == settings.json ]] && command -v python3 &>/dev/null; then
    local a b
    if a="$(_settings_canonical < "$CLAUDE_HOME/$1" 2>/dev/null)" && \
       b="$(_init_remote_version "$1" | _settings_canonical 2>/dev/null)"; then
      [[ "$a" != "$b" ]]
      return
    fi
  fi
  return 0
}

# _init_backup_local <rel> — keep the local version before the remote's
# replaces it (one folder per init run, under the never-synced backups/)
_init_backup_local() {
  local rel="$1"
  if [[ -z "$_INIT_BACKUP_DIR" ]]; then
    _INIT_BACKUP_DIR="$CLAUDE_HOME/.kitsync/backups/init-$(date '+%Y%m%dT%H%M%S')"
  fi
  mkdir -p "$(dirname "$_INIT_BACKUP_DIR/$rel")"
  cp "$CLAUDE_HOME/$rel" "$_INIT_BACKUP_DIR/$rel"
}

# _init_read_choice — one answer from the terminal (stubbed in tests)
_init_read_choice() {
  local reply=""
  printf "  [R]emote  [L]ocal > " >/dev/tty
  read -r reply </dev/tty || true
  printf '%s' "$reply"
}

# ---------------------------------------------------------------------------
# _init_prompt_file_conflict <rel> — REMOTE / LOCAL choice for one file.
#   R — the remote's version replaces the local one (local backed up first)
#   L — keep the local file; it is committed and pushed by init
# Without a terminal the remote wins (an automated install joins an
# existing setup); the local version is still backed up.
# ---------------------------------------------------------------------------
_init_prompt_file_conflict() {
  local _rel="$1"
  local _full="$CLAUDE_HOME/$_rel"

  printf "\n" >&2
  log_warn "Conflict: $_rel"
  diff -u --label "remote: $_rel" --label "local: $_rel" \
    <(_init_remote_version "$_rel") "$_full" 2>/dev/null | head -40 >&2 || true

  local _choice=""
  if _has_tty; then
    while true; do
      # tr, not ${x^^}: macOS ships bash 3.2
      _choice="$(_init_read_choice | tr '[:lower:]' '[:upper:]')"
      case "$_choice" in R|L) break ;; *) printf "  Please enter R or L\n" >/dev/tty ;; esac
    done
  else
    _choice="R"
    log_info "  No terminal: using the remote version of $_rel"
  fi

  case "$_choice" in
    R)
      _init_backup_local "$_rel"
      git -C "$CLAUDE_HOME" checkout FETCH_HEAD -- "$_rel" 2>/dev/null
      log_success "  → Remote: $_rel  (local copy: $_INIT_BACKUP_DIR/$_rel)"
      ;;
    L)
      log_info "  → Local:  $_rel"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _init_resolve_conflicts — compare local files with FETCH_HEAD:
#   - remote-only files  → pulled automatically (no prompt)
#   - both with diff     → REMOTE / LOCAL prompt per file
#   - local-only files   → left as-is (staged later in Step 5)
# ---------------------------------------------------------------------------
_init_resolve_conflicts() {
  local _whitelist=("settings.json" "CLAUDE.md" "agents" "skills" "hooks" "scripts" "rules" \
    "commands" "output-styles" "workflows" "themes" "keybindings.json")

  local _conflict_count=0
  local _pulled_count=0
  _INIT_BACKUP_DIR=""

  for _item in "${_whitelist[@]}"; do
    local _local_path="$CLAUDE_HOME/$_item"

    if [[ -d "$_local_path" ]]; then
      # Directory: walk every file present in FETCH_HEAD under this path
      while IFS= read -r _rel_file; do
        [[ -z "$_rel_file" ]] && continue
        local _local_file="$CLAUDE_HOME/$_rel_file"

        if [[ -f "$_local_file" ]]; then
          if _init_differs "$_rel_file"; then
            _init_prompt_file_conflict "$_rel_file" </dev/null
            _conflict_count=$(( _conflict_count + 1 ))
          fi
        else
          mkdir -p "$(dirname "$_local_file")"
          if git -C "$CLAUDE_HOME" checkout FETCH_HEAD -- "$_rel_file" 2>/dev/null; then
            log_success "Pulled from remote: $_rel_file"
            _pulled_count=$(( _pulled_count + 1 ))
          fi
        fi
      done < <(git -C "$CLAUDE_HOME" ls-tree -r --name-only FETCH_HEAD -- "${_item}/" 2>/dev/null)

    elif [[ -f "$_local_path" ]]; then
      if git -C "$CLAUDE_HOME" cat-file -e "FETCH_HEAD:$_item" 2>/dev/null && _init_differs "$_item"; then
        _init_prompt_file_conflict "$_item"
        _conflict_count=$(( _conflict_count + 1 ))
      fi
    else
      # Local item absent — pull from remote if available
      if git -C "$CLAUDE_HOME" checkout FETCH_HEAD -- "$_item" 2>/dev/null; then
        log_success "Pulled from remote: $_item"
        _pulled_count=$(( _pulled_count + 1 ))
      fi
    fi
  done

  if [[ $_conflict_count -eq 0 ]] && [[ $_pulled_count -eq 0 ]]; then
    log_info "Remote config synced — no conflicts found."
  else
    log_info "Resolved $_conflict_count conflict(s), pulled $_pulled_count remote-only file(s)."
  fi
  if [[ -n "$_INIT_BACKUP_DIR" ]]; then
    log_info "Local versions replaced by the remote are kept in: $_INIT_BACKUP_DIR"
  fi
}

# ---------------------------------------------------------------------------
# _gh_clone_url <owner/repo> — URL matching the git protocol configured in gh
# (SSH only if the user chose it; HTTPS pushes go through gh's credential
# helper). Same helper as install.sh.
# ---------------------------------------------------------------------------
_gh_clone_url() {
  local proto
  proto="$(gh config get git_protocol -h github.com 2>/dev/null || true)"
  if [[ "$proto" == "ssh" ]]; then
    printf 'git@github.com:%s.git' "$1"
  else
    printf 'https://github.com/%s.git' "$1"
  fi
}

# ---------------------------------------------------------------------------
# _create_repo_via_gh — create a new GitHub repo, return its clone URL
# ---------------------------------------------------------------------------
_create_repo_via_gh() {
  local repo_name
  repo_name="$(_read_tty "Repo name" "claude-config")"

  local vis_choice
  vis_choice="$(_select_menu "Visibility?" "Private  (recommended)" "Public")"
  local vis_flag="--private"
  [[ "$vis_choice" == "2" ]] && vis_flag="--public"

  log_step "Creating GitHub repo: $repo_name..."
  if gh repo create "$repo_name" "$vis_flag" --description "Claude Code config sync" >/dev/null 2>&1; then
    local gh_login
    gh_login="$(gh api user -q .login 2>/dev/null)"
    local result_url
    result_url="$(_gh_clone_url "${gh_login}/${repo_name}")"
    log_success "Repo created: github.com/${gh_login}/${repo_name}"
    printf '%s' "$result_url"
  else
    log_warn "gh repo create failed — please enter URL manually."
    _read_tty "Git URL (SSH or HTTPS)"
  fi
}

# ---------------------------------------------------------------------------
# _connect_repo_via_gh — browse existing GitHub repos, return selected clone URL
# ---------------------------------------------------------------------------
_connect_repo_via_gh() {
  log_step "Fetching your GitHub repos..."

  local repo_lines
  repo_lines="$(gh repo list --limit 30 2>/dev/null | awk '{print $1}' || true)"

  if [[ -z "$repo_lines" ]]; then
    log_warn "No repos found — enter URL manually."
    _read_tty "Git URL (SSH or HTTPS, blank to skip)"
    return
  fi

  local options=()
  while IFS= read -r repo; do
    [[ -n "$repo" ]] && options+=("$repo")
  done <<< "$repo_lines"

  local choice
  choice="$(_select_menu "Select a repository:" "${options[@]}")"

  local selected="${options[$((choice - 1))]}"
  _gh_clone_url "$selected"
}

# ---------------------------------------------------------------------------
# _github_repo_flow — sub-menu: create new or connect to existing GitHub repo
# ---------------------------------------------------------------------------
_github_repo_flow() {
  local action
  action="$(_select_menu "GitHub repository:" \
    "Create a new repo" \
    "Connect to an existing repo")"

  case "$action" in
    1) _INIT_REMOTE_MODE="new";     _create_repo_via_gh ;;
    2) _INIT_REMOTE_MODE="connect"; _connect_repo_via_gh ;;
  esac
}

# ---------------------------------------------------------------------------
# _prompt_remote_url — interactive menu to choose how to configure remote
# Returns the remote URL on stdout (empty string = skip).
# ---------------------------------------------------------------------------
_prompt_remote_url() {
  local options=()
  local has_gh=false
  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    has_gh=true
    options+=("GitHub  (create new or connect existing)")
  fi
  options+=("Enter a URL  (SSH: git@github.com:you/repo.git  or  HTTPS)")
  options+=("Skip — I'll configure this later")

  local choice
  choice="$(_select_menu "Where should your Claude config be stored?" "${options[@]}")"

  local actions=()
  [[ "$has_gh" == "true" ]] && actions+=("github")
  actions+=("url_input")
  actions+=("skip")

  local action="${actions[$((choice - 1))]}"

  case "$action" in
    github)
      _github_repo_flow  # sets _INIT_REMOTE_MODE="new" or "connect"
      ;;
    url_input)
      _INIT_REMOTE_MODE="url"
      _read_tty "Git URL (SSH or HTTPS, blank to skip)"
      ;;
    skip)
      _INIT_REMOTE_MODE="none"
      printf ''
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _prompt_sync_items — multi-select which categories to push or pull
# Arg $1: "push" or "pull"
# Arg $2: current comma-separated selection (displayed as hint, optional)
# Returns comma-separated list of selected category names on stdout
# ---------------------------------------------------------------------------
_prompt_sync_items() {
  local direction="$1"
  local current="${2:-}"
  local prompt
  case "$direction" in
    push) prompt="Which categories to push to remote?" ;;
    pull) prompt="Which categories to pull from remote?" ;;
    *)    prompt="Select categories:" ;;
  esac

  if [[ -n "$current" ]]; then
    log_info "Current ${direction} selection: ${current}" >&2
  fi

  local labels=("Agents  (agents/)" "Skills  (skills/)" "Hooks  (hooks/)" \
    "Scripts  (scripts/)" "Rules  (rules/)" "Commands  (commands/)" \
    "Output styles  (output-styles/)" "Workflows  (workflows/)" "Themes  (themes/)" \
    "Keybindings  (keybindings.json)" \
    "Settings  (settings.json)" "Instructions  (CLAUDE.md)")
  local keys=("agents" "skills" "hooks" "scripts" "rules" "commands" "output-styles" \
    "workflows" "themes" "keybindings.json" "settings.json" "CLAUDE.md")

  local selected_indices
  selected_indices="$(_select_multi "$prompt" "${labels[@]}")"

  local result=()
  for idx in $selected_indices; do
    result+=("${keys[$((idx - 1))]}")
  done

  local IFS=","
  echo "${result[*]}"
}

# ---------------------------------------------------------------------------
# _prompt_sync_preferences — interactive selection of pull/push modes
# Writes preferences to $CLAUDE_HOME/.kitsync/config
# ---------------------------------------------------------------------------
_prompt_sync_preferences() {
  printf "\n"
  local cfg="$CLAUDE_HOME/.kitsync/config"

  # Re-run: offer to keep what is there (without a terminal, keep it)
  if [[ -n "$(_cfg_get KITSYNC_PULL_MODE)" ]]; then
    local _cur_pull_mode _cur_push_mode
    _cur_pull_mode="$(_cfg_get KITSYNC_PULL_MODE)"
    _cur_push_mode="$(_cfg_get KITSYNC_PUSH_MODE || true)"
    local keep
    keep="$(_select_menu "Sync preferences already set (pull: ${_cur_pull_mode}, push: ${_cur_push_mode:-?})" \
      "Keep them" \
      "Change them")"
    if [[ "$keep" == "1" ]]; then
      log_info "Keeping current sync preferences."
      return 0
    fi
  fi

  # --- Pull mode ---
  local pull_choice
  pull_choice="$(_select_menu "Pull config from remote on each \`claude\` launch?" \
    "Automatically  (pulls silently in background)" \
    "On command only  (claude-kitsync pull)")"

  local pull_mode="auto"
  [[ "$pull_choice" == "2" ]] && pull_mode="manual"

  # --- Push mode ---
  local push_choice
  push_choice="$(_select_menu "Push config changes to remote?" \
    "End of session  (when claude exits)" \
    "Timer  (every N minutes during session)" \
    "On command only  (claude-kitsync push)" \
    "Never  (read-only sync)")"

  local push_mode="end_of_session"
  local push_timer="15"

  case "$push_choice" in
    1) push_mode="end_of_session" ;;
    2)
      push_mode="timer"
      push_timer="$(_read_tty "Push interval (minutes)" "15")"
      [[ "$push_timer" =~ ^[0-9]+$ ]] || push_timer="15"
      ;;
    3) push_mode="manual" ;;
    4) push_mode="never" ;;
  esac

  # --- Sync items (which categories to push / pull) ---
  local _cur_push _cur_pull
  _cur_push="$(_cfg_get KITSYNC_PUSH_ITEMS || true)"
  _cur_pull="$(_cfg_get KITSYNC_PULL_ITEMS || true)"

  printf "\n"
  local push_items
  push_items="$(_prompt_sync_items "push" "$_cur_push")"
  local pull_items
  pull_items="$(_prompt_sync_items "pull" "$_cur_pull")"

  # A category not pulled is never pushed either (it would revert the others)
  local _c _skip=""
  for _c in ${push_items//,/ }; do
    [[ ",$pull_items," == *",$_c,"* ]] || _skip+="$_c "
  done
  if [[ -n "$_skip" ]]; then
    log_info "Not pulled, so not pushed either (it would undo your other machines' changes): ${_skip% }"
  fi

  # Only these keys: the same file holds profiles, encryption, upgrade channel
  _config_set KITSYNC_PULL_MODE "$pull_mode"
  _config_set KITSYNC_PUSH_MODE "$push_mode"
  _config_set KITSYNC_PUSH_TIMER "$push_timer"
  _config_set KITSYNC_PUSH_ITEMS "$push_items"
  _config_set KITSYNC_PULL_ITEMS "$pull_items"

  log_success "Sync preferences saved."
}

# ---------------------------------------------------------------------------
# cmd_init — main entry point for `kitsync init`
# Args: [--remote <url>]
# ---------------------------------------------------------------------------
cmd_init() {
  local remote_url=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote)
        shift
        remote_url="${1:-}"
        if [[ -z "$remote_url" ]]; then
          die "--remote requires a URL argument"
        fi
        shift
        ;;
      --remote=*)
        remote_url="${1#--remote=}"
        shift
        ;;
      *)
        die "Unknown argument: $1 (usage: kitsync init [--remote <url>])"
        ;;
    esac
  done

  # ---------------------------------------------------------------------------
  # Step 0: Ensure CLAUDE_HOME exists
  # ---------------------------------------------------------------------------
  if [[ ! -d "$CLAUDE_HOME" ]]; then
    log_step "Creating $CLAUDE_HOME..."
    mkdir -p "$CLAUDE_HOME"
  fi

  # ---------------------------------------------------------------------------
  # Step 1: Detect existing git repo
  # ---------------------------------------------------------------------------
  local already_git=false
  if git -C "$CLAUDE_HOME" rev-parse --git-dir &>/dev/null 2>&1; then
    already_git=true
    log_info "$CLAUDE_HOME is already a git repository."
  fi

  # ---------------------------------------------------------------------------
  # Step 2: git init (if needed) + .gitignore
  # ---------------------------------------------------------------------------
  if [[ "$already_git" == "false" ]]; then
    log_step "Initialising git repository in $CLAUDE_HOME..."
    git -C "$CLAUDE_HOME" init -b main 2>/dev/null || git -C "$CLAUDE_HOME" init
    log_success "Git repository initialised."
  fi

  # Install .gitignore from template
  local gitignore_dest="$CLAUDE_HOME/.gitignore"
  local template_path
  template_path="$(_find_template)"

  if [[ -n "$template_path" ]] && [[ -f "$template_path" ]]; then
    if [[ -f "$gitignore_dest" ]] && ! _gitignore_is_allowlist "$gitignore_dest"; then
      _init_replace_gitignore "$template_path"
    elif [[ -f "$gitignore_dest" ]]; then
      log_info ".gitignore already set up (allowlist) — kept."
    else
      log_step "Installing .gitignore from template..."
      cp "$template_path" "$gitignore_dest"
      log_success ".gitignore installed."
    fi
  elif [[ ! -f "$gitignore_dest" ]]; then
    log_warn "Template not found — writing minimal .gitignore..."
    cat > "$gitignore_dest" <<'GITIGNORE'
# claude-kitsync — allowlist strict
*
!*/
!settings.json
!CLAUDE.md
!agents/
!agents/**
!skills/
!skills/**
!hooks/
!hooks/**
!scripts/
!scripts/**
!rules/
!rules/**
!.gitignore
!.kitsync/
!.kitsync/**
.credentials.json
settings.local.json
projects/
backups/
cache/
GITIGNORE
    log_success "Minimal .gitignore written."
  fi
  # Bring older/minimal allowlists up to date, and register the path-token filter
  # before any remote content is checked out
  _gitignore_migrate
  paths_filter_setup

  # ---------------------------------------------------------------------------
  # Step 3: Configure remote
  # ---------------------------------------------------------------------------
  local has_remote=false
  if git -C "$CLAUDE_HOME" remote get-url origin &>/dev/null 2>&1; then
    has_remote=true
    local existing_remote
    existing_remote="$(git -C "$CLAUDE_HOME" remote get-url origin 2>/dev/null)"
    log_info "Remote already configured: $existing_remote"
  fi

  if [[ "$has_remote" == "false" ]]; then
    if [[ -z "$remote_url" ]]; then
      remote_url="$(_prompt_remote_url)"
    fi

    if [[ -n "$remote_url" ]]; then
      # If mode wasn't set by the interactive prompt (i.e. --remote flag was used),
      # auto-detect based on remote content — same as "url" mode.
      [[ -z "$_INIT_REMOTE_MODE" ]] && _INIT_REMOTE_MODE="url"
      log_step "Adding remote origin: $remote_url"
      git -C "$CLAUDE_HOME" remote add origin "$remote_url"
      log_success "Remote added."
    else
      log_warn "No remote configured — add one later:"
      log_warn "  git -C \"$CLAUDE_HOME\" remote add origin <url>"
    fi
  fi

  # ---------------------------------------------------------------------------
  # Step 3.5: Resolve conflicts with remote config
  # Files only in remote are pulled automatically.
  # Files present in both local and remote with different content trigger a
  # per-file REMOTE / LOCAL prompt.
  # Files only in local are left as-is and staged in Step 5.
  # ---------------------------------------------------------------------------
  if [[ "$already_git" == "false" ]] && [[ "$_INIT_REMOTE_MODE" != "new" ]]; then
    if git -C "$CLAUDE_HOME" remote get-url origin &>/dev/null 2>&1; then
      log_step "Comparing local and remote configs..."
      if git -C "$CLAUDE_HOME" fetch -q origin main 2>/dev/null && \
         git -C "$CLAUDE_HOME" rev-parse FETCH_HEAD &>/dev/null 2>&1; then
        _init_resolve_conflicts
      else
        log_info "Remote is empty — nothing to pull."
      fi
    fi
  fi

  # ---------------------------------------------------------------------------
  # Step 4: Generate settings.template.json
  # ---------------------------------------------------------------------------
  _generate_settings_template

  # ---------------------------------------------------------------------------
  # Step 4.5: Offer claude-kitsync bundled starter kit import
  # Only on fresh init. Uses existing _copy_kit_dir/_copy_kit_item from install-kit.sh.
  # ---------------------------------------------------------------------------
  if [[ "$already_git" == "false" ]]; then
    local _kit_root="${KITSYNC_ROOT}/kit"
    if [[ -d "$_kit_root" ]]; then
      local _kit_all_items=("settings.json" "CLAUDE.md" "agents" "skills" "hooks" "scripts" "rules")
      local _kit_all_labels=(
        "settings.json   — Claude settings"
        "CLAUDE.md       — project memory / instructions"
        "agents/         — custom agents"
        "skills/         — slash commands"
        "hooks/          — rm goes to the trash (needs python3)"
        "scripts/        — status line + command validator (needs Bun)"
        "rules/          — coding rules"
      )

      # Build list of categories that actually exist in kit/
      local _kit_items=()
      local _kit_labels=()
      local _ki=0
      for _kp in "${_kit_all_items[@]}"; do
        if [[ -e "$_kit_root/$_kp" ]]; then
          _kit_items+=("$_kp")
          _kit_labels+=("${_kit_all_labels[$_ki]}")
        fi
        _ki=$(( _ki + 1 ))
      done

      # Without a terminal, menus fall back to "everything": import nothing
      # instead of pushing someone else's config into this user's remote
      if [[ ${#_kit_items[@]} -gt 0 ]] && ! _has_tty; then
        log_info "No terminal — starter config not imported (run 'claude-kitsync install' later)."
      elif [[ ${#_kit_items[@]} -gt 0 ]]; then
        printf "\n"
        local _kit_selected
        # Nothing preselected: Enter alone imports nothing
        _kit_selected="$(_SELECT_MULTI_DEFAULT=0 _select_multi \
          "Import claude-kitsync starter config? (Space to pick, Enter to confirm)" "${_kit_labels[@]}")"

        if [[ -n "$_kit_selected" ]]; then
          log_step "Importing starter config into $CLAUDE_HOME..."
          _KIT_CONFLICT_ALL="skip"  # skip conflicting files — only import items not already present
          local _kit_code=false
          for _kidx in $_kit_selected; do
            local _kitem="${_kit_items[$((_kidx - 1))]}"
            [[ "$_kitem" == hooks || "$_kitem" == scripts ]] && _kit_code=true
            local _ksrc="$_kit_root/$_kitem"
            if [[ -d "$_ksrc" ]]; then
              _copy_kit_dir "$_ksrc" "$CLAUDE_HOME"
            elif [[ -f "$_ksrc" ]]; then
              _copy_kit_item "$_ksrc" "$CLAUDE_HOME/$_kitem"
            fi
          done
          log_success "Starter config imported."
          [[ "$_kit_code" == true ]] && _kit_setup_prompt
        fi
      fi
    fi
  fi

  # ---------------------------------------------------------------------------
  # Step 4.7: Sync preferences
  # Before the initial commit: .kitsync/config must be in it, or the first
  # pull on another machine fails on an untracked .kitsync/config
  # ---------------------------------------------------------------------------
  _prompt_sync_preferences

  # ---------------------------------------------------------------------------
  # Step 4.8: Profile naming
  # Always offered when a remote was configured. Default is "default" when no
  # profiles exist yet; naming is required when profiles already exist so the
  # active profile stays consistent.
  # ---------------------------------------------------------------------------
  if [[ "${_INIT_REMOTE_MODE:-none}" != "none" ]] && \
     git -C "$CLAUDE_HOME" remote get-url origin &>/dev/null 2>&1; then
    local _existing_profiles _profile_default _init_profile_name _init_remote_url
    _existing_profiles="$(_profile_list_names 2>/dev/null || true)"
    _profile_default="$(_profile_get_active 2>/dev/null || true)"
    [[ -n "$_profile_default" ]] || _profile_default="default"

    if [[ -n "$_existing_profiles" ]]; then
      log_info "Existing profiles: $(printf '%s' "$_existing_profiles" | tr '\n' ' ')"
      log_info "You must name this remote to keep profiles consistent."
    fi

    while true; do
      _init_profile_name="$(_read_tty "Profile name for this remote" "$_profile_default")"
      [[ -z "$_init_profile_name" ]] && _init_profile_name="$_profile_default"
      if [[ "$_init_profile_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        break
      fi
      log_warn "Invalid name — only letters, digits, hyphens, underscores allowed."
    done

    _init_remote_url="$(git -C "$CLAUDE_HOME" remote get-url origin 2>/dev/null || true)"
    _profile_rewrite_config "$_init_profile_name" "$_init_profile_name" "$_init_remote_url"
    log_success "Profile '$_init_profile_name' registered."
  fi

  # ---------------------------------------------------------------------------
  # Step 4.9: Automatic sync (hooks in settings.json)
  # Before the initial commit, so the hooks are in it and the tree stays clean
  # ---------------------------------------------------------------------------
  log_step "Setting up automatic sync..."
  sync_trigger_setup
  # settings.json may have just gained the hooks: keep the template identical
  # on every machine, or each one commits its own version
  _generate_settings_template >/dev/null 2>&1 || true

  # ---------------------------------------------------------------------------
  # Step 5: Initial commit
  # ---------------------------------------------------------------------------
  log_step "Staging whitelisted files for initial commit..."

  local whitelist_items=(
    "settings.json"
    "settings.template.json"
    "CLAUDE.md"
    "agents/"
    "skills/"
    "hooks/"
    "scripts/"
    "rules/"
    "commands/"
    "output-styles/"
    "workflows/"
    "themes/"
    "keybindings.json"
    ".gitignore"
    ".kitsync/"
  )


  for item in "${whitelist_items[@]}"; do
    local full_path="$CLAUDE_HOME/$item"
    if [[ -e "$full_path" ]]; then
      git -C "$CLAUDE_HOME" add "$full_path" 2>/dev/null || true
    fi
  done

  # Safety check before committing (--name-only = one filename per line, match exactly)
  if git -C "$CLAUDE_HOME" diff --cached --name-only 2>/dev/null | grep -q "^\.credentials\.json$"; then
    log_error "CRITICAL: .credentials.json is about to be committed — aborting!"
    git -C "$CLAUDE_HOME" reset HEAD ".credentials.json" 2>/dev/null || true
    exit 1
  fi

  if ! git -C "$CLAUDE_HOME" diff --cached --quiet 2>/dev/null; then
    log_step "Creating initial commit..."
    local _commit_out
    if _commit_out="$(git -C "$CLAUDE_HOME" commit -m "kitsync: initial commit [$(date '+%Y-%m-%d')]" 2>&1)"; then
      printf "%s\n" "$_commit_out" | grep -Ev "^[[:space:]]+(create|delete) mode " || true
    else
      printf "%s\n" "$_commit_out" >&2
      exit 1
    fi
    log_success "Initial commit created."
  else
    log_info "Nothing staged for initial commit."
  fi

  # ---------------------------------------------------------------------------
  # Step 7: Push to remote (if configured)
  # ---------------------------------------------------------------------------
  if git -C "$CLAUDE_HOME" remote get-url origin &>/dev/null 2>&1; then
    # Auto-push if --remote was explicitly provided, or if user confirms interactively
    local do_push=false
    if [[ -n "$remote_url" ]]; then
      do_push=true  # --remote was given: push without prompt
    elif confirm "Push initial commit to remote now?"; then
      do_push=true
    fi

    if [[ "$do_push" == true ]]; then
      log_step "Pushing to origin main..."
      local _push_ok=false _push_err=""
      if _push_err="$(git -C "$CLAUDE_HOME" push -q -u origin HEAD:main 2>&1)"; then
        _push_ok=true
      else
        # Remote has its own history (connect mode): replay the local commit on
        # top of it. In a rebase "theirs" is the commit being replayed, so the
        # REMOTE/LOCAL choices made above win over the remote's content.
        log_step "Remote has existing commits — rebasing on top..."
        if _push_err="$(git -C "$CLAUDE_HOME" pull --rebase --allow-unrelated-histories \
                          -X theirs -q origin main 2>&1)" && \
           _push_err="$(git -C "$CLAUDE_HOME" push -q -u origin HEAD:main 2>&1)"; then
          _push_ok=true
        else
          git -C "$CLAUDE_HOME" rebase --abort 2>/dev/null || true
        fi
      fi

      if [[ "$_push_ok" == true ]]; then
        log_success "Pushed to remote."
      else
        log_warn "Push failed — your commit is local only:"
        [[ -n "$_push_err" ]] && printf '%s\n' "$_push_err" | head -5 | sed 's/^/      /' >&2
        log_warn "Run 'claude-kitsync push' to retry, or check your remote credentials."
      fi
    else
      log_info "Skipping push. Run 'claude-kitsync push' when ready."
    fi
  fi

  log_success "claude-kitsync init complete!"
  if [[ -n "$(_wrapper_rc_files)" ]]; then
    log_info "Invoke 'claude' normally — sync happens in the background."
    _print_reload_notice
  else
    log_info "Use Claude Code as usual (terminal, IDE or desktop) — each session syncs in the background."
  fi
}
