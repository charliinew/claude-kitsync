#!/usr/bin/env bash
# test/helpers.sh — shared utilities for the kitsync test suite
# No external deps. Pure bash. Source this file from each test_*.sh module.

# ---------------------------------------------------------------------------
# Test counters (global, accumulated across all sourced modules)
# ---------------------------------------------------------------------------
_TESTS_RUN=0
_TESTS_PASSED=0
_TESTS_FAILED=0
_FAILED_NAMES=()

# ---------------------------------------------------------------------------
# pass / fail — internal bookkeeping
# ---------------------------------------------------------------------------
_pass() {
  local name="$1"
  _TESTS_RUN=$(( _TESTS_RUN + 1 ))
  _TESTS_PASSED=$(( _TESTS_PASSED + 1 ))
  printf "  PASS  %s\n" "$name"
}

_fail() {
  local name="$1"
  local reason="${2:-}"
  _TESTS_RUN=$(( _TESTS_RUN + 1 ))
  _TESTS_FAILED=$(( _TESTS_FAILED + 1 ))
  _FAILED_NAMES+=("$name")
  printf "  FAIL  %s" "$name"
  if [[ -n "$reason" ]]; then
    printf " — %s" "$reason"
  fi
  printf "\n"
}

# ---------------------------------------------------------------------------
# assert_eq <expected> <actual> <test_name>
# ---------------------------------------------------------------------------
assert_eq() {
  local expected="$1"
  local actual="$2"
  local name="$3"
  if [[ "$expected" == "$actual" ]]; then
    _pass "$name"
  else
    _fail "$name" "expected='$expected' got='$actual'"
  fi
}

# ---------------------------------------------------------------------------
# assert_not_eq <unexpected> <actual> <test_name>
# ---------------------------------------------------------------------------
assert_not_eq() {
  local unexpected="$1"
  local actual="$2"
  local name="$3"
  if [[ "$unexpected" != "$actual" ]]; then
    _pass "$name"
  else
    _fail "$name" "value should not be '$unexpected'"
  fi
}

# ---------------------------------------------------------------------------
# assert_contains <haystack> <needle> <test_name>
# ---------------------------------------------------------------------------
assert_contains() {
  local haystack="$1"
  local needle="$2"
  local name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    _pass "$name"
  else
    _fail "$name" "'$needle' not found in output"
  fi
}

# ---------------------------------------------------------------------------
# assert_file_exists <path> <test_name>
# ---------------------------------------------------------------------------
assert_file_exists() {
  local path="$1"
  local name="$2"
  if [[ -f "$path" ]]; then
    _pass "$name"
  else
    _fail "$name" "file not found: $path"
  fi
}

# ---------------------------------------------------------------------------
# assert_dir_exists <path> <test_name>
# ---------------------------------------------------------------------------
assert_dir_exists() {
  local path="$1"
  local name="$2"
  if [[ -d "$path" ]]; then
    _pass "$name"
  else
    _fail "$name" "directory not found: $path"
  fi
}

# ---------------------------------------------------------------------------
# assert_file_not_exists <path> <test_name>
# ---------------------------------------------------------------------------
assert_file_not_exists() {
  local path="$1"
  local name="$2"
  if [[ ! -f "$path" ]]; then
    _pass "$name"
  else
    _fail "$name" "file should not exist: $path"
  fi
}

# ---------------------------------------------------------------------------
# assert_zero <value> <test_name>   — asserts exit code is 0
# assert_nonzero <value> <test_name> — asserts exit code is non-zero
# ---------------------------------------------------------------------------
assert_zero() {
  local code="$1"
  local name="$2"
  if [[ "$code" -eq 0 ]]; then
    _pass "$name"
  else
    _fail "$name" "expected exit 0, got $code"
  fi
}

assert_nonzero() {
  local code="$1"
  local name="$2"
  if [[ "$code" -ne 0 ]]; then
    _pass "$name"
  else
    _fail "$name" "expected non-zero exit, got 0"
  fi
}

