#!/usr/bin/env bash
# lib/wrapper.sh — Shell wrapper generator and installer for ~/.zshrc / ~/.bashrc
set -euo pipefail

readonly WRAPPER_START_MARKER="# kitsync-start"
readonly WRAPPER_END_MARKER="# kitsync-end"

# ---------------------------------------------------------------------------
# generate_wrapper — outputs the claude() shell function text.
# Reads KITSYNC_PULL_MODE / KITSYNC_PUSH_MODE / KITSYNC_PUSH_TIMER from
# $CLAUDE_HOME/.kitsync/config at runtime — no re-install needed after
# changing sync preferences.
# ---------------------------------------------------------------------------
generate_wrapper() {
  cat <<'WRAPPER_BODY'
# kitsync-start
# This block is managed by claude-kitsync — do not edit manually.
# To update: run `claude-kitsync init` again or edit ~/.zshrc after this block.
claude() {
  # Suppress job PID/Done notifications for background sync ops.
  # LOCAL_OPTIONS scopes the change to this function only (zsh restores on exit).
  [[ -n "${ZSH_VERSION:-}" ]] && setopt LOCAL_OPTIONS NO_MONITOR NO_NOTIFY 2>/dev/null || true

  # Not a session (version, help, updates, MCP/config management): no sync
  case "${1:-}" in
    -v|--version|-h|--help|update|install|doctor|mcp|config|plugin|migrate-installer|setup-token)
      command claude "$@"
      return
      ;;
  esac

  local _ks_home="${CLAUDE_HOME:-$HOME/.claude}"
  local _ks_cfg="$_ks_home/.kitsync/config"

  # Load sync preferences (defaults: auto pull, end-of-session push)
  local _ks_pull="auto" _ks_push="end_of_session" _ks_timer="15" _v
  if [[ -f "$_ks_cfg" || -f "$_ks_home/.kitsync/local" ]]; then
    _v="$(grep -h '^KITSYNC_PULL_MODE=' "$_ks_home/.kitsync/local" "$_ks_cfg" 2>/dev/null | head -1 | cut -d= -f2-)" && [[ -n "$_v" ]] && _ks_pull="$_v"
    _v="$(grep -h '^KITSYNC_PUSH_MODE=' "$_ks_home/.kitsync/local" "$_ks_cfg" 2>/dev/null | head -1 | cut -d= -f2-)" && [[ -n "$_v" ]] && _ks_push="$_v"
    _v="$(grep -h '^KITSYNC_PUSH_TIMER=' "$_ks_home/.kitsync/local" "$_ks_cfg" 2>/dev/null | head -1 | cut -d= -f2-)" && [[ -n "$_v" ]] && _ks_timer="$_v"
  fi
  [[ "$_ks_timer" =~ ^[0-9]+$ ]] && [[ "$_ks_timer" -gt 0 ]] || _ks_timer=15

  local _ks_on=false
  [[ -d "$_ks_home/.git" ]] && command -v claude-kitsync &>/dev/null && _ks_on=true

  # _ks_bg <cmd...> — run silently in the background, detached from this shell.
  # Backgrounded inside a subshell: the job belongs to the subshell, so neither
  # bash nor zsh prints a PID or "Done" (zsh's `&!` is a syntax error in bash).
  _ks_bg() {
    ("$@" >/dev/null 2>&1 &)
  }

  # Notices left by background syncs
  local _ks_cf="$_ks_home/.kitsync/conflict_pending"
  if [[ -f "$_ks_cf" ]]; then
    printf "\n\033[33m⚠  kitsync: sync conflict pending\033[0m\n" >&2
    _v="$(grep '^files:' "$_ks_cf" 2>/dev/null | cut -d: -f2-)"
    [[ -n "$_v" ]] && printf "   Conflicting: %s\n" "$_v" >&2
    printf "   Choose file by file:  claude-kitsync pull\n" >&2
    printf "   Take the remote:      claude-kitsync pull --force  (local versions backed up)\n\n" >&2
  fi
  local _ks_warn="$_ks_home/.kitsync/sync-warning"
  if [[ -f "$_ks_warn" ]]; then
    printf '\n\033[1;33m[kitsync]\033[0m  %s\n\n' "$(cat "$_ks_warn" 2>/dev/null)" >&2
    rm -f "$_ks_warn" 2>/dev/null || true
  fi
  local _ks_notice="$_ks_home/.kitsync/pending-notice"
  if [[ -f "$_ks_notice" ]]; then
    printf '\n\033[1;33m[kitsync]\033[0m  Config updated from remote — settings or agents may have changed.\n\n' >&2
    rm -f "$_ks_notice" 2>/dev/null || true
  fi

  # Auto-pull on launch: the real pull logic (selective sync, decryption,
  # conflicts), non-blocking; it never touches uncommitted local changes
  if [[ "$_ks_on" == true ]] && [[ "$_ks_pull" == "auto" ]]; then
    _ks_bg claude-kitsync pull --auto
  fi

  # Timer push: stops when the session ends (sentinel removed) or when this
  # shell is gone (terminal closed before the session ended)
  local _ks_sentinel=""
  if [[ "$_ks_on" == true ]] && [[ "$_ks_push" == "timer" ]]; then
    _ks_sentinel="$(mktemp "${TMPDIR:-/tmp}/kitsync-timer.XXXXXX" 2>/dev/null || true)"
    _ks_timer_loop() {
      while sleep "$(( $2 * 60 ))"; do
        [[ -f "$1" ]] && kill -0 "$3" 2>/dev/null || break
        claude-kitsync push --auto "kitsync: auto-push $(date '+%Y-%m-%d %H:%M')"
      done
      rm -f "$1"
    }
    [[ -n "$_ks_sentinel" ]] && _ks_bg _ks_timer_loop "$_ks_sentinel" "$_ks_timer" "$$"
  fi

  # Safety net: if settings.json still contains __CLAUDE_HOME__ / __HOME__ tokens
  # (e.g. a push interrupted between tokenize and detokenize), fix them before
  # launching Claude so hooks receive real paths.
  local _ks_settings="$_ks_home/settings.json" _ks_tok _ks_val
  for _ks_tok in __CLAUDE_HOME__ __HOME__; do
    [[ -f "$_ks_settings" ]] && grep -qF "$_ks_tok" "$_ks_settings" 2>/dev/null || continue
    [[ "$_ks_tok" == __HOME__ ]] && _ks_val="$HOME" || _ks_val="$_ks_home"
    _ks_val="$(printf '%s' "$_ks_val" | sed 's|[&\\|]|\\&|g')"
    if [[ "$(uname -s)" == "Darwin" ]]; then
      sed -i '' "s|${_ks_tok}|${_ks_val}|g" "$_ks_settings" 2>/dev/null || true
    else
      sed -i "s|${_ks_tok}|${_ks_val}|g" "$_ks_settings" 2>/dev/null || true
    fi
  done

  # Run the real claude binary
  command claude "$@"
  local _ks_exit=$?

  # Stop timer loop
  [[ -n "$_ks_sentinel" ]] && rm -f "$_ks_sentinel" 2>/dev/null

  # End-of-session push (background, non-blocking; waits for a running pull)
  if [[ "$_ks_on" == true ]] && [[ "$_ks_push" == "end_of_session" ]]; then
    _ks_bg claude-kitsync push --auto "kitsync: auto-push $(date '+%Y-%m-%d %H:%M')"
  fi

  unset -f _ks_bg _ks_timer_loop 2>/dev/null
  return $_ks_exit
}
# kitsync-end
WRAPPER_BODY
}

