# claude-kitsync — Plan d'architecture & Requirements

> Généré le 2026-04-22 via APEX

---

## Vue d'ensemble

Créer `claude-kitsync` : un CLI bash léger qui résout deux problèmes distincts via un seul mécanisme (git dans `~/.claude/`) — distribution d'une config publique et sync multi-device via repo privé.

---

## Décisions d'architecture résolues

| Décision | Choix retenu | Raison |
|---|---|---|
| **Modèle de stockage** | Git-in-~/.claude (Model A) | Pas de symlinks, édition en place, le plus simple |
| **Timing sync** | Background pull + timeout 2s | 0 latence perçue, config appliquée à la prochaine invocation |
| **Stratégie conflits** | skip-if-dirty → autostash rebase → `-X ours` | Sécuritaire : jamais de perte de données locales |
| **Chemins absolus** | Sed post-pull + `settings.template.json` | Simple, fiable, pas de dépendance runtime |
| **Shell wrapper** | Function zsh/bash (`command claude`) | Zéro risque de récursion, pas de manipulation PATH |
| **Structure repo** | Mono-repo (outil + templates) | L'outil distribue aussi les templates pour le repo privé |

---

## Architecture de fichiers cible

```
claude-kitsync/                      ← Repo public (l'outil)
├── install.sh                        ← curl | bash entry point
├── bin/
│   └── kitsync                       ← CLI principal (dispatcher)
├── lib/
│   ├── core.sh                       ← Colors, logging, CLAUDE_HOME detection
│   ├── sync.sh                       ← pull / push / status (git operations)
│   ├── init.sh                       ← `kitsync init` — setup complet
│   ├── install-kit.sh                ← `kitsync install <url>` — merge kit public
│   ├── wrapper.sh                    ← génère + installe la shell function
│   └── paths.sh                      ← normalisation chemins absolus post-pull
├── templates/
│   ├── .gitignore.template           ← Allowlist .gitignore pour ~/.claude
│   └── shell-wrapper.sh             ← Template de la claude() function
├── docs/
│   └── ARCHITECTURE.md               ← Décisions, flow, contribution guide
└── README.md
```

---

## Fichiers à créer — détail

### `install.sh`
- Flags : `-fsSL`, corps dans une fonction (protection partial download)
- Copie `bin/kitsync` → `~/.local/bin/kitsync` (ou `/usr/local/bin`)
- Détecte le shell (zsh/bash), injecte `export PATH` dans RC file
- Idempotent — safe to re-run

### `bin/kitsync`
- Dispatcher : `case "$1" in init|push|pull|status|install|doctor`
- Charge les libs via `source "$(dirname "$0")/../lib/*.sh"`
- Help intégré

### `lib/core.sh`
- `CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"`
- Fonctions : `log_info`, `log_warn`, `log_error`, `log_success` (avec couleurs)
- `require_git_repo()` — vérifie que `$CLAUDE_HOME` est un repo

### `lib/sync.sh`
- `sync_pull()` :
  1. Check dirty → warn "Uncommitted changes, skipping auto-pull" et return
  2. `git -C "$CLAUDE_HOME" pull --rebase --autostash -X ours -q 2>/dev/null`
  3. En cas d'échec : `git rebase --abort`, warn user
  4. Appelle `normalize_paths` après pull réussi
- `sync_push(msg)` : `git add` (fichiers de la whitelist uniquement) + `git commit` + `git push`
- `sync_status()` : `git -C "$CLAUDE_HOME" status --short`

### `lib/init.sh`
Flow :
1. Détecte si `~/.claude` est déjà un repo git
2. Si non : `git init`, crée `.gitignore` depuis template
3. Demande URL remote (ou `--remote <url>` en arg)
4. `git remote add origin <url>`
5. Génère `settings.template.json` depuis `settings.json` existant (remplace chemins absolus par `$HOME/.claude`)
6. Commit initial avec fichiers whitelistés
7. Installe le shell wrapper (appelle `wrapper.sh`)
8. `git push -u origin main`

### `lib/install-kit.sh`
`kitsync install <github-url>` :
1. Clone dans `$(mktemp -d)`
2. Copie sélective : agents/, skills/, hooks/, CLAUDE.md
3. Ne touche JAMAIS à : settings.json, settings.local.json, .credentials.json
4. Conflict detection : si fichier existe → demande [skip/overwrite/backup]
5. Cleanup tmpdir

### `lib/wrapper.sh`
- `generate_wrapper()` : sort le texte de la function shell
- `install_wrapper_zsh()` : injecte dans `~/.zshrc` entre markers `# kitsync-start / # kitsync-end` (idempotent)
- `install_wrapper_bash()` : idem pour `~/.bashrc`
- Template de la wrapper function :
  ```bash
  claude() {
    if [[ -d "$CLAUDE_HOME" ]] && git -C "$CLAUDE_HOME" rev-parse --git-dir &>/dev/null; then
      (timeout 2 git -C "$CLAUDE_HOME" pull --rebase --autostash -q 2>/dev/null; \
       kitsync _post-pull-hook) &
      disown
    fi
    command claude "$@"
  }
  ```

