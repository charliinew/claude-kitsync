#!/usr/bin/env bash
# lib/sync.sh — git pull / push / status operations for $CLAUDE_HOME
set -euo pipefail

# ---------------------------------------------------------------------------
# WHITELIST — files and directories safe to add to git commits
# ---------------------------------------------------------------------------
readonly SYNC_WHITELIST=(
  "settings.json"
  "CLAUDE.md"
  "agents/"
  "skills/"
  "hooks/"
  "scripts/"
  "rules/"
  ".gitignore"
  ".kitsync/"
  "settings.template.json"
)

# ---------------------------------------------------------------------------
# _is_dirty — returns 0 if working tree has uncommitted changes, 1 if clean
# ---------------------------------------------------------------------------
_is_dirty() {
  [[ -n "$(git -C "$CLAUDE_HOME" status --porcelain 2>/dev/null)" ]]
}

# ---------------------------------------------------------------------------
# _has_remote — returns 0 if origin remote is configured
# ---------------------------------------------------------------------------
_has_remote() {
  git -C "$CLAUDE_HOME" remote get-url origin &>/dev/null
}

# ---------------------------------------------------------------------------
# _prompt_conflict_resolution — interactive menu after a failed pull/rebase
# The rebase is aborted before this is called; repo is in a clean state.
# ---------------------------------------------------------------------------
_prompt_conflict_resolution() {
  local _branch="$1"

  printf "\n"
  local choice
  choice=$(_select_menu "How would you like to resolve?" \
    "Accept remote — reset local to remote version" \
    "Keep local — discard incoming changes" \
    "Exit — I will resolve manually")

  case "$choice" in
    1)
      log_step "Accepting remote version..."
      git -C "$CLAUDE_HOME" fetch origin -q 2>/dev/null || true
      git -C "$CLAUDE_HOME" reset --hard "origin/$_branch" 2>/dev/null || {
        log_warn "Hard reset failed — try manually: git -C \"$CLAUDE_HOME\" reset --hard origin/$_branch"
        return 1
      }
      normalize_paths
      paths_detokenize
      log_success "Pulled remote version — local state updated."
      ;;
    2)
      log_info "Keeping local version — no changes applied."
      ;;
    3)
      log_info "Exiting — repo is clean (rebase aborted)."
      log_info "To inspect: cd \"$CLAUDE_HOME\" && git status"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# sync_pull — pull latest changes from remote
