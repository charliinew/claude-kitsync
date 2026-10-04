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
# Applied to settings.json only — other *.json files under $CLAUDE_HOME
# (projects/, plugins/, …) are runtime data owned by Claude Code.
# ---------------------------------------------------------------------------
normalize_paths() {
  local f="$CLAUDE_HOME/settings.json"
  [[ -f "$f" ]] || return 0

  # Escape target for sed replacement (&  and \ are metacharacters in replacement)
  local target_claude
  target_claude="$(printf '%s' "${HOME}/.claude" | sed 's|[&\\|]|\\&|g')"

  # Two anchored patterns — /Users/ (macOS) and /home/ (Linux)
  # Anchoring prevents false matches on URLs or paths that merely contain /.claude
  _sed_inplace "s|/Users/[^/]*/\\.claude|${target_claude}|g" "$f" 2>/dev/null || true
  _sed_inplace "s|/home/[^/]*/\\.claude|${target_claude}|g"  "$f" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Portable path tokens
#
#   $CLAUDE_HOME  ↔  __CLAUDE_HOME__
#   $HOME         ↔  __HOME__          (covers .bun, .local, etc.)
#
# Tokens live only in git: a clean/smudge filter (paths_filter_setup) converts
# synced text files on their way in and out of the repo, so the working tree
# always keeps real absolute paths and never looks dirty after a push.
# A path is replaced only where it ends (/, quote, space…): /Users/al must not
# turn /Users/alice into __HOME__ice. CLAUDE_HOME is replaced first.
# ---------------------------------------------------------------------------
KITSYNC_PATH_FILTER="kitsync-paths"
KITSYNC_PATH_FILTERED_FILES=("settings.json" "*.json" "*.md" "*.sh" "*.py" "*.ts" "*.js"
  "*.mjs" "*.cjs" "*.toml" "*.yaml" "*.yml" "*.txt")

# _paths_sed_program <clean|smudge> — print the sed script for one direction
_paths_sed_program() {
  local pat_home pat_claude repl_home repl_claude
  # Pattern side (ERE): escape metacharacters and the | delimiter
  pat_home="$(printf '%s' "$HOME" | sed 's/[][\.*^$()+?{}|]/\\&/g')"
  pat_claude="$(printf '%s' "${CLAUDE_HOME:-$HOME/.claude}" | sed 's/[][\.*^$()+?{}|]/\\&/g')"
  # Replacement side: escape & \ and the | delimiter
  repl_home="$(printf '%s' "$HOME" | sed 's|[&\\|]|\\&|g')"
  repl_claude="$(printf '%s' "${CLAUDE_HOME:-$HOME/.claude}" | sed 's|[&\\|]|\\&|g')"
  # The path must end here: followed by a char that can't be part of a file
  # name, or by the end of the line (two rules: | is the sed delimiter)
  local end='([^A-Za-z0-9._-])'

  case "$1" in
    clean)
      printf 's|%s%s|__CLAUDE_HOME__\\1|g\ns|%s$|__CLAUDE_HOME__|\ns|%s%s|__HOME__\\1|g\ns|%s$|__HOME__|\n' \
        "$pat_claude" "$end" "$pat_claude" "$pat_home" "$end" "$pat_home" ;;
    smudge)
      printf 's|__CLAUDE_HOME__|%s|g\ns|__HOME__|%s|g\n' "$repl_claude" "$repl_home" ;;
  esac
}

# paths_tokenize_stream — stdin → stdout with $HOME paths replaced by tokens
paths_tokenize_stream() {
  sed -E -e "$(_paths_sed_program clean | tr '\n' ';')"
}

# paths_detokenize_stream — stdin → stdout with tokens replaced by $HOME paths
paths_detokenize_stream() {
  sed -E -e "$(_paths_sed_program smudge | tr '\n' ';')"
}

