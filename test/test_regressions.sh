#!/usr/bin/env bash
# test/test_regressions.sh
# End-to-end regressions for sync/encryption bugs fixed in 1.1.3:
#   - working tree dirty after push (path tokens rewritten in place)
#   - pull --rebase -X theirs kept LOCAL instead of remote
#   - rotated key backups, plaintext settings and template pushed under encryption
#   - machine-local .kitsync files synced; old .gitignore never migrated

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

# ---------------------------------------------------------------------------
# _reg_setup — fake $HOME with ~/.claude repo (template .gitignore) + bare remote
# Sets: _REG_ROOT, _REG_HOME, _REG_REMOTE
# ---------------------------------------------------------------------------
_reg_setup() {
  _REG_ROOT="$(mktemp -d)"
  _REG_HOME="$_REG_ROOT/home"
  _REG_REMOTE="$_REG_ROOT/remote.git"
  mkdir -p "$_REG_HOME/.claude"
  git init -q --bare "$_REG_REMOTE"
  # Clones must check out main regardless of the runner's init.defaultBranch
  git -C "$_REG_REMOTE" symbolic-ref HEAD refs/heads/main
  _reg_init_clone "$_REG_HOME"
  (
    cd "$_REG_HOME/.claude" || exit 1
    cp "$_PROJECT_ROOT/templates/.gitignore.template" .gitignore
    printf '{"hook":"python3 %s/.claude/hooks/a.py","bun":"%s/.bun/bin/bun"}\n' \
      "$_REG_HOME" "$_REG_HOME" > settings.json
    echo "# base" > CLAUDE.md
    git add -A && git commit -q -m init && git push -q -u origin main 2>/dev/null
  )
}

# _reg_init_clone <home> — empty repo in <home>/.claude wired to the bare remote
_reg_init_clone() {
  local h="$1"
  mkdir -p "$h/.claude"
  git -C "$h/.claude" init -q -b main
  git -C "$h/.claude" config user.email t@kitsync.local
  git -C "$h/.claude" config user.name kitsync-test
  git -C "$h/.claude" remote add origin "$_REG_REMOTE"
}

_reg_teardown() {
  [[ -n "${_REG_ROOT:-}" ]] && rm -rf "$_REG_ROOT"
}