#
# Strategy:
#   1. Skip with warning if dirty working tree (never lose local changes)
#   2. git pull --rebase --autostash -X theirs -q (repo wins on conflict)
#   3. On failure: abort rebase and warn
#   4. Run normalize_paths after successful pull
# ---------------------------------------------------------------------------
sync_pull() {
  local force="${1:-}"

  require_git_repo

  if ! _has_remote; then
    log_warn "No remote configured — skipping pull."
    return 0
  fi

  # Step 1: dirty tree check
  if _is_dirty; then
    if [[ "$force" == "--force" ]]; then
      log_warn "Dirty tree detected — force flag passed, continuing anyway."
    else
      log_warn "Uncommitted changes detected in $CLAUDE_HOME — skipping auto-pull."
      log_warn "Commit or stash your changes first, or run: claude-kitsync pull --force"
      return 0
    fi
  fi

  # Ensure upstream tracking is set
  local _branch
  _branch="$(git -C "$CLAUDE_HOME" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  if ! git -C "$CLAUDE_HOME" rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null 2>&1; then
    git -C "$CLAUDE_HOME" branch --set-upstream-to="origin/$_branch" "$_branch" 2>/dev/null || true
  fi

  log_step "Pulling from remote..."

  # Pre-fetch so we can warn about files that -X theirs would silently overwrite
  if git -C "$CLAUDE_HOME" fetch origin -q 2>/dev/null; then
    if git -C "$CLAUDE_HOME" rev-parse --verify "origin/$_branch" &>/dev/null; then
      local _local_changed _remote_changed _would_overwrite
      _local_changed="$(git -C "$CLAUDE_HOME" diff --name-only "origin/$_branch..HEAD" 2>/dev/null || true)"
      _remote_changed="$(git -C "$CLAUDE_HOME" diff --name-only "HEAD..origin/$_branch" 2>/dev/null || true)"

      if [[ -n "$_local_changed" ]] && [[ -n "$_remote_changed" ]]; then
        _would_overwrite="$(comm -12 \
          <(printf '%s\n' "$_local_changed" | sort) \
          <(printf '%s\n' "$_remote_changed" | sort) || true)"

        if [[ -n "$_would_overwrite" ]]; then
          log_warn "Conflict detected — the following files changed both locally and on remote:"
          while IFS= read -r _f; do
            log_warn "  • $_f"
          done <<< "$_would_overwrite"
          log_warn "Remote version will be kept (-X theirs). Your local commits on these files will be overwritten."
          printf "\n"
        fi
      fi
    fi
  fi

  # Step 2: rebase pull with autostash and theirs strategy (repo wins on conflict)
  local _pull_out
  if _pull_out="$(git -C "$CLAUDE_HOME" pull --rebase --autostash --allow-unrelated-histories -X theirs 2>&1)"; then
    log_success "Pull complete."
    # Step 4: normalise absolute paths after pull
    normalize_paths
    paths_detokenize
  else
    # Step 3: show conflict details, abort rebase, offer interactive resolution
    log_warn "Pull/rebase failed — checking for conflicts..."

    local _conflicts
    _conflicts="$(git -C "$CLAUDE_HOME" diff --name-only --diff-filter=U 2>/dev/null)"
    if [[ -n "$_conflicts" ]]; then
      log_warn "Conflicting files:"
      while IFS= read -r _f; do
        log_warn "  • $_f"
      done <<< "$_conflicts"
    fi

    if [[ -n "$_pull_out" ]]; then
      log_warn "Git output:"
      printf "%s\n" "$_pull_out" | grep -v "^$" | while IFS= read -r _line; do
        log_warn "  $_line"
      done
    fi

    git -C "$CLAUDE_HOME" rebase --abort 2>/dev/null || true
    log_warn "Rebase aborted — local state restored."
    _prompt_conflict_resolution "$_branch"
    return $?
  fi
}

