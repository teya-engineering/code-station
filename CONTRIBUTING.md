# Contributing to Teya Conductor

This guide covers the development workflow and the technical details behind the app. For the user-facing overview and normal build instructions, see [README.md](README.md).

## Development setup

You need:

- macOS 14 or later
- Xcode 16 or another Swift 6 toolchain
- Git

The app has one Swift package dependency, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), which Swift Package Manager resolves automatically.

Build and run the executable:

```bash
swift build --disable-sandbox
swift run --disable-sandbox
```

Create the app bundle used for normal manual testing:

```bash
./build-app.sh
open "build/Teya Conductor.app"
```

`build-app.sh` builds the `MenuBarApp` executable, copies its SwiftPM resource bundle into the app, adds the icon and `Info.plist`, and applies an ad-hoc signature. The result is written to `build/Teya Conductor.app`.

## Tests

Run the full test suite after changing code:

```bash
swift test --disable-sandbox
```

Run a focused test while iterating:

```bash
swift test --disable-sandbox --filter GitActionsTests
```

Tests live in `Tests/MenuBarAppTests`. They cover session and transcript behavior, CLI stream parsing, Git and worktree operations, terminal and PTY integration, file browsing, Postman and OAuth flows, skills, settings, persistence, and UI-facing presentation logic.

Add tests for behavior and business logic. Trivial view wiring, accessors, and framework behavior do not need dedicated tests.

## Project structure

- `Package.swift` defines the macOS executable and test targets.
- `Sources/MenuBarApp/MenuBarApp.swift` creates the application window and shared services.
- `Sources/MenuBarApp/RootView.swift` owns the top-level navigation and tool sheets.
- `Sources/MenuBarApp/Projects` contains projects, workspaces, sessions, Git support, the chat UI, the file explorer, and transcript persistence.
- `Sources/MenuBarApp/Terminal` contains the PTY-backed terminal and SwiftTerm integration.
- `Sources/MenuBarApp/Postman` contains saved HTTP requests, environments, OAuth, and response handling.
- The remaining files in `Sources/MenuBarApp` contain MCP, skills, Docker, local AI, settings, logging, and shared UI components.
- `Tests/MenuBarAppTests` mirrors the main behaviors with unit and integration tests.

## Runtime design

`AppDelegate` is the composition root. It creates the observable stores and services once, injects them into the SwiftUI environment, and shuts down child processes and terminals when the app quits.

A project is a reference to a folder on disk. A workspace is a reusable group of projects with one lead project. When a session starts, it records its own project paths and worktree choices so later workspace edits do not change an existing conversation.

`SessionRunner` launches the selected `codex` or `claude` executable and reads its JSONL stream. The Codex and Claude adapters normalize their different protocols into shared `StreamEvent` values. The rest of the app can then render messages, tool calls, permission requests, usage, and completion state without agent-specific branches.

Git worktree sessions use a checkout and branch owned by that session. Workspace sessions may create a separate worktree for each Git project. A session using a project folder edits that folder directly. Git inspection is kept separate from the commands that switch, commit, pull, and push.

The terminal uses a real pseudo-terminal through SwiftTerm. Each tab owns its shell process and remains alive while the drawer is closed.

## Persistence and local processes

App-owned data lives under:

```text
~/Library/Application Support/com.teya.conductor/
```

This includes the project and session index, one transcript file per session, saved HTTP requests, command shortcuts, worktrees, temporary attachments, and the cached skills marketplace. Small UI preferences use `UserDefaults`. OAuth client secrets and tokens use the macOS Keychain. Session logs live under `~/Library/Logs/com.teya.conductor`.

MCP definitions are read from and written to `~/.config/mcp/config.json`. The app uses those shared definitions when it registers a server in each coding agent's own configuration. Locally started MCP servers, shortcut commands, agent processes, and terminal shells are child processes owned by the app and are stopped when the app quits.

A Finder-launched app receives a limited `PATH`. Executable lookup also checks common Homebrew, local user, Go, and system binary directories. Use `ProcessManager.resolve` for new command-line integrations so they follow the same behavior.

## UI conventions

The app uses its own visual system instead of native controls with fixed macOS chrome.

- Use the shared colors and typography in `Theme.swift`.
- Show dialogs through `DialogPresenter` and the in-app `Dialog` type.
- Use `.appMenu` and `.appContextMenu` for menus.
- Use `ChoicePill` for segmented choices.
- Use `.appSwitch` and `.appCheckbox` for toggles.
- Style button labels explicitly and apply `.buttonStyle(.plain)`.
- Use plain text fields on a `Theme.field` background with a `Theme.border` stroke.
- Keep `NSOpenPanel` and `NSSavePanel` for file selection, where the system surface is expected.

Prefer existing controls and patterns before adding another variation. Comments should explain a constraint or reason that the code cannot make clear on its own.

## Before submitting a change

1. Build the package with `swift build --disable-sandbox`.
2. Run `swift test --disable-sandbox`.
3. For UI changes, build the app bundle and check the affected flow in the running app.
4. Review the diff for unrelated generated files or local configuration.

Keep commits focused and use a short imperative message such as `Improve session cleanup`.
