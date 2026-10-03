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
  "commands/"
  "output-styles/"
  "workflows/"
  "themes/"
  "keybindings.json"
  ".gitignore"
  ".kitsync/"
  "settings.template.json"
)

# User-configurable categories (infra items are always synced regardless of selection)
readonly SYNC_USER_CATEGORIES=("agents" "skills" "hooks" "scripts" "rules" "commands" "output-styles" "workflows" "themes" "keybindings.json" "settings.json" "CLAUDE.md")

# Map a user category name to its whitelist path
_sync_category_to_path() {
  case "$1" in
    agents|skills|hooks|scripts|rules|commands|output-styles|workflows|themes) printf '%s/' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Returns 0 if the given whitelist item is an infrastructure item (never filtered)
_sync_is_infra() {
  case "$1" in
    ".gitignore"|".kitsync/"|"settings.template.json") return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# _gitignore_migrate — bring an existing allowlist .gitignore up to date.
# `init` never overwrites an existing .gitignore, so rules added in later
# releases are appended here (only the missing ones, idempotent).
# Also untracks machine-local runtime files that older versions committed.
# ---------------------------------------------------------------------------
_gitignore_migrate() {
  local gi="$CLAUDE_HOME/.gitignore"
  # Only touch kitsync-style allowlists (deny-all first rule)
  grep -qx '\*' "$gi" 2>/dev/null || return 0

  local rules=(
    "!commands/" "!commands/**"
    "!output-styles/" "!output-styles/**"
    "!workflows/" "!workflows/**"
    "!themes/" "!themes/**"
    "!keybindings.json"
    ".kitsync/encryption.key*"
    ".kitsync/pending-notice"
    ".kitsync/conflict_pending"
    ".kitsync/sync-warning"
    ".kitsync/local"
    ".kitsync/*.tmp.*"
    "skills/synced/"
  )
  local missing=() r
  for r in "${rules[@]}"; do
    grep -qxF "$r" "$gi" 2>/dev/null || missing+=("$r")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '\n# Added by claude-kitsync %s\n' "${KITSYNC_VERSION:-upgrade}" >> "$gi"
    printf '%s\n' "${missing[@]}" >> "$gi"
  fi

  local tracked
  tracked="$(git -C "$CLAUDE_HOME" ls-files -- '.kitsync/encryption.key*' \
    .kitsync/pending-notice .kitsync/conflict_pending 2>/dev/null || true)"

  # Account skills managed by Claude Code (re-downloaded on every startup)
  if [[ -n "$(git -C "$CLAUDE_HOME" ls-files -- skills/synced 2>/dev/null | head -1)" ]]; then
    git -C "$CLAUDE_HOME" rm -r --cached -q -- skills/synced 2>/dev/null || true
    log_info "Stopped syncing skills/synced/ (claude.ai account skills, managed by Claude Code)."
  fi
  if [[ -n "$tracked" ]]; then
    printf '%s\n' "$tracked" | while IFS= read -r _f; do
      git -C "$CLAUDE_HOME" rm --cached -q -- "$_f" 2>/dev/null || true
    done
    log_warn "Untracked machine-local files from git: $(printf '%s' "$tracked" | tr '\n' ' ')"
  fi
}

