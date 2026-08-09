# Teya Conductor

Teya Conductor is a macOS app for running Codex and Claude Code across local projects. It combines a streaming chat with the project files and Git state, so coding agents can work in the project folder or an isolated worktree.

## Features

- Run Codex or Claude Code in projects and reusable multi-project workspaces.
- Keep concurrent sessions isolated with Git worktrees.
- Review changes, browse and edit files, and use a full terminal without leaving the session.
- Answer agent questions and permission requests in the chat.
- Manage MCP servers and agent skills, with tools for Docker, HTTP requests, local AI, and troubleshooting.

## Requirements

- macOS 14 or later
- Xcode 16 or a Swift 6 toolchain
- The `codex` or `claude` CLI on your `PATH`

## Run

```bash
swift run --disable-sandbox
```

For a double-clickable app bundle:

```bash
./build-app.sh
open "build/Teya Conductor.app"
```

## Test

```bash
swift test --disable-sandbox
```