# ---------------------------------------------------------------------------
# sync_push [msg] — stage whitelisted files, commit, push
#
# Safety check: aborts immediately if .credentials.json is staged.
# ---------------------------------------------------------------------------
sync_push() {
  local commit_msg=""
  local _auto=false
  local _dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto)       _auto=true;     shift ;;
      --dry-run|-n) _dry_run=true;  shift ;;
      *)            commit_msg="$1"; shift ;;
    esac
  done
  commit_msg="${commit_msg:-kitsync: sync $(date '+%Y-%m-%d %H:%M')}"

  # In auto mode suppress info/step/success — only warnings and errors remain
  _plog_step()    { [[ "$_auto" == false ]] && log_step "$@" || true; }
  _plog_success() { [[ "$_auto" == false ]] && log_success "$@" || true; }
  _plog_info()    { [[ "$_auto" == false ]] && log_info "$@" || true; }

  require_git_repo

  if ! _has_remote; then
    die "No remote configured. Run: git -C \"$CLAUDE_HOME\" remote add origin <url>"
  fi

  # Safety check: ensure .credentials.json is not staged or tracked
  if git -C "$CLAUDE_HOME" ls-files --error-unmatch ".credentials.json" &>/dev/null; then
    log_error "CRITICAL: .credentials.json is tracked by git!"
    log_error "Remove it immediately with:"
    log_error "  git -C \"$CLAUDE_HOME\" rm --cached .credentials.json"
    log_error "  echo '.credentials.json' >> \"$CLAUDE_HOME/.gitignore\""
    exit 1
  fi

  # Check if it would be staged (porcelain format: "XY PATH" — space before exact filename)
  if git -C "$CLAUDE_HOME" status --porcelain 2>/dev/null | grep -qE " \.credentials\.json$"; then
    log_error "CRITICAL: .credentials.json appears in git status!"
    log_error "This file must never be committed. Add it to .gitignore first."
    exit 1
  fi

  # Dry-run: stage → preview → reset → exit
  if [[ "$_dry_run" == true ]]; then
    log_step "Dry run — showing what would be committed\n"
    for item in "${SYNC_WHITELIST[@]}"; do
      local _fp="$CLAUDE_HOME/$item"
      [[ -e "$_fp" ]] && git -C "$CLAUDE_HOME" add "$_fp" 2>/dev/null || true
    done
    if git -C "$CLAUDE_HOME" diff --cached --quiet 2>/dev/null; then
      log_info "Nothing to commit — working tree clean for synced files."
    else
      git -C "$CLAUDE_HOME" diff --cached --name-status 2>/dev/null | \
        while IFS=$'\t' read -r _st _file; do
          case "$_st" in
            M) log_info "  modified:  $_file" ;;
            A) log_info "  new file:  $_file" ;;
            D) log_info "  deleted:   $_file" ;;
            *) log_info "  $_st         $_file" ;;
          esac
        done
      printf "\n"
      log_info "Commit message: kitsync: sync $(date '+%Y-%m-%d %H:%M')"
      log_info "Would push to:  $(git -C "$CLAUDE_HOME" remote get-url origin 2>/dev/null || echo 'no remote')"
    fi
    git -C "$CLAUDE_HOME" reset HEAD -- . 2>/dev/null || true
    printf "\n"
    return 0
  fi

  _plog_step "Staging whitelisted files..."

  # Stage only whitelisted paths (paths that exist)
  local staged_count=0
  for item in "${SYNC_WHITELIST[@]}"; do
    local full_path="$CLAUDE_HOME/$item"
    if [[ -e "$full_path" ]]; then
      git -C "$CLAUDE_HOME" add "$full_path" 2>/dev/null || true
      staged_count=$((staged_count + 1))
    fi
  done

  # Final safety: verify .credentials.json not staged after add (--name-only = one filename per line)
  if git -C "$CLAUDE_HOME" diff --cached --name-only 2>/dev/null | grep -q "^\.credentials\.json$"; then
    log_error "CRITICAL: .credentials.json ended up staged — aborting commit!"
    git -C "$CLAUDE_HOME" reset HEAD ".credentials.json" 2>/dev/null || true
    exit 1
  fi

  # Check if there is anything to commit
  if git -C "$CLAUDE_HOME" diff --cached --quiet 2>/dev/null; then
    _plog_info "Nothing to commit — working tree clean."
    return 0
  fi

  _plog_step "Committing: $commit_msg"
  local _commit_out
  if _commit_out="$(git -C "$CLAUDE_HOME" commit -m "$commit_msg" 2>&1)"; then
    [[ "$_auto" == false ]] && \
      printf "%s\n" "$_commit_out" | grep -Ev "^[[:space:]]+(create|delete) mode " || true
  else
    printf "%s\n" "$_commit_out" >&2
    exit 1
  fi

  _plog_step "Pushing to remote..."
  local _branch
  _branch="$(git -C "$CLAUDE_HOME" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  if ! git -C "$CLAUDE_HOME" push -q 2>/dev/null; then
    # No upstream set yet — set it and push
    git -C "$CLAUDE_HOME" push -q -u origin "$_branch" 2>/dev/null || \
      log_warn "Auto-push failed — run 'claude-kitsync push' to retry."
  fi

  _plog_success "Push complete."
}

# ---------------------------------------------------------------------------
# sync_log — show formatted git log of $CLAUDE_HOME
# ---------------------------------------------------------------------------
sync_log() {
  require_git_repo
  local count="${1:-15}"
  [[ "$count" =~ ^[0-9]+$ ]] || count=15

  printf "\n"
  log_info "Sync history — $CLAUDE_HOME\n"

  if ! git -C "$CLAUDE_HOME" log -1 --oneline &>/dev/null 2>&1; then
    log_warn "No commits yet."
    return 0
  fi

  git -C "$CLAUDE_HOME" log -n "$count" \
    --pretty=format:"%C(yellow)%h%Creset  %C(cyan)%ad%Creset  %s" \
    --date=format:'%Y-%m-%d %H:%M'

  printf "\n\n"
}

