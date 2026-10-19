# ADR-0002: The TUI's terminal layer and how it is launched

## Status

Accepted

## Context

The terminal UI (`.scratch/tui/spec.md`) is a second front end on `CodeStationCore`. It needs a terminal layer that handles raw mode, the alternate screen, resize signals, key decoding (including bracketed paste and modified keys) and screen-buffer diffing, with no ncurses. The core's stores are `@MainActor @Observable` and the session runner uses main-actor timers (ADR-0001), so the TUI must drive a main-actor run loop. The transcript renderer is already planned as a pure module that turns messages, a width and a theme into styled lines. Whatever paints those lines must keep up with transcripts that run to thousands of lines.

The TUI also has to be installed and started as `code-station tui`. It must find the same data as the GUI, and later find a daemon instead of opening the store itself. Today:

- `build-app.sh` copies one SwiftPM executable (`MenuBarApp`) and its resource bundle into `Teya Code Station.app`.
- `Scripts/release.sh` signs nested bundles and then the app, then notarizes it. Users install with the Homebrew cask `teya-engineering/tap/teya-code-station` or the DMG.
- `AppUpdateInstall` replaces the whole bundle in place.
- `AppPaths` files everything under `Bundle.main.bundleIdentifier ?? "com.teya.code-station"` in Application Support and Logs. Preferences live in `UserDefaults.standard`, which is keyed by the bundle identifier. Resources and `site-defaults.json` are found through `Bundle.main.resourceURL`.

Two throwaway spikes checked both decisions: a small ANSI layer on Swift 6.3.3, then swift-tui built for real on Swift 6.4 (Xcode 27).

## Decision

### Terminal layer: our own small ANSI layer, no new dependency

The TUI gets a terminal layer of its own, as a library target (`TerminalKit`) inside this package. It uses only Darwin and Dispatch, and it adds no new SwiftPM dependency. It has three parts:

- **`Terminal`** is `@MainActor`. It handles termios raw mode (`cfmakeraw`, keeping `OPOST` on), the alternate screen, hiding the cursor, and bracketed paste. It restores the terminal on exit, on SIGINT and SIGTERM, and around SIGTSTP and SIGCONT. Resize and input arrive through `DispatchSource` signal and read sources on the main queue, and are delivered as events. A lone ESC with nothing after it for 25 ms becomes the Escape key.
- **`KeyDecoder`** is a pure value that turns bytes into keys. It decodes UTF-8, control keys, Alt as an ESC prefix, CSI cursor and editing keys with xterm modifier parameters, bracketed paste, xterm `modifyOtherKeys` and kitty `CSI u` (so Shift+Enter can mean a new line in the composer). Unknown sequences are swallowed.
- **`Screen`** is a pure value that diffs lines. A frame is one styled string per row. Only rows that differ from the last frame are rewritten, and the whole frame is wrapped in a synchronized-update block (DEC mode 2026). A change of size clears the screen and repaints everything.

The TUI's `main` takes over the main actor and runs `RunLoop.main.run()`. That one loop serves the main dispatch queue (main-actor jobs and the dispatch sources) and Foundation timers, so the core's stores and the runner's timers behave as they do in the GUI.

Wrapping, display width (wide characters and emoji) and colour depth belong to the transcript renderer, not to this layer. The layer only paints lines it is given.

### Launch and install: a separate binary inside the app bundle, started through a launcher

- **Binary.** A new executable target builds a binary named `code-station`. It depends on `CodeStationCore` and `TerminalKit` and never links AppKit or SwiftUI. `build-app.sh` copies it to `Teya Code Station.app/Contents/MacOS/code-station`, next to `MenuBarApp`. It ships, signs, notarizes and updates with the app, so the GUI and the TUI are always the same version on the same state format. Its first argument picks a subcommand: `tui` now, `daemon` later.
- **Launcher.** `Contents/Resources/bin/code-station` is a small shell script. It resolves its own path, following symlinks with `/bin/realpath`, and runs `exec "<bundle>/Contents/MacOS/code-station" "$@"`. VS Code puts its `code` command in its bundle in the same way.
- **Putting it on `PATH`.**
  - The Homebrew cask adds `binary "#{appdir}/Teya Code Station.app/Contents/Resources/bin/code-station"`.
  - DMG users get an "Install command line tool" action in the GUI that symlinks the launcher into `~/.local/bin` or `/usr/local/bin`. This can follow later.
  - In development, run `swift run code-station tui`.
- **Data paths.** A command on `PATH` is a symlink, and the spike showed that a binary started through a symlink does not see its bundle. `Bundle.main` then points at the symlink's folder: `bundleIdentifier` is nil, `UserDefaults.standard` is a different domain and the resources cannot be found. Started directly, or through a launcher that `exec`s the real path, the same binary sees the app's identifier, preferences and resources. So:
  1. The launcher always `exec`s the real path.
  2. As a second guard, the core stops reading identity from `Bundle.main`. `AppPaths` takes a fixed station identifier, `com.teya.code-station`. That is already its fallback, so the GUI's paths do not change. Preferences the core needs are read through `UserDefaults(suiteName:)` with that identifier, which the spike confirmed reads the app's domain from a binary outside any bundle.
  3. A development build with no bundle still lands on the same Application Support folder.