# ---------------------------------------------------------------------------
# _render_wrapper — returns the wrapper text
# ---------------------------------------------------------------------------
_render_wrapper() {
  generate_wrapper
}

# ---------------------------------------------------------------------------
# _restore_target <backup file> — where a kitsync backup goes back to (empty
# for anything unknown: never guess a path in $HOME)
# ---------------------------------------------------------------------------
_restore_target() {
  local bn stem name
  bn="$(basename "$1")"     # .zshrc.20260503T131121.bak
  stem="${bn%.bak}"         # .zshrc.20260503T131121
  name="${stem%.*}"         # .zshrc
  case "$name" in
    .zshrc)         printf '%s/.zshrc' "${ZDOTDIR:-$HOME}" ;;
    .bashrc)        printf '%s/.bashrc' "$HOME" ;;
    .bash_profile)  printf '%s/.bash_profile' "$HOME" ;;
    settings.json)  printf '%s/settings.json' "${CLAUDE_HOME:-$HOME/.claude}" ;;
    .gitignore)     printf '%s/.gitignore' "${CLAUDE_HOME:-$HOME/.claude}" ;;
  esac
}

# ---------------------------------------------------------------------------
# cmd_restore [backup] — put back a file kitsync backed up before editing it
# (shell rc files, settings.json, ~/.claude/.gitignore). Without a terminal,
# the backup must be named: nothing is picked by default.
# ---------------------------------------------------------------------------
cmd_restore() {
  local backup_dir="${CLAUDE_HOME:-$HOME/.claude}/.kitsync/backups"
  local selected="${1:-}"

  if [[ ! -d "$backup_dir" ]]; then
    log_error "No backup directory found: $backup_dir"
    log_info  "Backups are created automatically when claude-kitsync modifies a file."
    return 1
  fi

  local backups=() f
  while IFS= read -r f; do
    [[ -n "$f" && -n "$(_restore_target "$f")" ]] && backups+=("$f")
  done < <(ls -t "$backup_dir"/*.bak "$backup_dir"/.*.bak 2>/dev/null || true)

  if [[ ${#backups[@]} -eq 0 ]]; then
    log_error "No backups found in $backup_dir"
    return 1
  fi

  if [[ -n "$selected" ]]; then
    [[ "$selected" == */* ]] || selected="$backup_dir/$selected"
    [[ -f "$selected" && -n "$(_restore_target "$selected")" ]] || \
      die "Not a kitsync backup: $1 (see: ls \"$backup_dir\")"
  elif ! _has_tty; then
    log_error "No terminal to choose a backup. Name it: claude-kitsync restore <file>"
    printf '%s\n' "${backups[@]}" | head -10 | xargs -n1 basename | sed 's/^/    /' >&2
    return 1
  else
    # ".zshrc  —  2026-05-03 13:11:21  →  ~/.zshrc"
    local labels=() bn stem ts
    for f in "${backups[@]}"; do
      bn="$(basename "$f")"; stem="${bn%.bak}"; ts="${stem##*.}"
      labels+=("${stem%.*}  —  ${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}  →  $(_restore_target "$f" | sed "s|^$HOME|~|")")
    done
    local idx
    idx="$(_select_menu "Select a backup to restore" "${labels[@]}")"
    selected="${backups[$((idx - 1))]}"
  fi

  local target
  target="$(_restore_target "$selected")"
  log_info "Restoring $target from $(basename "$selected")..."
  # The current version is backed up too, so a restore can be undone
  if [[ "$target" == */.zshrc || "$target" == */.bashrc || "$target" == */.bash_profile ]]; then
    _backup_rc "$target"
  elif [[ -f "$target" ]]; then
    cp -p "$target" "$backup_dir/$(basename "$target").$(date '+%Y%m%dT%H%M%S').bak"
  fi
  cat "$selected" > "$target"   # in place: a symlinked file stays a symlink
  log_success "Restored: $target"
  case "$target" in
    */.zshrc|*/.bashrc|*/.bash_profile) log_info "Run 'source $target' or open a new terminal to apply." ;;
  esac
}

