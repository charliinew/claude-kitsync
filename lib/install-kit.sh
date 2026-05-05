#!/usr/bin/env bash
# lib/install-kit.sh — `kitsync install <url>` — clone a public kit and merge into ~/.claude
set -euo pipefail

# Include guard — prevent re-definition of readonly arrays on multiple source calls
[[ -n "${_INSTALL_KIT_SH_LOADED:-}" ]] && return 0
readonly _INSTALL_KIT_SH_LOADED=1

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
# _find_kit_root — detect where kit items live inside a cloned repo.
# Some repos place agents/, skills/, etc. in a subdirectory rather than at root.
# Returns the best candidate path on stdout (falls back to $1 if none found).
# ---------------------------------------------------------------------------
_find_kit_root() {
  local tmp_dir="$1"
  # Local copy — avoids bash 3.2 scoping issue where readonly globals declared
  # in a sourced script are invisible outside the calling function's scope.
  local _dirs=(agents skills hooks rules scripts .kitsync)

  # Fast path: any copyable dir exists at root → standard layout
  for dir_name in "${_dirs[@]}"; do
    if [[ -d "$tmp_dir/$dir_name" ]]; then
      echo "$tmp_dir"
      return 0
    fi
  done

  # Scan up to depth 4 for copyable dir names in subdirectories.
  # For each candidate parent, count how many copyable dirs it contains.
  # Pick the parent with the highest count (shallowest wins on tie).
  local best_parent="" best_count=0 seen_parents=""

  for dir_name in "${_dirs[@]}"; do
    while IFS= read -r found; do
      local parent
      parent="$(dirname "$found")"

      # Skip already-scored parents (we already counted all their copyable dirs)
      [[ ",$seen_parents," == *",$parent,"* ]] && continue
      seen_parents="${seen_parents:+$seen_parents,}$parent"

      local count=0
      for check in "${_dirs[@]}"; do
        [[ -d "$parent/$check" ]] && count=$(( count + 1 ))
      done

      if (( count > best_count )) || \
         { (( count == best_count && count > 0 )) && \
           (( ${#parent} < ${#best_parent} )); }; then
        best_count=$count
        best_parent="$parent"
      fi
    done < <(find "$tmp_dir" -mindepth 2 -maxdepth 4 -type d -name "$dir_name" 2>/dev/null)
  done

  if [[ -n "$best_parent" && $best_count -gt 0 ]]; then
    log_info "Non-standard layout detected — kit root: ${best_parent#"$tmp_dir/"}"
    echo "$best_parent"
  else
    echo "$tmp_dir"
  fi
}

# ---------------------------------------------------------------------------
# _parse_skill_url — parse a URL that may point to a specific item in a repo.
# Handles GitHub tree URLs: https://github.com/owner/repo/tree/<branch>/<path>
# Sets globals: _PARSED_REPO_URL, _PARSED_SUBPATH
# ---------------------------------------------------------------------------
_PARSED_REPO_URL=""
_PARSED_SUBPATH=""

_parse_skill_url() {
  local url="$1"
  _PARSED_SUBPATH=""

  if [[ "$url" =~ ^(https://github\.com/[^/]+/[^/]+)/tree/[^/]+/(.+)$ ]]; then
    _PARSED_REPO_URL="${BASH_REMATCH[1]}"
    _PARSED_SUBPATH="${BASH_REMATCH[2]}"
  else
    _PARSED_REPO_URL="$url"
    _PARSED_SUBPATH=""
  fi
}

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
    printf "${_CLR_YELLOW}[kitsync]${_CLR_RESET}  File exists: %s\n" "$dest_file" >/dev/tty
    printf "  [s] skip   [o] overwrite   [b] backup+overwrite   [S] skip all   [O] overwrite all\n" >/dev/tty
    printf "  Choice: " >/dev/tty
    read -r choice </dev/tty

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
# cmd_install — main entry point for `kitsync install [--skill] <url>`
# ---------------------------------------------------------------------------
cmd_install() {
  local kit_url="" _mode="full"

  # Parse flags (pattern consistent with push/init commands)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skill)
        _mode="skill"
        shift
        kit_url="${1:-}"
        [[ -z "$kit_url" ]] && die "--skill requires a URL argument"
        shift
        ;;
      --skill=*)
        _mode="skill"
        kit_url="${1#--skill=}"
        shift
        ;;
      -*)
        die "Unknown option: $1 (usage: claude-kitsync install [--skill] <url>)"
        ;;
      *)
        kit_url="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$kit_url" ]]; then
    die "Usage: claude-kitsync install [--skill] <github-url>"
  fi

  require_command git

  # ---------------------------------------------------------------------------
  # Step 1: Resolve clone URL (handle GitHub tree URLs for --skill)
  # ---------------------------------------------------------------------------
  local clone_url="$kit_url"
  if [[ "$_mode" == "skill" ]]; then
    _parse_skill_url "$kit_url"
    clone_url="$_PARSED_REPO_URL"
  fi

  # Validate URL scheme — only https:// and git@ are accepted
  if [[ ! "$clone_url" =~ ^(https://|git@) ]]; then
    die "Only https:// and git@ URLs are accepted (got: $clone_url)"
  fi

  # ---------------------------------------------------------------------------
  # Step 2: Clone into a temp directory
  # ---------------------------------------------------------------------------
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT INT TERM

  log_step "Cloning kit from $clone_url..."
  if ! git clone --depth 1 "$clone_url" "$tmp_dir" 2>/dev/null; then
    die "Failed to clone $clone_url — check the URL and your network connection."
  fi
  log_success "Kit cloned successfully."

  # Reset conflict-all preference for this install session
  _KIT_CONFLICT_ALL=""

  # ---------------------------------------------------------------------------
  # Step 3: Install based on mode
  # ---------------------------------------------------------------------------
  if [[ "$_mode" == "skill" ]]; then
    # --skill: install only skills
    if [[ -n "$_PARSED_SUBPATH" ]]; then
      # Specific skill path extracted from a GitHub tree URL
      local specific_dir="$tmp_dir/$_PARSED_SUBPATH"
      if [[ ! -d "$specific_dir" ]]; then
        die "Path not found in repository: $_PARSED_SUBPATH"
      fi
      log_step "Installing skill from $_PARSED_SUBPATH..."
      _copy_kit_dir "$specific_dir" "$CLAUDE_HOME/skills"
    else
      # Plain repo URL with --skill: detect layout then install only skills/
      local kit_root
      kit_root="$(_find_kit_root "$tmp_dir")"
      local skills_src="$kit_root/skills"
      if [[ ! -d "$skills_src" ]]; then
        die "No skills/ directory found in repository"
      fi
      _copy_kit_dir "$skills_src" "$CLAUDE_HOME"
    fi
  else
    # ---------------------------------------------------------------------------
    # Full install: detect kit root (flexible layout) then copy all categories
    # ---------------------------------------------------------------------------
    local kit_root
    kit_root="$(_find_kit_root "$tmp_dir")"

    for dir_name in "${KIT_COPYABLE_DIRS[@]}"; do
      local kit_dir="$kit_root/$dir_name"
      if [[ -d "$kit_dir" ]]; then
        _copy_kit_dir "$kit_dir" "$CLAUDE_HOME"
      fi
    done

    for file_name in "${KIT_COPYABLE_FILES[@]}"; do
      local kit_file="$kit_root/$file_name"
      if [[ -f "$kit_file" ]]; then
        if _is_protected "$file_name"; then
          log_warn "Protected file skipped: $file_name"
          continue
        fi
        _copy_kit_item "$kit_file" "$CLAUDE_HOME/$file_name"
      fi
    done
  fi

  # ---------------------------------------------------------------------------
  # Step 4: Cleanup (handled by trap)
  # ---------------------------------------------------------------------------
  log_success "Kit installation complete."
  log_info "Review changes with: claude-kitsync status"
  log_info "Commit and push with: claude-kitsync push -m 'install kit from $kit_url'"
}
