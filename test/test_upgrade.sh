#!/usr/bin/env bash
# test/test_upgrade.sh
# upgrade: latest-tag fallback, release notes, rc refresh after an upgrade,
# release signature verification (offline, throwaway gpg keys)

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

# _upg_run <home> <cmd...> — run lib functions in a fresh bash (readonly vars
# from libs already sourced into the runner would abort a re-source)
_upg_run() {
  local h="$1"; shift
  HOME="$h" ZDOTDIR="$h" CLAUDE_HOME="$h/.claude" XDG_STATE_HOME="$h/.state" \
    KITSYNC_ROOT="${_UPG_KS_ROOT:-$_PROJECT_ROOT}" _UPG_LIBS="$_PROJECT_ROOT/lib" \
    bash -c '
      for _lib in core wrapper upgrade; do
        source "$_UPG_LIBS/$_lib.sh"
      done
      KITSYNC_VERSION="$(cat "$KITSYNC_ROOT/VERSION" 2>/dev/null || echo dev)"
      set +e
      "$@"
    ' _ "$@"
}

run_test_upg_pick_stable_tag() {
  local got
  got="$(printf '%s\n' \
    "aaa	refs/tags/v1.10.1-beta" \
    "bbb	refs/tags/v1.10.0" \
    "ccc	refs/tags/v1.9.0" | _upg_run "$(mktemp -d)" _pick_stable_tag)"
  assert_eq "v1.10.0" "$got" "UPG: ls-remote fallback skips pre-release tags"
}

run_test_upg_changelog_since() {
  local h cl out
  h="$(mktemp -d)"
  cl="$h/CHANGELOG.md"
  printf '%s\n' "# Changelog" "" "## [Unreleased]" "- unreleased item" "" \
    "## [1.2.0] — x" "- in 1.2.0" "" "## [1.1.9] — x" "- in 1.1.9" "" \
    "## [1.1.8] — x" "- in 1.1.8" > "$cl"

  out="$(_upg_run "$h" _changelog_since "$cl" 1.1.8 1.2.0)"
  assert_contains "$out" "- in 1.2.0" "UPG: release notes include the new version"
  assert_contains "$out" "- in 1.1.9" "UPG: release notes include skipped versions"
  assert_eq "0" "$(grep -c 'in 1.1.8\|unreleased' <<< "$out")" \
    "UPG: release notes exclude the current version and Unreleased"

  out="$(_upg_run "$h" _changelog_since "$cl" 1.1.8 1.2.0 3)"
  assert_contains "$out" "full notes:" "UPG: long release notes are capped"
  rm -rf "$h"
}