# ---------------------------------------------------------------------------
# _backup_rc — snapshot a rc file into ~/.claude/.kitsync/backups/
#
# Keeps the 5 most recent backups per rc file. Silently skips if the
# backup directory cannot be created (non-fatal).
# ---------------------------------------------------------------------------
_backup_rc() {
  local rc_file="$1"
  [[ -f "$rc_file" ]] || return 0

  local backup_dir="${CLAUDE_HOME:-$HOME/.claude}/.kitsync/backups"
  mkdir -p "$backup_dir" 2>/dev/null || return 0

  local basename timestamp backup_path
  basename="$(basename "$rc_file")"
  timestamp="$(date '+%Y%m%dT%H%M%S')"
  backup_path="$backup_dir/${basename}.${timestamp}.bak"

  # Two edits within the same second: keep the first snapshot (the original)
  [[ -e "$backup_path" ]] && return 0
  cp "$rc_file" "$backup_path" || return 0

  # Prune: keep only the 5 most recent backups for this rc file
  ls -t "$backup_dir/${basename}".*.bak 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

  log_info "Backed up $rc_file → $backup_path"
}

# ---------------------------------------------------------------------------
# _rc_write <tmp> <rc> — replace a rc file's content with <tmp>, in place:
# a symlinked rc (dotfiles repo) stays a symlink, and permissions are kept
# (mv would put mktemp's 600 regular file in its place)
# ---------------------------------------------------------------------------
_rc_write() {
  cat "$1" > "$2"
  rm -f "$1"
}

