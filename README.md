# Teya Conductor

[![GitHub Pages](https://img.shields.io/badge/GitHub%20Pages-site-222222.svg?logo=githubpages)](https://example.github.io/)
[![Contributing](https://img.shields.io/badge/Contributing-guide-2ea44f.svg?logo=github)](CONTRIBUTING.md)

Teya Conductor is a macOS app for running Codex and Claude Code across local projects. It brings the conversation, project files, Git state, and a terminal into one window, while each coding agent continues to use its own CLI and account.

## Main features

### Projects, workspaces, and sessions

- Add any local folder as a project and keep its agent sessions together.
- Group related projects into a reusable workspace. One project is the lead working directory and the others are attached to the same conversation.
- Run a session in the project folder when you want changes to land there immediately.
- Run a session in an isolated Git worktree when you want its own checkout and branch. Independent worktree sessions can run at the same time without editing the same files.
- Choose Codex or Claude Code for each session, along with its model, reasoning effort, and access settings.
- Resume saved conversations after relaunching the app and review old sessions before removing them.

### Everything needed around the conversation

- Read streamed replies and follow tool activity while the agent works.
- Answer questions and permission requests without switching to a terminal.
- Attach files by dropping or pasting them into the composer.
- Browse, preview, search, and edit files in the session checkout.
- Review Git changes and diffs, switch branches, commit, pull, and push from the app.
- Open a full terminal in the session directory, with multiple tabs that keep running while the drawer is closed.
- See token use, context use, changed-line totals, background activity, and pull requests associated with a session.

### Built-in tools

- Configure MCP servers and register them with Codex, Claude Code, or both.
- Install and update agent skills from the Example Engineering marketplace.
- Save and send HTTP requests with environment variables, path and query parameters, headers, request bodies, and OAuth secrets and tokens stored in the macOS Keychain.
- Inspect running Docker containers and stop them when needed.
- Save, edit, run, and stop shell-command shortcuts while inspecting their output. A local Qwen model through `llama-server` is included by default.
- Start a guided troubleshooting session with project context, attachments, environment safeguards, and configured observability tools.

## Build and run

### Requirements

- macOS 14 or later
- Xcode 16 or another Swift 6 toolchain
- Git
- At least one supported coding agent installed and signed in: `codex` or `claude`

Docker, MCP server executables, and `llama-server` are optional. Their tools and shortcuts remain available in the app and show command failures in context when a dependency is not installed.

### Build the app

Clone the repository and create a double-clickable app bundle:

```bash
git clone git@github.com:example/teya-conductor.git
cd teya-conductor
./build-app.sh
open "build/Teya Conductor.app"
```

The build script creates an ad-hoc signed release bundle at `build/Teya Conductor.app`. You can move that bundle to `/Applications` for normal use.

For a quick development run without creating an app bundle:

```bash
swift run --disable-sandbox
```

The app bundle is recommended for regular use and is required for the Start at Login setting.

## Get started

1. Open Teya Conductor and add a project folder.
2. Open Settings to choose the default agent and its access settings.
3. Start a session and choose whether it should use the project folder or an isolated worktree.
4. Describe the task, attach any useful files, and follow the work in Chat, Changes, Explorer, or Terminal.

For development setup, tests, architecture, and project conventions, see [CONTRIBUTING.md](CONTRIBUTING.md).
