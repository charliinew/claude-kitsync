#!/usr/bin/env bash
# test/test_uninstall.sh
# uninstall: deletes only the installer's own clone and links, asks first,
# edits rc files in place (symlinks, permissions, user lines kept)

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

# _uni_copy <dest> — a copy of the CLI (what an install dir holds)
_uni_copy() {
  mkdir -p "$1"
  cp -R "$_PROJECT_ROOT/bin" "$_PROJECT_ROOT/lib" "$_PROJECT_ROOT/completions" \
        "$_PROJECT_ROOT/VERSION" "$1/"
}

# _uni_home — fake $HOME with a script install, its link and rc blocks
# Sets: _UNI_HOME, _UNI_RC
_uni_home() {
  _UNI_HOME="$(mktemp -d)"
  local h="$_UNI_HOME"
  mkdir -p "$h/.claude/.kitsync" "$h/.local/bin"
  _uni_copy "$h/.local/share/kitsync"
  ln -s "$h/.local/share/kitsync/bin/claude-kitsync" "$h/.local/bin/claude-kitsync"
  _UNI_RC="$h/.zshrc"
  {
    printf 'export EDITOR=vim\n'
    printf '\n# claude-kitsync PATH\nexport PATH="%s/.local/bin:$PATH"\n' "$h"
    printf '\n# kitsync-start\nclaude() { :; }\n# kitsync-end\n'
    printf '\n# claude-kitsync completion\nfpath=("x" $fpath)\n# claude-kitsync completion end\n'
    printf 'alias ll="ls -l"\n'
  } > "$_UNI_RC"
}

# _uni_run <cli> <args...> — run a CLI copy as the fake user, no terminal
_uni_run() {
  local cli="$1"; shift
  HOME="$_UNI_HOME" ZDOTDIR="$_UNI_HOME" CLAUDE_HOME="$_UNI_HOME/.claude" XDG_STATE_HOME="$_UNI_HOME/.state" \
    PATH="$_UNI_HOME/.local/bin:/usr/bin:/bin" KITSYNC_ROOT="" \
    bash "$cli" "$@" </dev/null >/dev/null 2>&1
  echo $?
}

run_test_uni_managed_install() {
  _uni_home
  local h="$_UNI_HOME"
  assert_eq "0" "$(_uni_run "$h/.local/bin/claude-kitsync" uninstall --yes)" \
    "UNI: uninstall --yes succeeds"
  assert_eq "no" "$([[ -e "$h/.local/share/kitsync" ]] && echo yes || echo no)" \
    "UNI: installer's clone removed"
  assert_eq "no" "$([[ -L "$h/.local/bin/claude-kitsync" ]] && echo yes || echo no)" \
    "UNI: binary link removed"
  assert_eq "0" "$(grep -c 'kitsync' "$_UNI_RC")" "UNI: all kitsync blocks removed from rc"
  assert_eq "2" "$(grep -cE '^export EDITOR=vim$|^alias ll=' "$_UNI_RC")" \
    "UNI: user lines kept in rc"
  assert_dir_exists "$h/.claude" "UNI: ~/.claude kept"
  rm -rf "$h"
}

run_test_uni_needs_confirmation() {
  _uni_home
  local h="$_UNI_HOME"
  assert_eq "1" "$(_uni_run "$h/.local/bin/claude-kitsync" uninstall)" \
    "UNI: without a terminal and --yes, uninstall refuses"
  assert_dir_exists "$h/.local/share/kitsync" "UNI: refused uninstall removes nothing"
  assert_eq "1" "$(grep -c '^# kitsync-start$' "$_UNI_RC")" "UNI: refused uninstall leaves rc alone"
  rm -rf "$h"
}

run_test_uni_dev_checkout_kept() {
  _uni_home
  local h="$_UNI_HOME"
  # Run from a working copy (dev checkout / KITSYNC_INSTALL_DIR install)
  _uni_copy "$h/dev/claude-kitsync"
  echo "work in progress" > "$h/dev/claude-kitsync/NOTES"
  _uni_run "$h/dev/claude-kitsync/bin/claude-kitsync" uninstall --yes >/dev/null
  assert_file_exists "$h/dev/claude-kitsync/NOTES" "UNI: a dev checkout is never deleted"
  assert_eq "yes" "$([[ -L "$h/.local/bin/claude-kitsync" ]] && echo yes || echo no)" \
    "UNI: link of another install is kept"
  assert_dir_exists "$h/.local/share/kitsync" "UNI: the other install dir is kept"
  rm -rf "$h"
}

run_test_uni_rc_in_place() {
  _uni_home
  local h="$_UNI_HOME"
  # Dotfiles setup: ~/.zshrc is a symlink; the PATH line was hand-edited
  mkdir -p "$h/dotfiles"
  { printf '# claude-kitsync PATH\nsource ~/.private_env\n'; cat "$_UNI_RC"; } > "$h/dotfiles/zshrc"
  chmod 644 "$h/dotfiles/zshrc"
  rm -f "$_UNI_RC"
  ln -s "$h/dotfiles/zshrc" "$_UNI_RC"

  _uni_run "$h/.local/bin/claude-kitsync" uninstall --yes >/dev/null
  assert_eq "yes" "$([[ -L "$_UNI_RC" ]] && echo yes || echo no)" "UNI: symlinked rc stays a symlink"
  assert_eq "0" "$(grep -c 'kitsync' "$h/dotfiles/zshrc")" "UNI: blocks removed through the symlink"
  assert_eq "1" "$(grep -c '^source ~/.private_env$' "$h/dotfiles/zshrc")" \
    "UNI: line after a stale PATH marker is kept unless it is the export"
  assert_eq "644" "$(stat -c '%a' "$h/dotfiles/zshrc" 2>/dev/null || stat -f '%Lp' "$h/dotfiles/zshrc")" \
    "UNI: rc permissions kept"
  assert_nonzero "$(ls -A "$h/.claude/.kitsync/backups/" 2>/dev/null | wc -l | tr -d ' ')" \
    "UNI: rc backed up before edits"
  rm -rf "$h"
}

run_uninstall_tests() {
  printf "\n=== test_uninstall.sh (uninstall safety) ===\n"
  run_test_uni_managed_install
  run_test_uni_needs_confirmation
  run_test_uni_dev_checkout_kept
  run_test_uni_rc_in_place
}