run_test_upg_refresh_shell_setup() {
  local h rc want before after out
  h="$(mktemp -d)"
  mkdir -p "$h/.claude/.kitsync" "$h/.local/share"
  # The installer's clone location (refresh only rewires completion for it)
  ln -s "$_PROJECT_ROOT" "$h/.local/share/kitsync"
  rc="$h/.zshrc"
  # A script install from an older version: stale wrapper and completion path
  {
    printf '# claude-kitsync PATH\nexport PATH="%s/.local/bin:$PATH"\n\n' "$h"
    _upg_run "$h" generate_wrapper | sed 's/^claude() {$/claude() { # old/'
    printf '\n'
    _upg_run "$h" _completion_block zsh /old/kitsync/completions
    printf '\nalias ll="ls -l"\n'
  } > "$rc"

  local original
  original="$(cat "$rc")"
  _upg_run "$h" refresh_shell_setup >/dev/null 2>&1

  local bak
  bak="$(ls "$h/.claude/.kitsync/backups/".zshrc.*.bak 2>/dev/null | head -1)"
  assert_eq "$original" "$(cat "$bak" 2>/dev/null)" \
    "UPG: rc backup holds the original, not an intermediate edit"

  want="$(_upg_run "$h" generate_wrapper)"
  assert_eq "$want" "$(_upg_run "$h" _rc_block "$rc" "# kitsync-start" "# kitsync-end")" \
    "UPG: refresh rewrites a stale wrapper block"
  assert_contains "$(cat "$rc")" "fpath=(\"$_PROJECT_ROOT/completions\"" \
    "UPG: refresh points completion at the current install"
  assert_eq "1" "$(grep -c '^# claude-kitsync completion$' "$rc")" \
    "UPG: refresh keeps a single completion block"
  assert_eq "0" "$(grep -c '/old/kitsync' "$rc")" "UPG: stale completion path removed"
  assert_eq "1" "$(grep -c '^alias ll=' "$rc")" "UPG: refresh keeps the rest of the rc file"

  # PATH line migrated to the idempotent form: sourcing twice adds the dir once
  local pline
  pline="$(grep -A1 '^# claude-kitsync PATH$' "$rc" | tail -1)"
  assert_contains "$pline" 'case ":$PATH:" in' "UPG: old PATH line migrated"
  assert_eq "1" "$(PATH=/usr/bin:/bin bash -c "$pline; $pline; echo \"\$PATH\"" | tr ':' '\n' | grep -c "^$h/.local/bin$")" \
    "UPG: migrated PATH line is idempotent"

  before="$(cat "$rc")"
  out="$(_upg_run "$h" refresh_shell_setup 2>&1)"
  after="$(cat "$rc")"
  assert_eq "$before" "$after" "UPG: refresh is a no-op when up to date"
  assert_eq "" "$out" "UPG: no output when nothing changed"

  # A dev checkout run by hand must not rewire the completion block
  local before_dev
  before_dev="$(cat "$rc")"
  sed -i.bak "s|$_PROJECT_ROOT/completions|/elsewhere/completions|" "$rc" && rm -f "$rc.bak"
  _UPG_KS_ROOT="$(mktemp -d)" _upg_run "$h" refresh_shell_setup >/dev/null 2>&1
  assert_contains "$(cat "$rc")" "/elsewhere/completions" \
    "UPG: refresh from a non-installer dir leaves completion alone"
  printf '%s\n' "$before_dev" > "$rc"

  # Uninstall removes the new PATH form too
  _upg_run "$h" _remove_path_from_rc "$rc" >/dev/null 2>&1
  assert_eq "0" "$(grep -c 'kitsync PATH\|case ":\$PATH:"' "$rc")" "UPG: idempotent PATH line removable"

  # bashrc without kitsync blocks (e.g. Homebrew install, zsh user) is left alone
  printf 'export X=1\n' > "$h/.bashrc"
  _upg_run "$h" refresh_shell_setup >/dev/null 2>&1
  assert_eq "export X=1" "$(cat "$h/.bashrc")" "UPG: refresh ignores rc files without kitsync blocks"

  # ensure_shell_setup records the version, then stays quiet
  _upg_run "$h" ensure_shell_setup >/dev/null 2>&1
  assert_eq "$(cat "$_PROJECT_ROOT/VERSION")" "$(cat "$h/.state/kitsync/shell-setup" 2>/dev/null)" \
    "UPG: shell setup stamp records the current version"
  rm -rf "$h"
}

# ---------------------------------------------------------------------------
# Release verification fixture
#   _UPG_DIR/ks        fake install (git repo: bin lib keys VERSION)
#   _UPG_DIR/dl/<tag>  release assets (tarball, SHA256SUMS[.asc])
#   _UPG_FPR / _UPG_FPR2  release key / unrelated key
# ---------------------------------------------------------------------------
_upg_gpg() { GNUPGHOME="$_UPG_DIR/signer" gpg --batch --quiet "$@" 2>/dev/null; }

_upg_fixture() {
  # Short path: gpg agent sockets live in GNUPGHOME (macOS caps at 104 bytes)
  _UPG_DIR="$(mktemp -d /tmp/ks-upg.XXXXXX)"
  mkdir -m 700 "$_UPG_DIR/signer"
  _upg_gpg --passphrase '' --quick-gen-key "kitsync test release" ed25519 sign never
  _upg_gpg --passphrase '' --quick-gen-key "kitsync someone else" ed25519 sign never
  _UPG_FPR="$(_upg_gpg --with-colons --list-keys "kitsync test release" | awk -F: '/^fpr/{print $10; exit}')"
  _UPG_FPR2="$(_upg_gpg --with-colons --list-keys "kitsync someone else" | awk -F: '/^fpr/{print $10; exit}')"

  local ks="$_UPG_DIR/ks"
  mkdir -p "$ks/bin" "$ks/lib" "$ks/keys"
  echo 'echo cli' > "$ks/bin/claude-kitsync"
  echo 'echo lib' > "$ks/lib/core.sh"
  echo '9.0.0' > "$ks/VERSION"
  _upg_gpg --armor --export "$_UPG_FPR" > "$ks/keys/release-signing.asc"
  git -C "$ks" init -q
  git -C "$ks" add -A
  git -C "$ks" commit -q -m release
  _UPG_REV="$(git -C "$ks" rev-parse HEAD)"

  _upg_publish v9.0.0 "$_UPG_FPR"
}