# ---------------------------------------------------------------------------
# _inject_into_rc — idempotent injection of wrapper block into a rc file
#
# If markers already exist: replaces the block between them.
# If markers do not exist: appends at the end.
# ---------------------------------------------------------------------------
_inject_into_rc() {
  local rc_file="$1"

  # Create the file if it doesn't exist
  if [[ ! -f "$rc_file" ]]; then
    touch "$rc_file"
    log_info "Created $rc_file"
  fi

  _backup_rc "$rc_file"

  local wrapper_text
  wrapper_text="$(_render_wrapper)"

  if grep -qF "$WRAPPER_START_MARKER" "$rc_file" 2>/dev/null; then
    # Markers exist — replace the block between them (inclusive)
    log_info "Updating existing kitsync block in $rc_file"

    # We need a temp file for safe in-place editing
    local tmp_file
    tmp_file="$(mktemp)"

    # Write wrapper to a temp file so awk can read it via getline
    # (awk -v doesn't support multi-line strings)
    local new_block_file
    new_block_file="$(mktemp)"
    printf '%s\n' "$wrapper_text" > "$new_block_file"

    awk -v start="$WRAPPER_START_MARKER" -v end="$WRAPPER_END_MARKER" \
        -v nbf="$new_block_file" \
    '
    $0 == start { while ((getline line < nbf) > 0) print line; in_block=1; next }
    in_block && $0 == end { in_block=0; next }
    !in_block { print }
    ' "$rc_file" > "$tmp_file"

    rm -f "$new_block_file"
    _rc_write "$tmp_file" "$rc_file"
  else
    # No markers — append block at end of file
    log_info "Adding kitsync wrapper to $rc_file"
    printf '\n%s\n' "$wrapper_text" >> "$rc_file"
  fi
}

# ---------------------------------------------------------------------------
# _remove_from_rc — remove the kitsync block from a rc file
# ---------------------------------------------------------------------------
_remove_from_rc() {
  local rc_file="$1"

  if [[ ! -f "$rc_file" ]]; then
    return 0
  fi

  if ! grep -qF "$WRAPPER_START_MARKER" "$rc_file" 2>/dev/null; then
    return 0
  fi

  _backup_rc "$rc_file"
  log_info "Removing kitsync block from $rc_file"

  local tmp_file
  tmp_file="$(mktemp)"

  awk -v start="$WRAPPER_START_MARKER" -v end="$WRAPPER_END_MARKER" \
  '
  $0 == start { in_block=1; next }
  in_block && $0 == end { in_block=0; next }
  !in_block { print }
  ' "$rc_file" > "$tmp_file"

  _rc_write "$tmp_file" "$rc_file"
}

