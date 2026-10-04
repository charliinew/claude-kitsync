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
    # 1.2.5: never synced, even inside synced folders
    "node_modules/" ".venv/" "venv/" "__pycache__/" "*.pyc" ".env" ".env.*" "!.env.example" "*.pem" "*.key" "*.p12" "*.pfx" "id_rsa*" "id_ed25519*" "*.log"
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
  # Dependencies, caches, secrets and logs committed before 1.2.5: untrack them
  # (they stay on disk) — the same files would be refused from now on anyway
  local leaked
  leaked="$(git -C "$CLAUDE_HOME" ls-files -ci --exclude-standard -- \
    '*node_modules/*' '*.venv/*' '*venv/*' '*__pycache__/*' '*.pyc' '*.env' '*.env.*' \
    '*.pem' '*.key' '*.p12' '*.pfx' '*id_rsa*' '*id_ed25519*' '*.log' 2>/dev/null || true)"
  if [[ -n "$leaked" ]]; then
    printf '%s\n' "$leaked" | while IFS= read -r _f; do
      git -C "$CLAUDE_HOME" rm --cached -q -- "$_f" 2>/dev/null || true
    done
    log_warn "Stopped syncing (kept on disk): $(printf '%s' "$leaked" | head -5 | tr '\n' ' ')$([[ $(grep -c . <<< "$leaked") -gt 5 ]] && echo "…")"
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
  # Encryption key copied after a mismatch: catch settings.json up
  crypto_recover_key 2>/dev/null || true
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

# _git_raw <git args...> — git on ~/.claude with the path-token filter off.
# Only to get a rebase past content committed before the filter existed,
# which otherwise looks modified forever and stops it. Real paths are
# restored by paths_detokenize afterwards.
_git_raw() {
  git -C "$CLAUDE_HOME" -c "filter.${KITSYNC_PATH_FILTER}.clean=cat" \
    -c "filter.${KITSYNC_PATH_FILTER}.smudge=cat" "$@"
}

# _sync_record_conflict <files,comma,separated> — notice shown at the next session
_sync_record_conflict() {
  mkdir -p "$CLAUDE_HOME/.kitsync" 2>/dev/null || true
  printf 'files:%s\n' "$1" > "$CLAUDE_HOME/.kitsync/conflict_pending" 2>/dev/null || true
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
# Categories this machine doesn't pull are a local version on purpose: never
# overwritten by a pull, never pushed (that would revert the other machines),
# and never in the way of the rest of the sync.
# ---------------------------------------------------------------------------

# _sync_pull_excluded_paths — allowlist paths of the categories not pulled
_sync_pull_excluded_paths() {
  local items cat
  items="$(_sync_get_pull_items)"
  for cat in "${SYNC_USER_CATEGORIES[@]}"; do
    _sync_item_in_list "$cat" "$items" && continue
    _sync_category_to_path "$cat" | sed 's:/$::'
    printf '\n'
    # Under encryption the remote holds settings.json as settings.json.enc
    [[ "$cat" == settings.json ]] && printf 'settings.json.enc\n'
  done
  return 0
}

# _sync_hold_local — move this machine's version of the non-pulled paths out
# of the way (into .git/, never synced) and put HEAD's in place, so a rebase
# neither overwrites nor trips over them. A hold left by an interrupted run is
# released first.
_SYNC_HOLD=""
_sync_hold_local() {
  local gd p
  gd="$(git -C "$CLAUDE_HOME" rev-parse --absolute-git-dir)"
  _SYNC_HOLD="$gd/kitsync-hold"
  [[ -d "$_SYNC_HOLD" ]] && _sync_release_local
  _SYNC_HOLD="$gd/kitsync-hold"
  mkdir -p "$_SYNC_HOLD"
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != *..* ]] || continue
    if [[ -e "$CLAUDE_HOME/$p" ]]; then
      mkdir -p "$(dirname "$_SYNC_HOLD/$p")"
      mv "$CLAUDE_HOME/$p" "$_SYNC_HOLD/$p"
    fi
    git -C "$CLAUDE_HOME" checkout HEAD -- "$p" 2>/dev/null || true
  done < <(_sync_pull_excluded_paths)
}

