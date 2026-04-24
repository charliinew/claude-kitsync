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
      printf "${_CLR_CYAN}[kitsync]${_CLR_RESET}  Enter your remote git URL (leave blank to skip): " >&2
      read -r remote_url
    fi

    if [[ -n "$remote_url" ]]; then
      log_step "Adding remote origin: $remote_url"
      git -C "$CLAUDE_HOME" remote add origin "$remote_url"
      log_success "Remote added."
    else
      log_warn "No remote configured — you can add one later with:"
      log_warn "  git -C \"$CLAUDE_HOME\" remote add origin <url>"
    fi
  fi

  # ---------------------------------------------------------------------------
  # Step 4: Generate settings.template.json
  # ---------------------------------------------------------------------------
  _generate_settings_template

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
      if git -C "$CLAUDE_HOME" push -q -u origin main 2>&1 || \
         git -C "$CLAUDE_HOME" push -q -u origin HEAD 2>&1; then
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