# _upg_publish <tag> <signing fpr|none> — release assets from the fake install
_upg_publish() {
  local tag="$1" fpr="$2" dir="$_UPG_DIR/dl/$1"
  mkdir -p "$dir"
  tar -czf "$dir/claude-kitsync-$tag.tar.gz" -C "$_UPG_DIR/ks" bin lib keys VERSION
  (cd "$dir" && _sha256_line "claude-kitsync-$tag.tar.gz" > SHA256SUMS)
  if [[ "$fpr" != none ]]; then
    _upg_gpg --yes --local-user "$fpr" --detach-sign --armor -o "$dir/SHA256SUMS.asc" "$dir/SHA256SUMS"
  fi
}

_sha256_line() {
  if command -v sha256sum &>/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

# _upg_verify <tag> [rev] — exit code of _verify_release against the fixture
_upg_verify() {
  _UPG_KS_ROOT="$_UPG_DIR/ks" _upg_run "$_UPG_DIR" _verify_release "$1" "${2:-$_UPG_REV}" \
    "$_UPG_DIR/ks/keys/release-signing.asc" "$_UPG_FPR" "file://$_UPG_DIR/dl" >/dev/null 2>&1
  echo $?
}

_upg_teardown() {
  GNUPGHOME="$_UPG_DIR/signer" gpgconf --kill all 2>/dev/null || true
  rm -rf "$_UPG_DIR"
}

run_test_upg_verify_release() {
  if ! command -v gpg &>/dev/null; then
    printf "  SKIP  UPG: release verification (gpg not installed)\n"
    return 0
  fi
  _upg_fixture
  local dl="$_UPG_DIR/dl"

  assert_eq "0" "$(_upg_verify v9.0.0)" "UPG: genuine signed release is accepted"

  # Code fetched from git differs from the signed tarball
  echo 'echo evil' > "$_UPG_DIR/ks/lib/core.sh"
  git -C "$_UPG_DIR/ks" commit -q -am tampered
  assert_eq "1" "$(_upg_verify v9.0.0 "$(git -C "$_UPG_DIR/ks" rev-parse HEAD)")" \
    "UPG: fetched code differing from the release is refused"

  # Extra file sourced from the fetched tree, absent from the tarball
  git -C "$_UPG_DIR/ks" reset -q --hard "$_UPG_REV"
  echo 'echo extra' > "$_UPG_DIR/ks/lib/extra.sh"
  git -C "$_UPG_DIR/ks" add -A && git -C "$_UPG_DIR/ks" commit -q -m extra
  assert_eq "1" "$(_upg_verify v9.0.0 "$(git -C "$_UPG_DIR/ks" rev-parse HEAD)")" \
    "UPG: extra file in fetched code is refused"
  git -C "$_UPG_DIR/ks" reset -q --hard "$_UPG_REV"

  # Tarball swapped after signing
  printf 'x' >> "$dl/v9.0.0/claude-kitsync-v9.0.0.tar.gz"
  assert_eq "1" "$(_upg_verify v9.0.0)" "UPG: tarball not matching signed checksums is refused"

  # Signed by another key
  _upg_publish v9.0.0 "$_UPG_FPR2"
  assert_eq "1" "$(_upg_verify v9.0.0)" "UPG: release signed by another key is refused"

  # Signature stripped from a release that must be signed
  _upg_publish v9.0.0 none
  rm -f "$dl/v9.0.0/SHA256SUMS.asc"
  assert_eq "1" "$(_upg_verify v9.0.0)" "UPG: unsigned release after signing started is refused"

  # Releases older than signing are let through
  _upg_publish v1.1.5 none
  assert_eq "0" "$(_upg_verify v1.1.5)" "UPG: release predating signatures is accepted"

  _upg_teardown
}

run_upgrade_tests() {
  printf "\n=== test_upgrade.sh (upgrade: tags, notes, rc refresh, signatures) ===\n"
  export GIT_AUTHOR_NAME=kitsync-test GIT_AUTHOR_EMAIL=t@kitsync.local
  export GIT_COMMITTER_NAME=kitsync-test GIT_COMMITTER_EMAIL=t@kitsync.local
  run_test_upg_pick_stable_tag
  run_test_upg_changelog_since
  run_test_upg_refresh_shell_setup
  run_test_upg_verify_release
}
