# ADR 0004 - Local data and processes

## Context

Code Station is a local Mac app with no server of its own. It stores conversations and settings, and it starts many child processes: agents, terminals, MCP servers and shortcuts. Data must not be lost or brought back by mistake, and nothing should keep running after the app quits.

## Decision

All app data stays on the Mac, in plain files the app owns:

- Projects, sessions, one transcript file per session, saved requests, shortcuts and review comments live in `~/Library/Application Support/com.teya.code-station/`.
- Managed worktrees live in `~/.code-station/` (see [ADR 0003](0003-projects-workspaces-and-worktrees.md)).
- Small UI preferences use `UserDefaults`. Secrets and tokens use the macOS Keychain.
- Logs live in `~/Library/Logs/com.teya.code-station`.
- MCP servers are defined once in `~/.config/mcp/config.json` and registered from there into each agent's own config.

Writes to one transcript happen in order, so a queued write cannot bring back a deleted conversation. Normal edits and streamed replies save in the background. Actions that must not be lost wait for the save. A failed read or write shows a visible warning, and the app keeps the data in memory so the user can retry.

Every process the app starts is its child and is stopped when the app quits. A Mac app opened from Finder gets a short `PATH`, so commands are found through `ProcessManager.resolve`, which also checks the usual Homebrew and user tool folders.

Docker commands support every common engine on a Mac (Docker Desktop, Rancher Desktop, Podman, Colima and OrbStack), and fall back to plainer forms when one engine rejects a command.

## Consequences

- There is no account or sync. A user's data is only on the Mac where they made it.
- Uninstalling the app leaves its data folders behind until the user removes them.
- New command-line integrations must use `ProcessManager.resolve` and run as child processes, or they will miss tools and outlive the app.