# ---------------------------------------------------------------------------
# _sync_prepare_repo — per-run repo maintenance shared by push and pull:
# path-token filter, .gitignore migration, plaintext untracking under encryption.
# ---------------------------------------------------------------------------
_sync_prepare_repo() {
  paths_filter_setup 2>/dev/null || true
  _gitignore_migrate 2>/dev/null || true
  # Setups made before 1.1.15 committed .kitsync/config only on the first
  # push: another machine's pull then fails ("untracked working tree files
  # would be overwritten"). Track it before any rebase.
  if [[ -f "$CLAUDE_HOME/.kitsync/config" ]] && \
     ! git -C "$CLAUDE_HOME" ls-files --error-unmatch .kitsync/config &>/dev/null && \
     git -C "$CLAUDE_HOME" rev-parse -q --verify HEAD >/dev/null; then
    git -C "$CLAUDE_HOME" add -- .kitsync/config 2>/dev/null && \
      git -C "$CLAUDE_HOME" commit -q -m "kitsync: track sync preferences" -- .kitsync/config 2>/dev/null || true
  fi
  # 1.2.1: per-machine choices move to the never-synced .kitsync/local
  if _config_migrate_local && \
     git -C "$CLAUDE_HOME" ls-files --error-unmatch .kitsync/config &>/dev/null; then
    git -C "$CLAUDE_HOME" commit -q -m "kitsync: keep per-machine preferences out of sync" \
      -- .kitsync/config 2>/dev/null || true
  fi
  if _crypto_is_enabled 2>/dev/null; then
    _crypto_gitignore_block add 2>/dev/null || true
    git -C "$CLAUDE_HOME" rm --cached -q --ignore-unmatch \
      settings.json settings.template.json 2>/dev/null || true
  fi
}

# Returns comma-separated push categories from config, or all if unset
_sync_get_push_items() {
  local raw
  raw="$(_cfg_get KITSYNC_PUSH_ITEMS || true)"
  if [[ -z "$raw" ]]; then
    local IFS=","; echo "${SYNC_USER_CATEGORIES[*]}"
  else
    echo "$raw"
  fi
}

# Returns comma-separated pull categories from config, or all if unset
_sync_get_pull_items() {
  local raw
  raw="$(_cfg_get KITSYNC_PULL_ITEMS || true)"
  if [[ -z "$raw" ]]; then
    local IFS=","; echo "${SYNC_USER_CATEGORIES[*]}"
  else
    echo "$raw"
  fi
}

# Returns 0 if $1 is present in the comma-separated list $2
_sync_item_in_list() {
  [[ ",$2," == *",$1,"* ]]
}

# ---------------------------------------------------------------------------
# _is_dirty — returns 0 if working tree has uncommitted changes, 1 if clean
# ---------------------------------------------------------------------------
_is_dirty() {
  # Untracked files never block a rebase — only tracked changes count
  [[ -n "$(git -C "$CLAUDE_HOME" status --porcelain --untracked-files=no 2>/dev/null)" ]]
}

# ---------------------------------------------------------------------------
# Per-machine sync lock (inside .git/, never synced): two terminals, or a pull
# and an end-of-session push, must not run git on ~/.claude at the same time.
# ---------------------------------------------------------------------------
_SYNC_LOCKED=""

