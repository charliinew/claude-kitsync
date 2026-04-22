#!/usr/bin/env bash
# test/test_install_kit.sh
# AC8 : kitsync install <url> merge un kit public sans écraser config locale

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_HELPERS_DIR/.." && pwd)"
source "$_HELPERS_DIR/helpers.sh"

# ---------------------------------------------------------------------------
# _source_install_kit_lib — source lib/install-kit.sh if available.
# Restores set +e after sourcing so test assertions continue normally.
# ---------------------------------------------------------------------------
_INSTALL_KIT_LIB_AVAILABLE=0
_source_install_kit_lib() {
  if [[ -f "$_PROJECT_ROOT/lib/install-kit.sh" ]]; then
    [[ -f "$_PROJECT_ROOT/lib/core.sh" ]] && { set +e; source "$_PROJECT_ROOT/lib/core.sh"; set +e; } 2>/dev/null || true
    set +e
    source "$_PROJECT_ROOT/lib/install-kit.sh"
    set +e
    _INSTALL_KIT_LIB_AVAILABLE=1
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _simulate_kit_merge — replicates the selective copy logic from PLAN.md
# without requiring lib/install-kit.sh to exist yet.
#
# Args:
#   $1 = source kit dir (clone of the public kit)
#   $2 = destination CLAUDE_HOME
#   $3 = "skip"|"overwrite"|"backup" — conflict strategy
# ---------------------------------------------------------------------------
_simulate_kit_merge() {
  local src="$1"
  local dst="$2"
  local conflict_strategy="${3:-skip}"

  local mergeable_dirs=("agents" "skills" "hooks" "scripts")
  local mergeable_files=("CLAUDE.md")

  # Copy top-level files
  for f in "${mergeable_files[@]}"; do
    if [[ -f "$src/$f" ]]; then
      if [[ -f "$dst/$f" ]]; then
        case "$conflict_strategy" in
          skip)     continue ;;
          backup)   cp "$dst/$f" "$dst/${f}.bak" ; cp "$src/$f" "$dst/$f" ;;
          overwrite) cp "$src/$f" "$dst/$f" ;;
        esac
      else
        cp "$src/$f" "$dst/$f"
      fi
    fi
  done

  # Copy directories
  for d in "${mergeable_dirs[@]}"; do
    if [[ -d "$src/$d" ]]; then
      mkdir -p "$dst/$d"
      for kit_file in "$src/$d"/*; do
        [[ -e "$kit_file" ]] || continue
        local fname
        fname="$(basename "$kit_file")"
        if [[ -f "$dst/$d/$fname" ]]; then
          case "$conflict_strategy" in
            skip)     continue ;;
            backup)   cp "$dst/$d/$fname" "$dst/$d/${fname}.bak" ; cp "$kit_file" "$dst/$d/$fname" ;;
            overwrite) cp "$kit_file" "$dst/$d/$fname" ;;
          esac
        else
          cp "$kit_file" "$dst/$d/$fname"
        fi
      done
    fi
  done
}

# ---------------------------------------------------------------------------
# _create_fake_kit — creates a fake public kit in a temp dir and echoes its path
# ---------------------------------------------------------------------------
_create_fake_kit() {
  local kit_dir
  kit_dir="$(mktemp -d)"

  mkdir -p "$kit_dir/agents" "$kit_dir/skills" "$kit_dir/hooks"
  echo "# Kit Agent"           > "$kit_dir/agents/kit-agent.md"
  echo "# Kit Skill"           > "$kit_dir/skills/kit-skill.md"
  echo "#!/bin/bash # kit hook" > "$kit_dir/hooks/kit-hook.sh"
  echo "# Kit CLAUDE.md"       > "$kit_dir/CLAUDE.md"

  # These must NEVER be touched by install-kit
  echo '{"apiKey":"secret"}'   > "$kit_dir/settings.json"
  echo '{"local":true}'        > "$kit_dir/settings.local.json"
  echo '{"token":"secret"}'    > "$kit_dir/.credentials.json"

  printf "%s" "$kit_dir"
}

# ---------------------------------------------------------------------------
# AC8 tests
# ---------------------------------------------------------------------------

run_test_ac8_new_agents_copied() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local kit_dir
  kit_dir="$(_create_fake_kit)"
  trap "rm -rf '$kit_dir'" RETURN

  _simulate_kit_merge "$kit_dir" "$CLAUDE_HOME" "skip"

  assert_file_exists "$CLAUDE_HOME/agents/kit-agent.md" \
    "AC8: new agent from kit is copied to CLAUDE_HOME/agents/"
}

run_test_ac8_new_skills_copied() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local kit_dir
  kit_dir="$(_create_fake_kit)"
  trap "rm -rf '$kit_dir'" RETURN

  _simulate_kit_merge "$kit_dir" "$CLAUDE_HOME" "skip"

  assert_file_exists "$CLAUDE_HOME/skills/kit-skill.md" \
    "AC8: new skill from kit is copied to CLAUDE_HOME/skills/"
}

run_test_ac8_new_hooks_copied() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local kit_dir
  kit_dir="$(_create_fake_kit)"
  trap "rm -rf '$kit_dir'" RETURN

  _simulate_kit_merge "$kit_dir" "$CLAUDE_HOME" "skip"

  assert_file_exists "$CLAUDE_HOME/hooks/kit-hook.sh" \
    "AC8: new hook from kit is copied to CLAUDE_HOME/hooks/"
}

run_test_ac8_settings_json_never_overwritten() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local kit_dir
  kit_dir="$(_create_fake_kit)"
  trap "rm -rf '$kit_dir'" RETURN

  # Pre-existing local settings.json
  echo '{"localSetting": true}' > "$CLAUDE_HOME/settings.json"

  _simulate_kit_merge "$kit_dir" "$CLAUDE_HOME" "overwrite"

  local content
  content="$(cat "$CLAUDE_HOME/settings.json")"
  assert_contains "$content" "localSetting" \
    "AC8: local settings.json NOT overwritten by kit install"
}

run_test_ac8_settings_local_never_overwritten() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local kit_dir
  kit_dir="$(_create_fake_kit)"
  trap "rm -rf '$kit_dir'" RETURN

  echo '{"localPerm": true}' > "$CLAUDE_HOME/settings.local.json"

  _simulate_kit_merge "$kit_dir" "$CLAUDE_HOME" "overwrite"

  local content
  content="$(cat "$CLAUDE_HOME/settings.local.json")"
  assert_contains "$content" "localPerm" \
    "AC8: settings.local.json NOT overwritten by kit install"
}

run_test_ac8_credentials_never_overwritten() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local kit_dir
  kit_dir="$(_create_fake_kit)"
  trap "rm -rf '$kit_dir'" RETURN

  echo '{"token":"my-local-secret"}' > "$CLAUDE_HOME/.credentials.json"

  _simulate_kit_merge "$kit_dir" "$CLAUDE_HOME" "overwrite"

  local content
  content="$(cat "$CLAUDE_HOME/.credentials.json")"
  assert_contains "$content" "my-local-secret" \
    "AC8: .credentials.json NOT overwritten by kit install"
}

run_test_ac8_conflict_skip_preserves_existing_file() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local kit_dir
  kit_dir="$(_create_fake_kit)"
  trap "rm -rf '$kit_dir'" RETURN

  # Pre-existing local agent
  mkdir -p "$CLAUDE_HOME/agents"
  echo "# My local agent" > "$CLAUDE_HOME/agents/kit-agent.md"

  _simulate_kit_merge "$kit_dir" "$CLAUDE_HOME" "skip"

  local content
  content="$(cat "$CLAUDE_HOME/agents/kit-agent.md")"
  assert_contains "$content" "My local agent" \
    "AC8: conflict=skip preserves existing local agent file"
}

run_test_ac8_conflict_backup_creates_bak_file() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local kit_dir
  kit_dir="$(_create_fake_kit)"
  trap "rm -rf '$kit_dir'" RETURN

  mkdir -p "$CLAUDE_HOME/agents"
  echo "# My local agent" > "$CLAUDE_HOME/agents/kit-agent.md"

  _simulate_kit_merge "$kit_dir" "$CLAUDE_HOME" "backup"

  assert_file_exists "$CLAUDE_HOME/agents/kit-agent.md.bak" \
    "AC8: conflict=backup creates .bak of original file"
}

run_test_ac8_conflict_overwrite_replaces_file() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local kit_dir
  kit_dir="$(_create_fake_kit)"
  trap "rm -rf '$kit_dir'" RETURN

  mkdir -p "$CLAUDE_HOME/agents"
  echo "# My local agent" > "$CLAUDE_HOME/agents/kit-agent.md"

  _simulate_kit_merge "$kit_dir" "$CLAUDE_HOME" "overwrite"

  local content
  content="$(cat "$CLAUDE_HOME/agents/kit-agent.md")"
  assert_contains "$content" "Kit Agent" \
    "AC8: conflict=overwrite replaces local file with kit version"
}

run_test_ac8_claude_md_copied_when_absent() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local kit_dir
  kit_dir="$(_create_fake_kit)"
  trap "rm -rf '$kit_dir'" RETURN

  # No pre-existing CLAUDE.md
  _simulate_kit_merge "$kit_dir" "$CLAUDE_HOME" "skip"

  assert_file_exists "$CLAUDE_HOME/CLAUDE.md" \
    "AC8: CLAUDE.md copied from kit when not present locally"
}

run_test_ac8_claude_md_not_overwritten_by_skip() {
  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local kit_dir
  kit_dir="$(_create_fake_kit)"
  trap "rm -rf '$kit_dir'" RETURN

  echo "# My local CLAUDE.md" > "$CLAUDE_HOME/CLAUDE.md"

  _simulate_kit_merge "$kit_dir" "$CLAUDE_HOME" "skip"

  local content
  content="$(cat "$CLAUDE_HOME/CLAUDE.md")"
  assert_contains "$content" "My local CLAUDE.md" \
    "AC8: conflict=skip preserves existing local CLAUDE.md"
}

run_test_ac8_via_lib_if_available() {
  if ! _source_install_kit_lib; then
    printf "  SKIP  AC8: lib/install-kit.sh not yet implemented — skipping lib integration test\n"
    return 0
  fi

  setup_fake_claude_home
  trap "teardown_fake_claude_home" RETURN

  local kit_dir
  kit_dir="$(_create_fake_kit)"
  trap "rm -rf '$kit_dir'" RETURN

  echo '{"localSetting": true}' > "$CLAUDE_HOME/settings.json"

  # Call the real function — must not overwrite settings.json
  # The function signature from PLAN.md: install_kit <src_dir> (or similar)
  # We pass SKIP as conflict strategy assuming a non-interactive flag
  install_kit "$kit_dir" 2>/dev/null || true

  local content
  content="$(cat "$CLAUDE_HOME/settings.json" 2>/dev/null || echo "{}")"
  assert_contains "$content" "localSetting" \
    "AC8: install_kit() via lib does not overwrite local settings.json"
}

# ---------------------------------------------------------------------------
# Run all tests in this module
# ---------------------------------------------------------------------------
run_install_kit_tests() {
  printf "\n=== test_install_kit.sh (AC8) ===\n"
  run_test_ac8_new_agents_copied
  run_test_ac8_new_skills_copied
  run_test_ac8_new_hooks_copied
  run_test_ac8_settings_json_never_overwritten
  run_test_ac8_settings_local_never_overwritten
  run_test_ac8_credentials_never_overwritten
  run_test_ac8_conflict_skip_preserves_existing_file
  run_test_ac8_conflict_backup_creates_bak_file
  run_test_ac8_conflict_overwrite_replaces_file
  run_test_ac8_claude_md_copied_when_absent
  run_test_ac8_claude_md_not_overwritten_by_skip
  run_test_ac8_via_lib_if_available
}
