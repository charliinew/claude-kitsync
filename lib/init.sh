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
  cp "$settings_src" "$settings_tpl"
  sed -i.bak "s|/Users/[^/]*/.claude|__CLAUDE_HOME__|g" "$settings_tpl" 2>/dev/null || true
  sed -i.bak "s|/home/[^/]*/.claude|__CLAUDE_HOME__|g"  "$settings_tpl" 2>/dev/null || true
  rm -f "${settings_tpl}.bak"

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

# ---------------------------------------------------------------------------
# _create_repo_via_gh — create a new GitHub repo, return its SSH URL
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
    local result_url="git@github.com:${gh_login}/${repo_name}.git"
    log_success "Repo created: github.com/${gh_login}/${repo_name}"
    printf '%s' "$result_url"
  else
    log_warn "gh repo create failed — please enter URL manually."
    _read_tty "Git URL (SSH or HTTPS)"
  fi
}

# ---------------------------------------------------------------------------
# _connect_repo_via_gh — browse existing GitHub repos, return selected SSH URL
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
  printf 'git@github.com:%s.git' "$selected"
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
    if [[ -f "$gitignore_dest" ]]; then
      log_warn ".gitignore already exists in $CLAUDE_HOME — keeping existing file."
      log_warn "To reset, delete it and run: claude-kitsync init"
    else
      log_step "Installing .gitignore from template..."
      cp "$template_path" "$gitignore_dest"
      log_success ".gitignore installed."
    fi
  else
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
  # Step 3.5: Pull remote config (automatic)
  # Only on fresh init — if already_git, user should run 'claude-kitsync pull'.
  # Fetch and restore any whitelisted item that isn't already present locally.
  # Items already present locally are kept as-is (local takes precedence).
  # Skipped for new repos (remote is empty) and when no remote is configured.
  # ---------------------------------------------------------------------------
  if [[ "$already_git" == "false" ]] && [[ "$_INIT_REMOTE_MODE" != "new" ]]; then
    if git -C "$CLAUDE_HOME" remote get-url origin &>/dev/null 2>&1; then
      log_step "Pulling remote config..."
      if git -C "$CLAUDE_HOME" fetch origin -q 2>/dev/null && \
         git -C "$CLAUDE_HOME" rev-parse FETCH_HEAD &>/dev/null 2>&1; then

        local _pull_paths=("settings.json" "CLAUDE.md" "agents" "skills" "hooks" "scripts" "rules")
        local _pulled=0
        for _p in "${_pull_paths[@]}"; do
          if [[ ! -e "$CLAUDE_HOME/$_p" ]]; then
            if git -C "$CLAUDE_HOME" checkout FETCH_HEAD -- "$_p" 2>/dev/null; then
              log_success "Pulled from remote: $_p"
              (( _pulled++ )) || true
            fi
          fi
        done

        [[ $_pulled -eq 0 ]] && log_info "Remote config pulled — all items already present locally."
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
        "hooks/          — lifecycle hooks"
        "scripts/        — helper scripts"
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

      if [[ ${#_kit_items[@]} -gt 0 ]]; then
        printf "\n"
        local _kit_selected
        _kit_selected="$(_select_multi "Import claude-kitsync starter config?" "${_kit_labels[@]}")"

        if [[ -n "$_kit_selected" ]]; then
          log_step "Importing starter config into $CLAUDE_HOME..."
          _KIT_CONFLICT_ALL="skip"  # skip conflicting files — only import items not already present
          for _kidx in $_kit_selected; do
            local _kitem="${_kit_items[$((${_kidx} - 1))]}"
            local _ksrc="$_kit_root/$_kitem"
            if [[ -d "$_ksrc" ]]; then
              _copy_kit_dir "$_ksrc" "$CLAUDE_HOME"
            elif [[ -f "$_ksrc" ]]; then
              _copy_kit_item "$_ksrc" "$CLAUDE_HOME/$_kitem"
            fi
          done
          log_success "Starter config imported."
        fi
      fi
    fi
  fi

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
  # Step 6: Install shell wrapper
  # ---------------------------------------------------------------------------
  log_step "Installing shell wrapper..."
  install_wrapper_auto

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
      local _push_ok=false
      if git -C "$CLAUDE_HOME" push -q -u origin main 2>/dev/null; then
        _push_ok=true
      elif git -C "$CLAUDE_HOME" push -q -u origin HEAD 2>/dev/null; then
        _push_ok=true
      fi

      if [[ "$_push_ok" == false ]]; then
        # Remote has existing commits (connect mode) — rebase local on top of remote history.
        log_step "Remote has existing commits — rebasing on top..."
        if git -C "$CLAUDE_HOME" pull --rebase --allow-unrelated-histories -X ours -q 2>/dev/null; then
          git -C "$CLAUDE_HOME" push -q 2>/dev/null && _push_ok=true
        fi
      fi

      if [[ "$_push_ok" == true ]]; then
        log_success "Pushed to remote."
      else
        log_warn "Push failed — your commit is local only."
        log_warn "Run 'claude-kitsync push' to retry, or check your remote credentials."
      fi
    else
      log_info "Skipping push. Run 'claude-kitsync push' when ready."
    fi
  fi

  printf "\n"
  log_success "claude-kitsync init complete!"
  log_info "Reload your shell or run: source ~/.zshrc (or ~/.bashrc)"
  log_info "Then invoke 'claude' normally — sync happens in the background."
  printf "\n"
}
