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
3. Initialise `~/.claude` as a git repo + add the sync hooks to `~/.claude/settings.json`

Open a new terminal (for the `claude-kitsync` command itself) and you're done: every Claude Code session — terminal, IDE extension or desktop app — now syncs.

**If you already know your remote URL** — the variable goes on the `bash` side of the pipe:

```bash
curl -fsSL https://raw.githubusercontent.com/charliinew/claude-kitsync/main/install.sh \
  | KITSYNC_REMOTE=git@github.com:you/claude-config.git bash
```

This skips the storage question; `init` still asks for a profile name and your sync preferences.

The installer installs the latest release. Pin a version with `KITSYNC_VERSION=v1.1.6`, or follow development with `KITSYNC_VERSION=main`.

**Verified install** — check the installer against the signed release checksums before running it:

```bash
B=https://github.com/charliinew/claude-kitsync/releases/latest/download
curl -fsSLO "$B/install.sh" -O "$B/SHA256SUMS" -O "$B/SHA256SUMS.asc"
curl -fsSL https://raw.githubusercontent.com/charliinew/claude-kitsync/main/keys/release-signing.asc | gpg --import
gpg --verify SHA256SUMS.asc SHA256SUMS && shasum -a 256 -c --ignore-missing SHA256SUMS && bash install.sh
```

`gpg --verify` must report a good signature from key `592A 3F38 2C54 2ABA A60A  AED6 6F6E C0A5 1AFF 673D` (claude-kitsync release signing). Releases from v1.1.9 on are signed, and `claude-kitsync upgrade` checks this signature itself before installing a new version.

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
| `claude-kitsync init [--remote <url>]` | Initialise `~/.claude` as git repo + add the sync hooks |
| `claude-kitsync push [-m "message"] [--dry-run]` | Commit and push whitelisted changes; `--dry-run` previews without committing |
| `claude-kitsync pull [--force]` | Pull manually from remote (skips if dirty working tree) |
| `claude-kitsync status` | Show modified files and ahead/behind count |
| `claude-kitsync log [-n <count>]` | Show sync history (default: last 15 commits) |
| `claude-kitsync diff` | Show diff between local and remote before pushing |
| `claude-kitsync publish` | Package and publish agents/skills as a kit to GitHub |
| `claude-kitsync restore` | Restore a rc file from a timestamped backup |
| `claude-kitsync setup-kit [--print]` | Wire the starter kit's hooks and status line into `settings.json` (`--print`: show the snippet instead) |
| `claude-kitsync install [--skill] <url>` | Merge a public kit into `~/.claude` (no overwrite of local config); `--skill` installs skills only |
| `claude-kitsync profile [list\|add\|switch\|remove]` | Manage named remotes for multi-environment sync (work, perso…) |
| `claude-kitsync encrypt [enable\|disable\|rotate\|status]` | Encrypt `settings.json` with AES-256 before push (opt-in) |
| `claude-kitsync settings` | Interactive menu to change pull/push mode, remote URL, sync triggers |
| `claude-kitsync doctor` | Diagnose the health of your setup |
| `claude-kitsync upgrade` | Update claude-kitsync to the latest release (signature checked, release notes shown) |
| `claude-kitsync uninstall [--yes]` | Remove claude-kitsync (binary, PATH, sync hooks); `~/.claude` is kept |

---

## How It Works

**Claude Code hooks** — `claude-kitsync init` adds three entries to `~/.claude/settings.json`. Claude Code runs them in every session, wherever it runs (terminal, IDE extensions, desktop app); each one only starts a background job, so Claude never waits on the network:

| Hook | What kitsync does |
|---|---|
| `SessionStart` | pulls in the background, and shows any sync notice (conflict, file not pushed, config updated) |
| `SessionEnd` | pushes in the background (default push mode) |
| `Stop` | in timer mode only: pushes at most every N minutes |

Pulled changes to `settings.json` apply from the next session. The background pull never touches files you edited and haven't pushed yet, and a push never sends a half-merged file or an invalid `settings.json`. Two syncs never run at the same time on one machine.

Without `python3` (needed to edit `settings.json`), kitsync falls back to a `claude()` function in your `~/.zshrc`/`~/.bashrc`, which only syncs sessions started from a terminal. Versions before 1.2.0 used that function; upgrading replaces it with the hooks.

**Git-in-~/.claude** — your config directory becomes a standard git repo. Only explicitly whitelisted files are committed:

