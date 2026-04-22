# claude-kitsync — Architecture Documentation

> Last updated: 2026-04-22

---

## Overview

`claude-kitsync` is a lightweight bash CLI that turns `~/.claude/` into a git repository, enabling:

1. **Multi-device synchronisation** — push/pull config across machines via a private git remote.
2. **Public kit distribution** — install community agent packs/skills without touching sensitive config.
3. **Zero-latency background sync** — a shell function wrapper pulls in the background before each Claude invocation.

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
               │                    └── post-pull: normalize_paths
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
| `-X ours` | On merge conflicts inside files, prefer the local version (safe default) |

This means **local changes always win** — users must explicitly `kitsync push` to share changes.

### Absolute Path Handling: sed Post-Pull + settings.template.json

`settings.json` contains absolute paths like `/Users/alice/.claude/hooks/...`. These break when synced to a machine with a different username.

**Two-layer solution:**
1. `settings.template.json` — tokenised version committed to git (`__CLAUDE_HOME__` placeholders)
2. `normalize_paths()` — regex replacement run after every pull: any path matching `/*/\.claude` → `$HOME/.claude`

This means `settings.json` stays usable on the local machine while the committed copy is portable.

### Shell Wrapper: Function (not PATH manipulation)

```bash
claude() {
  ...background pull...
  command claude "$@"   # the real binary
}
```

- `command claude` bypasses shell functions → **zero recursion risk**
- No PATH manipulation — function shadows the name only within the shell session
- Works identically in zsh and bash
- Idempotent: `# kitsync-start` / `# kitsync-end` markers allow safe re-injection

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
│   ├── paths.sh                # normalize_paths(), paths_tokenize(), paths_detokenize()
│   ├── sync.sh                 # sync_pull(), sync_push(), sync_status()
│   ├── wrapper.sh              # generate_wrapper(), install_wrapper_zsh/bash/auto()
│   ├── init.sh                 # cmd_init() — full setup flow
│   └── install-kit.sh          # cmd_install() — public kit merge
├── templates/
│   ├── .gitignore.template     # Allowlist .gitignore for ~/.claude
│   └── shell-wrapper.sh        # Standalone template for the claude() function
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
  ├── install_wrapper_auto() → injects claude() into ~/.zshrc or ~/.bashrc
  └── git push -u origin main (optional, prompts user)
```

### Sync Flow (every `claude` invocation)

```
User: claude "write me a test"
         │
         ├── [background, disowned]
         │     timeout 2s git pull --rebase --autostash -X ours
         │     └── on success: kitsync _post-pull-hook → normalize_paths
         │
         └── [foreground, immediate]
               command claude "write me a test"
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

**Resolution:** `normalize_paths()` runs after every pull. It matches the regex `/[A-Za-z0-9._/-]*/\.claude` and replaces all occurrences with `$HOME/.claude` for the current user.

### Dirty Working Tree on Auto-Pull

**Scenario:** User edits `agents/myagent.md`, then invokes `claude` before committing.

**Resolution:** `_is_dirty()` check in `sync_pull()` detects uncommitted changes and returns early with a warning. The user's changes are never overwritten. They should `kitsync push` first, then the next `claude` invocation will pull cleanly.

### Background Pull Takes > 2 Seconds

**Scenario:** Slow network or large objects in git history.

**Resolution:** The wrapper uses `timeout 2` which sends SIGTERM to the git process. The pull is silently abandoned. Config is applied on the next invocation when the network is faster. Existing local config continues to work untouched.

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
| `settings.local.json` leaked | Listed in `.gitignore` + excluded from `normalize_paths()` processing |
| Arbitrary code via kit install | Only copies files — no execution. User reviews changes with `kitsync status` |
| Path traversal in kit install | Kit files are only copied into `$CLAUDE_HOME/<known-dirs>/` — never outside |
| Partial download of install.sh | Entire body wrapped in `install()` function, called only at last line |

---

## Contributing

1. All scripts use `#!/usr/bin/env bash` and `set -euo pipefail`.
2. Follow the logging convention: `log_info`, `log_warn`, `log_error`, `log_success`, `log_step`.
3. Never use absolute paths — always `$CLAUDE_HOME` or `$KITSYNC_ROOT`.
4. Test on macOS (zsh + bash) and Linux (bash) before submitting.
5. Update this document when adding new commands or changing behaviour.
