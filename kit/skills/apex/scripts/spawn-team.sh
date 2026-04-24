#!/usr/bin/env bash
# spawn-team.sh - Génère le prompt de spawn d'équipe optimal
#
# Usage:
#   bash spawn-team.sh "<roles>" "<task_description>" [display_mode]
#
# Arguments:
#   $1  roles         - Rôles séparés par virgule (ex: "backend,tester,security")
#   $2  task_desc     - Description de la tâche
#   $3  display_mode  - "in-process" | "tmux" | "auto" (défaut: auto)
#
# Output: Prompt de spawn formaté prêt à coller dans Claude Code

set -e

ROLES="${1:-}"
TASK_DESC="${2:-}"
DISPLAY_MODE="${3:-auto}"

if [ -z "$ROLES" ] || [ -z "$TASK_DESC" ]; then
  echo "Usage: bash spawn-team.sh \"<roles>\" \"<task_description>\" [display_mode]"
  echo ""
  echo "Rôles disponibles: researcher, backend, frontend, security, tester, reviewer, devil"
  echo ""
  echo "Exemples:"
  echo "  bash spawn-team.sh \"backend,tester,security\" \"implémenter l'authentification JWT\""
  echo "  bash spawn-team.sh \"researcher,researcher,devil\" \"investiguer le bug de performance\""
  exit 1
fi

# Construire la liste des teammates
TEAMMATES_LIST=""
IFS=',' read -ra ROLE_ARRAY <<< "$ROLES"
TEAM_SIZE=${#ROLE_ARRAY[@]}

# Valider la taille
if [ "$TEAM_SIZE" -gt 5 ]; then
  echo "⚠️  Attention: $TEAM_SIZE teammates est supérieur au maximum recommandé (5)" >&2
  echo "   Les équipes > 5 génèrent plus de coûts que de bénéfices." >&2
  echo ""
fi

# Générer la description de chaque teammate
for ROLE in "${ROLE_ARRAY[@]}"; do
  ROLE=$(echo "$ROLE" | tr -d ' ')
  case "$ROLE" in
    researcher)
      DESC="Explorer et synthétiser les informations pertinentes pour : $TASK_DESC"
      ;;
    backend)
      DESC="Implémenter la logique backend (API, services, DB) pour : $TASK_DESC"
      ;;
    frontend)
      DESC="Implémenter l'interface utilisateur et les interactions pour : $TASK_DESC"
      ;;
    security)
      DESC="Auditer la sécurité (lecture seule) et reporter les vulnérabilités pour : $TASK_DESC"
      ;;
    tester)
      DESC="Écrire les tests et valider les acceptance criteria pour : $TASK_DESC"
      ;;
    reviewer)
      DESC="Reviewer la qualité du code (lecture seule) pour : $TASK_DESC"
      ;;
    devil)
      DESC="Challenger les hypothèses et identifier les risques cachés pour : $TASK_DESC"
      ;;
    *)
      DESC="Travailler sur : $TASK_DESC"
      ;;
  esac

  TEAMMATES_LIST="${TEAMMATES_LIST}
- **$ROLE** (agent: team-$ROLE) : $DESC"
done

# Générer le prompt de spawn
cat << EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PROMPT DE SPAWN — Copie-colle dans Claude Code
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Crée une équipe de $TEAM_SIZE teammates pour travailler sur :
"$TASK_DESC"

Spawn les teammates suivants :
$TEAMMATES_LIST

Instructions pour l'équipe :
- Chaque teammate travaille sur son périmètre de fichiers exclusivement
- Utiliser SendMessage pour coordonner entre vous
- Prévenir le lead dès qu'une dépendance bloquante est identifiée
- Partager les findings importants rapidement, pas seulement en fin de travail

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Navigation (mode $DISPLAY_MODE) :
  Shift+Down   → Passer au teammate suivant
  Shift+Up     → Teammate précédent
  Ctrl+T       → Afficher la task list
  Escape       → Interrompre le teammate actif

Coût estimé : ~${TEAM_SIZE}x le coût d'une session standard
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
