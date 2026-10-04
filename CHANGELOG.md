# Changelog

## [1.2.9] — 2026-10-04

### Fixed
- **`settings` → Remote & Repository only repointed `origin`**, so connecting to an existing repository merged two configs, exactly like the old profile switch. It now goes through the same switch: the current config is pushed to its repository, synced files are backed up, then this machine takes the new repository's config (or moves its config there if the repository is empty). The active profile follows the new URL.

## [1.2.8] — 2026-10-04

### Fixed
- **Switching profile pushed one profile's files into the other's repository**: `profile switch` only changed the remote URL, so the next sync merged, say, your personal agents into the work repo. Switching now pushes the current profile to its own repository, backs up this machine's synced files, then gives the machine the other profile's config. An empty repository starts with this machine's config.
- **The profile list was replaced when switching**: it lived in the synced config, i.e. in each profile's repository. The registry (known profiles, active one) is now per machine, in `.kitsync/local`; existing setups migrate automatically.
- `profile add` without a terminal switched to the new profile on its own; it no longer does.

## [1.2.7] — 2026-10-04

### Fixed
- **After a key rotation, other machines silently forked the encrypted settings**: unable to decrypt the new `settings.json.enc`, a machine with the old key kept its stale settings without a word, then re-encrypted them with its old key and pushed them — leaving the remote with a version the rotating machine couldn't read. The synced config now records the key's fingerprint (the first 16 hex chars of its SHA-256; it reveals nothing about the key). A machine without the current key never encrypts or overwrites anything, is told at its next session, and `doctor` reports it as an error.
- **Once the right key is copied, settings catch up by themselves** at the next sync (the stale local file is backed up), instead of waiting for the next remote change.
- `encrypt rotate` re-encrypts the settings with the new key right away.
- A failed decryption is reported instead of ignored.

## [1.2.6] — 2026-10-04

### Fixed
- **`log -n <count>` ignored the count** and always showed 15 syncs.
- **`status` never checked the remote**, so incoming changes were invisible, and it called a tree with unpushed work "clean".
- **`status` and `diff` ignored what the next push sends** (changes not committed yet, which is the usual case since pushes happen at the end of a session): `diff` said "nothing to diff".
- `diff` without a terminal dumped the full diff; it now stops after the summary.