# ---------------------------------------------------------------------------
# install_wrapper_zsh — install wrapper into ~/.zshrc
# ---------------------------------------------------------------------------
install_wrapper_zsh() {
  local zshrc="${ZDOTDIR:-$HOME}/.zshrc"
  _inject_into_rc "$zshrc"
  log_success "Wrapper installed in $zshrc"
}

# ---------------------------------------------------------------------------
# install_wrapper_bash — install wrapper into ~/.bashrc
# ---------------------------------------------------------------------------
install_wrapper_bash() {
  local bashrc="$HOME/.bashrc"
  _inject_into_rc "$bashrc"
  log_success "Wrapper installed in $bashrc"
}

# ---------------------------------------------------------------------------
# install_wrapper_auto — detect current shell and install accordingly
# ---------------------------------------------------------------------------
install_wrapper_auto() {
  local current_shell
  current_shell="$(basename "${SHELL:-/bin/bash}")"

  case "$current_shell" in
    zsh)
      install_wrapper_zsh
      ;;
    bash)
      install_wrapper_bash
      ;;
    *)
      log_warn "Unrecognised shell: $current_shell — installing in both ~/.zshrc and ~/.bashrc"
      install_wrapper_zsh
      install_wrapper_bash
      ;;
  esac
}

# ---------------------------------------------------------------------------
# remove_wrapper — remove wrapper from both rc files
# ---------------------------------------------------------------------------
remove_wrapper() {
  _remove_from_rc "${ZDOTDIR:-$HOME}/.zshrc"
  _remove_from_rc "$HOME/.bashrc"
  log_success "Shell wrapper removed from rc files."
}

# ---------------------------------------------------------------------------
# _remove_completion_from_rc — remove the completion block added by install.sh
# ---------------------------------------------------------------------------
_remove_completion_from_rc() {
  local rc_file="$1"
  [[ -f "$rc_file" ]] || return 0
  grep -qF "# claude-kitsync completion" "$rc_file" 2>/dev/null || return 0

  _backup_rc "$rc_file"
  local tmp_file
  tmp_file="$(mktemp)"
  awk '/^# claude-kitsync completion$/{skip=1; next}
       /^# claude-kitsync completion end$/{skip=0; next}
       !skip' "$rc_file" > "$tmp_file"
  _rc_write "$tmp_file" "$rc_file"
  log_info "Removed completion setup from $rc_file"
}

# ---------------------------------------------------------------------------
# _remove_path_from_rc — remove the PATH injection line added by install.sh
# Handles both old marker (# kitsync PATH) and new (# claude-kitsync PATH)
# ---------------------------------------------------------------------------
_remove_path_from_rc() {
  local rc_file="$1"
  if [[ ! -f "$rc_file" ]]; then return 0; fi
  if ! grep -qF "kitsync PATH" "$rc_file" 2>/dev/null; then return 0; fi

  _backup_rc "$rc_file"
  local tmp_file
  tmp_file="$(mktemp)"
  # Remove the marker line and the export PATH line that follows it — only if
  # it still is one (a user-edited rc must not lose an unrelated line)
  awk '/^# kitsync PATH$|^# claude-kitsync PATH$/{skip=1; next}
       skip { skip=0; if ($0 ~ /^export PATH=/ || $0 ~ /^case ":\$PATH:" in /) next }
       {print}' "$rc_file" > "$tmp_file"
  _rc_write "$tmp_file" "$rc_file"
  log_info "Removed PATH entry from $rc_file"
}

# ---------------------------------------------------------------------------
# _completion_block <zsh|bash> <completions_dir> — the completion block
# install.sh writes into the rc file (keep both in sync)
# ---------------------------------------------------------------------------
_completion_block() {
  local shell="$1" dir="$2"
  printf '# claude-kitsync completion\n'
  case "$shell" in
    zsh)
      # shellcheck disable=SC2016
      printf 'fpath=("%s" $fpath)\n' "$dir"
      # shellcheck disable=SC2016
      printf '(( $+functions[compdef] )) && { autoload -Uz _claude-kitsync && compdef _claude-kitsync claude-kitsync; }\n'
      ;;
    bash)
      printf '[ -f "%s/claude-kitsync.bash" ] && . "%s/claude-kitsync.bash"\n' "$dir" "$dir"
      ;;
  esac
  printf '# claude-kitsync completion end\n'
}

