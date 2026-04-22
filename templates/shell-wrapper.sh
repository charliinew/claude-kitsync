#!/usr/bin/env bash
# templates/shell-wrapper.sh
#
# This is a standalone template for the claude() shell function.
# It is sourced/embedded by lib/wrapper.sh into ~/.zshrc or ~/.bashrc.
#
# Variables substituted at install time:
#   KITSYNC_TIMEOUT  — pull timeout in seconds (default: 2)
#
# The function is compatible with both zsh and bash.
#
# DO NOT source this file directly — use `kitsync init` to install it.

# kitsync-start
# This block is managed by kitsync — do not edit manually.
# To update: run `kitsync init` or remove the block and re-run.
claude() {
  # Resolve CLAUDE_HOME at call time (allows per-session override)
  local _ks_home="${CLAUDE_HOME:-$HOME/.claude}"
  local _ks_timeout="${KITSYNC_TIMEOUT:-2}"

  # Background pull: only if CLAUDE_HOME is a valid git repo
  if [[ -d "$_ks_home" ]] && git -C "$_ks_home" rev-parse --git-dir &>/dev/null 2>&1; then
    (
      # Pull with timeout — silent on failure (network issues are non-blocking)
      timeout "$_ks_timeout" git -C "$_ks_home" pull --rebase --autostash -q 2>/dev/null

      # Post-pull hook: normalise absolute paths in settings.json
      if command -v kitsync &>/dev/null; then
        kitsync _post-pull-hook 2>/dev/null || true
      fi
    ) &
    disown
  fi

  # Invoke the real claude binary — never a recursive call
  command claude "$@"
}
# kitsync-end
