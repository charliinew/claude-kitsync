#!/usr/bin/env bash
# lib/upgrade.sh — self-upgrade of a script install (stable releases or dev channel)
set -euo pipefail

readonly KITSYNC_REPO_URL="https://github.com/charliinew/claude-kitsync"
# Release signing key, shipped as keys/release-signing.asc. The SHA256SUMS of
# every release from KITSYNC_SIGNED_SINCE on is signed with it by the release
# workflow; upgrade refuses an unsigned one.
readonly KITSYNC_RELEASE_KEY_FPR="592A3F382C542ABAA60AAED66F6EC0A51AFF673D"
readonly KITSYNC_SIGNED_SINCE="1.1.9"

# ---------------------------------------------------------------------------
# _version_lt <a> <b> — true if version a is strictly lower than b
# (numeric major.minor.patch; non-digit suffixes are ignored)
# ---------------------------------------------------------------------------
_version_lt() {
  local IFS=.
  # shellcheck disable=SC2206  # split on IFS=. is the point
  local -a _a=($1) _b=($2)
  local i x y
  for i in 0 1 2; do
    x="${_a[i]:-0}"; x="${x//[^0-9]/}"; x="${x:-0}"
    y="${_b[i]:-0}"; y="${y//[^0-9]/}"; y="${y:-0}"
    (( 10#$x < 10#$y )) && return 0
    (( 10#$x > 10#$y )) && return 1
  done
  return 1
}

# _git_error <message> <git output> — log a failure with git's own explanation
_git_error() {
  log_error "$1"
  [[ -n "$2" ]] && printf '%s\n' "$2" | sed 's/^/    /' >&2
  return 0
}

# _sha256 <file> — print the SHA-256 of a file (Linux or macOS)
_sha256() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# _pick_stable_tag — first plain vX.Y.Z tag of `git ls-remote --tags` output
# (pre-releases such as v1.2.0-rc1 would otherwise sort first)
_pick_stable_tag() {
  awk '{ sub(/.*refs\/tags\//, "") } /^v[0-9]+\.[0-9]+\.[0-9]+$/ { print; exit }'
}

# _latest_release_tag — latest stable release tag, empty if unreachable
_latest_release_tag() {
  local tag=""
  # GitHub API: latest non-pre-release (60 unauthenticated calls per hour)
  if command -v curl &>/dev/null; then
    tag="$(curl -fsSL "https://api.github.com/repos/charliinew/claude-kitsync/releases/latest" \
      2>/dev/null | grep '"tag_name"' | head -1 | \
      sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)"
  fi
  # Fallback: highest stable semver tag
  if [[ -z "$tag" ]]; then
    tag="$(git ls-remote --tags --sort=-v:refname "$KITSYNC_REPO_URL" 'refs/tags/v*' \
      2>/dev/null | _pick_stable_tag || true)"
  fi
  printf '%s' "$tag"
}

# ---------------------------------------------------------------------------
# _changelog_since <changelog> <from> <to> [max_lines] — release notes of the
# versions in (from, to], capped at max_lines (default 40)
# ---------------------------------------------------------------------------
_changelog_since() {
  local file="$1" from="$2" to="$3" max="${4:-40}"
  [[ -f "$file" ]] || return 0
  local re='^## \[([0-9]+\.[0-9]+\.[0-9]+)\]'
  local line printing=false n=0
  while IFS= read -r line; do
    if [[ "$line" =~ $re ]]; then
      if _version_lt "$from" "${BASH_REMATCH[1]}" && ! _version_lt "$to" "${BASH_REMATCH[1]}"; then
        printing=true
      else
        printing=false
      fi
    elif [[ "$line" == "## "* ]]; then
      printing=false   # [Unreleased] and any other section
    fi
    [[ "$printing" == true ]] || continue
    if (( n >= max )); then
      printf '  … (full notes: %s)\n' "$file"
      return 0
    fi
    printf '%s\n' "$line"
    n=$(( n + 1 ))
  done < "$file"
}

# ---------------------------------------------------------------------------
# _verify_release <tag> <rev> [key_file] [fingerprint] [base_url]
#
# Checks that the code at <rev> (the fetched tag) is what the release workflow
# published and signed: SHA256SUMS signed by the release key, the release
# tarball matching it, and the tarball matching <rev> file for file.
# Returns 1 on any mismatch; releases older than KITSYNC_SIGNED_SINCE and
# machines without gpg are let through with a warning.
# ---------------------------------------------------------------------------
_verify_release() {
  local tag="$1" rev="$2"
  local key="${3:-$KITSYNC_ROOT/keys/release-signing.asc}"
  local fpr="${4:-$KITSYNC_RELEASE_KEY_FPR}"
  local base="${5:-$KITSYNC_REPO_URL/releases/download}/$tag"

  if ! command -v gpg &>/dev/null; then
    log_warn "gpg not found — release signature not checked (install gnupg to enable it)."
    return 0
  fi

  # Short path under /tmp: gpg's agent sockets live in GNUPGHOME and macOS
  # caps socket paths at 104 bytes ($TMPDIR is already ~50)
  local tmp rc=0
  tmp="$(mktemp -d /tmp/kitsync-verify.XXXXXX)"
  _verify_release_in "$tmp" "$tag" "$rev" "$key" "$fpr" "$base" || rc=$?
  GNUPGHOME="$tmp/gnupg" gpgconf --kill all 2>/dev/null || true
  rm -rf "$tmp"
  return "$rc"
}

_verify_release_in() {
  local tmp="$1" tag="$2" rev="$3" key="$4" fpr="$5" base="$6"
  local tarball="claude-kitsync-${tag}.tar.gz" err

  if ! curl -fsSL -o "$tmp/SHA256SUMS.asc" "$base/SHA256SUMS.asc" 2>/dev/null; then
    if _version_lt "${tag#v}" "$KITSYNC_SIGNED_SINCE"; then
      log_warn "$tag predates signed releases — signature not checked."
      return 0
    fi
    log_error "Could not download the signature of $tag (SHA256SUMS.asc)."
    return 1
  fi
  if ! err="$(curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" 2>&1 && \
              curl -fsSL -o "$tmp/$tarball" "$base/$tarball" 2>&1)"; then
    log_error "Could not download $tag to verify it: $err"
    return 1
  fi

  # Signature, against the pinned key only (throwaway keyring)
  mkdir -m 700 "$tmp/gnupg"
  if ! GNUPGHOME="$tmp/gnupg" gpg --batch --quiet --import "$key" 2>/dev/null; then
    log_error "Cannot read the release signing key: $key"
    return 1
  fi
  local status
  status="$(GNUPGHOME="$tmp/gnupg" gpg --batch --status-fd 1 \
    --verify "$tmp/SHA256SUMS.asc" "$tmp/SHA256SUMS" 2>/dev/null || true)"
  if ! awk -v f="$fpr" '$2 == "VALIDSIG" && ($3 == f || $NF == f) { ok=1 } END { exit !ok }' \
       <<< "$status"; then
    log_error "Invalid signature on $tag — it was not signed by the claude-kitsync release key."
    return 1
  fi

  # Tarball against the signed checksums
  local want
  want="$(awk -v f="$tarball" '$2 == f || $2 == "*" f { print $1; exit }' "$tmp/SHA256SUMS")"
  if [[ -z "$want" ]] || [[ "$want" != "$(_sha256 "$tmp/$tarball")" ]]; then
    log_error "Checksum mismatch for $tarball."
    return 1
  fi

  # Fetched code against the tarball, for every path the tarball ships
  mkdir "$tmp/release" "$tmp/git"
  tar -xzf "$tmp/$tarball" -C "$tmp/release"
  local -a paths=()
  local p
  for p in "$tmp/release"/*; do paths+=("$(basename "$p")"); done
  for p in bin lib keys; do
    if [[ ! -e "$tmp/release/$p" ]]; then
      log_error "Release $tag is missing $p/ — refusing to install it."
      return 1
    fi
  done
  if ! git -C "$KITSYNC_ROOT" archive "$rev" -- "${paths[@]}" > "$tmp/git.tar" 2>/dev/null || \
     ! tar -xf "$tmp/git.tar" -C "$tmp/git" || \
     ! diff -r "$tmp/release" "$tmp/git" >/dev/null 2>&1; then
    log_error "The code fetched for $tag differs from the signed release."
    return 1
  fi

  log_success "Release signature verified"
}

# _check_local_changes — confirm before reset --hard discards local edits
_check_local_changes() {
  local changes
  changes="$(git -C "$KITSYNC_ROOT" status --porcelain --untracked-files=no 2>/dev/null || true)"
  [[ -z "$changes" ]] && return 0
  log_warn "Local changes in $KITSYNC_ROOT would be overwritten:"
  printf '%s\n' "$changes" | sed 's/^/    /' >&2
  if confirm "Discard them and upgrade?"; then
    return 0
  fi
  log_info "Upgrade cancelled. Use --force to discard local changes."
  return 1
}

# ---------------------------------------------------------------------------
# Shell setup stamp — the version whose wrapper/completion blocks are in the
# rc files. Machine-local (outside ~/.claude, which is synced).
# ---------------------------------------------------------------------------
_shell_stamp_file() {
  printf '%s/kitsync/shell-setup' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# post_upgrade [from_version] — refresh rc blocks, then show what changed.
# Runs in the NEW version (upgrade calls the freshly installed binary).
post_upgrade() {
  local from="${1:-}"
  # 1.2.0: sync moved from the claude() shell wrapper to Claude Code hooks
  if declare -F sync_trigger_setup >/dev/null && [[ -n "$(_wrapper_rc_files)" ]]; then
    sync_trigger_setup
  fi
  refresh_shell_setup
  local stamp
  stamp="$(_shell_stamp_file)"
  mkdir -p "$(dirname "$stamp")" 2>/dev/null && printf '%s\n' "$KITSYNC_VERSION" > "$stamp" 2>/dev/null || true

  if [[ -n "$from" ]] && _version_lt "$from" "$KITSYNC_VERSION"; then
    local notes
    notes="$(_changelog_since "$KITSYNC_ROOT/CHANGELOG.md" "$from" "$KITSYNC_VERSION")"
    if [[ -n "$notes" ]]; then
      printf '\n%s\n\n' "$notes" >&2
    fi
  fi
}

# _run_post_upgrade [from_version] — hand over to the freshly installed binary
# (skipped when that version predates post_upgrade)
_run_post_upgrade() {
  local cli="$KITSYNC_ROOT/bin/claude-kitsync"
  grep -q '_post-upgrade)' "$cli" 2>/dev/null || return 0
  "$cli" _post-upgrade "$@" || true
}

# ensure_shell_setup — catch up after an upgrade that skipped post_upgrade
# (Homebrew, or an older version's upgrade command)
ensure_shell_setup() {
  [[ -d "$CLAUDE_HOME/.kitsync" ]] || return 0
  local stamp
  stamp="$(_shell_stamp_file)"
  [[ "$(cat "$stamp" 2>/dev/null || true)" == "$KITSYNC_VERSION" ]] && return 0
  post_upgrade
}

# ---------------------------------------------------------------------------
# cmd_upgrade — update claude-kitsync to the latest stable release, or latest commit (dev mode)
# Usage: claude-kitsync upgrade [--dev] [--force] [--no-verify]
# ---------------------------------------------------------------------------
cmd_upgrade() {
  local _dev_mode=false _force=false _verify=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dev)       _dev_mode=true; shift ;;
      --force)     _force=true; shift ;;
      --no-verify) _verify=false; shift ;;
      *) die "Unknown option: $1 (usage: claude-kitsync upgrade [--dev] [--force] [--no-verify])" ;;
    esac
  done

  if _installed_via_brew; then
    log_info "claude-kitsync is managed by Homebrew — run: brew upgrade claude-kitsync"
    return 0
  fi

  if [[ ! -d "$KITSYNC_ROOT/.git" ]]; then
    log_warn "KITSYNC_ROOT is not a git repo — can't auto-upgrade."
    log_warn "Re-run the installer: curl -fsSL https://raw.githubusercontent.com/charliinew/claude-kitsync/main/install.sh | bash"
    return 1
  fi

  # Check config for dev channel if flag not set
  if [[ "$_dev_mode" != true ]]; then
    local _channel
    _channel="$(grep '^KITSYNC_UPGRADE_CHANNEL=' "$CLAUDE_HOME/.kitsync/config" 2>/dev/null | cut -d= -f2- || true)"
    [[ "$_channel" == "dev" ]] && _dev_mode=true
  fi

  local current_version err
  current_version="$(cat "$KITSYNC_ROOT/VERSION" 2>/dev/null || echo "0.0.0")"

  # ---------------------------------------------------------------------------
  # Dev mode — latest commit on main (unsigned: commits are not releases)
  # ---------------------------------------------------------------------------
  if [[ "$_dev_mode" == true ]]; then
    log_step "Upgrading to latest commit (dev channel)..."
    local before_sha after_sha
    before_sha="$(git -C "$KITSYNC_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
    # Installs are shallow clones that may sit on a release tag (detached
    # HEAD), so move to origin/main explicitly instead of pulling
    if ! err="$(git -C "$KITSYNC_ROOT" fetch -q --depth 1 origin main 2>&1)"; then
      _git_error "Upgrade failed — could not fetch main:" "$err"
      return 1
    fi
    after_sha="$(git -C "$KITSYNC_ROOT" rev-parse --short FETCH_HEAD 2>/dev/null || echo '?')"
    if [[ "$before_sha" == "$after_sha" ]]; then
      log_success "Already up to date  ($after_sha)"
      return 0
    fi
    [[ "$_force" == true ]] || _check_local_changes || return 1
    if ! err="$(git -C "$KITSYNC_ROOT" reset -q --hard FETCH_HEAD 2>&1)"; then
      _git_error "Could not apply the latest commit:" "$err"
      return 1
    fi
    log_success "Upgraded: $before_sha → $after_sha"
    _run_post_upgrade
    return 0
  fi

  # ---------------------------------------------------------------------------
  # Stable mode — latest GitHub release
  # ---------------------------------------------------------------------------
  log_step "Checking latest release..."

  local latest_tag
  latest_tag="$(_latest_release_tag)"
  if [[ -z "$latest_tag" ]]; then
    log_warn "Could not determine latest release — check your network."
    log_info "Tip: use --dev to upgrade to the latest commit instead."
    return 1
  fi

  local latest_version="${latest_tag#v}"

  # Never downgrade: the API's "latest" lags behind a freshly pushed tag
  # until its release workflow has finished
  if ! _version_lt "$current_version" "$latest_version"; then
    log_success "Already up to date  (v$current_version)"
    return 0
  fi

  log_info "Current: v$current_version  →  Latest: $latest_tag"
  [[ "$_force" == true ]] || _check_local_changes || return 1
  log_step "Downloading release $latest_tag..."

  # Fetch the specific tag commit (shallow, only what we need)
  if ! err="$(git -C "$KITSYNC_ROOT" fetch -q --depth 1 origin "refs/tags/$latest_tag" 2>&1)"; then
    _git_error "Could not fetch $latest_tag:" "$err"
    return 1
  fi
  local rev
  rev="$(git -C "$KITSYNC_ROOT" rev-parse FETCH_HEAD)"

  if [[ "$_verify" == true ]]; then
    if ! _verify_release "$latest_tag" "$rev"; then
      log_info "Nothing was changed. To install it anyway: claude-kitsync upgrade --no-verify"
      return 1
    fi
  else
    log_warn "Skipping release verification (--no-verify)."
  fi

  if ! err="$(git -C "$KITSYNC_ROOT" reset -q --hard "$rev" 2>&1)"; then
    _git_error "Could not apply release $latest_tag:" "$err"
    return 1
  fi

  local new_version
  new_version="$(cat "$KITSYNC_ROOT/VERSION" 2>/dev/null || echo "$latest_version")"
  log_success "Upgraded: v$current_version → v$new_version"
  # The new version refreshes the rc blocks and prints its release notes
  _run_post_upgrade "$current_version"
}
