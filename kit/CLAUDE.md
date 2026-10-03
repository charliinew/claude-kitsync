# Claude Code — Starter Configuration

> Installed via [claude-kitsync](https://github.com/charliinew/claude-kitsync)

## Setup

This configuration is synced automatically across machines using `claude-kitsync`.

```bash
claude-kitsync status   # see pending changes
claude-kitsync push     # commit and push config changes
claude-kitsync pull     # pull latest from remote
```

## Workflow

- `claude` is wrapped — a background pull runs silently on each launch
- Changes are pushed when a session ends; push now with `claude-kitsync push -m "message"`
