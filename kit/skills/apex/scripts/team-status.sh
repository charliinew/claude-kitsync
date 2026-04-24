#!/usr/bin/env bash
# team-status.sh - Vérifie l'état de la feature Agent Teams

set -e

RESET='\033[0m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'

echo ""
echo -e "${BOLD}=== Agent Teams Status ===${RESET}"
echo ""

# 1. Vérifier la variable d'environnement
if [ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS}" = "1" ]; then
  echo -e "  ${GREEN}✓${RESET} CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = 1 (actif)"
  TEAMS_ACTIVE=true
else
  echo -e "  ${YELLOW}⚠${RESET}  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS non défini dans l'environnement"
  # Vérifier dans settings.json
  SETTINGS_FILE="$HOME/.claude/settings.json"
  if [ -f "$SETTINGS_FILE" ]; then
    if grep -q '"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"' "$SETTINGS_FILE" 2>/dev/null; then
      echo -e "  ${GREEN}✓${RESET} Configuré dans ~/.claude/settings.json (actif au prochain démarrage)"
      TEAMS_ACTIVE=false
    else
      echo -e "  ${RED}✗${RESET} Non configuré dans ~/.claude/settings.json"
      TEAMS_ACTIVE=false
    fi
  fi
fi

echo ""

# 2. Vérifier tmux
if command -v tmux &>/dev/null; then
  TMUX_VERSION=$(tmux -V 2>/dev/null | head -1)
  echo -e "  ${GREEN}✓${RESET} tmux disponible : $TMUX_VERSION"
  # Vérifier si on est dans une session tmux
  if [ -n "$TMUX" ]; then
    echo -e "  ${GREEN}✓${RESET} Session tmux active → split-panes disponibles"
    DISPLAY_MODE="split-panes (tmux)"
  else
    echo -e "  ${YELLOW}→${RESET}  Pas dans une session tmux → mode in-process"
    DISPLAY_MODE="in-process"
  fi
else
  echo -e "  ${YELLOW}⚠${RESET}  tmux non installé (brew install tmux pour split-panes)"
  DISPLAY_MODE="in-process"
fi

echo ""

# 3. Vérifier Claude Code version
if command -v claude &>/dev/null; then
  CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1 || echo "inconnu")
  echo -e "  ${GREEN}✓${RESET} Claude Code : $CLAUDE_VERSION"
else
  echo -e "  ${YELLOW}⚠${RESET}  Commande 'claude' non trouvée"
fi

echo ""

# 4. Afficher les agents disponibles
AGENTS_DIR="$HOME/.claude/agents"
TEAM_AGENTS=$(ls "$AGENTS_DIR"/team-*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$TEAM_AGENTS" -gt 0 ]; then
  echo -e "  ${GREEN}✓${RESET} $TEAM_AGENTS agents team disponibles :"
  ls "$AGENTS_DIR"/team-*.md 2>/dev/null | while read f; do
    NAME=$(basename "$f" .md)
    echo -e "      - $NAME"
  done
else
  echo -e "  ${YELLOW}⚠${RESET}  Aucun agent team trouvé dans ~/.claude/agents/"
fi

echo ""
echo -e "${BOLD}Mode d'affichage recommandé : ${DISPLAY_MODE}${RESET}"
echo ""

# 5. Résumé et instructions
if [ "$TEAMS_ACTIVE" = true ]; then
  echo -e "${GREEN}✓ Agent Teams prêt à l'emploi${RESET}"
  echo ""
  echo "  Usage : /apex -t <description de la tâche>"
  echo ""
  echo "  Navigation :"
  echo "    Shift+Down  →  Cycler entre teammates"
  echo "    Shift+Up    →  Teammate précédent"
  echo "    Ctrl+T      →  Toggle task list"
  echo "    Escape      →  Interrompre le teammate actif"
else
  echo -e "${YELLOW}→ Redémarre Claude Code pour activer Agent Teams${RESET}"
fi

echo ""