# _sync_release_local — put the held local version back (whatever the
# pull brought for those paths is left in git only)
_sync_release_local() {
  [[ -n "$_SYNC_HOLD" && -d "$_SYNC_HOLD" ]] || return 0
  local p
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != *..* ]] || continue
    rm -rf "${CLAUDE_HOME:?}/$p"
    if [[ -e "$_SYNC_HOLD/$p" ]]; then
      mkdir -p "$(dirname "$CLAUDE_HOME/$p")"
      mv "$_SYNC_HOLD/$p" "$CLAUDE_HOME/$p"
    fi
  done < <(_sync_pull_excluded_paths)
  rm -rf "$_SYNC_HOLD"
  _SYNC_HOLD=""
}

# _sync_dirty_overlap <branch> — uncommitted local edits to files the remote
# changed (those can't be set aside and put back without a conflict)
_sync_dirty_overlap() {
  local dirty
  # Uncommitted edits, and new files not yet pushed (the remote may add the
  # same path: git would refuse to overwrite it)
  dirty="$(git -C "$CLAUDE_HOME" diff --name-only HEAD 2>/dev/null || true)
$(git -C "$CLAUDE_HOME" ls-files --others --exclude-standard 2>/dev/null || true)"
  dirty="$(grep -v '^$' <<< "$dirty" || true)"
  [[ -n "$dirty" ]] || return 0
  # What the REMOTE changed since the common ancestor — not the local
  # commits that HEAD..origin would also list
  local base
  base="$(git -C "$CLAUDE_HOME" merge-base HEAD "origin/$1" 2>/dev/null || echo HEAD)"
  comm -12 <(sort <<< "$dirty") \
    <(git -C "$CLAUDE_HOME" diff --name-only "$base" "origin/$1" 2>/dev/null | sort)
}

# _pull_backup <file> <source> — keep a local version before the remote's
# replaces it: <source> is "worktree" or a git object spec (e.g. :3:file)
_PULL_BACKUP_DIR=""
_pull_backup() {
  local f="$1" src="$2" dest
  if [[ -z "$_PULL_BACKUP_DIR" ]]; then
    _PULL_BACKUP_DIR="$CLAUDE_HOME/.kitsync/backups/pull-$(date '+%Y%m%dT%H%M%S')"
  fi
  dest="$_PULL_BACKUP_DIR/$f"
  mkdir -p "$(dirname "$dest")"
  if [[ "$src" == worktree ]]; then
    [[ -f "$CLAUDE_HOME/$f" ]] && cp -p "$CLAUDE_HOME/$f" "$dest"
  else
    # --filters: the version as it would be on disk (path tokens expanded)
    git -C "$CLAUDE_HOME" cat-file --filters "$src" > "$dest" 2>/dev/null || rm -f "$dest"
  fi
  return 0
}

