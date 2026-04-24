---
name: step-00b-team
description: Configure Agent Teams for parallel multi-agent execution
returns_to: steps/step-00-init.md
---

# Step 00b: Team Configuration

## MANDATORY EXECUTION RULES:

- ✅ Vérifier que CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS est actif
- ✅ Analyser la tâche pour recommander la composition optimale
- ✅ Générer des spawn prompts riches en contexte
- ✅ Définir la partition des fichiers pour éviter les conflits
- 🚫 FORBIDDEN de spawner les teammates ici — seulement configurer
- 🚫 FORBIDDEN de démarrer l'analyse (c'est step-01)

## YOUR TASK:

Configurer la composition de l'équipe Agent Teams et préparer les spawn prompts
avant de retourner à step-00-init.

---

## EXECUTION SEQUENCE:

### 1. Vérifier la feature Agent Teams

```bash
bash {skill_dir}/scripts/team-status.sh
```

Si `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` n'est **pas** actif :

```
⚠️  AGENT TEAMS NON ACTIF

La feature est activée dans ~/.claude/settings.json mais nécessite
un redémarrage de Claude Code pour prendre effet.

Redémarre Claude Code puis relance avec /apex -t.
```

Si actif → continuer.

### 2. Analyser la tâche et recommander une équipe

En fonction de `{task_description}`, déterminer la composition optimale :

**Règles de composition :**

| Type de tâche | Composition recommandée |
|---------------|------------------------|
| Nouvelle feature full-stack | backend + frontend + tester |
| Bug complexe | researcher × 2-3 (hypothèses concurrentes) |
| Revue / audit | security + reviewer + devil |
| Refactoring | reviewer + tester + devil |
| Recherche / exploration | researcher × 3-5 |
| Feature backend only | backend + tester + security |
| Feature frontend only | frontend + tester + reviewer |

**Taille maximale recommandée : 3-5 teammates**

**Agents disponibles :**

| Agent | Fichier | Spécialité |
|-------|---------|------------|
| `team-researcher` | `~/.claude/agents/team-researcher.md` | Recherche parallèle, synthèse |
| `team-backend` | `~/.claude/agents/team-backend.md` | API, DB, logic métier |
| `team-frontend` | `~/.claude/agents/team-frontend.md` | UI, hooks, state |
| `team-security` | `~/.claude/agents/team-security.md` | Audit sécurité, OWASP |
| `team-tester` | `~/.claude/agents/team-tester.md` | Tests, couverture, edge cases |
| `team-reviewer` | `~/.claude/agents/team-reviewer.md` | Qualité code, patterns, perf |
| `team-devil` | `~/.claude/agents/team-devil.md` | Avocat du diable, risques cachés |

### 3. Présenter la composition et demander confirmation

**Si `{auto_mode}` = true :** utiliser la composition recommandée directement.

**Si `{auto_mode}` = false :** présenter via AskUserQuestion :

```yaml
questions:
  - header: "Équipe"
    question: "Composition d'équipe recommandée pour cette tâche. Valider ?"
    options:
      - label: "Valider cette composition (Recommandé)"
        description: "Procéder avec les teammates suggérés"
      - label: "Modifier la composition"
        description: "Choisir différents agents ou ajuster la taille"
      - label: "Équipe minimale (3)"
        description: "Garder uniquement les 3 rôles les plus critiques"
    multiSelect: false
```

### 4. Définir la partition des fichiers

**CRITIQUE : chaque teammate doit travailler sur des fichiers distincts.**

Analyser `{task_description}` pour déterminer :

```markdown
## Partition des fichiers

| Teammate | Périmètre | Exemples de fichiers |
|----------|-----------|----------------------|
| backend  | src/api/, src/lib/, src/db/ | *.controller.ts, *.service.ts |
| frontend | src/components/, src/hooks/ | *.tsx, *.hook.ts |
| tester   | **/__tests__/, **/*.test.* | *.test.ts, *.spec.ts |
```

### 5. Générer les spawn prompts

Pour chaque teammate, générer un prompt de spawn riche incluant :
- Son rôle précis
- Sa partition de fichiers
- Le contexte de la tâche
- Les contraintes de coordination

**Template de spawn prompt :**

```
Tu es {role} dans une équipe Agent Teams travaillant sur : {task_description}

Ton périmètre : {file_partition}
Ton objectif : {specific_goal}

Contraintes importantes :
- Ne touche QU'AUX fichiers de ton périmètre
- Partage tes findings via message aux autres teammates si pertinent
- {role_specific_constraints}

Commence par explorer ton périmètre, puis attends les instructions du lead.
```

Stocker dans `{team_config}` :
```
{team_config} = {
  teammates: [
    { role: "backend", agent: "team-backend", spawn_prompt: "...", files: [...] },
    { role: "tester", agent: "team-tester", spawn_prompt: "...", files: [...] },
    ...
  ],
  display_mode: "auto",  // auto = tmux si disponible, sinon in-process
  navigation: "Shift+Down pour cycler, Ctrl+T pour task list"
}
```

### 6. Afficher le résumé et les instructions

```
✓ ÉQUIPE CONFIGURÉE

| Teammate | Agent | Périmètre |
|----------|-------|-----------|
| backend  | team-backend | src/api/, src/lib/ |
| tester   | team-tester  | **/*.test.ts |
| security | team-security | lecture seule |

📋 Mode d'affichage : {display_mode}
⌨️  Navigation : Shift+Down (cycler) · Ctrl+T (task list)

💡 Pour spawner l'équipe après l'analyse, le lead utilisera :
   "Crée une équipe de {N} teammates : {roles}"

→ Retour à step-00-init...
```

### 7. Retourner à step-00-init

Retourner avec `{team_config}` initialisé.

---

## STATE VARIABLES SET:

| Variable | Type | Description |
|----------|------|-------------|
| `{team_config}` | object | Composition, spawn prompts, partition fichiers |

## RETURNS TO:

`steps/step-00-init.md` — après avoir initialisé `{team_config}`