# _sync_lock <wait_seconds> — take the lock; 1 if still held by a live process
_sync_lock() {
  [[ -n "$_SYNC_LOCKED" ]] && return 0   # re-entrant (pull → push)
  local dir pid waited=0
  dir="$(git -C "$CLAUDE_HOME" rev-parse --absolute-git-dir 2>/dev/null)/kitsync.lock"
  while ! mkdir "$dir" 2>/dev/null; do
    pid="$(cat "$dir/pid" 2>/dev/null || true)"
    # Stale: holder gone, or crashed before writing its pid
    if { [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; } || \
       { [[ -z "$pid" ]] && [[ -n "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; }; then
      rm -f "$dir/pid"; rmdir "$dir" 2>/dev/null || true
      continue
    fi
    (( waited >= $1 )) && return 1
    sleep 1
    waited=$(( waited + 1 ))
  done
  printf '%s\n' "$$" > "$dir/pid"
  _SYNC_LOCKED="$dir"
  trap '_sync_unlock' EXIT
}

_sync_unlock() {
  [[ -n "$_SYNC_LOCKED" ]] || return 0
  rm -f "$_SYNC_LOCKED/pid"
  rmdir "$_SYNC_LOCKED" 2>/dev/null || true
  _SYNC_LOCKED=""
}

# _sync_warn_next_launch <msg> — shown by the claude() wrapper next time
# (background syncs have no terminal to warn on)
_sync_warn_next_launch() {
  mkdir -p "$CLAUDE_HOME/.kitsync" 2>/dev/null || true
  printf '%s\n' "$1" > "$CLAUDE_HOME/.kitsync/sync-warning" 2>/dev/null || true
}

# _markers <cmd...> — number of conflict-marker lines in the command's output
_markers() {
  "$@" 2>/dev/null | grep -cE '^(<<<<<<<|>>>>>>>)( |$)' || true
}

# Secret formats worth stopping a push for (name|extended regex)
_SYNC_SECRET_PATTERNS=(
  'Anthropic API key|sk-ant-[A-Za-z0-9_-]{20,}'
  'OpenAI API key|sk-(proj-)?[A-Za-z0-9_-]{32,}'
  'GitHub token|gh[pousr]_[A-Za-z0-9]{36}'
  'GitHub token|github_pat_[A-Za-z0-9_]{50,}'
  'AWS access key|AKIA[0-9A-Z]{16}'
  'Slack token|xox[abprs]-[A-Za-z0-9-]{10,}'
  'Google API key|AIza[0-9A-Za-z_-]{35}'
  'Private key|-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

# _sync_secret_in <file> — name of the first secret format found in the lines
# this commit adds to <file> (staged diff), empty if none
_sync_secret_in() {
  local added entry
  added="$(git -C "$CLAUDE_HOME" diff --cached -U0 -- "$1" 2>/dev/null | grep '^+' | grep -v '^+++' || true)"
  [[ -n "$added" ]] || return 0
  for entry in "${_SYNC_SECRET_PATTERNS[@]}"; do
    if grep -qE -- "${entry#*|}" <<< "$added"; then
      printf '%s' "${entry%%|*}"
      return 0
    fi
  done
}

# _sync_secret_allowed <file> — listed in .kitsync/allow-secrets (synced)
_sync_secret_allowed() {
  grep -qxF -- "$1" "$CLAUDE_HOME/.kitsync/allow-secrets" 2>/dev/null
}

# _sync_allow_secret <path> — `push --allow-secret <path>`
_sync_allow_secret() {
  local f="${1:-}"
  [[ -n "$f" ]] || die "Usage: claude-kitsync push --allow-secret <path relative to $CLAUDE_HOME>"
  f="${f#"$CLAUDE_HOME"/}"
  mkdir -p "$CLAUDE_HOME/.kitsync"
  _sync_secret_allowed "$f" || printf '%s\n' "$f" >> "$CLAUDE_HOME/.kitsync/allow-secrets"
  log_info "Secrets in $f will be pushed (listed in .kitsync/allow-secrets)."
}

# ---------------------------------------------------------------------------
# _sync_unstage_unsafe [dry] — leave out of the commit, with a warning:
#   - half-merged files: conflict markers the committed version did not have
#     (docs may show markers on purpose)
#   - a settings.json that is not valid JSON
#   - files that add something shaped like a secret (unless allowed)
# Everything else is still pushed. Sets _SYNC_LEFT_OUT ("file (reason)" lines).
# With "dry", nothing is recorded for the next session.
# ---------------------------------------------------------------------------
_SYNC_LEFT_OUT=""
_sync_unstage_unsafe() {
  local dry="${1:-}" f secret out=""
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if (( $(_markers git -C "$CLAUDE_HOME" show ":$f") > $(_markers git -C "$CLAUDE_HOME" show "HEAD:$f") )); then
      out+="$f (unresolved merge)"$'\n'
    elif ! _sync_secret_allowed "$f"; then
      secret="$(_sync_secret_in "$f")"
      [[ -z "$secret" ]] || out+="$f (looks like a secret: $secret)"$'\n'
    fi
  done < <(git -C "$CLAUDE_HOME" diff --cached --name-only --diff-filter=AM 2>/dev/null)

  # settings.json is checked on disk: under encryption only its .enc is staged
  if [[ -f "$CLAUDE_HOME/settings.json" ]] && command -v python3 &>/dev/null && \
     ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CLAUDE_HOME/settings.json" 2>/dev/null; then
    for f in settings.json settings.json.enc; do
      git -C "$CLAUDE_HOME" diff --cached --quiet -- "$f" 2>/dev/null || out+="$f (invalid JSON)"$'\n'
    done
  fi

  _SYNC_LEFT_OUT="$out"
  [[ -n "$out" ]] || return 0
  while IFS= read -r f; do
    [[ -n "$f" ]] && git -C "$CLAUDE_HOME" reset -q -- "${f% (*}" 2>/dev/null || true
  done <<< "$out"
  [[ "$dry" == dry ]] && return 0
  local list
  list="$(printf '%s' "$out" | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
  log_warn "Not pushed: $list"
  if grep -q 'looks like a secret' <<< "$out"; then
    log_info "  Move the secret out, encrypt settings.json (claude-kitsync encrypt enable), or allow it: claude-kitsync push --allow-secret <file>"
  fi
  _sync_warn_next_launch "Not pushed: $list — fix, then run claude-kitsync push"
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
      crypto_decrypt_all 2>/dev/null || true
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
#   2. git pull --rebase --autostash -X ours (remote wins on conflict).
#      During a rebase the sides are swapped: "ours" is the upstream being
#      rebased onto (the remote), "theirs" is the local commits being replayed.
#   3. On failure: abort rebase and warn
#   4. Decrypt, then normalise paths after successful pull
# ---------------------------------------------------------------------------
sync_pull() {
  local force=""
  case "${1:-}" in
    --auto)  _sync_pull_auto; return 0 ;;
    --force) force="--force" ;;
    "")      ;;
    *)       die "Unknown option: $1 (usage: claude-kitsync pull [--force])" ;;
  esac

  require_git_repo
  _sync_lock 30 || die "Another kitsync sync is running on this machine — try again in a moment."
  _sync_prepare_repo

  if ! _has_remote; then
    log_warn "No remote configured — skipping pull."
    return 0
  fi

  # Clear any pending conflict notification — user is handling it explicitly
  rm -f "$CLAUDE_HOME/.kitsync/conflict_pending" 2>/dev/null || true

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

  # Pre-fetch so we can warn about local commits that -X ours will override
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
          log_warn "Remote version will be kept on conflicting hunks. Your local changes to these hunks will be overwritten."
          printf "\n"
        fi
      fi
    fi
  fi

  # Save SHA before pull for selective pull restore
  local _pre_pull_sha
  _pre_pull_sha="$(git -C "$CLAUDE_HOME" rev-parse HEAD 2>/dev/null || true)"

  # Step 2: rebase pull with autostash; -X ours = remote wins (rebase swaps sides)
  local _pull_out
  if _pull_out="$(git -C "$CLAUDE_HOME" pull --rebase --autostash --allow-unrelated-histories -X ours 2>&1)"; then
    log_success "Pull complete."

    _sync_after_pull "$_pre_pull_sha"
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
# _sync_after_pull <pre_sha> [quiet] — selective pull, decryption and paths,
# shared by pull and pull --auto
# ---------------------------------------------------------------------------
_sync_after_pull() {
  local pre="$1" quiet="${2:-}" items cat path f kept
  items="$(_sync_get_pull_items)"
  if [[ -n "$pre" ]]; then
    for cat in "${SYNC_USER_CATEGORIES[@]}"; do
      _sync_item_in_list "$cat" "$items" && continue
      path="$(_sync_category_to_path "$cat")"
      # File by file: only what the pull changed goes back to its pre-pull
      # version — a local edit the pull didn't touch is never overwritten
      kept=false
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        git -C "$CLAUDE_HOME" cat-file -e "$pre:$f" 2>/dev/null || continue
        git -C "$CLAUDE_HOME" checkout "$pre" -- "$f" 2>/dev/null || true
        git -C "$CLAUDE_HOME" reset -q HEAD -- "$f" 2>/dev/null || true
        kept=true
      done < <(git -C "$CLAUDE_HOME" diff --name-only "$pre" HEAD -- "$path" 2>/dev/null)
      [[ "$kept" == true && -z "$quiet" ]] && log_info "Selective pull: kept local ${cat} (not in pull selection)"
    done
  fi
  crypto_decrypt_all 2>/dev/null || true
  normalize_paths 2>/dev/null || true
  paths_detokenize 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _sync_pull_auto — background pull run by the claude() wrapper. Never asks,
# never prints, never touches local changes:
#   - skips when busy (lock), dirty (uncommitted edits stay as they are —
#     no autostash, which leaves conflict markers in files) or mid-rebase
#   - only the download has a timeout; the local rebase is never interrupted
#   - same rules as pull: remote wins, selective pull, decryption, paths
#   - a real conflict is recorded in .kitsync/conflict_pending; new commits
#     leave .kitsync/pending-notice for the next launch
# ---------------------------------------------------------------------------
_sync_pull_auto() {
  [[ -d "$CLAUDE_HOME/.git" ]] && _has_remote || return 0
  _sync_lock 0 || return 0
  local gd
  gd="$(git -C "$CLAUDE_HOME" rev-parse --absolute-git-dir 2>/dev/null)"
  [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" || -f "$gd/MERGE_HEAD" ]] && return 0

  local branch pre
  branch="$(git -C "$CLAUDE_HOME" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  KITSYNC_NET_TIMEOUT="${KITSYNC_TIMEOUT:-10}" _git_net fetch -q origin "$branch" &>/dev/null || return 0
  git -C "$CLAUDE_HOME" rev-parse --verify -q "origin/$branch" >/dev/null || return 0
  git -C "$CLAUDE_HOME" rev-parse --abbrev-ref '@{u}' &>/dev/null || \
    git -C "$CLAUDE_HOME" branch -q --set-upstream-to="origin/$branch" "$branch" 2>/dev/null || true

  _sync_prepare_repo
  pre="$(git -C "$CLAUDE_HOME" rev-parse HEAD 2>/dev/null || true)"

  # Local edits not pushed yet (files excluded from push, a session still
  # running…): skip only if the remote changed one of the same files. Other
  # edits are set aside and put back — the remote didn't touch them, so they
  # can't conflict (a blanket skip would block pulls forever).
  local dirty overlap stash=""
  dirty="$(git -C "$CLAUDE_HOME" diff --name-only HEAD 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    overlap="$(comm -12 <(sort <<< "$dirty") \
      <(git -C "$CLAUDE_HOME" diff --name-only HEAD "origin/$branch" 2>/dev/null | sort))"
    [[ -z "$overlap" ]] || return 0
    stash="--autostash"
  fi

  # -X ours = remote wins (a rebase swaps sides)
  if git -C "$CLAUDE_HOME" rebase -q -X ours ${stash:+"$stash"} "origin/$branch" &>/dev/null; then
    rm -f "$CLAUDE_HOME/.kitsync/conflict_pending" 2>/dev/null || true
    if [[ "$pre" != "$(git -C "$CLAUDE_HOME" rev-parse HEAD 2>/dev/null)" ]]; then
      _sync_after_pull "$pre" quiet
      printf 'updated\n' > "$CLAUDE_HOME/.kitsync/pending-notice" 2>/dev/null || true
    fi
    return 0
  fi

  local files
  files="$(git -C "$CLAUDE_HOME" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
  git -C "$CLAUDE_HOME" rebase --abort 2>/dev/null || true   # our own rebase (lock held)
  if [[ -n "$files" ]]; then
    printf 'files:%s\n' "$files" > "$CLAUDE_HOME/.kitsync/conflict_pending" 2>/dev/null || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _sync_stage — encrypt (when enabled), refresh the template, and stage the
# allowlist filtered by the push selection — deletions included
# ---------------------------------------------------------------------------
_sync_stage() {
  if _crypto_is_enabled 2>/dev/null; then
    crypto_encrypt_all >/dev/null 2>&1 || true
  fi

  # Keep settings.template.json in sync with settings.json (plaintext only —
  # under encryption the template is ignored and untracked).
  local items
  items="$(_sync_get_push_items)"
  if ! _crypto_is_enabled 2>/dev/null && \
     [[ -f "$CLAUDE_HOME/settings.template.json" ]] && [[ -f "$CLAUDE_HOME/settings.json" ]] && \
     _sync_item_in_list "settings.json" "$items"; then
    paths_tokenize_stream < "$CLAUDE_HOME/settings.json" > "$CLAUDE_HOME/settings.template.json" 2>/dev/null || true
  fi

  local item
  for item in "${SYNC_WHITELIST[@]}"; do
    # Infrastructure items always staged; user categories filtered by config
    if ! _sync_is_infra "$item"; then
      _sync_item_in_list "${item%/}" "$items" || continue
    fi
    # Under encryption the plaintext is ignored: stage its .enc instead
    if _crypto_is_enabled 2>/dev/null && [[ -f "$CLAUDE_HOME/${item}.enc" ]]; then
      git -C "$CLAUDE_HOME" add -A -- "${item}.enc" 2>/dev/null || true
      continue
    fi
    # -A: a deleted file or folder is pushed as a deletion too (git errors
    # harmlessly on a path that neither exists nor is tracked)
    git -C "$CLAUDE_HOME" add -A -- "$item" 2>/dev/null || true
  done

  # Re-run the path-token clean filter even if git's stat cache thinks
  # settings.json is unchanged (first push after the filter was configured)
  if ! _crypto_is_enabled 2>/dev/null && _sync_item_in_list "settings.json" "$items" && \
     [[ -f "$CLAUDE_HOME/settings.json" ]]; then
    git -C "$CLAUDE_HOME" add --renormalize -- settings.json 2>/dev/null || true
  fi

  # Final safety: verify .credentials.json not staged after add (--name-only = one filename per line)
  if git -C "$CLAUDE_HOME" diff --cached --name-only 2>/dev/null | grep -q "^\.credentials\.json$"; then
    log_error "CRITICAL: .credentials.json ended up staged — aborting commit!"
    git -C "$CLAUDE_HOME" reset HEAD ".credentials.json" 2>/dev/null || true
    exit 1
  fi
}

# _sync_dry_run — what push would commit, without changing anything
_sync_dry_run() {
  log_step "Dry run — showing what would be committed"; printf "\n" >&2
  local gd idx bak f
  gd="$(git -C "$CLAUDE_HOME" rev-parse --absolute-git-dir)"
  idx="$(mktemp)"; bak="$(mktemp -d)"
  cp "$gd/index" "$idx" 2>/dev/null || true
  for f in settings.json.enc settings.template.json; do
    [[ -f "$CLAUDE_HOME/$f" ]] && cp -p "$CLAUDE_HOME/$f" "$bak/$f"
  done

  export GIT_INDEX_FILE="$idx"
  _sync_stage
  _sync_unstage_unsafe dry
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
  fi
  unset GIT_INDEX_FILE
  if [[ -n "$_SYNC_LEFT_OUT" ]]; then
    printf "\n" >&2
    log_warn "Would be left out:"
    printf '%s' "$_SYNC_LEFT_OUT" | while IFS= read -r f; do [[ -n "$f" ]] && log_warn "  $f"; done
  fi

  # Put derived files back exactly as they were
  for f in settings.json.enc settings.template.json; do
    if [[ -f "$bak/$f" ]]; then
      cp -p "$bak/$f" "$CLAUDE_HOME/$f"
    else
      rm -f "$CLAUDE_HOME/$f"
    fi
  done
  rm -f "$idx" "$bak/settings.json.enc" "$bak/settings.template.json"
  rmdir "$bak" 2>/dev/null || true

  printf "\n" >&2
  local url profile
  url="$(git -C "$CLAUDE_HOME" remote get-url origin 2>/dev/null || echo 'no remote')"
  profile="$(_profile_get_active 2>/dev/null || true)"
  log_info "Would push to:  $url${profile:+  (profile: $profile)}"
  printf "\n"
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

  # Background pushes wait for a running pull; a human gets a clear message
  if ! _sync_lock "$([[ "$_auto" == true ]] && echo 120 || echo 30)"; then
    [[ "$_auto" == true ]] && return 0
    die "Another kitsync sync is running on this machine — try again in a moment."
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

  # Dry run: the real staging, on a throwaway copy of the index; derived files
  # it writes (settings.json.enc, settings.template.json) are put back after
  if [[ "$_dry_run" == true ]]; then
    _sync_dry_run
    return 0
  fi

  # Filter/gitignore maintenance — after the dry-run exit so a preview never mutates the repo
  _sync_prepare_repo
  _plog_step "Staging whitelisted files..."
  _sync_stage
  _sync_unstage_unsafe

  # Check if there is anything to commit — local commits not yet pushed
  # (earlier failed push, path-token migration) still need to go out
  if git -C "$CLAUDE_HOME" diff --cached --quiet 2>/dev/null; then
    local _unpushed
    _unpushed="$(git -C "$CLAUDE_HOME" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 1)"
    if [[ "$_unpushed" == "0" ]]; then
      _plog_info "Nothing to commit — working tree clean."
      return 0
    fi
  else
    _plog_step "Committing: $commit_msg"
    local _commit_out
    if _commit_out="$(git -C "$CLAUDE_HOME" commit -m "$commit_msg" 2>&1)"; then
      [[ "$_auto" == false ]] && \
        printf "%s\n" "$_commit_out" | grep -Ev "^[[:space:]]+(create|delete) mode " || true
    else
      printf "%s\n" "$_commit_out" >&2
      exit 1
    fi
  fi

  _plog_step "Pushing to remote..."
  local _branch
  _branch="$(git -C "$CLAUDE_HOME" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  if ! git -C "$CLAUDE_HOME" push -q -u origin "$_branch" 2>/dev/null; then
    # Usually the remote moved on (another machine pushed): replay the local
    # commits on top and retry. No -X strategy: a local commit never silently
    # loses hunks here; a real conflict is left for `claude-kitsync pull`.
    if _git_net fetch -q origin "$_branch" &>/dev/null && \
       git -C "$CLAUDE_HOME" rebase -q "origin/$_branch" &>/dev/null && \
       git -C "$CLAUDE_HOME" push -q -u origin "$_branch" 2>/dev/null; then
      :
    else
      local _cf
      _cf="$(git -C "$CLAUDE_HOME" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
      git -C "$CLAUDE_HOME" rebase --abort 2>/dev/null || true
      if [[ -n "$_cf" ]]; then
        printf 'files:%s\n' "$_cf" > "$CLAUDE_HOME/.kitsync/conflict_pending" 2>/dev/null || true
        log_warn "Push failed — your changes conflict with the remote's ($_cf). Your commit is kept locally; resolve with: claude-kitsync pull"
      else
        log_warn "Push failed — your commit is kept locally. Run 'claude-kitsync push' to retry (or 'claude-kitsync doctor')."
      fi
      return 1
    fi
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
  log_info "Sync history — $CLAUDE_HOME"; printf "\n" >&2

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
  log_info "Diff — $CLAUDE_HOME  (branch: $_branch)"; printf "\n" >&2

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
  local _status_profile
  _status_profile="$(_profile_get_active 2>/dev/null || true)"
  if [[ -n "$_status_profile" ]]; then
    log_info "Profile:    $_status_profile"
  fi
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
