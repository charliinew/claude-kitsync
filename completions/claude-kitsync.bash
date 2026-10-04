# bash completion for claude-kitsync
# shellcheck disable=SC2207  # COMPREPLY=($(compgen …)) is the completion idiom; bash 3.2 (macOS) has no mapfile

# Profile names known on this machine (.kitsync/local; older setups: .kitsync/config)
_claude_kitsync_profiles() {
  local d="${CLAUDE_HOME:-$HOME/.claude}/.kitsync"
  grep -h '^KITSYNC_PROFILES_[A-Z0-9_]*_URL=' "$d/local" "$d/config" 2>/dev/null \
    | sed 's/^KITSYNC_PROFILES_//; s/_URL=.*//' | tr '[:upper:]' '[:lower:]' | sort -u
}

# Backups `restore` can put back
_claude_kitsync_backups() {
  local f d="${CLAUDE_HOME:-$HOME/.claude}/.kitsync/backups"
  for f in "$d"/*.bak "$d"/.*.bak; do
    [[ -f "$f" ]] && basename "$f"
  done
  return 0
}

_claude_kitsync() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local commands="init push pull status log diff publish install profile encrypt settings doctor restore setup-kit upgrade uninstall"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$commands -h --help -v --version" -- "$cur"))
    return 0
  fi

  case "${COMP_WORDS[1]}" in
    init)
      [[ "$prev" == --remote ]] && return 0
      COMPREPLY=($(compgen -W "--remote" -- "$cur"))
      ;;
    push)
      case "$prev" in
        -m) return 0 ;;
        --allow-secret) COMPREPLY=($(compgen -f -- "$cur")); return 0 ;;
      esac
      COMPREPLY=($(compgen -W "-m -n --dry-run --allow-secret" -- "$cur"))
      ;;
    pull)
      COMPREPLY=($(compgen -W "--force" -- "$cur"))
      ;;
    log)
      [[ "$prev" == -n ]] && return 0
      COMPREPLY=($(compgen -W "-n" -- "$cur"))
      ;;
    install)
      COMPREPLY=($(compgen -W "--skill" -- "$cur"))
      ;;
    profile)
      if [[ $COMP_CWORD -eq 2 ]]; then
        COMPREPLY=($(compgen -W "list add switch remove" -- "$cur"))
      elif [[ $COMP_CWORD -eq 3 && ( "$prev" == switch || "$prev" == remove ) ]]; then
        COMPREPLY=($(compgen -W "$(_claude_kitsync_profiles)" -- "$cur"))
      fi
      ;;
    encrypt)
      [[ $COMP_CWORD -eq 2 ]] && COMPREPLY=($(compgen -W "enable disable rotate status" -- "$cur"))
      ;;
    restore)
      [[ $COMP_CWORD -eq 2 ]] && COMPREPLY=($(compgen -W "$(_claude_kitsync_backups)" -- "$cur"))
      ;;
    upgrade)
      COMPREPLY=($(compgen -W "--dev --force --no-verify" -- "$cur"))
      ;;
    setup-kit)
      COMPREPLY=($(compgen -W "--print" -- "$cur"))
      ;;
    uninstall)
      COMPREPLY=($(compgen -W "--yes" -- "$cur"))
      ;;
  esac
}

complete -F _claude_kitsync claude-kitsync
