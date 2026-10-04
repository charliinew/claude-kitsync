#!/usr/bin/env bash
# test/run_tests.sh — main test runner for claude-kitsync
#
# Usage:
#   bash test/run_tests.sh           # run all modules
#   bash test/run_tests.sh gitignore # run only test_gitignore.sh
#
# Exit code: 0 if all tests pass, 1 if any fail.

# Note: intentionally no 'set -e' — test functions return non-zero to signal
# "ignored" / "not found" and those results are handled by assert_* helpers.
set -uo pipefail

_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_RUNNER_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Safety: ensure we never pollute the real ~/.claude
# ---------------------------------------------------------------------------
if [[ -z "${CLAUDE_HOME:-}" ]]; then
  # Not yet set — leave it unset; each test module sets its own via helpers.sh
  : # no-op
fi
# Tests fake $HOME, but rc-file lookups use ${ZDOTDIR:-$HOME}: an inherited
# ZDOTDIR would point them at the developer's real ~/.zshrc
unset ZDOTDIR

# ---------------------------------------------------------------------------
# Source helpers (counters must be global for the runner to see final totals)
# ---------------------------------------------------------------------------
source "$_RUNNER_DIR/helpers.sh"

# ---------------------------------------------------------------------------
# Source test modules (each registers a run_*_tests function)
# ---------------------------------------------------------------------------
source "$_RUNNER_DIR/test_gitignore.sh"
source "$_RUNNER_DIR/test_paths.sh"
source "$_RUNNER_DIR/test_sync.sh"
source "$_RUNNER_DIR/test_install_kit.sh"
source "$_RUNNER_DIR/test_idempotent.sh"
source "$_RUNNER_DIR/test_wrapper.sh"
source "$_RUNNER_DIR/test_regressions.sh"
source "$_RUNNER_DIR/test_upgrade.sh"
source "$_RUNNER_DIR/test_uninstall.sh"
source "$_RUNNER_DIR/test_doctor.sh"
source "$_RUNNER_DIR/test_init.sh"
source "$_RUNNER_DIR/test_kit.sh"
source "$_RUNNER_DIR/test_autosync.sh"
source "$_RUNNER_DIR/test_hooks.sh"
source "$_RUNNER_DIR/test_push.sh"
source "$_RUNNER_DIR/test_pull.sh"
source "$_RUNNER_DIR/test_selective.sh"
source "$_RUNNER_DIR/test_consult.sh"
source "$_RUNNER_DIR/test_encrypt.sh"
source "$_RUNNER_DIR/test_profiles.sh"
source "$_RUNNER_DIR/test_restore.sh"
source "$_RUNNER_DIR/test_publish.sh"

# Some sourced lib files (lib/core.sh, lib/wrapper.sh) call set -euo pipefail,
# which activates -e in this shell. Re-disable it — the runner intentionally
# has no -e so that test functions can return non-zero without aborting the run.
set +e

# ---------------------------------------------------------------------------
# Determine which modules to run
# ---------------------------------------------------------------------------
_FILTER="${1:-all}"

printf "\nkitsync test suite\n"
printf "Project root: %s\n" "$_PROJECT_ROOT"
printf "Filter: %s\n" "$_FILTER"

case "$_FILTER" in
  all|"")
    run_gitignore_tests
    run_paths_tests
    run_sync_tests
    run_install_kit_tests
    run_idempotent_tests
    run_wrapper_tests
    run_regressions_tests
    run_upgrade_tests
    run_uninstall_tests
    run_doctor_tests
    run_init_tests
    run_kit_tests
    run_autosync_tests
    run_hooks_tests
    run_push_tests
    run_pull_tests
    run_selective_tests
    run_consult_tests
    run_encrypt_tests
    run_profiles_tests
    run_restore_tests
    run_publish_tests
    ;;
  gitignore)
    run_gitignore_tests
    ;;
  paths)
    run_paths_tests
    ;;
  sync)
    run_sync_tests
    ;;
  install|install_kit|kit)
    run_install_kit_tests
    ;;
  idempotent)
    run_idempotent_tests
    ;;
  wrapper)
    run_wrapper_tests
    ;;
  regressions)
    run_regressions_tests
    ;;
  upgrade)
    run_upgrade_tests
    ;;
  uninstall)
    run_uninstall_tests
    ;;
  doctor)
    run_doctor_tests
    ;;
  init)
    run_init_tests
    ;;
  starter)
    run_kit_tests
    ;;
  autosync)
    run_autosync_tests
    ;;
  hooks)
    run_hooks_tests
    ;;
  push)
    run_push_tests
    ;;
  pull)
    run_pull_tests
    ;;
  selective)
    run_selective_tests
    ;;
  consult)
    run_consult_tests
    ;;
  encrypt)
    run_encrypt_tests
    ;;
  profiles)
    run_profiles_tests
    ;;
  restore)
    run_restore_tests
    ;;
  publish)
    run_publish_tests
    ;;
  *)
    printf "Unknown filter '%s'. Valid: all, gitignore, paths, sync, install, idempotent, wrapper, regressions, upgrade, uninstall, doctor, init, starter, autosync, hooks, push, pull, selective, consult, encrypt, profiles, restore, publish\n" "$_FILTER" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Print summary and exit with appropriate code
# ---------------------------------------------------------------------------
print_summary
