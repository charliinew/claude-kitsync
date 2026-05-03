# claude-kitsync

Sync your Claude config (`~/.claude/`) across machines using git. Background pull before every `claude` invocation — zero latency, no friction.

---

## Quick Start

**One command — everything configured automatically:**

```bash
curl -fsSL https://raw.githubusercontent.com/charliinew/claude-kitsync/main/install.sh | bash
```

The installer will:
1. Install the `claude-kitsync` binary
2. Ask for your git remote URL (or skip if you don't have one yet)
3. Initialise `~/.claude` as a git repo + install the shell wrapper

Then run the one activation command it prints (e.g. `source ~/.zshrc`) and you're done.

**If you already know your remote URL:**

```bash
KITSYNC_REMOTE=git@github.com:you/claude-config.git \
  curl -fsSL https://raw.githubusercontent.com/charliinew/claude-kitsync/main/install.sh | bash
```

No prompts — fully automated setup.

**Via Homebrew:**

```bash
brew tap charliinew/claude-kitsync https://github.com/charliinew/claude-kitsync
brew install claude-kitsync
```

---

## Commands

| Command | Description |
|---|---|
| `claude-kitsync init [--remote <url>]` | Initialise `~/.claude` as git repo + install shell wrapper |
| `claude-kitsync push [-m "message"] [--dry-run]` | Commit and push whitelisted changes; `--dry-run` previews without committing |
| `claude-kitsync pull [--force]` | Pull manually from remote (skips if dirty working tree) |
| `claude-kitsync status` | Show modified files and ahead/behind count |
| `claude-kitsync log [-n <count>]` | Show sync history (default: last 15 commits) |
| `claude-kitsync diff` | Show diff between local and remote before pushing |
| `claude-kitsync restore` | Restore a rc file from a timestamped backup |
| `claude-kitsync install <url>` | Merge a public kit into `~/.claude` (selective, no overwrite of local config) |
| `claude-kitsync settings` | Interactive menu to change pull/push mode, remote URL, wrapper |
| `claude-kitsync doctor` | Diagnose the health of your setup |
| `claude-kitsync upgrade` | Update claude-kitsync to the latest version |
| `claude-kitsync uninstall` | Fully remove claude-kitsync (binary, PATH, shell wrapper) |

---

## How It Works

**Shell wrapper** — `claude-kitsync init` injects a `claude()` function into your `~/.zshrc` (or `~/.bashrc`):

```bash
claude() {
  # Background: pull latest config (max 2s, then timeout)
  ( timeout 2 git -C ~/.claude pull --rebase --autostash -q ) &
  disown
  # Foreground: run claude immediately, no wait
  command claude "$@"
}
```

**Git-in-~/.claude** — your config directory becomes a standard git repo. Only explicitly whitelisted files are committed:

- `settings.json`, `CLAUDE.md`
- `agents/`, `skills/`, `hooks/`, `scripts/`, `rules/`

**Absolute path normalisation** — `settings.json` often contains paths like `/Users/alice/.claude/hooks/...`. After every pull, `claude-kitsync` rewrites these to match the current machine's `$HOME/.claude/`.

---

## FAQ

### Will `.credentials.json` ever be synced?

No. The `.gitignore` uses a deny-by-default allowlist — only explicitly whitelisted files can be committed. `.credentials.json` is additionally double-blocked and `claude-kitsync push` will abort with an error if it somehow ends up staged.

### What happens if I have uncommitted changes when `claude` runs?

The background pull is skipped with a warning (you won't see it since it's background). Your local changes are never overwritten. Run `claude-kitsync push` to commit them first.

### My `settings.json` has broken paths after pulling on a new machine.

Run `claude-kitsync pull` manually — it calls `normalize_paths()` which fixes all absolute paths to match the current `$HOME`. This also happens automatically in the background wrapper.

### Can I use this with a private repo?

Yes — `claude-kitsync init --remote git@github.com:you/private-claude-config.git`. The remote is just a standard git remote. Use SSH keys or HTTPS tokens as you normally would.

### How do I install someone else's agent pack?

```bash
claude-kitsync install https://github.com/someone/claude-kit
```

This clones the kit into a temp directory, then copies only `agents/`, `skills/`, `hooks/`, `rules/`, and `CLAUDE.md`. It never touches your `settings.json`, `settings.local.json`, or `.credentials.json`. You'll be prompted for each conflicting file: skip / overwrite / backup.

### What is `settings.template.json`?

A copy of `settings.json` with absolute paths replaced by `__CLAUDE_HOME__` tokens. It's committed to git so that cross-user portability is explicit. On pull, `normalize_paths()` resolves tokens back to the real path.

### Can I override `CLAUDE_HOME`?

Yes: `CLAUDE_HOME=/path/to/other-claude claude-kitsync status` or export it permanently in your shell rc.

### `claude-kitsync doctor` says my wrapper is missing

Run `claude-kitsync init` again — it's idempotent. It will add the wrapper block without duplicating it.

### How do I uninstall completely?

```bash
claude-kitsync uninstall
exec $SHELL
```

This removes the binary, PATH entry, and shell wrapper in one command.

---

## Security

- **Allowlist gitignore** — deny-by-default, only whitelisted files can be staged
- **Double guard on `.credentials.json`** — `.gitignore` + runtime abort in `claude-kitsync push`
- **No code execution during `claude-kitsync install`** — only file copies, no scripts run
- **Partial download protection in `install.sh`** — body wrapped in a function, only called at the last line

---

## Requirements

- Bash 3.2+ or Zsh 5.0+
- git 2.x
- Standard POSIX utilities (`sed`, `awk`, `find`, `mktemp`)
- macOS or Linux

---

## License

MIT