# ---------------------------------------------------------------------------
# sync_diff — fetch remote and show ahead/behind summary with interactive pager
# ---------------------------------------------------------------------------
sync_diff() {
  require_git_repo

  if ! _has_remote; then
    log_warn "No remote configured — run: claude-kitsync settings"
    return 1
  fi

  log_step "Fetching remote state..."
  git -C "$CLAUDE_HOME" fetch origin -q 2>/dev/null || {
    log_warn "Could not reach remote — check your connection."
    return 1
  }

  local _branch
  _branch="$(git -C "$CLAUDE_HOME" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  local _remote="origin/$_branch"

  if ! git -C "$CLAUDE_HOME" rev-parse --verify "$_remote" &>/dev/null; then
    log_warn "Remote branch $_remote does not exist yet."
    log_info "Push first: claude-kitsync push"
    return 0
  fi

  local _ahead _behind
  _ahead="$(git -C "$CLAUDE_HOME" rev-list --count "$_remote..HEAD" 2>/dev/null || echo 0)"
  _behind="$(git -C "$CLAUDE_HOME" rev-list --count "HEAD..$_remote" 2>/dev/null || echo 0)"

  printf "\n"
  log_info "Diff — $CLAUDE_HOME  (branch: $_branch)\n"

  if [[ "$_ahead" -eq 0 ]] && [[ "$_behind" -eq 0 ]]; then
    log_success "Up to date with remote — nothing to diff."
    printf "\n"
    return 0
  fi

  printf "  %s ahead · %s behind\n\n" "$_ahead" "$_behind"

  if [[ "$_ahead" -gt 0 ]]; then
    local _s; [[ "$_ahead" -gt 1 ]] && _s="s" || _s=""
    printf "%s  ↑ Outgoing (%s commit%s not yet pushed):%s\n" \
      "$_CLR_YELLOW" "$_ahead" "$_s" "$_CLR_RESET"
    git -C "$CLAUDE_HOME" log \
      --pretty=format:"    %C(yellow)%h%Creset  %C(cyan)%ad%Creset  %s" \
      --date=format:'%Y-%m-%d %H:%M' \
      "$_remote..HEAD"
    printf "\n\n"
  fi

  if [[ "$_behind" -gt 0 ]]; then
    local _s; [[ "$_behind" -gt 1 ]] && _s="s" || _s=""
    printf "%s  ↓ Incoming (%s commit%s from remote):%s\n" \
      "$_CLR_CYAN" "$_behind" "$_s" "$_CLR_RESET"
    git -C "$CLAUDE_HOME" log \
      --pretty=format:"    %C(yellow)%h%Creset  %C(cyan)%ad%Creset  %s" \
      --date=format:'%Y-%m-%d %H:%M' \
      "HEAD..$_remote"
    printf "\n\n"

    local _stat
    _stat="$(git -C "$CLAUDE_HOME" diff --stat "HEAD...$_remote" 2>/dev/null || true)"
    if [[ -n "$_stat" ]]; then
      printf "  Files changed (incoming):\n"
      printf "%s\n\n" "$_stat" | sed 's/^/    /'
    fi
  fi

  local choice
  choice=$(_select_menu "View full diff?" \
    "Incoming diff  (remote → local)" \
    "Outgoing diff  (local → remote)" \
    "Exit")

  case "$choice" in
    1) git -C "$CLAUDE_HOME" diff "HEAD...$_remote" 2>/dev/null | "${PAGER:-less}" -R ;;
    2) git -C "$CLAUDE_HOME" diff "$_remote...HEAD" 2>/dev/null | "${PAGER:-less}" -R ;;
    3) true ;;
  esac
}

# ---------------------------------------------------------------------------
# sync_status — show short git status of $CLAUDE_HOME
# ---------------------------------------------------------------------------
sync_status() {
  require_git_repo

  local branch
  branch="$(git -C "$CLAUDE_HOME" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"

  printf "\n"
  log_info "Repository: $CLAUDE_HOME"
  log_info "Branch:     $branch"
  printf "\n"

  local status_output
  status_output="$(git -C "$CLAUDE_HOME" status --short 2>/dev/null)"

  if [[ -z "$status_output" ]]; then
    log_success "Working tree clean — nothing to sync."
  else
    printf "%s\n" "$status_output"
  fi

  printf "\n"

  # Show last commit info
  if git -C "$CLAUDE_HOME" log -1 --oneline &>/dev/null 2>&1; then
    log_info "Last commit: $(git -C "$CLAUDE_HOME" log -1 --oneline 2>/dev/null)"
  fi

  # Show ahead/behind if remote exists
  if _has_remote; then
    local ahead behind
    ahead="$(git -C "$CLAUDE_HOME" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    behind="$(git -C "$CLAUDE_HOME" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
    if [[ "$ahead" -gt 0 ]] || [[ "$behind" -gt 0 ]]; then
      log_info "Remote delta: $ahead ahead, $behind behind"
    fi
  fi
}
