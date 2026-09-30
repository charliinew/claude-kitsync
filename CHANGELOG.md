# Changelog

## [1.1.5] — 2026-09-30

### Changed
- **`skills/synced/` is no longer synced.** It holds the skills of your claude.ai account, which Claude Code re-downloads (and updates) on every startup; its `.last-complete-round` marker produced a commit on almost every session. Existing repos stop tracking it on the next push/pull; the files stay on disk.

## [1.1.4] — 2026-09-29

### Fixed
- **`upgrade` exited silently** (and never upgraded) when `KITSYNC_UPGRADE_CHANNEL` was not set in the config: a `grep` with no match aborted the script under `set -euo pipefail`. Same fix for the upgrade-channel settings menu and selective-sync config reads.
- `install.sh` re-run now updates an existing install by aligning it on `origin/main`; `git pull --rebase` failed after the upstream history rewrite while still reporting "up to date".
- `upgrade` no longer prints git's `HEAD is now at …` line.

### Docs
- Homebrew 6+ requires trusting third-party taps: `brew trust --formula charliinew/claude-kitsync/claude-kitsync`.

## [1.1.3] — 2026-09-29

### Fixed
- **Working tree always dirty after push** — path tokens (`__CLAUDE_HOME__`, `__HOME__`) are now applied by a git clean/smudge filter (per-machine, in `.git/config` + `.git/info/attributes`) instead of rewriting `settings.json` in place. `pull` is no longer skipped after every push, and `settings.json` is never rewritten while Claude Code is running. Existing repos get a one-time `kitsync: portable path tokens` commit.
- **Conflict side inverted** — `pull` used `-X theirs`, which during a rebase keeps the *local* commits. It now uses `-X ours` so the remote wins, as documented.
- **`push` never sent pending local commits** when nothing new was staged (after an offline push or a migration commit).
- **Encryption**: rotated key backups (`.kitsync/encryption.key.bak.*`) were pushed; plaintext `settings.json` stayed tracked and `settings.template.json` was pushed in clear. Enabling encryption now untracks both and ignores them; `.enc` content is tokenized and only re-encrypted when it changes (no more spurious commit on every push).
- Background auto-pull now decrypts `settings.json.enc` (post-pull hook).
- Machine-local state (`.kitsync/pending-notice`, `.kitsync/conflict_pending`) is no longer synced.
- `normalize_paths` only touches `settings.json` (it used to rewrite every `*.json` under `~/.claude`, including runtime data).
- `init` no longer overwrites an existing `.gitignore` when the template is missing.
- `--version` printed an empty version on bash 3.2 (macOS default), which also broke the Homebrew formula test and `upgrade` version checks.
- Release workflow never ran (`secrets` used in step-level `if:`), so no signed artifacts and a Homebrew formula stuck at v1.0.0.

### Changed
- New sync categories: `commands/`, `output-styles/`, `workflows/`, `themes/`, `keybindings.json`. Existing `.gitignore` files are migrated automatically on the next push/pull.
- `settings.template.json` is regenerated on each push instead of being frozen at `init`.
- `install <url>` no longer copies a kit's `.kitsync/`, and asks before installing `hooks/` or `scripts/` (code Claude Code executes).
- CI: `actions/checkout@v7`, `ludeeus/action-shellcheck@2.0.0` (pinned). Release tarball now includes `completions/`.

## [1.1.2] — 2026-05-05

### Fixed
- **`init` — per-file conflict resolution on initial commit**: when connecting to an existing remote, files that differ between local and remote now trigger a `[R]emote / [L]ocal / [P]ass` prompt instead of being silently overwritten. Remote-only files are pulled automatically; local-only files are staged as new additions.

## [1.1.1] — 2026-05-05

### Added
- **Selective sync** — choose which categories are pushed and pulled (`KITSYNC_PUSH_ITEMS` / `KITSYNC_PULL_ITEMS`).
- **`install --skill <url>`** — install only skills, including a single skill from a GitHub tree URL; flexible kit layout detection.
- **`upgrade`** defaults to the latest stable GitHub release.

### Fixed
- Wrapper: auto-pull timeout no longer reported as a conflict; works without `timeout` (falls back to `gtimeout` or none); no stale `conflict_pending` files.

## [1.1.0] — 2026-05-04

### Added
- **`profile`** — named remotes for multi-environment sync (work, perso…).
- **`encrypt`** — opt-in AES-256-CBC encryption of `settings.json` before push.
- **`diff`** — ahead/behind summary with incoming/outgoing diff viewer; interactive conflict resolution on pull.
- **`publish`** — package and publish agents/skills as a kit on GitHub.
- Portable path tokens (`__HOME__` in addition to `__CLAUDE_HOME__`); warning when a pull overrides local changes; notice after an auto-pull conflict.

### Changed
- CI runs on `macos-latest` and `ubuntu-latest`.

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