- `settings.json`, `CLAUDE.md`, `keybindings.json`
- `agents/`, `skills/`, `hooks/`, `scripts/`, `rules/`, `commands/`, `output-styles/`, `workflows/`, `themes/`

`skills/synced/` is excluded: it holds the skills of your claude.ai account, which Claude Code downloads by itself on startup.

Pick a subset per direction with **selective sync** (`claude-kitsync settings` → Sync categories), separately on each machine: for example push `skills/` from every machine but never pull `settings.json` on a work laptop. A category a machine doesn't pull is its own local version: pulls never overwrite it, and it is never pushed either — pushing a version that never saw the other machines' changes would undo them.

**Portable paths** — `settings.json` often contains paths like `/Users/alice/.claude/hooks/...`. A git clean/smudge filter stores them in the repo as `__CLAUDE_HOME__/hooks/...` (and `$HOME` as `__HOME__`) and expands them back to the current machine's paths on checkout. Your working copy always keeps real absolute paths; only the committed version is tokenized.

---

## FAQ

### Will `.credentials.json` ever be synced?

No. The `.gitignore` uses a deny-by-default allowlist — only explicitly whitelisted files can be committed. `.credentials.json` is additionally double-blocked and `claude-kitsync push` will abort with an error if it somehow ends up staged.

### What happens if I have uncommitted changes when `claude` runs?

The background pull stashes them, pulls, and re-applies them (`--autostash`). A manual `claude-kitsync pull` refuses to run on a dirty tree unless you pass `--force`. Your local changes are never discarded; run `claude-kitsync push` to commit them.

### Who wins when the same file changed on two machines?

Nobody, silently. Changes to different lines of a file merge by themselves. When the same lines changed on both machines:

- the background pull (each session start) changes nothing and Claude Code shows a "sync conflict pending" notice;
- `claude-kitsync pull` in a terminal shows each conflicting file as a diff and asks **remote** or **local**. Remote keeps a copy of your version in `~/.claude/.kitsync/backups/pull-<date>/`; local is pushed right away;
- `claude-kitsync pull --force` takes the remote for every conflicting file, backing up yours.

A change that never reached the remote is never dropped without asking. Use `claude-kitsync diff` first if you want to review.

### My `settings.json` has broken paths after pulling on a new machine.

Run `claude-kitsync pull` once — it registers the path filter for this machine and rewrites any foreign `/Users/<name>/.claude` or `/home/<name>/.claude` path in `settings.json` to your own `$HOME`. The background pull does the same after each sync.

### Can I use this with a private repo?

Yes — `claude-kitsync init --remote git@github.com:you/private-claude-config.git`. The remote is just a standard git remote. Use SSH keys or HTTPS tokens as you normally would.

### What is in the starter kit, and what does it need?

`init` offers to import a starter config (agents, skills, `CLAUDE.md`, a hook and two scripts). Nothing is preselected for you to import blindly: pick what you want. The hook and scripts only run once `settings.json` points to them — `init` offers to do it (with a backup), or run `claude-kitsync setup-kit` later; `setup-kit --print` shows the snippet to add by hand.

| Component | What it does | Needs |
|---|---|---|
| `hooks/rm_to_trash.py` | Every `rm` Claude runs goes to the system trash instead, so a wrong deletion can be undone. `git rm`, `terraform state rm`… are left alone. With no trash command installed, Claude's `rm` is blocked — never run for real. | `python3`, and a trash command: built in on macOS 15+ (`brew install trash` on older macOS); `trash-cli` (`apt`/`dnf`/`pacman`) or `gio` on Linux |
| `scripts/command-validator` | Blocks dangerous shell commands (`rm -rf`, `curl \| sh`, writes to system paths…) before Claude runs them | [Bun](https://bun.sh) |
| `scripts/statusline` | Status line: git branch, path, session cost, context usage | Bun |

An existing status line of yours is never replaced, and running `setup-kit` twice adds nothing twice.

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

### `claude-kitsync doctor` says there is no automatic sync

Run `claude-kitsync settings` → Sync triggers → Install / repair hooks. It's idempotent, keeps your own hooks, and backs up `settings.json` first.

### How do I uninstall completely?

```bash
claude-kitsync uninstall
exec $SHELL
```

This removes the binary, PATH entry and sync hooks in one command (`~/.claude` and its remote are kept).

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
- Optional, for the starter kit's hook and scripts: `python3`, a trash command, [Bun](https://bun.sh) (see FAQ)

---

## License

MIT