# ---------------------------------------------------------------------------
# setup_fake_claude_home — creates an isolated tmp dir that mimics ~/.claude
# Sets: CLAUDE_HOME, _TEST_TMPDIR (for cleanup)
# Call teardown_fake_claude_home when done.
# ---------------------------------------------------------------------------
setup_fake_claude_home() {
  _TEST_TMPDIR="$(mktemp -d)"
  CLAUDE_HOME="$_TEST_TMPDIR/claude"
  mkdir -p "$CLAUDE_HOME"
  export CLAUDE_HOME
}

teardown_fake_claude_home() {
  if [[ -n "${_TEST_TMPDIR:-}" && -d "$_TEST_TMPDIR" ]]; then
    rm -rf "$_TEST_TMPDIR"
  fi
  unset CLAUDE_HOME _TEST_TMPDIR
}

# ---------------------------------------------------------------------------
# setup_git_claude_home — like setup_fake_claude_home but also runs git init
# and creates a minimal .gitignore from the project template.
# ---------------------------------------------------------------------------
setup_git_claude_home() {
  setup_fake_claude_home

  local project_root
  project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  git -C "$CLAUDE_HOME" init -q
  git -C "$CLAUDE_HOME" config user.email "test@kitsync.local"
  git -C "$CLAUDE_HOME" config user.name "kitsync-test"

  # Copy .gitignore template if it exists; otherwise create a minimal one
  if [[ -f "$project_root/templates/.gitignore.template" ]]; then
    cp "$project_root/templates/.gitignore.template" "$CLAUDE_HOME/.gitignore"
  else
    # Minimal allowlist matching PLAN.md spec — used when template not yet created
    cat > "$CLAUDE_HOME/.gitignore" << 'GITIGNORE'
# claude-kitsync — allowlist strict
*
!*/

# Config shareable
!settings.json
!CLAUDE.md

# Répertoires synchronisés
!agents/
!agents/**
!skills/
!skills/**
!hooks/
!hooks/**
!scripts/
!scripts/**
!rules/
!rules/**

# Méta
!.gitignore
!.kitsync/
!.kitsync/**

# JAMAIS syncé (explicite)
.credentials.json
projects/
backups/
cache/
file-history/
paste-cache/
shell-snapshots/
session-env/
sessions/
tasks/
telemetry/
stats-cache.json
history.jsonl
GITIGNORE
  fi
}

# ---------------------------------------------------------------------------
# make_dirty_tree — stages an uncommitted change in CLAUDE_HOME
# ---------------------------------------------------------------------------
make_dirty_tree() {
  # Create an initial commit so HEAD exists
  echo "initial" > "$CLAUDE_HOME/settings.json"
  git -C "$CLAUDE_HOME" add settings.json
  git -C "$CLAUDE_HOME" commit -q -m "initial"

  # Now modify a tracked file without committing
  echo "dirty change" >> "$CLAUDE_HOME/settings.json"
}

# ---------------------------------------------------------------------------
# make_clean_tree — ensures CLAUDE_HOME has a clean working tree
# ---------------------------------------------------------------------------
make_clean_tree() {
  echo "initial" > "$CLAUDE_HOME/settings.json"
  git -C "$CLAUDE_HOME" add settings.json
  git -C "$CLAUDE_HOME" commit -q -m "initial"
  # No pending changes
}

# ---------------------------------------------------------------------------
# print_summary — prints overall pass/fail counts; returns 1 if any failures
# ---------------------------------------------------------------------------
print_summary() {
  printf "\n%s\n" "----------------------------------------"
  printf "Results: %d run, %d passed, %d failed\n" \
    "$_TESTS_RUN" "$_TESTS_PASSED" "$_TESTS_FAILED"
  if [[ ${#_FAILED_NAMES[@]} -gt 0 ]]; then
    printf "Failed tests:\n"
    for n in "${_FAILED_NAMES[@]}"; do
      printf "  - %s\n" "$n"
    done
    printf "%s\n" "----------------------------------------"
    return 1
  fi
  printf "%s\n" "----------------------------------------"
  return 0
}