# _reg_run <home> <cmd...> — run kitsync lib functions as the user of <home>.
# Uses a fresh bash process: earlier test modules source the same libs into the
# runner shell, and re-declaring their readonly arrays in a mere subshell aborts
# the source under bash 5 (set -e).
_reg_run() {
  local h="$1"; shift
  HOME="$h" CLAUDE_HOME="$h/.claude" _REG_LIBS="$_PROJECT_ROOT/lib" \
    bash -c '
      for _lib in core paths profiles crypto sync; do
        source "$_REG_LIBS/$_lib.sh"
      done
      set +e
      "$@"
    ' _reg_run "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
run_test_reg_clean_after_push() {
  _reg_setup
  trap "_reg_teardown" RETURN
  local ch="$_REG_HOME/.claude"

  printf '{"hook":"python3 %s/.claude/hooks/b.py"}\n' "$_REG_HOME" > "$ch/settings.json"
  _reg_run "$_REG_HOME" sync_push "change" >/dev/null

  assert_eq "" "$(git -C "$ch" status --porcelain --untracked-files=no)" \
    "REG: working tree clean right after push"
  assert_contains "$(git -C "$ch" show HEAD:settings.json)" "__CLAUDE_HOME__/hooks/b.py" \
    "REG: committed settings.json uses __CLAUDE_HOME__ token"
  assert_contains "$(cat "$ch/settings.json")" "$_REG_HOME/.claude/hooks/b.py" \
    "REG: working-tree settings.json keeps absolute paths"

  local out
  out="$(_reg_run "$_REG_HOME" sync_pull 2>&1)"
  assert_eq "0" "$(printf '%s' "$out" | grep -c 'skipping auto-pull')" \
    "REG: pull is not skipped after a push"
}

run_test_reg_pull_smudges_other_home() {
  _reg_setup
  trap "_reg_teardown" RETURN
  _reg_run "$_REG_HOME" sync_push "tokens" >/dev/null

  local other="$_REG_ROOT/other"
  _reg_init_clone "$other"
  _reg_run "$other" paths_filter_setup
  git -C "$other/.claude" pull -q origin main 2>/dev/null

  assert_contains "$(cat "$other/.claude/settings.json")" "$other/.claude/hooks/a.py" \
    "REG: pull on another machine resolves tokens to its own HOME"
  assert_contains "$(cat "$other/.claude/settings.json")" "$other/.bun/bin/bun" \
    "REG: __HOME__ token resolved on another machine"
}

run_test_reg_remote_wins_on_conflict() {
  _reg_setup
  trap "_reg_teardown" RETURN

  local other="$_REG_ROOT/other"
  git clone -q "$_REG_REMOTE" "$other/.claude" 2>/dev/null
  echo "REMOTE" > "$other/.claude/CLAUDE.md"
  git -C "$other/.claude" -c user.email=o@o -c user.name=o commit -qam remote
  git -C "$other/.claude" push -q 2>/dev/null

  echo "LOCAL" > "$_REG_HOME/.claude/CLAUDE.md"
  git -C "$_REG_HOME/.claude" commit -qam local
  _reg_run "$_REG_HOME" sync_pull >/dev/null

  assert_eq "REMOTE" "$(cat "$_REG_HOME/.claude/CLAUDE.md")" \
    "REG: conflicting hunk resolved in favour of remote"
}

run_test_reg_encryption_leaks_nothing() {
  _reg_setup
  trap "_reg_teardown" RETURN
  local ch="$_REG_HOME/.claude"

  echo '{}' > "$ch/settings.template.json"
  git -C "$ch" add settings.template.json && git -C "$ch" commit -qm tpl
  _reg_run "$_REG_HOME" cmd_encrypt enable
  _reg_run "$_REG_HOME" cmd_encrypt rotate
  _reg_run "$_REG_HOME" sync_push "encrypted" >/dev/null

  local tree
  tree="$(git -C "$ch" ls-tree -r --name-only HEAD)"
  assert_eq "0" "$(printf '%s\n' "$tree" | grep -c 'encryption.key')" \
    "REG: no encryption key (or rotated backup) in pushed tree"
  assert_eq "0" "$(printf '%s\n' "$tree" | grep -cx 'settings.json')" \
    "REG: plaintext settings.json untracked under encryption"
  assert_eq "0" "$(printf '%s\n' "$tree" | grep -cx 'settings.template.json')" \
    "REG: settings.template.json untracked under encryption"
  assert_eq "1" "$(printf '%s\n' "$tree" | grep -cx 'settings.json.enc')" \
    "REG: settings.json.enc committed"
  assert_eq "" "$(git -C "$ch" status --porcelain --untracked-files=no)" \
    "REG: clean tree after encrypted push"

  local before after
  before="$(git -C "$ch" rev-parse HEAD)"
  _reg_run "$_REG_HOME" sync_push "again" >/dev/null
  after="$(git -C "$ch" rev-parse HEAD)"
  assert_eq "$before" "$after" \
    "REG: unchanged settings do not create a new encrypted commit"
}

run_test_reg_encrypted_pull_other_machine() {
  _reg_setup
  trap "_reg_teardown" RETURN
  local other="$_REG_ROOT/other"

  # Machine B tracks the plaintext version first
  git clone -q "$_REG_REMOTE" "$other/.claude" 2>/dev/null

  _reg_run "$_REG_HOME" cmd_encrypt enable
  _reg_run "$_REG_HOME" sync_push "encrypted" >/dev/null

  mkdir -p "$other/.claude/.kitsync"
  cp "$_REG_HOME/.claude/.kitsync/encryption.key" "$other/.claude/.kitsync/"
  _reg_run "$other" sync_pull >/dev/null

  assert_file_exists "$other/.claude/settings.json" \
    "REG: settings.json recreated from .enc on another machine"
  assert_contains "$(cat "$other/.claude/settings.json" 2>/dev/null)" "$other/.claude/hooks/a.py" \
    "REG: decrypted settings.json resolved to the other machine's HOME"
}

run_test_reg_gitignore_migration() {
  _reg_setup
  trap "_reg_teardown" RETURN
  local ch="$_REG_HOME/.claude"

  # Simulate a pre-1.1.3 allowlist and a tracked rotated key backup
  grep -v -e 'encryption.key' -e 'pending-notice' -e 'conflict_pending' \
    -e 'commands' -e 'skills/synced' "$ch/.gitignore" > "$ch/.gitignore.old"
  mv "$ch/.gitignore.old" "$ch/.gitignore"
  mkdir -p "$ch/.kitsync" "$ch/commands" "$ch/skills/synced/acct" "$ch/skills/mine"
  echo "# mine" > "$ch/skills/mine/SKILL.md"
  echo "# managed" > "$ch/skills/synced/acct/SKILL.md"
  echo old > "$ch/.kitsync/encryption.key.bak.1"
  echo notice > "$ch/.kitsync/pending-notice"
  git -C "$ch" add -A && git -C "$ch" commit -qm legacy
  echo "# cmd" > "$ch/commands/hello.md"

  _reg_run "$_REG_HOME" sync_push "migrate" >/dev/null

  local tree
  tree="$(git -C "$ch" ls-tree -r --name-only HEAD)"
  assert_eq "0" "$(printf '%s\n' "$tree" | grep -c -e 'encryption.key' -e 'pending-notice')" \
    "REG: machine-local .kitsync files untracked by migration"
  assert_eq "1" "$(printf '%s\n' "$tree" | grep -cx 'commands/hello.md')" \
    "REG: commands/ synced after migration"
  assert_eq "0" "$(printf '%s\n' "$tree" | grep -c '^skills/synced/')" \
    "REG: skills/synced/ (claude.ai account skills) untracked by migration"
  assert_eq "1" "$(printf '%s\n' "$tree" | grep -cx 'skills/mine/SKILL.md')" \
    "REG: user skills still synced"
  assert_file_exists "$ch/skills/synced/acct/SKILL.md" \
    "REG: skills/synced/ kept on disk (only untracked)"
}

run_test_reg_normalize_scope() {
  _reg_setup
  trap "_reg_teardown" RETURN
  local ch="$_REG_HOME/.claude"

  mkdir -p "$ch/projects/p"
  echo '{"p":"/Users/someone/.claude/x"}' > "$ch/projects/p/state.json"
  _reg_run "$_REG_HOME" normalize_paths

  assert_contains "$(cat "$ch/projects/p/state.json")" "/Users/someone/.claude/x" \
    "REG: normalize_paths leaves runtime json untouched"
}

run_test_reg_upgrade_never_downgrades() {
  # Load only _version_lt from the CLI (sourcing bin/ would run main)
  eval "$(awk '/^_version_lt\(\) \{/,/^\}/' "$_PROJECT_ROOT/bin/claude-kitsync")"

  local pair a b expected got
  for pair in "1.1.4:1.1.5:lt" "1.1.5:1.1.4:ge" "1.1.5:1.1.5:ge" \
              "1.1.9:1.1.10:lt" "1.10.0:1.9.0:ge" "0.0.0:1.1.5:lt" "1.2.0-rc1:1.2.0:ge"; do
    IFS=: read -r a b expected <<< "$pair"
    if _version_lt "$a" "$b"; then got=lt; else got=ge; fi
    assert_eq "$expected" "$got" "REG: version $a vs $b → $expected (upgrade never downgrades)"
  done
}

run_test_reg_brew_install_detection() {
  # upgrade/uninstall must hand over to brew instead of touching its Cellar
  eval "$(awk '/^_installed_via_brew\(\) \{/,/^\}/' "$_PROJECT_ROOT/bin/claude-kitsync")"

  local root expected got
  for root in \
      "/opt/homebrew/Cellar/claude-kitsync/1.1.8/libexec:brew" \
      "/home/linuxbrew/.linuxbrew/Cellar/claude-kitsync/1.1.8/libexec:brew" \
      "$HOME/.local/share/kitsync:script" \
      "/opt/homebrew/Cellar/other-tool/1.0/libexec:script"; do
    expected="${root##*:}"
    KITSYNC_ROOT="${root%:*}"
    if _installed_via_brew; then got=brew; else got=script; fi
    assert_eq "$expected" "$got" "REG: ${root%:*} detected as $expected install"
  done
  unset KITSYNC_ROOT
}

run_test_reg_install_sh_rerun() {
  # Offline re-run of install.sh over an existing kitsync setup: no prompt,
  # no duplicated rc lines, completion loaded from the install dir.
  local root home rc
  root="$(mktemp -d)"
  trap "rm -rf '$root'" RETURN
  home="$root/home"
  rc="$home/.zshrc"
  mkdir -p "$home/.claude/.kitsync"
  echo "KITSYNC_PULL_MODE=auto" > "$home/.claude/.kitsync/config"
  git -C "$home/.claude" init -q

  local i
  for i in 1 2; do
    HOME="$home" SHELL=/bin/zsh ZDOTDIR="" CLAUDE_HOME="$home/.claude" \
      KITSYNC_INSTALL_DIR="$_PROJECT_ROOT" bash "$_PROJECT_ROOT/install.sh" \
      </dev/null >/dev/null 2>&1
  done

  assert_eq "1" "$(grep -c '^# claude-kitsync PATH$' "$rc")" \
    "REG: install.sh re-run adds the PATH line once"
  assert_eq "1" "$(grep -c '^# claude-kitsync completion$' "$rc")" \
    "REG: install.sh re-run adds the completion block once"
  assert_contains "$(cat "$rc")" "fpath=(\"$_PROJECT_ROOT/completions\"" \
    "REG: zsh completion loaded from the install dir"
  assert_file_exists "$home/.local/bin/claude-kitsync" \
    "REG: binary linked into ~/.local/bin"

  # uninstall's rc cleanup removes the whole completion block
  # fresh process: the runner shell already sourced these libs (readonly vars)
  _REG_LIBS="$_PROJECT_ROOT/lib" bash -c '
    source "$_REG_LIBS/core.sh"
    source "$_REG_LIBS/wrapper.sh"
    set +e
    _remove_completion_from_rc "$1"
  ' _ "$rc" >/dev/null 2>&1
  assert_eq "0" "$(grep -c 'claude-kitsync completion\|compdef _claude-kitsync' "$rc")" \
    "REG: uninstall removes the completion block"
  assert_eq "1" "$(grep -c '^# claude-kitsync PATH$' "$rc")" \
    "REG: completion cleanup leaves the PATH line alone"
}

run_regressions_tests() {
  printf "\n=== test_regressions.sh (sync / encryption regressions) ===\n"
  export GIT_AUTHOR_NAME=kitsync-test GIT_AUTHOR_EMAIL=t@kitsync.local
  export GIT_COMMITTER_NAME=kitsync-test GIT_COMMITTER_EMAIL=t@kitsync.local
  run_test_reg_clean_after_push
  run_test_reg_pull_smudges_other_home
  run_test_reg_remote_wins_on_conflict
  run_test_reg_encryption_leaks_nothing
  run_test_reg_encrypted_pull_other_machine
  run_test_reg_gitignore_migration
  run_test_reg_normalize_scope
  run_test_reg_upgrade_never_downgrades
  run_test_reg_install_sh_rerun
  run_test_reg_brew_install_detection
}
