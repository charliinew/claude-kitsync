# claude-kitsync — Architecture Documentation

> Last updated: 2026-04-22

---

## Overview

`claude-kitsync` is a lightweight bash CLI that turns `~/.claude/` into a git repository, enabling:

1. **Multi-device synchronisation** — push/pull config across machines via a private git remote.
2. **Public kit distribution** — install community agent packs/skills without touching sensitive config.
3. **Zero-latency background sync** — Claude Code hooks (`SessionStart`, `SessionEnd`, `Stop` in timer mode) start background pulls and pushes in every session: terminal, IDE extensions and desktop app. The `claude()` shell function is only a fallback without `python3`.

---

## Architecture Decisions

### Model A: Git-in-~/.claude (chosen)

| Option | Notes |
|---|---|
| **Git-in-~/.claude** (chosen) | No symlinks, edit files in place, minimal tooling, portable |
| Symlink farm | Complex, brittle across updates, difficult to explain |
| Separate sync daemon | Requires persistent process management (launchd/systemd) |

**Rationale:** Users already have `~/.claude/` where they expect their config. A git repo in-place is the simplest model — no new concepts, uses existing tooling, works on all POSIX systems.

### Sync Timing: Background Pull + Timeout 2s

Pulling synchronously before `claude` runs would add visible latency. Instead:

```
User types: claude <prompt>
               │
               ├── background: git pull (max 2s, then timeout)
               │                    └── post-pull: decrypt .enc (if enabled), normalize_paths
               │
               └── foreground: command claude "$@"  ← no wait
```

- Zero perceived latency for the user
- Config is applied on the *next* invocation if pull completes after launch
- Silent failure on network issues — non-blocking

### Conflict Strategy: skip-if-dirty → autostash rebase → `-X ours`

| Layer | What it does |
|---|---|
| `skip-if-dirty` | If uncommitted changes exist, skip the pull entirely (never overwrite local work) |
| `--autostash` | If the tree is clean, git auto-stashes before rebase and restores after |
| `-X ours` | On conflicting hunks, keep the **remote** version. During a rebase the sides are swapped: "ours" is the upstream being rebased onto, "theirs" is the local commits being replayed |

Uncommitted work is never lost (skip-if-dirty / autostash). For *committed* local changes that conflict with the remote, **the remote wins**; `pull` lists the affected files before rebasing.

### Absolute Path Handling: git clean/smudge filter

`settings.json` contains absolute paths like `/Users/alice/.claude/hooks/...`. These break when synced to a machine with a different username.

**Solution:** `paths_filter_setup()` registers a `kitsync-paths` filter in `.git/config` and binds it to `settings.json` in `.git/info/attributes` (both per-machine, never synced):

- **clean** (working tree → repo): `$HOME/.claude` → `__CLAUDE_HOME__`, `$HOME` → `__HOME__`
- **smudge** (repo → working tree): the reverse, with the current machine's `$HOME`

The working copy always holds real paths and never looks modified after a push; the committed copy is portable. `normalize_paths()` additionally rewrites foreign `/Users/<x>/.claude` / `/home/<x>/.claude` paths in `settings.json` after a pull (legacy content). Content that bypasses git (decrypted `settings.json.enc`) is detokenized explicitly. On first setup, a repo whose `settings.json` was committed with absolute paths gets a one-time migration commit.

### Sync Triggers: Claude Code Hooks (not a shell function)

`lib/hooks.sh` adds to `settings.json` one command per event, e.g.:

```
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:…:$PATH"; command -v claude-kitsync >/dev/null 2>&1 && claude-kitsync _hook session-start 2>/dev/null || true
```

- Fires in every Claude Code surface (terminal, IDE extensions, desktop), unlike a shell function
- The usual install dirs are prepended because GUI-launched Claude may not have the user's PATH; `|| true` keeps a machine without kitsync quiet (settings.json is synced)
- `_hook` only starts a detached `pull --auto` / `push --auto` and returns: `SessionEnd` hooks share a 1.5 s budget
- Entries are identified by `claude-kitsync _hook`; install/remove leave the user's own hooks alone; `Stop` exists only in timer mode
- Fallback without `python3`: the legacy `claude()` function between `# kitsync-start` / `# kitsync-end` markers in the rc file; upgrading to 1.2.0 replaces it with the hooks

### .gitignore: Allowlist (deny-by-default)

```gitignore
*        # deny everything
!*/      # re-allow directories (so we can whitelist inside them)
!agents/**
...
.credentials.json   # explicit deny even though * covers it (belt-and-suspenders)
```

The allowlist approach means new files added to `~/.claude/` by Claude's runtime (session data, telemetry, etc.) are automatically excluded without requiring `.gitignore` updates.

---

## File Structure

```
claude-kitsync/
├── install.sh                  # curl | bash entry point — partial-download safe
├── bin/
│   └── kitsync                 # CLI dispatcher — sources all libs, case statement
├── lib/
│   ├── core.sh                 # CLAUDE_HOME, logging (log_info/warn/error/success)
│   ├── paths.sh                # normalize_paths(), paths_filter_setup(), token streams
│   ├── sync.sh                 # sync_pull(), sync_push(), sync_status()
│   ├── hooks.sh                # Claude Code sync hooks: install/remove, `_hook` runtime
│   ├── wrapper.sh              # rc file editing; legacy claude() wrapper (fallback)
│   ├── init.sh                 # cmd_init() — full setup flow
│   └── install-kit.sh          # cmd_install() — public kit merge
├── templates/
│   └── .gitignore.template     # Allowlist .gitignore for ~/.claude
├── docs/
│   └── ARCHITECTURE.md         # This file
└── README.md
```

---

## Flow Diagrams

### Install Flow (`curl | bash install.sh`)

