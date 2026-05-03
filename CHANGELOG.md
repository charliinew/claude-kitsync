# Changelog

## [1.0.0] — 2026-05-03

First stable release. All core sync features are production-ready.

### Features
- **`claude-kitsync init`** — interactive setup: git init, remote config, shell wrapper install, sync preferences
- **`claude-kitsync push`** — stage whitelisted files, commit, push; auto-push mode for wrapper
- **`claude-kitsync push --dry-run`** — preview what would be committed without touching the repo
- **`claude-kitsync pull`** — rebase pull with autostash; skips dirty working tree unless `--force`
- **`claude-kitsync status`** — show modified files, last commit, ahead/behind count
- **`claude-kitsync log [-n <count>]`** — formatted sync history from `~/.claude` git log
- **`claude-kitsync settings`** — interactive menu to change pull/push mode, remote URL, wrapper
- **`claude-kitsync doctor`** — health checks: repo, remote, credentials safety, wrapper presence
- **`claude-kitsync restore`** — interactive restore of rc file from timestamped backup
- **`claude-kitsync install <url>`** — merge a public kit (agents/skills/hooks) into `~/.claude`
- **`claude-kitsync upgrade`** — self-update via git pull
- **`claude-kitsync uninstall`** — full removal: wrapper, PATH, binary, install dir
- **Shell wrapper** — `claude()` function auto-pulls on launch; supports end-of-session and timer-based auto-push
- **Shell completion** — zsh and bash tab completion for all commands and flags
- **RC file backups** — automatic timestamped backups in `~/.claude/.kitsync/backups/` before any rc modification (keeps 5 most recent)
- **Cross-machine path normalisation** — `__CLAUDE_HOME__` token replaces absolute paths before push; detokenised on pull

### Security
- `.credentials.json` double-guarded: excluded from `.gitignore` AND runtime check before every push
- Allowlist `.gitignore` — only explicitly whitelisted files are ever synced

### Fixed
- BSD awk multiline injection bug that could wipe `.zshrc` on macOS (`_inject_into_rc` now uses temp file for awk)
- zsh job PID notification (`[N] XXXX`) suppressed via `NO_MONITOR NO_NOTIFY`
- Upstream tracking auto-set before pull when branch has no remote tracking ref