# _pull_take <stage> <file> — resolve a conflicted file with one side
# (2 = remote, 3 = local during a rebase); a side without the file deletes it
_pull_take() {
  if git -C "$CLAUDE_HOME" cat-file -e ":$1:$2" 2>/dev/null; then
    git -C "$CLAUDE_HOME" checkout "--$([[ $1 == 2 ]] && echo ours || echo theirs)" -- "$2" 2>/dev/null
    git -C "$CLAUDE_HOME" add -- "$2" 2>/dev/null
  else
    git -C "$CLAUDE_HOME" rm -q -- "$2" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# _pull_resolve <force> — settle a stopped rebase file by file.
#   R (remote): the local version is backed up first
#   L (local):  kept, and pushed once the pull is done
# --force takes the remote for every file. Without a terminal (and without
# --force) nothing is decided: returns 1 so the caller aborts and records it.
# ---------------------------------------------------------------------------
_PULL_KEPT_LOCAL=""
_pull_resolve() {
  local force="$1" gd files f choice
  gd="$(git -C "$CLAUDE_HOME" rev-parse --absolute-git-dir)"
  [[ "$force" == --force ]] || _has_tty || return 1
  local rounds=0
  while [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" ]]; do
    (( ++rounds <= 100 )) || return 1
    files="$(git -C "$CLAUDE_HOME" diff --name-only --diff-filter=U 2>/dev/null)"
    if [[ -z "$files" ]]; then
      # Stopped without a conflict: a file only *looks* modified (path-token
      # filter vs. content committed before it existed). Real local edits were
      # set aside before the rebase, so discarding the difference is safe.
      [[ -n "$(git -C "$CLAUDE_HOME" diff --name-only 2>/dev/null)" ]] || return 1
      _git_raw checkout -- . 2>/dev/null || return 1
      GIT_EDITOR=true _git_raw rebase --continue &>/dev/null || true
      continue
    fi
    while IFS= read -r f; do
      if [[ "$force" == --force ]]; then
        choice=R
      else
        printf "\n" >&2
        log_warn "Conflict: $f"
        diff -u --label "remote: $f" --label "local: $f" \
          <(git -C "$CLAUDE_HOME" cat-file --filters ":2:$f" 2>/dev/null) \
          <(git -C "$CLAUDE_HOME" cat-file --filters ":3:$f" 2>/dev/null) | head -40 >&2 || true
        while true; do
          # tr, not ${x^^}: macOS ships bash 3.2
          choice="$(_init_read_choice | tr '[:lower:]' '[:upper:]')"
          case "$choice" in R|L) break ;; *) printf "  Please enter R or L\n" >/dev/tty ;; esac
        done
      fi
      if [[ "$choice" == R ]]; then
        _pull_backup "$f" ":3:$f"
        _pull_take 2 "$f"
        log_info "  → Remote: $f  (local copy: $_PULL_BACKUP_DIR/$f)"
      else
        _pull_take 3 "$f"
        _PULL_KEPT_LOCAL+="$f "
        log_info "  → Local:  $f"
      fi
    done <<< "$files"
    # A commit left with nothing of its own (all remote) is dropped
    if git -C "$CLAUDE_HOME" diff --cached --quiet 2>/dev/null; then
      GIT_EDITOR=true git -C "$CLAUDE_HOME" rebase --skip &>/dev/null || true
    else
      GIT_EDITOR=true git -C "$CLAUDE_HOME" rebase --continue &>/dev/null || true
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# sync_pull [--force] — pull, asking about real conflicts
#
#   - local commits are replayed on top of the remote; changes to different
#     lines merge by themselves
#   - a conflict is resolved file by file (remote or local); a remote choice
#     backs up the local version, a local choice is pushed right away
#   - uncommitted edits to files the remote changed stop the pull (push them
#     first) unless --force, which takes the remote everywhere, backed up
#   - without a terminal nothing is decided: the conflict is recorded
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

  local branch err
  branch="$(git -C "$CLAUDE_HOME" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  log_step "Pulling from remote..."
  if ! err="$(_git_net fetch -q origin "$branch" 2>&1)"; then
    log_warn "Could not reach the remote:"
    printf '%s\n' "$err" | head -3 | sed 's/^/    /' >&2
    return 1
  fi
  if ! git -C "$CLAUDE_HOME" rev-parse --verify -q "origin/$branch" >/dev/null; then
    log_info "Remote is empty — nothing to pull."
    return 0
  fi
  git -C "$CLAUDE_HOME" rev-parse --abbrev-ref '@{u}' &>/dev/null || \
    git -C "$CLAUDE_HOME" branch -q --set-upstream-to="origin/$branch" "$branch" 2>/dev/null || true

  _PULL_BACKUP_DIR=""
  _PULL_KEPT_LOCAL=""
  _sync_hold_local

  # Uncommitted edits to files the remote also changed
  local overlap f
  overlap="$(_sync_dirty_overlap "$branch")"
  if [[ -n "$overlap" ]]; then
    if [[ "$force" == --force ]]; then
      while IFS= read -r f; do
        _pull_backup "$f" worktree
        git -C "$CLAUDE_HOME" checkout HEAD -- "$f" 2>/dev/null || rm -f "$CLAUDE_HOME/$f"
      done <<< "$overlap"
      log_info "Your uncommitted edits to $(tr '\n' ' ' <<< "$overlap")were set aside in $_PULL_BACKUP_DIR"
    else
      log_warn "You have uncommitted edits to files that also changed on the remote:"
      while IFS= read -r f; do log_warn "  • $f"; done <<< "$overlap"
      log_info "Push them first (claude-kitsync push), then pull to resolve file by file"
      log_info "(new files and categories you don't push included) —"
      log_info "or take the remote version: claude-kitsync pull --force (your edits are backed up)."
      _sync_release_local
      return 1
    fi
  fi

  local pre stash=""
  pre="$(git -C "$CLAUDE_HOME" rev-parse HEAD 2>/dev/null || true)"
  [[ -z "$(git -C "$CLAUDE_HOME" diff --name-only HEAD 2>/dev/null)" ]] || stash="--autostash"

  if ! git -C "$CLAUDE_HOME" rebase -q ${stash:+"$stash"} "origin/$branch" &>/dev/null; then
    local conflicts
    conflicts="$(git -C "$CLAUDE_HOME" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    if ! _pull_resolve "$force"; then
      git -C "$CLAUDE_HOME" rebase --abort 2>/dev/null || true
      if [[ -n "$conflicts" ]]; then
        _sync_record_conflict "$conflicts"
        log_warn "Conflict in: $conflicts — nothing was changed."
        log_info "Run 'claude-kitsync pull' in a terminal to choose file by file, or"
        log_info "'claude-kitsync pull --force' to take the remote (local versions are backed up)."
      else
        log_warn "Pull failed — nothing was changed. Check: git -C \"$CLAUDE_HOME\" status"
      fi
      _sync_release_local
      return 1
    fi
  fi

  _sync_release_local
  rm -f "$CLAUDE_HOME/.kitsync/conflict_pending" 2>/dev/null || true
  if [[ "$pre" == "$(git -C "$CLAUDE_HOME" rev-parse HEAD 2>/dev/null)" ]]; then
    log_success "Already up to date."
  else
    log_success "Pull complete."
    _sync_after_pull
  fi
  [[ -n "$_PULL_BACKUP_DIR" ]] && log_info "Local versions replaced by the remote are kept in: $_PULL_BACKUP_DIR"

  # Versions kept on purpose go out now, or the next pull would ask again
  if [[ -n "$_PULL_KEPT_LOCAL" ]]; then
    log_step "Pushing the local versions you kept..."
    sync_push "kitsync: keep local version of ${_PULL_KEPT_LOCAL% }"
  fi
}

