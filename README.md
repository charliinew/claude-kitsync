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
brew trust --formula charliinew/claude-kitsync/claude-kitsync   # Homebrew 6+ requires trusting third-party taps
brew install claude-kitsync
```

Use one install method only: Homebrew (`brew upgrade claude-kitsync`) or the script (`claude-kitsync upgrade`).

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
| `claude-kitsync publish` | Package and publish agents/skills as a kit to GitHub |
| `claude-kitsync restore` | Restore a rc file from a timestamped backup |
| `claude-kitsync install [--skill] <url>` | Merge a public kit into `~/.claude` (no overwrite of local config); `--skill` installs skills only |
| `claude-kitsync profile [list\|add\|switch\|remove]` | Manage named remotes for multi-environment sync (work, perso…) |
| `claude-kitsync encrypt [enable\|disable\|rotate\|status]` | Encrypt `settings.json` with AES-256 before push (opt-in) |
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

- `settings.json`, `CLAUDE.md`, `keybindings.json`
- `agents/`, `skills/`, `hooks/`, `scripts/`, `rules/`, `commands/`, `output-styles/`, `workflows/`, `themes/`

Pick a subset per direction with **selective sync** (`claude-kitsync settings` → Sync categories): for example push `skills/` from every machine but never pull `settings.json` on a work laptop.

**Portable paths** — `settings.json` often contains paths like `/Users/alice/.claude/hooks/...`. A git clean/smudge filter stores them in the repo as `__CLAUDE_HOME__/hooks/...` (and `$HOME` as `__HOME__`) and expands them back to the current machine's paths on checkout. Your working copy always keeps real absolute paths; only the committed version is tokenized.

---

## FAQ

### Will `.credentials.json` ever be synced?

No. The `.gitignore` uses a deny-by-default allowlist — only explicitly whitelisted files can be committed. `.credentials.json` is additionally double-blocked and `claude-kitsync push` will abort with an error if it somehow ends up staged.

### What happens if I have uncommitted changes when `claude` runs?

The background pull stashes them, pulls, and re-applies them (`--autostash`). A manual `claude-kitsync pull` refuses to run on a dirty tree unless you pass `--force`. Your local changes are never discarded; run `claude-kitsync push` to commit them.

### Who wins when the same file changed on two machines?

The remote. `pull` rebases your local commits on top of the remote with `-X ours` (during a rebase "ours" is the upstream side), and lists the files concerned before doing so. Use `claude-kitsync diff` first if you want to review.

### My `settings.json` has broken paths after pulling on a new machine.

Run `claude-kitsync pull` once — it registers the path filter for this machine and rewrites any foreign `/Users/<name>/.claude` or `/home/<name>/.claude` path in `settings.json` to your own `$HOME`. The background wrapper does the same after each auto-pull.

### Can I use this with a private repo?

Yes — `claude-kitsync init --remote git@github.com:you/private-claude-config.git`. The remote is just a standard git remote. Use SSH keys or HTTPS tokens as you normally would.

### How do I install someone else's agent pack?

```bash
claude-kitsync install https://github.com/someone/claude-kit
```

This clones the kit into a temp directory, then copies only `agents/`, `skills/`, `rules/`, `hooks/`, `scripts/` and `CLAUDE.md`. `hooks/` and `scripts/` contain code that Claude Code will execute, so they are only installed after you confirm. It never touches your `settings.json`, `settings.local.json`, `.credentials.json` or kitsync configuration. You'll be prompted for each conflicting file: skip / overwrite / backup.

Only want skills? `claude-kitsync install --skill https://github.com/someone/claude-kit/tree/main/skills/my-skill`.

### What is `settings.template.json`?

A readable copy of `settings.json` with `__CLAUDE_HOME__` / `__HOME__` tokens, regenerated on every push. Claude Code never reads it. When encryption is enabled it is neither committed nor pushed.

### How does encryption work?

`claude-kitsync encrypt enable` generates a key in `~/.claude/.kitsync/encryption.key` (never synced — copy it to your other machines yourself). From then on only `settings.json.enc` is pushed; the plaintext `settings.json` and `settings.template.json` are untracked and ignored. Versions committed *before* you enabled encryption stay in git history: rotate any secret they contained.

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
- **`claude-kitsync install` runs nothing itself** — it only copies files, and asks before copying `hooks/` or `scripts/`, which Claude Code will execute later. Review third-party kits before accepting
- **Machine-local state never synced** — encryption keys (including rotated backups), conflict notices, rc-file backups
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
