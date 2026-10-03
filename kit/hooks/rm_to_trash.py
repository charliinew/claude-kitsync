#!/usr/bin/env python3
"""
PreToolUse hook (Bash): send files Claude deletes to the system trash instead
of erasing them, so a wrong `rm` can always be undone.

  rm file          -> trash file
  rm -rf dir       -> trash dir
  sudo rm -f a b   -> sudo trash a b

Only `rm` used as a command is rewritten: at the start, after ; & | ( or a
newline, or after sudo / xargs. Subcommands such as `git rm` or
`terraform state rm` are left alone.

Trash command, first one found:
  trash      macOS 15+ (built in), Homebrew `trash`, or trash-cli
  trash-put  trash-cli (Linux)
  gio trash  GLib, present on most Linux desktops
If none is installed the command is blocked with install instructions: it
never falls back to a permanent rm.
"""
import json
import re
import shutil
import sys

INSTALL_HELP = (
    "rm is routed to the trash, but no trash command is installed. Install one, "
    "then retry: macOS 14 or older `brew install trash`; Debian/Ubuntu "
    "`sudo apt install trash-cli`; Fedora `sudo dnf install trash-cli`; "
    "Arch `sudo pacman -S trash-cli`."
)

# lead: start of command, shell operator, or sudo/xargs; then rm (also \rm,
# /bin/rm, /usr/bin/rm), its options, and an optional `--` terminator
RM = re.compile(
    r"(?P<lead>(?:^|[;&|(\n]|\bsudo|\bxargs)\s*)"
    r"(?:\\|(?:/usr)?/bin/)?rm"
    r"(?:\s+-[A-Za-z]+|\s+--[A-Za-z][A-Za-z-]*)*"
    r"(?P<dashdash>\s+--)?"
    r"(?=\s|$|[;&|)])"
)


def trash_command():
    for name in ("trash", "trash-put"):
        path = shutil.which(name)
        if path:
            return name, path
    if shutil.which("gio"):
        return "gio trash", shutil.which("gio")
    return None, None


def main():
    data = json.load(sys.stdin)
    tool_input = data.get("tool_input", {})
    cmd = tool_input.get("command", "")
    if not RM.search(cmd):
        print("{}")
        return

    name, path = trash_command()
    if name is None:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": INSTALL_HELP,
        }}))
        return

    # macOS's built-in trash reads `--` as a file name; the others accept it
    keep_dashdash = not (sys.platform == "darwin" and path == "/usr/bin/trash")

    def repl(m):
        tail = m.group("dashdash") if (m.group("dashdash") and keep_dashdash) else ""
        return m.group("lead") + name + tail

    new_cmd = RM.sub(repl, cmd)
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        # updatedInput replaces the whole input: keep description, timeout...
        "updatedInput": dict(tool_input, command=new_cmd),
    }}))


if __name__ == "__main__":
    main()