# ---------------------------------------------------------------------------
# _sync_after_pull <pre_sha> [quiet] — selective pull, decryption and paths,
# shared by pull and pull --auto
# ---------------------------------------------------------------------------
_sync_after_pull() {
  # Non-pulled categories were held aside during the rebase; under
  # encryption settings.json is not decrypted over this machine's version
  if _sync_item_in_list "settings.json" "$(_sync_get_pull_items)"; then
    crypto_decrypt_all 2>/dev/null || true
  fi
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
  _sync_hold_local
  local overlap stash=""
  overlap="$(_sync_dirty_overlap "$branch")"
  if [[ -n "$overlap" ]]; then
    # Not silently skipped forever: reported at the next session
    _sync_release_local
    _sync_record_conflict "$(tr '\n' ',' <<< "$overlap" | sed 's/,$//')"
    return 0
  fi
  [[ -z "$(git -C "$CLAUDE_HOME" diff --name-only HEAD 2>/dev/null)" ]] || stash="--autostash"

  # Plain rebase: changes to different lines merge; a real conflict (also with
  # a local commit that failed to push) is left for the user, never settled
  # by dropping one side
  if git -C "$CLAUDE_HOME" rebase -q ${stash:+"$stash"} "origin/$branch" &>/dev/null; then
    _sync_release_local
    rm -f "$CLAUDE_HOME/.kitsync/conflict_pending" 2>/dev/null || true
    if [[ "$pre" != "$(git -C "$CLAUDE_HOME" rev-parse HEAD 2>/dev/null)" ]]; then
      _sync_after_pull
      printf 'updated\n' > "$CLAUDE_HOME/.kitsync/pending-notice" 2>/dev/null || true
    fi
    return 0
  fi

  local files
  files="$(git -C "$CLAUDE_HOME" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
  git -C "$CLAUDE_HOME" rebase --abort 2>/dev/null || true   # our own rebase (lock held)
  _sync_release_local
  if [[ -n "$files" ]]; then
    _sync_record_conflict "$files"
  fi
  return 0
}

