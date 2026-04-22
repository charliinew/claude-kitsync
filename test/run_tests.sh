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
  *)
    printf "Unknown filter '%s'. Valid: all, gitignore, paths, sync, install, idempotent\n" "$_FILTER" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Print summary and exit with appropriate code
# ---------------------------------------------------------------------------
print_summary