- **Daemon discovery later.** The station ownership lock file in Application Support already records the holder's pid and kind. It gains an optional `endpoint` field, the path of a local socket.
  - On start, a front end reads the lock. If a live daemon holds it, the front end connects to its endpoint and drives the same commands façade over the socket. If nobody holds it, the front end takes the lock itself, as the spec describes.
  - The daemon is the same in-bundle binary run as `code-station daemon`. It is registered with `SMAppService.agent(plistName:)` from a plist in `Contents/Library/LaunchAgents`, which requires the program to live inside the bundle.
  - The socket goes under the station's folder, or under `$TMPDIR` if that path would pass the 104-byte `sun_path` limit.
  - Nothing in the TUI hard-codes in-process versus socket. It is handed a façade at startup.

## Alternatives considered

Terminal layer:

- **swift-tui (github.com/SwiftTUI/swift-tui, v0.18, MIT):** the best maintained option, with strict concurrency and SwiftUI semantics. A hands-on spike on Swift 6.4 found:
  - It builds clean in Swift 6 mode, redraws from an `@Observable` store driven by outside timers, works inside tmux and restores the screen on signals.
  - It links AppKit, which breaks this ADR's rule that the TUI never does. The binary is 42 MB.
  - It is pre-1.0 and churns fast: about 85 tags and 17 source-breaking minor versions in three months, almost all from one author.
  - Its multi-line editor ignores Shift+Enter and has no cursor API, so we would write our own composer anyway. It drops xterm `modifyOtherKeys` sequences.
  - It takes over the mouse, so plain drag-to-select stops working. By default it starts a loopback HTTP companion, and it prints a banner on every launch.
  - Raw OSC 52 and OSC 9 writes only work by relying on undocumented behaviour.
  - It owns state and layout, which competes with our façade-driven view state and the pure transcript renderer. Scrolling took 2–3 ms per frame (median), up to 20 ms (p99), against about 15 µs for our own layer.
  - Look again if it reaches 1.0. Worth borrowing now: enable kitty keyboard flags only after the terminal answers a probe, and scroll with a scroll region.
- **rensbreur/SwiftTUI:** a well-known SwiftUI-style API, but no push since July 2024 and written before Swift 6.
- **TermKit (de Icaza):** a full widget toolkit. Its last commit was in February 2026. It pulls in SwiftTerm, TextBufferKit, swift-markdown, swift-log and the SwiftLint and DocC plugins, and it is built around its own widget and event model rather than a `@MainActor` loop we own.
- **TUIkit (phranck) and bpisano/SwiftTUI:** young (2025–26), single maintainers, small user bases. A SwiftUI-like framework is more than we need, with too little track record.
- **Noora (Tuist):** actively maintained, but it is for CLI prompts and progress output, not full-screen alternate-screen apps.
- **Termbox or ncurses wrappers:** the C dependency is ruled out by the spec, and the Swift wrappers have been inactive since 2021.

Launch and install:

- **A launcher script beside the app (in `/Applications`):** nothing to change in the bundle, but it lives outside the signed bundle. Updates and uninstalls leave it behind, and it still needs a binary to run.
- **A `tui` mode of `MenuBarApp`:** one binary and one signature. But the TUI would load AppKit, SwiftUI, SwiftTerm and 55k lines of views. It would lose the build-time guarantee that the TUI's import graph has no AppKit. A stray `NSApp` access would fail over SSH. And running the binary with no arguments from a shell would open the GUI.
- **A standalone binary installed outside the bundle (`brew` formula, `/usr/local/bin`):** a simple install, but it can drift from the app's version and state format. It needs its own signing and notarization. It cannot host an `SMAppService` daemon.
- **Symlinking `Contents/MacOS/code-station` straight onto `PATH`:** simplest, but the spike showed it breaks bundle identity, preferences and resources unless every `Bundle.main` use is removed.

## Consequences

- **No new dependency.** No SwiftPM dependency is added. SwiftTerm stays a dependency of the GUI target only.
- **Code we own.** The terminal layer is ours to maintain. The spike's version is about 200 lines:
  - `Terminal` 85, `KeyDecoder` 100, `Screen` 25;
  - it builds clean under Swift 6 language mode;
  - a pty smoke test covered Ctrl+Down, paste, lone Escape, resize and restoring the screen on quit.

  With restore-on-signal, suspend and resume, the OSC 9 and OSC 52 helpers and tests, it should come to roughly 500–700 lines. `KeyDecoder` and `Screen` are pure, so they get byte-fixture tests. `Terminal` is checked by hand in Terminal.app, iTerm2, Ghostty, tmux and over SSH, as the spec says.
- **Speed.** Painting is cheap enough not to matter. In the spike, a 60×200 viewport over a 10,000-line coloured transcript took about 15 µs per frame when every row changes (scrolling by one line, about 13 KB written). An unchanged frame took under 1 µs, and decoding a 100 KB bracketed paste took 37 ms. The cost on long transcripts is in the renderer, which only renders the visible window.
- **Type-ahead.** Raw mode must be entered with `TCSANOW` or `TCSADRAIN`, not `TCSAFLUSH`, or keys typed during startup are lost. The spike hit this.
- **Build.** `build-app.sh` copies a second executable and the launcher script.
- **Release.** `Scripts/release.sh` must sign `Contents/MacOS/code-station` with the hardened runtime and the same entitlements before it signs the app. The current loop only signs nested `.bundle`, `.framework` and `.dylib` items, and `codesign --verify --strict` fails on an unsigned Mach-O inside the bundle.
- **Homebrew.** The Homebrew tap's cask gains one `binary` line.
- **Keychain.** The TUI binary has its own code identity, so reading the GUI's Keychain item would show an access prompt. Nothing in the TUI's scope (Dispatch is excluded) needs the Keychain. If that changes, the item's access list or an access group must include both binaries.
- **Core paths.** The core's `AppPaths` and preference access stop depending on `Bundle.main`. That also helps tests and the later daemon.