# _path_line <dir> — the idempotent PATH line install.sh writes
_path_line() {
  # shellcheck disable=SC2016
  printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' "$1" "$1"
}

# _migrate_path_line <rc> — older installers wrote `export PATH="<dir>:$PATH"`,
# which stacks <dir> again each time the rc is sourced
_migrate_path_line() {
  local rc="$1" dir
  dir="$(awk '/^# (claude-)?kitsync PATH$/ { getline; print; exit }' "$rc" |
         sed -n 's|^export PATH="\(.*\):\$PATH"$|\1|p')"
  [[ -n "$dir" ]] || return 0
  _backup_rc "$rc"
  local tmp new
  tmp="$(mktemp)"
  new="$(_path_line "$dir")"
  awk -v new="$new" '/^# (claude-)?kitsync PATH$/ { print; getline; print new; next } { print }' \
    "$rc" > "$tmp"
  _rc_write "$tmp" "$rc"
  log_success "PATH entry made idempotent in $rc"
}

# _rc_block <rc_file> <start_line> <end_line> — print a block, markers included
_rc_block() {
  awk -v s="$2" -v e="$3" '$0 == s {on=1} on {print} on && $0 == e {exit}' "$1"
}

# ---------------------------------------------------------------------------
# _managed_install_dir — true when KITSYNC_ROOT is the installer's own clone.
# A dev checkout or a KITSYNC_INSTALL_DIR install is someone's working copy:
# uninstall must never delete it, nor point the rc file at it.
# ---------------------------------------------------------------------------
_managed_install_dir() {
  local root managed
  root="$(cd "$KITSYNC_ROOT" 2>/dev/null && pwd -P)" || return 1
  managed="$(cd "$HOME/.local/share/kitsync" 2>/dev/null && pwd -P)" || return 1
  [[ "$root" == "$managed" ]]
}

# ---------------------------------------------------------------------------
# refresh_shell_setup — bring rc blocks written by an older version up to date
#
# The wrapper and completion blocks are copied into the rc file at install
# time, so upgrading the tool alone leaves the old copies in place. Only
# blocks that already exist (wrapper) or belong to a script install (PATH line)
# are touched, and a file is rewritten only when its content changed.
# ---------------------------------------------------------------------------
refresh_shell_setup() {
  local rc shell want
  for rc in "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    [[ -f "$rc" ]] || continue

    if grep -qxF "$WRAPPER_START_MARKER" "$rc" 2>/dev/null && \
       [[ "$(_rc_block "$rc" "$WRAPPER_START_MARKER" "$WRAPPER_END_MARKER")" != "$(_render_wrapper)" ]]; then
      _inject_into_rc "$rc"
      log_success "Shell wrapper updated in $rc"
    fi

    grep -qF "kitsync PATH" "$rc" 2>/dev/null && _migrate_path_line "$rc"

    # Completion: the installer's clone only (Homebrew installs its own, and a
    # dev checkout run by hand must not take over the user's rc file)
    _managed_install_dir || continue
    grep -qF "kitsync PATH" "$rc" 2>/dev/null || continue
    [[ -d "$KITSYNC_ROOT/completions" ]] || continue
    case "$rc" in
      */.zshrc) shell=zsh ;;
      *)        shell=bash ;;
    esac
    want="$(_completion_block "$shell" "$KITSYNC_ROOT/completions")"
    if [[ "$(_rc_block "$rc" "# claude-kitsync completion" "# claude-kitsync completion end")" != "$want" ]]; then
      _backup_rc "$rc"
      _remove_completion_from_rc "$rc" >/dev/null 2>&1
      printf '\n%s\n' "$want" >> "$rc"
      log_success "Shell completion updated in $rc"
    fi
  done
}