### Changed
- **`status` is a sync dashboard**: what the next push sends (the same preview as `push --dry-run`), what it would leave out, what stays local (categories this machine doesn't sync), unpushed commits, incoming commits and files (after a 10 s fetch), pending notices.
- **`log` lists the files of each sync**, and sync commits now name the machine that sent them, e.g. `kitsync: auto-push 2026-10-04 12:59 (work-laptop)`. The name is the short hostname, or `KITSYNC_MACHINE_NAME` in `.kitsync/local`.
- `diff`'s outgoing view includes changes not committed yet.

## [1.2.5] — 2026-10-04

### Fixed
- **The allowlist let dependencies, secrets and caches through inside synced folders**: a `node_modules/` from `bun install` in a skill, a `.env`, a `.pem` key, a Python `.venv/` or `__pycache__/`, logs. They are now never synced, even inside `skills/`, `hooks/`, `scripts/`… (`.env.example` still is). Existing setups get the rules automatically; such files already committed are untracked (kept on disk) with a warning.

## [1.2.4] — 2026-10-04

### Fixed
- **Path tokens cut into other paths sharing the prefix**: with `HOME=/Users/al`, `/Users/alice/x` was stored as `__HOME__ice/x` and became `/home/bobice/x` on another machine. A path is now replaced only where it ends.
- `__CLAUDE_HOME__` followed `$HOME/.claude` even when `CLAUDE_HOME` points elsewhere; it now maps one machine's `CLAUDE_HOME` to the other's.

### Changed
- **Portable paths cover synced text files, not only `settings.json`**: hook scripts, agents, skills and scripts (`.json`, `.md`, `.sh`, `.py`, `.ts`, `.js`, `.mjs`, `.cjs`, `.toml`, `.yaml`, `.yml`, `.txt`). Files already committed with this machine's paths are migrated in a single commit, without touching pending local edits.

## [1.2.3] — 2026-10-04

### Fixed
- **A machine that didn't pull a category could undo the others' changes to it**: it kept its old version locally and pushed it back at the end of the session (the push selection defaulted to everything). A category not pulled is now never pushed; the preferences menu says so.
- **A non-pulled category blocked every later pull, silently**: the kept local version looked like an unpushed edit, and since 1.2.1 the background pull skipped without telling anyone. Non-pulled paths are now held aside during the rebase and put back, so they never get in the way.
- **A background pull skipped because of a local edit is now reported** (shown at the next session) instead of being skipped silently, for good.
- **Under encryption, excluding `settings.json` from pulls had no effect**: the decrypted remote version overwrote the local one. `settings.json.enc` now follows the `settings.json` category.
- **The same new file created on two machines** made every pull fail without saying why (git refuses to overwrite an untracked file). It is now reported as a conflict; `pull --force` takes the remote's and backs up yours.

## [1.2.2] — 2026-10-04

### Fixed
- **A local commit whose push hit a conflict was silently lost**: the next background pull rebased with "remote wins" (`-X ours`), dropped the local change and cleared the conflict notice. Pulls no longer force a side: changes to different lines merge, and a real conflict is left for you (the background pull changes nothing and Claude Code shows the notice).
- **The conflict menu's "Accept remote" ran `git reset --hard`**, erasing every unpushed local commit (even unrelated ones), with no backup — and it was picked automatically without a terminal. It is gone.
- **"Keep local" did nothing**, so the next push failed again on the same conflict.
- The conflict notice suggested `pull --force` to "take the remote", which it didn't do.
- `claude-kitsync pull` refused to run as soon as any file was modified; it now only stops on edits to files the remote changed, and names them.
- The conflict notice could fail to be written when `.kitsync/` did not exist yet.

### Changed
- **`claude-kitsync pull` resolves conflicts file by file**: a labelled diff, then **remote** (your version is backed up to `.kitsync/backups/pull-<date>/`) or **local** (kept and pushed right away). Without a terminal nothing is decided and the conflict is recorded.
- **`pull --force`** takes the remote for every conflicting file — committed or not — and backs up the local versions.

## [1.2.1] — 2026-10-04

### Fixed
- **Deleted files were never pushed**: push only staged paths that still existed, so a deleted `CLAUDE.md` or folder stayed on the remote, came back on other machines, and left the tree dirty. Deletions are pushed now.
- **Background pulls stopped forever on a machine with a local-only edit** (a category excluded from push, such as `settings.json` that Claude Code rewrites): since 1.1.15 `pull --auto` skipped on any local change. It now skips only when the remote changed one of the same files; other local edits are set aside and put back.
- **Selective pull could overwrite a local edit** in an excluded category: it restored the whole folder to its pre-pull state. It now restores only the files the pull changed.
- **Per-machine preferences were synced**, so the last machine to push imposed its pull/push modes, categories, timer and upgrade channel on all the others. They now live in `.kitsync/local` (never synced); `.kitsync/config` keeps what machines must share (encryption, profiles). Existing setups migrate automatically, each machine keeping its own values.

### Added
- **Secret check on push**: a file whose new lines look like an API key or token (Anthropic, OpenAI, GitHub, AWS, Slack, Google, private keys) is left out with a warning — the secret itself is never printed. `claude-kitsync push --allow-secret <file>` lets a file through.
- `push --dry-run` runs the real staging on a throwaway index: it previews encrypted settings and shows what would be left out (half-merged files, invalid JSON, secrets), then restores the derived files it wrote.

## [1.2.0] — 2026-10-03

### Changed
- **Sync now runs from Claude Code hooks instead of a `claude()` function in your shell rc.** `settings.json` gets three entries: `SessionStart` (background pull + sync notices), `SessionEnd` (background push) and, in timer mode only, `Stop` (push at most every N minutes). Claude Code fires them in every session — terminal, IDE extensions, desktop app — where the shell function only covered `claude` typed in a terminal. Each hook only starts a detached job, so Claude never waits on the network.
- **Upgrading migrates automatically**: the hooks are added (your own hooks are kept, `settings.json` is backed up) and the `claude()` block is removed from your rc file. Without `python3`, kitsync keeps the shell function as a fallback.
- `claude-kitsync settings` → "Sync triggers" installs/repairs the hooks or turns automatic sync off; `doctor` reports which trigger is active; `uninstall` removes the hooks too. Changing the push mode adds or removes the `Stop` hook.
- Sync notices (pending conflict, file not pushed, config updated) are shown by Claude Code at session start.

### Fixed
- **`push` when another machine had pushed first** failed and still printed "Push complete." It now replays your commits on top of the remote and retries; a real conflict keeps your commit locally and is reported for `claude-kitsync pull`.
- `init` generated `settings.template.json` before its last change to `settings.json`, so every machine committed its own version and the next push conflicted.
- `init` on a second machine reported `settings.json` as a conflict when only formatting or kitsync's own hook entries differed.

### Removed
- `templates/shell-wrapper.sh`, an unused copy of the old wrapper.

## [1.1.15] — 2026-10-03

### Fixed
- **The `claude()` wrapper did not parse in bash** (zsh's `&!`): bash users got an error on every new shell and never had automatic sync. Background jobs now use `( cmd & )`, which works in both shells.
- **Auto-pull could push a broken `settings.json` to every machine**: with an uncommitted edit, `git pull --autostash` left conflict markers in the file and reported success; the end-of-session push then committed them. The wrapper now calls `claude-kitsync pull --auto`, which skips the pull when there are local edits instead of stashing them.
- **Auto-pull ignored the pull selection, decryption order and conflict rules** of `claude-kitsync pull`: it now runs the same code.
- **`push` never checks for half-merged files**: files with new conflict markers, and an invalid `settings.json`, are now left out of the commit with a warning (shown again at the next `claude` launch). Conflict markers already in the committed file (docs about merges) don't block.
- **The path-token migration committed local `settings.json` edits on its own** before every push and pull, bypassing the push selection and checks. It now commits only the tokenized version of the already-committed file.
- **A second machine could never pull after `init`**: `.kitsync/config` was committed by the first push only, so the next pull stopped on "untracked working tree files would be overwritten". `init` now commits it in the first commit, and existing setups track it automatically before syncing.
- **Concurrent syncs** (two terminals, or a pull and an end-of-session push) could run git at the same time, and one could `rebase --abort` the other's rebase. A per-machine lock (in `.git/`, never synced) now serialises them; background syncs skip or wait.
- **The 2 s auto-pull timeout covered the whole pull**, so slow networks never pulled, and a killed git could leave `index.lock` behind. The timeout (`KITSYNC_TIMEOUT`, now 10 s) applies to the download only.
- **Timer push loop survived a closed terminal** and kept pushing forever; it now stops when its shell is gone.

### Changed
- `claude --version`, `--help`, `update`, `mcp`, `config`, `doctor`, `plugin`… no longer trigger a sync.

## [1.1.14] — 2026-10-03

### Added
- **`claude-kitsync setup-kit`** wires the starter kit's hook and scripts into `settings.json` (backup first, idempotent, never replaces your own status line); `--print` shows the snippet instead. `init` offers it right after importing `hooks/` or `scripts/` — before, they were copied but never run.

### Fixed
- **Starter kit `rm_to_trash.py` rewrote any `rm`**, e.g. `git rm --cached` → `git trash --cached`. It now only rewrites `rm` used as a command (also after `sudo`/`xargs`, `\rm`, `/bin/rm`), keeps the rest of the tool input, and works on Linux: `trash`, `trash-put` or `gio trash`, whichever exists. With none installed, Claude's `rm` is blocked with install instructions — never run for real.
- Starter kit `CLAUDE.md` pointed to a `/push` skill the kit does not ship.

### Changed
- Starter kit `scripts/` trimmed to what runs (no tests, fixtures, lockfile, lint config or dev notes); `package.json` lists only the dependency actually used. Status line, `apex` (isolated-agent flow with `-s`) and `commit` skills updated to their current versions.
- The starter kit import menu starts with nothing selected, and says what `hooks/` and `scripts/` need.

## [1.1.13] — 2026-10-03

### Fixed
- **`init`'s conflict prompt crashed on macOS's bash 3.2** (`${x^^}`: bad substitution), leaving a half-initialised repo on the first real conflict.
- **No conflict prompt during `curl | bash`**: it checked stdin (the pipe) instead of the terminal, so every conflict silently took the remote version.
- **The local version was lost when the remote one was chosen**: it is now backed up to `.kitsync/backups/init-<date>/` first, and the path is printed.
- **False conflict on `settings.json`**: the comparison used the remote's path tokens (`__CLAUDE_HOME__`) instead of this machine's paths.
- `init` compares against `origin/main` explicitly, not whichever branch `FETCH_HEAD` listed first.

### Changed
- The conflict choice is now **Remote** or **Local**. "Pass" left the file out of the first commit only; the next push sent it anyway. Remote plus the backup covers that need.
- Conflicts show a labelled unified diff (`--- remote` / `+++ local`).

## [1.1.12] — 2026-10-03

### Fixed
- **Re-running `init` wiped `.kitsync/config`**: the encryption flag (settings silently stopped syncing), every other profile and the upgrade channel were lost. `init` now only updates its own keys, offers to keep the current sync preferences, and defaults the profile name to the active profile.
- **`init`'s GitHub menu always used an SSH URL** (fixed in `install.sh` in 1.1.7, not here): the URL now follows `gh`'s git protocol.
- **LOCAL choices were overwritten on the first push**: when the remote already had history, `init` rebased with `-X ours`, which in a rebase means the remote. It now uses `-X theirs` (your choices win), aborts cleanly on failure, and shows git's error.
- **An existing non-allowlist `.gitignore` was kept**, leaving conversations and caches pushable. `init` now backs it up and installs the allowlist (asked in a terminal, default otherwise), and stops tracking files it excludes (kept on disk).
- **Without a terminal, the starter kit was imported in full** and pushed. Nothing is imported without a terminal now.

### Changed
- Prompts return their default without a terminal on purpose instead of by accident; `KITSYNC_NO_TTY=1` forces it.

## [1.1.11] — 2026-10-02

### Changed
- **`doctor` checks that sync actually works**, in four sections:
  - **Config repo**: the remote is reachable, not just configured. This is a 15 s check that never prompts, and it shows git's error.
  - **Sync**: unpushed or unpulled commits, a rebase or merge stuck in progress, a pending conflict, each with the command that fixes it.
  - **Data safety**: the `.gitignore` is still the allowlist, no excluded file is tracked (e.g. `projects/` conversations), `settings.json` is not tracked in plaintext when encryption is on, and the portable paths filter is active.
  - **Installation**: version and available update, several installs on PATH, `gpg` missing, wrapper.
- Check numbering was inconsistent ([1/6] … [5/7]); checks are now grouped by section.

### Fixed
- **The PATH line stacked `~/.local/bin` again every time the rc file was sourced** (which kitsync asks you to do after a wrapper update). It is now idempotent; existing installs are migrated automatically.
- **Running a dev checkout's CLI could point your rc completion block at that checkout.** Only the installer's own clone now rewrites it.

## [1.1.10] — 2026-10-02

### Fixed
- **`uninstall` deleted whatever directory it ran from**: run from a dev checkout, or after an install with `KITSYNC_INSTALL_DIR`, it erased that working copy. It now deletes only the installer's own clone (`~/.local/share/kitsync`) and leaves any other directory in place with a warning.
- **`uninstall` asked nothing**: it now lists what it will remove and what it keeps, and asks first (`--yes` for scripts; without a terminal it refuses).
- **`uninstall` could remove another install's binary** (e.g. Homebrew's link, first in PATH): it now removes only links pointing to its own install.
- **rc edits replaced a symlinked rc file** (dotfiles repo) with a plain copy and reset its permissions to 600. Edits are now written in place.
- **Removing the PATH entry deleted the line after the marker blindly**, even when it was no longer the `export PATH=` line. PATH and completion removals now also back up the rc file first.

### Changed
- `uninstall` removes the machine-local state file added in 1.1.9 and says what remains (`~/.claude`, its history and remote).

## [1.1.9] — 2026-10-02

### Security
- **Releases are signed**: the release workflow signs `SHA256SUMS` and the tarball with a dedicated key (`keys/release-signing.asc`, fingerprint `592A3F382C542ABAA60AAED66F6EC0A51AFF673D`) and fails without it. `upgrade` checks the signature, the tarball checksum and that the fetched tag matches the tarball before installing anything; `--no-verify` skips the check. Without `gpg` installed, the check is skipped with a warning.

### Fixed
- **`upgrade` left the shell wrapper and completion block of the old version in your rc file**: they are copied there at install time and were never refreshed. They are now updated after an upgrade, and on the first run of a new version installed another way (Homebrew, or an `upgrade` run by an older version).
- **`upgrade` hid git's error messages** behind "check your network".
- **`upgrade` silently discarded local changes** in the install directory: it now lists them and asks first (`--force` to skip).
- **rc backups**: two edits within the same second overwrote the backup of the original file with the intermediate one.
- **`upgrade`'s fallback** (when the GitHub API is unreachable) would have picked a pre-release tag such as `v1.2.0-rc1`.

### Added
- `upgrade` prints the release notes of the versions it installs.

### Changed
- **Homebrew formula now downloads the release tarball** instead of GitHub's auto-generated source archive. Its checksum is the one published in `SHA256SUMS`, and it cannot change between downloads.

## [1.1.8] — 2026-09-30

### Fixed
- **Homebrew formula never installed** (since v1.0.0): `libexec.install` moved `completions/` before the completion files were installed (`Errno::ENOENT: completions/_claude-kitsync`). Completions are now installed first; verified with `brew install`, `brew test` and `brew style`.
- **`uninstall` on a Homebrew install deleted files inside Homebrew's Cellar**, leaving a corrupted formula. It now removes the shell wrapper and tells you to run `brew uninstall claude-kitsync`.
- **`upgrade` on a Homebrew install** suggested re-running the curl installer (creating a second install); it now points to `brew upgrade claude-kitsync`.
- Several messages printed a literal `\n`.

### Changed
- Formula gains a `livecheck` block (latest GitHub release).

## [1.1.7] — 2026-09-30

### Fixed
- **Installer: `KITSYNC_REMOTE` was never seen** — the documented `KITSYNC_REMOTE=… curl … | bash` only sets the variable for `curl`. Docs now use `curl … | KITSYNC_REMOTE=… bash`, and no longer claim a prompt-free setup.
- **Installer: Ctrl+C in a menu selected the highlighted option** instead of aborting.
- **Installer: an existing `~/.claude` git repo not set up by kitsync skipped `init` entirely** (no allowlist, no remote) while reporting success. `init` now runs; only a repo already configured by kitsync is left as is.
- **Installer: GitHub repos were always wired with an SSH URL**; the URL now follows `gh`'s configured git protocol.
- Installer shows git's actual error when cloning or updating fails.
- `upgrade --dev` works on installs sitting on a release tag (detached HEAD).
- `uninstall` also cleans `~/.bash_profile` (used for bash on macOS) and removes the completion setup.

### Changed
- **The installer installs the latest release** (same channel as `upgrade`) instead of `main`; pin with `KITSYNC_VERSION=vX.Y.Z` or `KITSYNC_VERSION=main`.
- **Verifiable installer**: `install.sh` is published with each release and listed in `SHA256SUMS` (see README "Verified install").
- Completions are loaded by your rc file straight from the install dir — no more links in Homebrew's prefix or in `~/.zsh/completions` (which zsh never searched). Old links, including dangling ones, are removed.
- Tests no longer run the real installer against the network (it used to leave completion links in the Homebrew prefix); an offline re-run test replaces it.

## [1.1.6] — 2026-09-30

### Fixed
- **`upgrade` could downgrade.** It only checked that the installed version differed from the latest GitHub release, so right after a new tag was pushed (before its release existed) it "upgraded" back to the previous version. Versions are now compared numerically and `upgrade` never goes backwards.

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