# _sync_push_effective — push categories minus the ones this machine doesn't
# pull: it never sees the others' changes there, so pushing would revert them
_sync_push_effective() {
  local push pull out="" cat
  push="$(_sync_get_push_items)"; pull="$(_sync_get_pull_items)"
  for cat in "${SYNC_USER_CATEGORIES[@]}"; do
    _sync_item_in_list "$cat" "$push" && _sync_item_in_list "$cat" "$pull" && out+="${out:+,}$cat"
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# _sync_stage — encrypt (when enabled), refresh the template, and stage the
# allowlist filtered by the push selection — deletions included
# ---------------------------------------------------------------------------
_sync_stage() {
  local items
  items="$(_sync_push_effective)"
  if _crypto_is_enabled 2>/dev/null && _sync_item_in_list "settings.json" "$items"; then
    crypto_encrypt_all >/dev/null 2>&1 || true
  fi

  # Keep settings.template.json in sync with settings.json (plaintext only —
  # under encryption the template is ignored and untracked).
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

# _sync_preview — what push would commit right now, without changing anything:
# the real staging on a throwaway index; derived files it writes
# (settings.json.enc, settings.template.json) are put back byte for byte.
# Sets _SYNC_PREVIEW ("<status>\t<path>" lines) and _SYNC_LEFT_OUT.
_SYNC_PREVIEW=""
_sync_preview() {
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
  _SYNC_PREVIEW="$(git -C "$CLAUDE_HOME" diff --cached --name-status 2>/dev/null || true)"
  unset GIT_INDEX_FILE

  for f in settings.json.enc settings.template.json; do
    if [[ -f "$bak/$f" ]]; then
      cp -p "$bak/$f" "$CLAUDE_HOME/$f"
    else
      rm -f "$CLAUDE_HOME/$f"
    fi
  done
  rm -f "$idx" "$bak/settings.json.enc" "$bak/settings.template.json"
  rmdir "$bak" 2>/dev/null || true
}

# _sync_print_preview [indent] — _SYNC_PREVIEW as "modified: path" lines
_sync_print_preview() {
  local pad="${1:-  }" st file
  while IFS=$'\t' read -r st file; do
    [[ -n "$st" ]] || continue
    case "$st" in
      M) printf '%smodified:  %s\n' "$pad" "$file" ;;
      A) printf '%snew file:  %s\n' "$pad" "$file" ;;
      D) printf '%sdeleted:   %s\n' "$pad" "$file" ;;
      *) printf '%s%-10s %s\n' "$pad" "$st" "$file" ;;
    esac
  done <<< "$_SYNC_PREVIEW" >&2
}

# _sync_dry_run — what push would commit, without changing anything
_sync_dry_run() {
  log_step "Dry run — showing what would be committed"; printf "\n" >&2
  _sync_preview
  if [[ -z "$_SYNC_PREVIEW" ]]; then
    log_info "Nothing to commit — working tree clean for synced files."
  else
    _sync_print_preview "[kitsync]    "
  fi
  if [[ -n "$_SYNC_LEFT_OUT" ]]; then
    printf "\n" >&2
    log_warn "Would be left out:"
    printf '%s' "$_SYNC_LEFT_OUT" | while IFS= read -r f; do [[ -n "$f" ]] && log_warn "  $f"; done
  fi
  printf "\n" >&2
  local url profile
  url="$(git -C "$CLAUDE_HOME" remote get-url origin 2>/dev/null || echo 'no remote')"
  profile="$(_profile_get_active 2>/dev/null || true)"
  log_info "Would push to:  $url${profile:+  (profile: $profile)}"
  printf "\n"
}

