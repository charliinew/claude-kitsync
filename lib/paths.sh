#!/usr/bin/env bash
# lib/paths.sh — Absolute path normalisation across machines and OS variants
set -euo pipefail

# ---------------------------------------------------------------------------
# _sed_inplace — portable in-place sed (macOS requires sed -i '', Linux sed -i)
# Usage: _sed_inplace 'expression' file
# ---------------------------------------------------------------------------
_sed_inplace() {
  local expression="$1"
  local file="$2"

  if is_macos; then
    sed -i '' "$expression" "$file"
  else
    sed -i "$expression" "$file"
  fi
}

# ---------------------------------------------------------------------------
# normalize_paths — rewrite absolute paths pointing to any user's ~/.claude
# directory to the current user's $HOME/.claude.
#
# Handles cross-user portability: /Users/alice/.claude → /home/bob/.claude
#
# Applied to: settings.json (and any *.json inside $CLAUDE_HOME, recursively,
# except .credentials.json and settings.local.json).
# ---------------------------------------------------------------------------
normalize_paths() {
  # Escape target for sed replacement (&  and \ are metacharacters in replacement)
  local target_claude
  target_claude="$(printf '%s' "${HOME}/.claude" | sed 's|[&\\]|\\&|g')"

  # Two anchored patterns — /Users/ (macOS) and /home/ (Linux)
  # Anchoring prevents false matches on URLs or paths that merely contain /.claude
  local pattern_users="s|/Users/[^/]*/\\.claude|${target_claude}|g"
  local pattern_home="s|/home/[^/]*/\\.claude|${target_claude}|g"

  # Files to normalise — never touch credentials or local settings
  local files_to_process=()
  while IFS= read -r -d '' f; do
    local basename_f
    basename_f="$(basename "$f")"
    # Skip protected files
    if [[ "$basename_f" == ".credentials.json" ]] || \
       [[ "$basename_f" == "settings.local.json" ]]; then
      continue
    fi
    files_to_process+=("$f")
  done < <(find "$CLAUDE_HOME" -maxdepth 3 -name "*.json" -print0 2>/dev/null)

  local changed=0
  for f in "${files_to_process[@]+"${files_to_process[@]}"}"; do
    if [[ -f "$f" ]]; then
      _sed_inplace "$pattern_users" "$f" 2>/dev/null || true
      _sed_inplace "$pattern_home"  "$f" 2>/dev/null || true
      changed=$((changed + 1))
    fi
  done

  if [[ $changed -gt 0 ]]; then
    log_info "normalize_paths: processed $changed file(s) in $CLAUDE_HOME"
  fi
}

# ---------------------------------------------------------------------------
# paths_tokenize — before push, replace $HOME/.claude with __CLAUDE_HOME__
# in settings.json so that the repo remains portable across users.
# This is the inverse of normalize_paths.
# ---------------------------------------------------------------------------
paths_tokenize() {
  local settings_file="$CLAUDE_HOME/settings.json"
  if [[ ! -f "$settings_file" ]]; then
    return 0
  fi

  # Escape HOME for use in sed replacement
  local escaped_home
  escaped_home="$(printf '%s' "$HOME" | sed 's|[.[\*^$/\\]|\\&|g')"

  local pattern="s|${escaped_home}/\\.claude|__CLAUDE_HOME__|g"

  if is_macos; then
    sed -i '' "$pattern" "$settings_file" 2>/dev/null || true
  else
    sed -i "$pattern" "$settings_file" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# paths_detokenize — replace __CLAUDE_HOME__ back to $HOME/.claude
# Called after pull, as a fallback if normalize_paths regex misses tokens.
# ---------------------------------------------------------------------------
paths_detokenize() {
  local settings_file="$CLAUDE_HOME/settings.json"
  if [[ ! -f "$settings_file" ]]; then
    return 0
  fi

  local escaped_target
  escaped_target="${HOME}/.claude"
  # Escape for sed replacement
  local escaped_repl
  escaped_repl="$(printf '%s' "$escaped_target" | sed 's|[&\\|]|\\&|g')"

  local pattern="s|__CLAUDE_HOME__|${escaped_repl}|g"

  if is_macos; then
    sed -i '' "$pattern" "$settings_file" 2>/dev/null || true
  else
    sed -i "$pattern" "$settings_file" 2>/dev/null || true
  fi
}