### `lib/paths.sh`
- `normalize_paths()` :
  ```bash
  local pattern='s|/Users/[^/]*/\.claude|'"$HOME"'/.claude|g'
  sed -i '' "$pattern" "$CLAUDE_HOME/settings.json" 2>/dev/null || \
  sed -i "$pattern" "$CLAUDE_HOME/settings.json"  # Linux compat
  ```
- `paths_export()` : inverse — avant push, remplace `$HOME/.claude` par un token `__CLAUDE_HOME__` dans settings.json (optionnel, pour repo cross-user)

### `templates/.gitignore.template`
```gitignore
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
```

### `templates/shell-wrapper.sh`
- Wrapper paramétré : variables `CLAUDE_HOME`, `KITSYNC_TIMEOUT`
- Support zsh et bash dans le même template

### `docs/ARCHITECTURE.md`
- Flowchart install, flowchart sync
- Log des décisions avec rationale
- Scénarios edge cases documentés

### `README.md`
- Quick start (5 lignes)
- Commandes référence
- FAQ (conflits, chemins absolus, sécurité)

---

## Acceptance Criteria

- [ ] **AC1** — `curl -fsSL .../install.sh | bash` installe kitsync en < 30s sur macOS et Linux
- [ ] **AC2** — `kitsync init` configure `~/.claude` comme repo git avec `.gitignore` allowlist correct
- [ ] **AC3** — Shell wrapper installé et actif dans tout nouveau shell après init
- [ ] **AC4** — `claude` ne bloque pas plus de 2s au démarrage (timeout async)
- [ ] **AC5** — `.credentials.json` et `projects/` n'apparaissent jamais dans `git status`
- [ ] **AC6** — Sur Machine B (username différent), `settings.json` résolu correctement post-pull
- [ ] **AC7** — Dirty tree → skip sync + warning visible ; clean tree → rebase auto sans friction
- [ ] **AC8** — `kitsync install <url>` merge un kit public sans écraser config locale
- [ ] **AC9** — `kitsync doctor` diagnostique l'état de santé de la sync en < 5 items
- [ ] **AC10** — Fonctionne macOS (zsh/bash) + Linux (bash/zsh)
- [ ] **AC11** — Install script idempotent (re-run safe)

---

## Risques & Mitigations

| Risque | Mitigation |
|---|---|
| `.credentials.json` committé accidentellement | `.gitignore` allowlist strict + check pre-push dans `sync_push()` |
| `git` dans `~/.claude` corrompt les données Claude | `.gitignore` couvre tous les fichiers runtime ; `.git/` ignoré par Claude |
| Pull en arrière-plan rate avec réseau lent | Timeout 2s + silent fail — sync au prochain lancement |
| Conflits simultanés deux machines | skip-if-dirty en default ; `kitsync pull --force` pour override conscient |
| `settings.json` paths brisés post-pull | `normalize_paths()` appelée systématiquement après chaque pull |
| macOS `sed -i ''` vs Linux `sed -i` | Détection OS dans `paths.sh`, deux chemins |

---

## Contexte de l'environnement existant (~/.claude)

### Fichiers à syncer (portables)
| Fichier/Dossier | Taille | Notes |
|---|---|---|
| `settings.json` | 1.4 KB | 4 chemins absolus à normaliser |
| `CLAUDE.md` | — | Si présent |
| `agents/` | 44 KB | 11 fichiers .md |
| `skills/` | 624 KB | 16 répertoires |
| `hooks/rm_to_trash.py` | 647 B | Aucun chemin absolu interne |
| `scripts/` | 248 KB | TypeScript (statusline, command-validator) |

### Chemins absolus identifiés dans settings.json
1. `"command": "python3 /Users/cignoux/.claude/hooks/rm_to_trash.py"`
2. `"command": "afplay -v 0.1 '/Users/cignoux/.claude/song/finish.mp3'"`
3. `"command": "afplay -v 0.1 '/Users/cignoux/.claude/song/need-human.mp3'"`
4. `"command": "bun /Users/cignoux/.claude/scripts/statusline/src/index.ts"`

### Fichiers à NE JAMAIS syncer
- `.credentials.json` — secrets OAuth
- `projects/` — 15 MB, historique de sessions local
- `backups/`, `cache/`, `file-history/`, `paste-cache/` — runtime local
- `settings.local.json` — permissions machine-spécifiques
- `history.jsonl` — historique local

---

## Commandes CLI cibles

```
kitsync init [--remote <url>]    # Initialise ~/.claude comme repo git + installe wrapper
kitsync push [-m "message"]      # Commit + push les changements locaux
kitsync pull                     # Pull manuel depuis le remote
kitsync status                   # Affiche les fichiers modifiés/non-syncés
kitsync install <url>            # Installe un kit public dans ~/.claude
kitsync doctor                   # Diagnostique la santé de la config sync
```
