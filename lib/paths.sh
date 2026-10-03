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
#   $HOME/.claude  ↔  __CLAUDE_HOME__
#   $HOME          ↔  __HOME__          (covers .bun, .local, etc.)
#
# Tokens live only in git: a clean/smudge filter (paths_filter_setup) converts
# settings.json on its way in and out of the repo, so the working tree always
# keeps real absolute paths and never looks dirty after a push.
# Order matters: the longer prefix is replaced first.
# ---------------------------------------------------------------------------
KITSYNC_PATH_FILTER="kitsync-paths"
KITSYNC_PATH_FILTERED_FILES=("settings.json")

# _paths_sed_program <clean|smudge> — print the sed script for one direction
_paths_sed_program() {
  local pat_home repl_home repl_claude_home
  # Pattern side: escape regex metacharacters and the | delimiter
  pat_home="$(printf '%s' "$HOME" | sed 's|[].[\*^$/\\|]|\\&|g')"
  # Replacement side: escape & \ and the | delimiter
  repl_home="$(printf '%s' "$HOME" | sed 's|[&\\|]|\\&|g')"
  repl_claude_home="$(printf '%s' "$HOME/.claude" | sed 's|[&\\|]|\\&|g')"

  case "$1" in
    clean)
      printf 's|%s/\\.claude|__CLAUDE_HOME__|g\ns|%s|__HOME__|g\n' "$pat_home" "$pat_home" ;;
    smudge)
      printf 's|__CLAUDE_HOME__|%s|g\ns|__HOME__|%s|g\n' "$repl_claude_home" "$repl_home" ;;
  esac
}

# paths_tokenize_stream — stdin → stdout with $HOME paths replaced by tokens
paths_tokenize_stream() {
  sed -e "$(_paths_sed_program clean | tr '\n' ';')"
}

# paths_detokenize_stream — stdin → stdout with tokens replaced by $HOME paths
paths_detokenize_stream() {
  sed -e "$(_paths_sed_program smudge | tr '\n' ';')"
}

# _paths_commit_tokenized_head <file> — commit HEAD's <file> with its paths
# tokenized, through a temporary index (the real index and working tree keep
# any pending edit)
_paths_commit_tokenized_head() {
  local f="$1" mode sha tree commit idx rc=0
  mode="$(git -C "$CLAUDE_HOME" ls-tree HEAD -- "$f" | awk '{print $1}')"
  sha="$(git -C "$CLAUDE_HOME" show "HEAD:$f" | paths_tokenize_stream | git -C "$CLAUDE_HOME" hash-object -w --stdin)" || return 1
  idx="$(mktemp)"
  GIT_INDEX_FILE="$idx" git -C "$CLAUDE_HOME" read-tree HEAD &&
    GIT_INDEX_FILE="$idx" git -C "$CLAUDE_HOME" update-index --cacheinfo "$mode,$sha,$f" &&
    tree="$(GIT_INDEX_FILE="$idx" git -C "$CLAUDE_HOME" write-tree)" &&
    commit="$(git -C "$CLAUDE_HOME" commit-tree "$tree" -p HEAD -m "kitsync: portable path tokens in $f")" &&
    git -C "$CLAUDE_HOME" update-ref HEAD "$commit" || rc=1
  rm -f "$idx"
  # The index entry still holds the old blob: point it at the new HEAD
  [[ $rc -eq 0 ]] && git -C "$CLAUDE_HOME" reset -q -- "$f" 2>/dev/null
  return $rc
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
  if [[ "$HOME" == *"'"* ]]; then
    log_warn "HOME contains a single quote — path tokens disabled."
    return 0
  fi

  local clean smudge
  clean="sed -e '$(_paths_sed_program clean | tr '\n' ';')'"
  smudge="sed -e '$(_paths_sed_program smudge | tr '\n' ';')'"
  git -C "$CLAUDE_HOME" config "filter.${KITSYNC_PATH_FILTER}.clean" "$clean"
  git -C "$CLAUDE_HOME" config "filter.${KITSYNC_PATH_FILTER}.smudge" "$smudge"

  local attrs="$CLAUDE_HOME/.git/info/attributes" f line
  mkdir -p "$CLAUDE_HOME/.git/info" 2>/dev/null || true
  for f in "${KITSYNC_PATH_FILTERED_FILES[@]}"; do
    line="$f filter=${KITSYNC_PATH_FILTER}"
    grep -qxF "$line" "$attrs" 2>/dev/null || printf '%s\n' "$line" >> "$attrs"

    # Migration: a file committed with absolute paths now differs from its
    # cleaned form and would look modified forever. Commit the tokenized
    # version of the COMMITTED file once — never the working-tree edits, which
    # go through push (its selection and its broken-file checks).
    git -C "$CLAUDE_HOME" ls-files --error-unmatch -- "$f" &>/dev/null || continue
    git -C "$CLAUDE_HOME" show "HEAD:$f" 2>/dev/null | grep -qF "$HOME" || continue
    _paths_commit_tokenized_head "$f" || true
  done
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