# _sync_commit_msg <kind> — default commit message, with the machine's name
# so `log` tells which machine sent what
_sync_commit_msg() {
  local name
  name="$(_cfg_get KITSYNC_MACHINE_NAME)"
  [[ -n "$name" ]] || name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  printf 'kitsync: %s %s (%s)' "$1" "$(date '+%Y-%m-%d %H:%M')" "$name"
}

# _sync_fetch_quiet — refresh origin/<branch> for a read-only command; 1 if unreachable
_sync_fetch_quiet() {
  _has_remote || return 1
  KITSYNC_NET_TIMEOUT="${KITSYNC_TIMEOUT:-10}" _git_net fetch -q origin &>/dev/null
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
  [[ -n "$commit_msg" ]] || commit_msg="$(_sync_commit_msg sync)"

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
    local _rb=1 _stash=""
    if _git_net fetch -q origin "$_branch" &>/dev/null; then
      _sync_hold_local
      if [[ -z "$(_sync_dirty_overlap "$_branch")" ]]; then
        [[ -z "$(git -C "$CLAUDE_HOME" diff --name-only HEAD 2>/dev/null)" ]] || _stash="--autostash"
        git -C "$CLAUDE_HOME" rebase -q ${_stash:+"$_stash"} "origin/$_branch" &>/dev/null && _rb=0
      fi
      [[ $_rb -eq 0 ]] && _sync_release_local
    fi
    if [[ $_rb -eq 0 ]] && git -C "$CLAUDE_HOME" push -q -u origin "$_branch" 2>/dev/null; then
      _sync_after_pull   # decrypt + real paths for what came in
    else
      local _cf
      _cf="$(git -C "$CLAUDE_HOME" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
      git -C "$CLAUDE_HOME" rebase --abort 2>/dev/null || true
      _sync_release_local
      if [[ -n "$_cf" ]]; then
        _sync_record_conflict "$_cf"
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
  local count=15
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--count) count="${2:-}"; shift 2 || shift ;;
      -n*)        count="${1#-n}"; shift ;;
      *)          count="$1"; shift ;;
    esac
  done
  [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )) || die "Usage: claude-kitsync log [-n <count>]"

  printf "\n" >&2
  log_info "Sync history — $CLAUDE_HOME"; printf "\n" >&2

  if ! git -C "$CLAUDE_HOME" log -1 --oneline &>/dev/null; then
    log_warn "No commits yet."
    return 0
  fi

  # Each sync with the files it carried (5 at most)
  git -C "$CLAUDE_HOME" --no-pager log -n "$count" --color=always \
    --pretty=format:"%C(yellow)%h%Creset  %C(cyan)%ad%Creset  %s" \
    --date=format:'%Y-%m-%d %H:%M' --name-status 2>/dev/null | awk '
      /^\x1b|^[0-9a-f]+  / { if (n > 5) printf "      … %d more\n", n - 5; n = 0; print; next }
      /^$/ { next }
      { n++; if (n <= 5) printf "      %s\n", $0 }
      END { if (n > 5) printf "      … %d more\n", n - 5 }'
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

  _sync_preview
  if [[ "$_ahead" -eq 0 ]] && [[ "$_behind" -eq 0 ]] && [[ -z "$_SYNC_PREVIEW" ]]; then
    log_success "Up to date with remote — nothing to diff."
    printf "\n"
    return 0
  fi

  printf "  %s ahead · %s behind\n\n" "$_ahead" "$_behind"

  if [[ -n "$_SYNC_PREVIEW" ]]; then
    printf "%s  ↑ Not committed yet (sent by the next push):%s\n" "$_CLR_YELLOW" "$_CLR_RESET"
    _sync_print_preview "    "
    printf "\n"
  fi

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

  # The full diff is an interactive extra: never dumped into a pipe or a log
  _has_tty || return 0
  local choice
  choice=$(_select_menu "View full diff?" \
    "Incoming diff  (remote → local)" \
    "Outgoing diff  (local → remote, committed and not yet committed)" \
    "Exit")

  case "$choice" in
    1) git -C "$CLAUDE_HOME" diff --color=always "HEAD...$_remote" 2>/dev/null | "${PAGER:-less}" -R ;;
    2) git -C "$CLAUDE_HOME" diff --color=always "$_remote" 2>/dev/null | "${PAGER:-less}" -R ;;
    3) true ;;
  esac
}