# _paths_migrate_head — commit, once, the tokenized version of the COMMITTED
# filtered files that still hold this machine's absolute paths (they would
# look modified forever otherwise). Done through a temporary index: the real
# index and working tree keep any pending edit, which goes through push (its
# selection and its checks).
_paths_migrate_head() {
  local files f mode old new idx tree commit changed=""
  files="$(git -C "$CLAUDE_HOME" grep -lF -e "$HOME" HEAD -- "${KITSYNC_PATH_FILTERED_FILES[@]}" 2>/dev/null \
    | sed 's/^HEAD://')" || true
  [[ -n "$files" ]] || return 0
  idx="$(mktemp)"
  GIT_INDEX_FILE="$idx" git -C "$CLAUDE_HOME" read-tree HEAD || { rm -f "$idx"; return 1; }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    mode="$(git -C "$CLAUDE_HOME" ls-tree HEAD -- "$f" | awk '{print $1}')"
    old="$(git -C "$CLAUDE_HOME" rev-parse "HEAD:$f")"
    new="$(git -C "$CLAUDE_HOME" show "HEAD:$f" | paths_tokenize_stream | git -C "$CLAUDE_HOME" hash-object -w --stdin)" || continue
    [[ "$new" == "$old" ]] && continue   # only another user's path, e.g. /Users/alice
    GIT_INDEX_FILE="$idx" git -C "$CLAUDE_HOME" update-index --cacheinfo "$mode,$new,$f" && changed+="$f"$'\n'
  done <<< "$files"
  if [[ -n "$changed" ]] && tree="$(GIT_INDEX_FILE="$idx" git -C "$CLAUDE_HOME" write-tree)" &&
     commit="$(git -C "$CLAUDE_HOME" commit-tree "$tree" -p HEAD -m "kitsync: portable path tokens")" &&
     git -C "$CLAUDE_HOME" update-ref HEAD "$commit"; then
    # The real index still holds the old blobs: point them at the new HEAD
    while IFS= read -r f; do
      [[ -n "$f" ]] && git -C "$CLAUDE_HOME" reset -q -- "$f" 2>/dev/null
    done <<< "$changed"
  fi
  rm -f "$idx"
  return 0
}

# ---------------------------------------------------------------------------
# paths_filter_setup — idempotently register the clean/smudge filter in the
# repo's .git/config and bind it to settings.json in .git/info/attributes.
# Both are per-machine (never synced): the filter embeds this machine's $HOME,
# and a synced .gitattributes created locally would block the first pull.
# ---------------------------------------------------------------------------
paths_filter_setup() {
  [[ -d "$CLAUDE_HOME/.git" ]] || return 0

  # The sed program is single-quoted inside the git config value
  if [[ "$HOME$CLAUDE_HOME" == *"'"* ]]; then
    log_warn "HOME contains a single quote — path tokens disabled."
    return 0
  fi

  local clean smudge
  clean="sed -E -e '$(_paths_sed_program clean | tr '\n' ';')'"
  smudge="sed -E -e '$(_paths_sed_program smudge | tr '\n' ';')'"
  git -C "$CLAUDE_HOME" config "filter.${KITSYNC_PATH_FILTER}.clean" "$clean"
  git -C "$CLAUDE_HOME" config "filter.${KITSYNC_PATH_FILTER}.smudge" "$smudge"

  local attrs="$CLAUDE_HOME/.git/info/attributes" f line
  mkdir -p "$CLAUDE_HOME/.git/info" 2>/dev/null || true
  for f in "${KITSYNC_PATH_FILTERED_FILES[@]}"; do
    line="$f filter=${KITSYNC_PATH_FILTER}"
    grep -qxF "$line" "$attrs" 2>/dev/null || printf '%s\n' "$line" >> "$attrs"
  done
  _paths_migrate_head || true
}

# ---------------------------------------------------------------------------
# paths_detokenize — replace tokens in the working-tree settings.json.
# Needed for content that bypasses the smudge filter (decrypted .enc files,
# repos pulled before the filter was configured).
# ---------------------------------------------------------------------------
paths_detokenize() {
  local settings_file="$CLAUDE_HOME/settings.json"
  [[ -f "$settings_file" ]] || return 0
  grep -q '__CLAUDE_HOME__\|__HOME__' "$settings_file" 2>/dev/null || return 0

  local tmp="${settings_file}.tmp.$$"
  if paths_detokenize_stream < "$settings_file" > "$tmp" 2>/dev/null; then
    cat "$tmp" > "$settings_file"
  fi
  rm -f "$tmp"
}
