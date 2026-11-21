# Contributing to Teya Code Station

This guide covers the development workflow. The design and the decisions behind it live in [`docs/`](docs). For the user-facing overview and normal build instructions, see [README.md](README.md).

## Development setup

You need:

- macOS 15 or later
- The Xcode named in `.xcode-version`
- Git

CI builds, tests and releases with the Xcode named in `.xcode-version`. Use the same one locally (`xcodes install` reads that file). A Swift release can reject or crash on code that another release builds, and the SDK a build links against decides some AppKit behaviour, so a different Xcode can pass locally and fail in CI. To move to a new Xcode, change `.xcode-version`. If no runner image has that version, also change `runs-on` in both workflows.

The app has four Swift package dependencies, which Swift Package Manager resolves automatically: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), [SwiftNIO](https://github.com/apple/swift-nio), [Yams](https://github.com/jpsim/Yams) and [swift-markdown](https://github.com/swiftlang/swift-markdown).

Build and run the executable:

```bash
./Scripts/swiftpm.sh build --disable-sandbox
./Scripts/swiftpm.sh run --disable-sandbox
```

`Scripts/swiftpm.sh` uses SwiftPM's default build system and records the installed SDK version in the binary, which keeps AppKit's sheet resizing behaviour consistent. It forwards extra options to SwiftPM.

Create the app bundle used for normal manual testing:

```bash
./build-app.sh
open "build/Teya Code Station.app"
```

`build-app.sh` builds the `MenuBarApp` executable, copies its SwiftPM resource bundle into the app, adds the icon and `Info.plist`, and applies an ad-hoc signature. The result is written to `build/Teya Code Station.app`.

Pass `debug` or `release` as its first argument. Any following options go to SwiftPM, such as `./build-app.sh debug --disable-sandbox`.

## Tests

Run the full test suite after changing code:

```bash
./Scripts/swiftpm.sh test --disable-sandbox --no-parallel
```

Run a focused test while iterating:

```bash
./Scripts/swiftpm.sh test --disable-sandbox --no-parallel --filter GitActionsTests
```

Run the suite serially because the AppKit, WebKit, process, and preference fixtures share host resources. SwiftTerm embeds its shader source, so builds do not need the separate Metal shader toolchain.

Pull requests and pushes to `main` run the suite on macOS. Tests live in `Tests/MenuBarAppTests`. They cover session and transcript behavior, CLI stream parsing, Git and worktree operations, terminal and PTY integration, file browsing, Dispatch and OAuth flows, skills, settings, persistence, and UI-facing presentation logic.

Live background-task tests are opt-in because they use the installed agents and their signed-in accounts. They start `sleep 600`, send a follow-up, and cancel the task. Set `CODE_STATION_LIVE_AGENT_TESTS=1` and filter to `AgentSessionLiveTests`; optionally set `CODE_STATION_LIVE_AGENT=codex` or `copilot` to test only one. Codex uses an account-advertised model for this disposable test. Normal test runs use protocol fixtures and make no model calls.

Add tests for behavior and business logic. Trivial view wiring, accessors, and framework behavior do not need dedicated tests.

## Project structure

- `Package.swift` defines one macOS executable target and one test target.
- `Sources/MenuBarApp/App` creates the window, owns shared service lifetimes, and composes the main navigation.
- `Sources/MenuBarApp/Features` groups each feature's views and behavior: Projects, Sessions, Changes, PullRequestReviews, Explorer, Design, Tasks, Home, Stats, Notes, Settings, MCP, Skills, Dispatch, Terminal, MobileAccess, Shortcuts, Docker, Trace, and Troubleshoot.
- `Sources/MenuBarApp/Infrastructure` contains agent protocols, Git and GitHub operations, persistence, process execution, local HTTP, and system integration.
- `Sources/MenuBarApp/DesignSystem` contains the palette, typography, controls, layout components, and motion.
- `Sources/MenuBarApp/Resources` contains bundled assets, including the mobile page's HTML, CSS, and JavaScript.
- `Tests/MenuBarAppTests` follows the same folders. Shared fixtures live in `Support`.

Folders describe ownership within the existing Swift target. Put behavior beside the feature that owns it, and move a type into shared infrastructure only when its callers need that boundary. A view keeps focus, hover, and presentation state; its model owns asynchronous reads and operations.

## Docs and decisions

All docs live in [`docs/`](docs). The decisions behind how the app is built are in [`docs/adrs`](docs/adrs), one short file per topic:

- [Decision records](docs/adrs/0001-decision-records.md) - how ADRs are written and kept current
- [Agent sessions](docs/adrs/0002-agent-sessions.md)
- [Projects, workspaces and worktrees](docs/adrs/0003-projects-workspaces-and-worktrees.md)
- [Local data and processes](docs/adrs/0004-local-data-and-processes.md)
- [Site configuration](docs/adrs/0005-site-configuration.md)
- [Own design system](docs/adrs/0006-own-design-system.md)

Guides for working on specific areas:

- [Design system](docs/design-system.md) - tokens, shared parts and motion. Read it before changing anything a person can see.
- [Site configuration](docs/site-configuration.md) - the organisation settings file and every field in it.
- [Releases](docs/releases.md) - how to cut a release or hand out a quick build.

Read the ADR for an area before changing an established pattern. When a change alters a decision, update its ADR in the same change so it describes what is true now.

## Before submitting a change

1. Build the package with `./Scripts/swiftpm.sh build --disable-sandbox`.
2. Run `./Scripts/swiftpm.sh test --disable-sandbox --no-parallel`.
3. For UI changes, build the app bundle and check the affected flow in the running app.
4. Review the diff for unrelated generated files or local configuration.

Keep commits focused and use a short imperative message such as `Improve session cleanup`.
