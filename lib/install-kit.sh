#!/usr/bin/env bash
# lib/install-kit.sh — `kitsync install <url>` — clone a public kit and merge into ~/.claude
set -euo pipefail

# ---------------------------------------------------------------------------
# Protected files that must NEVER be overwritten by a kit install
# ---------------------------------------------------------------------------
readonly PROTECTED_FILES=(
  "settings.json"
  "settings.local.json"
  ".credentials.json"
  ".gitignore"
)

# ---------------------------------------------------------------------------
# Directories and files that are safe to copy from a kit
# ---------------------------------------------------------------------------
readonly KIT_COPYABLE_DIRS=(
  "agents"
  "skills"
  "hooks"
  "rules"
  "scripts"
  ".kitsync"
)

readonly KIT_COPYABLE_FILES=(
  "CLAUDE.md"
)

# ---------------------------------------------------------------------------
# _is_protected — returns 0 if the given relative path should not be touched
# ---------------------------------------------------------------------------
_is_protected() {
  local rel_path="$1"
  local basename_rel
  basename_rel="$(basename "$rel_path")"

  for p in "${PROTECTED_FILES[@]}"; do
    if [[ "$basename_rel" == "$p" ]] || [[ "$rel_path" == "$p" ]]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# _resolve_conflict — asks the user what to do when a file already exists
# Returns the action: skip | overwrite | backup
# ---------------------------------------------------------------------------
_resolve_conflict() {
  local dest_file="$1"
  local action=""

  while true; do
    printf "${_CLR_YELLOW}[kitsync]${_CLR_RESET}  File exists: %s\n" "$dest_file" >&2
    printf "  [s] skip   [o] overwrite   [b] backup+overwrite   [S] skip all   [O] overwrite all\n" >&2
    printf "  Choice: " >&2
    read -r choice

    case "$choice" in
      s|S) action="skip" ;;
      o|O) action="overwrite" ;;
      b)   action="backup" ;;
      *)
        log_warn "Invalid choice — please enter s, o, b, S, or O"
        continue
        ;;
    esac

    # Store global skip/overwrite-all preferences for the session
    if [[ "$choice" == "S" ]]; then
      _KIT_CONFLICT_ALL="skip"
    elif [[ "$choice" == "O" ]]; then
      _KIT_CONFLICT_ALL="overwrite"
    fi

    echo "$action"
    return 0
  done
}

# Global conflict-all preference (set during session)
_KIT_CONFLICT_ALL=""

# ---------------------------------------------------------------------------
# _copy_kit_item — copy a single file from kit tmpdir to $CLAUDE_HOME
# Handles conflict resolution.
# ---------------------------------------------------------------------------
_copy_kit_item() {
  local src="$1"
  local dest="$2"

  # Create destination directory if needed
  local dest_dir
  dest_dir="$(dirname "$dest")"
  mkdir -p "$dest_dir"

  if [[ -f "$dest" ]]; then
    local action

    if [[ -n "$_KIT_CONFLICT_ALL" ]]; then
      action="$_KIT_CONFLICT_ALL"
    else
      action="$(_resolve_conflict "$dest")"
    fi

    case "$action" in
      skip)
        log_info "Skipped: $dest"
        return 0
        ;;
      overwrite)
        cp "$src" "$dest"
        log_success "Overwritten: $dest"
        ;;
      backup)
        local backup_path="${dest}.bak.$(date '+%Y%m%d%H%M%S')"
        cp "$dest" "$backup_path"
        cp "$src" "$dest"
        log_success "Backed up to $backup_path — then overwritten: $dest"
        ;;
    esac
  else
    cp "$src" "$dest"
    log_success "Installed: $dest"
  fi
}

# ---------------------------------------------------------------------------
# _copy_kit_dir — recursively copy a directory from kit to $CLAUDE_HOME
# Skips protected files automatically.
# ---------------------------------------------------------------------------
_copy_kit_dir() {
  local kit_dir="$1"
  local dest_base="$2"

  if [[ ! -d "$kit_dir" ]]; then
    return 0
  fi

  local dir_name
  dir_name="$(basename "$kit_dir")"
  local dest_dir="$dest_base/$dir_name"

  log_step "Installing $dir_name/..."

  while IFS= read -r -d '' src_file; do
    # Get relative path within the kit dir
    local rel_path="${src_file#"$kit_dir/"}"
    local dest_file="$dest_dir/$rel_path"

    # Skip protected files
    if _is_protected "$rel_path"; then
      log_warn "Protected file skipped: $rel_path"
      continue
    fi

    _copy_kit_item "$src_file" "$dest_file"
  done < <(find "$kit_dir" -type f -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# cmd_install — main entry point for `kitsync install <url>`
# ---------------------------------------------------------------------------
cmd_install() {
  local kit_url="${1:-}"

  if [[ -z "$kit_url" ]]; then
    die "Usage: kitsync install <github-url>"
  fi

  require_command git

  # ---------------------------------------------------------------------------
  # Step 1: Clone into a temp directory
  # ---------------------------------------------------------------------------
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # Ensure cleanup on exit
  trap 'rm -rf "$tmp_dir"' EXIT INT TERM

  # Validate URL scheme — only https:// and git@ are accepted
  if [[ ! "$kit_url" =~ ^(https://|git@) ]]; then
    die "Only https:// and git@ URLs are accepted (got: $kit_url)"
  fi

  log_step "Cloning kit from $kit_url..."
  if ! git clone --depth 1 "$kit_url" "$tmp_dir" 2>/dev/null; then
    die "Failed to clone $kit_url — check the URL and your network connection."
  fi
  log_success "Kit cloned successfully."

  # Reset conflict-all preference for this install session
  _KIT_CONFLICT_ALL=""

  # ---------------------------------------------------------------------------
  # Step 2: Copy selectable directories
  # ---------------------------------------------------------------------------
  for dir_name in "${KIT_COPYABLE_DIRS[@]}"; do
    local kit_dir="$tmp_dir/$dir_name"
    if [[ -d "$kit_dir" ]]; then
      _copy_kit_dir "$kit_dir" "$CLAUDE_HOME"
    fi
  done

  # ---------------------------------------------------------------------------
  # Step 3: Copy selectable top-level files
  # ---------------------------------------------------------------------------
  for file_name in "${KIT_COPYABLE_FILES[@]}"; do
    local kit_file="$tmp_dir/$file_name"
    if [[ -f "$kit_file" ]]; then
      local dest_file="$CLAUDE_HOME/$file_name"

      # Never overwrite protected files
      if _is_protected "$file_name"; then
        log_warn "Protected file skipped: $file_name"
        continue
      fi

      _copy_kit_item "$kit_file" "$dest_file"
    fi
  done

  # ---------------------------------------------------------------------------
  # Step 4: Cleanup (handled by trap)
  # ---------------------------------------------------------------------------
  log_success "Kit installation complete."
  log_info "Review changes with: kitsync status"
  log_info "Commit and push with: kitsync push -m 'install kit from $kit_url'"
}
