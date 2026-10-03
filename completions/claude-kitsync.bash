_claude_kitsync() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local commands="init push pull status log diff publish install profile encrypt settings doctor restore setup-kit upgrade uninstall"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    return 0
  fi

  case "${COMP_WORDS[1]}" in
    init)
      COMPREPLY=($(compgen -W "--remote" -- "$cur"))
      ;;
    push)
      case "$prev" in
        -m) return 0 ;;
      esac
      COMPREPLY=($(compgen -W "-m --auto -n --dry-run --allow-secret" -- "$cur"))
      ;;
    pull)
      COMPREPLY=($(compgen -W "--force" -- "$cur"))
      ;;
    log)
      COMPREPLY=($(compgen -W "-n" -- "$cur"))
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
    install)
      COMPREPLY=()
      ;;
  esac
}

complete -F _claude_kitsync claude-kitsync