```
curl -fsSL install.sh | bash
  │
  ├── git clone claude-kitsync → ~/.local/share/kitsync
  ├── ln -sf bin/kitsync → ~/.local/bin/kitsync
  └── echo 'export PATH=...' >> ~/.zshrc (idempotent)
```

### Init Flow (`kitsync init`)

```
kitsync init [--remote <url>]
  │
  ├── mkdir -p ~/.claude
  ├── git init (if not already a repo)
  ├── cp .gitignore.template → ~/.claude/.gitignore
  ├── Prompt for / accept --remote URL
  ├── git remote add origin <url>
  ├── Generate settings.template.json (tokenise paths)
  ├── git add <whitelist>
  ├── git commit -m "kitsync: initial commit"
  ├── sync_trigger_setup() → sync hooks in settings.json (fallback: claude() in rc)
  └── git push -u origin main (optional, prompts user)
```

### Sync Flow (every Claude Code session)

```
Session starts (terminal, IDE, desktop)
         │
         ├── SessionStart hook → claude-kitsync _hook session-start
         │     ├── prints pending notices (systemMessage)
         │     └── [detached] pull --auto: lock → skip if dirty/mid-rebase
         │           → fetch (timeout) → rebase -X ours → selective pull,
         │             decrypt, paths → conflict_pending / pending-notice
         │
         ├── … session …   (timer mode: Stop hook → push every N minutes)
         │
         └── SessionEnd hook → [detached] push --auto: lock → stage allowlist
               → leave out half-merged files → commit → push
               (remote moved on: rebase and retry; conflict → conflict_pending)
```

### Push Flow (`kitsync push`)

```
kitsync push [-m "message"]
  │
  ├── require_git_repo
  ├── SAFETY: check .credentials.json NOT staged (exit 1 if found)
  ├── git add <whitelist items that exist>
  ├── SAFETY: verify .credentials.json not in staged diff (exit 1 if found)
  ├── git commit -m "<message>"
  └── git push
```

### Kit Install Flow (`kitsync install <url>`)

```
kitsync install https://github.com/user/claude-kit
  │
  ├── git clone --depth 1 <url> $(mktemp -d)
  ├── hooks/ or scripts/ present? → warn + ask (skipped unless confirmed)
  ├── For each of: agents/ skills/ hooks/ rules/ scripts/ CLAUDE.md
  │     └── For each file in source:
  │           ├── Skip if in PROTECTED_FILES list
  │           ├── If dest exists: prompt [skip/overwrite/backup] (or use session default)
  │           └── Copy file
  └── rm -rf tmpdir (via trap)
```

---

## Edge Cases

### Machine B Has Different Username

**Scenario:** `settings.json` committed with `/Users/alice/.claude/hooks/...` is pulled on a machine where home is `/home/bob`.

**Resolution:** the committed copy holds `__CLAUDE_HOME__` tokens, expanded to `/home/bob/.claude` by the smudge filter on checkout. Older commits with raw `/Users/alice/.claude` paths are rewritten by `normalize_paths()` after the pull.

### Dirty Working Tree on Auto-Pull

**Scenario:** User edits `agents/myagent.md`, then invokes `claude` before committing.

**Resolution:** `_is_dirty()` check in `sync_pull()` detects uncommitted changes and returns early with a warning. The user's changes are never overwritten. They should `kitsync push` first, then the next `claude` invocation will pull cleanly.

### Background Pull on a Slow Network

**Scenario:** Slow network or large objects in git history.

**Resolution:** `pull --auto` puts a timeout (`KITSYNC_TIMEOUT`, 10 s) on the download only; the local rebase is never interrupted, so no `index.lock` is left behind. A timed-out pull is abandoned silently and retried at the next session.

### .credentials.json Accidentally Added

**Scenario:** User runs `git -C ~/.claude add .` manually.

**Resolution:** Two guards:
1. `.gitignore` allowlist (deny-by-default) means `git add .` will not stage it even if run manually.
2. `sync_push()` explicitly checks `git ls-files --error-unmatch .credentials.json` and exits 1 with a clear message if the file is tracked.

### Rebase Conflict During Pull

**Scenario:** Both local and remote modified the same line in `settings.json`.

**Resolution:** `git pull --rebase -X ours` resolves in favour of the local version automatically. If the rebase still fails (e.g., complex conflict), `sync_pull()` runs `git rebase --abort` to restore the pre-pull state and warns the user.

---

## Security Considerations

| Concern | Mitigation |
|---|---|
| `.credentials.json` leaked | Allowlist `.gitignore` + `sync_push()` safety check (exit 1) |
| `settings.local.json` leaked | Listed in `.gitignore`; `normalize_paths()` only touches `settings.json` |
| Arbitrary code via kit install | `install` runs nothing, but `hooks/`/`scripts/` are executed by Claude Code later — copied only after explicit confirmation. A kit's `.kitsync/` is never copied |
| Encryption key leaked | `.kitsync/encryption.key*` (incl. rotated backups) ignored; plaintext `settings.json` / `settings.template.json` untracked + ignored while encryption is on |
| Path traversal in kit install | Kit files are only copied into `$CLAUDE_HOME/<known-dirs>/` — never outside |
| Partial download of install.sh | Entire body wrapped in `install()` function, called only at last line |

---

## Contributing

1. All scripts use `#!/usr/bin/env bash` and `set -euo pipefail`.
2. Follow the logging convention: `log_info`, `log_warn`, `log_error`, `log_success`, `log_step`.
3. Never use absolute paths — always `$CLAUDE_HOME` or `$KITSYNC_ROOT`.
4. Test on macOS (zsh + bash) and Linux (bash) before submitting.
5. Update this document when adding new commands or changing behaviour.
