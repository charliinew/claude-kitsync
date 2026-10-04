#!/usr/bin/env bash
# lib/doctor.sh — health checks: config repo, sync state, data safety, install
set -euo pipefail

_DOC_ERRORS=0
_DOC_WARNINGS=0

_doc_ok()   { log_success "$1"; }
_doc_warn() { log_warn "$1"; _DOC_WARNINGS=$(( _DOC_WARNINGS + 1 )); }
_doc_err()  { log_error "$1"; _DOC_ERRORS=$(( _DOC_ERRORS + 1 )); }
# _doc_hint <text> — indented follow-up line (fix command, git output)
_doc_hint() { printf '      %s\n' "$1" >&2; }
_doc_section() { printf '\n  %s%s%s\n' "$_CLR_BOLD" "$1" "$_CLR_RESET" >&2; }

# ---------------------------------------------------------------------------
# Config repo
# ---------------------------------------------------------------------------
_doc_check_repo() {
  _doc_section "Config repo"
  if [[ ! -d "$CLAUDE_HOME" ]]; then
    _doc_err "CLAUDE_HOME missing: $CLAUDE_HOME — run: claude-kitsync init"
    return 1
  fi
  if ! git -C "$CLAUDE_HOME" rev-parse --git-dir &>/dev/null; then
    _doc_err "$CLAUDE_HOME is not a git repo — run: claude-kitsync init"
    return 1
  fi
  _doc_ok "$CLAUDE_HOME is a git repository"

  local url
  if ! url="$(git -C "$CLAUDE_HOME" remote get-url origin 2>/dev/null)"; then
    _doc_warn "No remote configured — nothing is synced"
    _doc_hint "git -C \"$CLAUDE_HOME\" remote add origin <url>"
    return 0
  fi
  local out
  if out="$(_git_net ls-remote -q origin HEAD 2>&1)"; then
    _doc_ok "Remote reachable: $url"
  else
    _doc_err "Remote unreachable: $url — automatic pushes are failing"
    [[ -n "$out" ]] && printf '%s\n' "$out" | head -3 | while IFS= read -r l; do _doc_hint "$l"; done
  fi

  local profile purl
  profile="$(_profile_get_active 2>/dev/null || true)"
  if [[ -n "$profile" ]]; then
    purl="$(_profile_get_url "$profile" 2>/dev/null || true)"
    if [[ -z "$purl" ]]; then
      _doc_warn "Active profile '$profile' not found in config"
    elif [[ "$purl" != "$url" ]]; then
      _doc_warn "Profile '$profile' points to $purl but origin is $url"
      _doc_hint "claude-kitsync profile switch $profile"
    else
      _doc_ok "Profile '$profile' matches origin"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Sync state
# ---------------------------------------------------------------------------
_doc_check_sync() {
  _doc_section "Sync"
  local gd
  gd="$(git -C "$CLAUDE_HOME" rev-parse --absolute-git-dir 2>/dev/null)"

  if [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" ]]; then
    _doc_err "A rebase is stuck in progress — every sync is blocked"
    _doc_hint "git -C \"$CLAUDE_HOME\" rebase --abort && claude-kitsync pull"
  elif [[ -f "$gd/MERGE_HEAD" ]]; then
    _doc_err "A merge is stuck in progress — every sync is blocked"
    _doc_hint "git -C \"$CLAUDE_HOME\" merge --abort && claude-kitsync pull"
  fi

  if [[ -f "$CLAUDE_HOME/.kitsync/conflict_pending" ]]; then
    _doc_warn "A sync conflict is waiting for you"
    _doc_hint "claude-kitsync pull   (or: claude-kitsync pull --force to take the remote)"
  fi

  if ! git -C "$CLAUDE_HOME" rev-parse --abbrev-ref '@{u}' &>/dev/null; then
    git -C "$CLAUDE_HOME" remote get-url origin &>/dev/null && \
      _doc_warn "Branch has no upstream — run: claude-kitsync push"
    return 0
  fi

  # Refresh the remote-tracking ref so "behind" is current (best effort)
  _git_net fetch -q origin &>/dev/null || true
  local counts ahead behind
  counts="$(git -C "$CLAUDE_HOME" rev-list --left-right --count 'HEAD...@{u}' 2>/dev/null || echo "0 0")"
  read -r ahead behind <<< "$counts"
  if (( ahead > 0 )); then
    _doc_warn "$ahead local commit(s) not pushed — run: claude-kitsync push"
  fi
  if (( behind > 0 )); then
    _doc_warn "$behind remote commit(s) not pulled — run: claude-kitsync pull"
  fi
  (( ahead == 0 && behind == 0 )) && _doc_ok "In sync with the remote"

  local dirty
  dirty="$(git -C "$CLAUDE_HOME" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  (( dirty > 0 )) && log_info "$dirty file(s) changed since the last push (pushed at the end of your next session)"
  return 0
}

# ---------------------------------------------------------------------------
# Data safety — what could leak to the remote
# ---------------------------------------------------------------------------
_doc_check_safety() {
  _doc_section "Data safety"

  if git -C "$CLAUDE_HOME" ls-files --error-unmatch ".credentials.json" &>/dev/null; then
    _doc_err "CRITICAL: .credentials.json is tracked by git"
    _doc_hint "git -C \"$CLAUDE_HOME\" rm --cached .credentials.json  — then rotate your token"
  else
    _doc_ok ".credentials.json is not tracked"
  fi

  # Allowlist .gitignore: first rule must deny everything
  local first
  first="$(grep -v '^[[:space:]]*\(#\|$\)' "$CLAUDE_HOME/.gitignore" 2>/dev/null | head -1 || true)"
  if [[ "$first" == "*" ]]; then
    _doc_ok ".gitignore is an allowlist (deny by default)"
  else
    _doc_err ".gitignore is not kitsync's allowlist — conversations and caches could be pushed"
    _doc_hint "Restore it: cp \"$KITSYNC_ROOT/templates/.gitignore.template\" \"$CLAUDE_HOME/.gitignore\""
  fi

  # Tracked files the .gitignore excludes (added before the rule, or forced)
  local leaked n
  leaked="$(git -C "$CLAUDE_HOME" ls-files -ci --exclude-standard 2>/dev/null || true)"
  n="$(grep -c . <<< "$leaked" || true)"
  if (( n > 0 )); then
    _doc_err "$n tracked file(s) should not be synced, e.g.: $(head -3 <<< "$leaked" | tr '\n' ' ')"
    _doc_hint "git -C \"$CLAUDE_HOME\" rm -r --cached <path> && claude-kitsync push"
  else
    _doc_ok "No excluded file is tracked"
  fi

  if _crypto_is_enabled 2>/dev/null; then
    local key
    key="$(_crypto_key_path)"
    if [[ ! -f "$key" ]]; then
      _doc_err "Encryption enabled but key file missing: $key"
      _doc_hint "Copy the key from another machine, or: claude-kitsync encrypt enable"
    elif ! _crypto_key_ok; then
      _doc_err "This machine's encryption key is not the current one — settings.json is not synced"
      _doc_hint "Copy $key from a machine that has the current key"
    elif git -C "$CLAUDE_HOME" ls-files --error-unmatch settings.json &>/dev/null; then
      _doc_err "Encryption enabled but settings.json is tracked in plaintext"
      _doc_hint "git -C \"$CLAUDE_HOME\" rm --cached settings.json && claude-kitsync push"
    else
      _doc_ok "Encryption enabled — key present, settings.json pushed encrypted"
    fi
  fi

  if git -C "$CLAUDE_HOME" config --get "filter.${KITSYNC_PATH_FILTER}.clean" &>/dev/null; then
    _doc_ok "Portable paths filter active"
  else
    _doc_warn "Portable paths filter not set up — your home path would be pushed as is"
    _doc_hint "claude-kitsync push  (sets it up)"
  fi
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
_doc_check_install() {
  _doc_section "Installation"

  local method="script"
  _installed_via_brew && method="Homebrew"

  # Distinct binaries on PATH (the same link listed twice in PATH is fine)
  local -a bins=()
  local b real seen=" "
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    real="$(cd "$(dirname "$b")" && pwd -P)/$(basename "$b")"
    [[ -L "$b" ]] && real="$(readlink "$b")"
    [[ "$seen" == *" $real "* ]] && continue
    seen="$seen$real "
    bins+=("$b")
  done < <(type -ap claude-kitsync 2>/dev/null || true)
  if (( ${#bins[@]} > 1 )); then
    _doc_warn "Several installs on PATH: ${bins[*]} — keep one (see README)"
  fi

  local latest=""
  [[ "${KITSYNC_OFFLINE:-}" == 1 ]] || latest="$(_latest_release_tag 2>/dev/null || true)"
  if [[ -n "$latest" ]] && _version_lt "$KITSYNC_VERSION" "${latest#v}"; then
    _doc_warn "v$KITSYNC_VERSION ($method) — $latest is available"
    if [[ "$method" == Homebrew ]]; then
      _doc_hint "brew upgrade claude-kitsync"
    else
      _doc_hint "claude-kitsync upgrade"
    fi
  else
    _doc_ok "v$KITSYNC_VERSION ($method)$([[ -n "$latest" ]] && echo ", up to date")"
  fi

  if [[ "$method" == script ]] && ! command -v gpg &>/dev/null; then
    _doc_warn "gpg not found — upgrades can't check release signatures (install gnupg)"
  fi

  local rcs
  rcs="$(_wrapper_rc_files)"
  if hooks_installed; then
    _doc_ok "Sync hooks installed (terminal, IDE, desktop)"
    [[ -z "$rcs" ]] || _doc_warn "Shell wrapper still in $(tr '\n' ' ' <<< "$rcs")— sessions sync twice; fix: claude-kitsync settings → Sync triggers"
  elif [[ -n "$rcs" ]]; then
    _doc_warn "Only the shell wrapper syncs (terminal only, not IDE/desktop) — fix: claude-kitsync settings → Sync triggers"
  else
    _doc_warn "No automatic sync — fix: claude-kitsync settings → Sync triggers"
  fi
}

# ---------------------------------------------------------------------------
# cmd_doctor — diagnose the setup; exit 1 when an error needs action
# ---------------------------------------------------------------------------
cmd_doctor() {
  _DOC_ERRORS=0
  _DOC_WARNINGS=0

  printf "\n" >&2
  log_info "Running claude-kitsync doctor..."

  if _doc_check_repo; then
    _doc_check_sync
    _doc_check_safety
  fi
  _doc_check_install

  printf "\n" >&2
  if (( _DOC_ERRORS > 0 )); then
    log_error "Doctor found $_DOC_ERRORS error(s) and $_DOC_WARNINGS warning(s) — action required."
    return 1
  elif (( _DOC_WARNINGS > 0 )); then
    log_warn "Doctor found $_DOC_WARNINGS warning(s) — review recommended."
  else
    log_success "All checks passed — claude-kitsync is healthy."
  fi
}