# ---------------------------------------------------------------------------
# sync_status — show short git status of $CLAUDE_HOME
# ---------------------------------------------------------------------------
sync_status() {
  require_git_repo
  local branch profile
  branch="$(git -C "$CLAUDE_HOME" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
  profile="$(_profile_get_active 2>/dev/null || true)"

  printf "\n" >&2
  log_info "Repository: $CLAUDE_HOME  (branch: $branch${profile:+, profile: $profile})"

  local reachable=true
  _sync_fetch_quiet || reachable=false
  printf "\n" >&2

  # Notices left by background syncs
  local f="$CLAUDE_HOME/.kitsync"
  [[ -f "$f/conflict_pending" ]] && \
    log_warn "Sync conflict pending: $(grep '^files:' "$f/conflict_pending" | cut -d: -f2-) — run: claude-kitsync pull"
  [[ -f "$f/sync-warning" ]] && log_warn "$(cat "$f/sync-warning")"

  # What the next push sends
  _sync_preview
  if [[ -n "$_SYNC_PREVIEW" ]]; then
    log_info "Next push sends (at the end of your session, or now: claude-kitsync push):"
    _sync_print_preview "    "
  fi
  if [[ -n "$_SYNC_LEFT_OUT" ]]; then
    log_warn "Left out of the next push:"
    printf '%s' "$_SYNC_LEFT_OUT" | sed 's/^/    /' >&2
  fi

  # Changed here but never sent (categories this machine doesn't push or pull)
  local staged local_only
  staged="$(cut -f2- <<< "$_SYNC_PREVIEW")"
  local_only="$(git -C "$CLAUDE_HOME" diff --name-only HEAD 2>/dev/null | grep -vxF -f <(printf '%s\n' "$staged" ; printf '%s' "$_SYNC_LEFT_OUT" | sed 's/ (.*//') || true)"
  if [[ -n "$local_only" ]]; then
    log_info "Local only (categories not synced from this machine):"
    printf '%s\n' "$local_only" | sed 's/^/    /' >&2
  fi

  # Commits both ways
  local ahead=0 behind=0
  if git -C "$CLAUDE_HOME" rev-parse --abbrev-ref '@{u}' &>/dev/null; then
    ahead="$(git -C "$CLAUDE_HOME" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    behind="$(git -C "$CLAUDE_HOME" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
  fi
  (( ahead > 0 )) && log_info "$ahead commit(s) not pushed yet"
  if (( behind > 0 )); then
    log_info "$behind commit(s) to pull (next session, or now: claude-kitsync pull):"
    git -C "$CLAUDE_HOME" --no-pager diff --stat=70 'HEAD...@{u}' 2>/dev/null | sed 's/^/    /' >&2
  fi
  [[ "$reachable" == true ]] || log_warn "Remote unreachable — incoming changes not checked."

  if [[ -z "$_SYNC_PREVIEW$_SYNC_LEFT_OUT" ]] && (( ahead == 0 && behind == 0 )) && \
     [[ "$reachable" == true && ! -f "$f/conflict_pending" ]]; then
    log_success "In sync — nothing to push or pull."
  fi
  printf "\n" >&2
}
