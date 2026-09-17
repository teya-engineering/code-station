# Project Instructions

## UI

- Never use native AppKit or SwiftUI controls that draw with the system's chrome. They cannot be styled and look like a piece of another program. This rules out `NSAlert`, `.alert`, `.confirmationDialog`, `.contextMenu`, `Menu`, `Picker` (dropdown and segmented), the built-in `Button` styles (`.bordered`, `.borderedProminent`, or no style at all), the built-in `Toggle` styles (`.switch`, `.checkbox`) and `.textFieldStyle(.roundedBorder)`.
- For popup dialogs, use the in-app `Dialog` shown through `DialogPresenter` (see `Sources/MenuBarApp/Dialog.swift`).
- For dropdown selections and context menus, use `.appMenu` and `.appContextMenu` backed by `MenuPresenter` (see `Sources/MenuBarApp/ContextMenu.swift`).
- For segmented choices, lay out `ChoicePill`s in an `HStack` (see `Sources/MenuBarApp/Choices.swift`).
- For switches and checkboxes, use `.toggleStyle(.appSwitch)` and `.toggleStyle(.appCheckbox)` (see `Sources/MenuBarApp/Controls.swift`).
- Buttons are `.buttonStyle(.plain)` with a hand-styled label: a filled pill for the main action, a card-and-border pill for a secondary one, accent-coloured text for a small inline one. Style the label inside the button and give it a `.contentShape`, so the whole pill is clickable, not just the text.
- Text fields are `.textFieldStyle(.plain)` on a `Theme.field` background with a `Theme.border` stroke.
- The only sanctioned native surface is `NSOpenPanel`/`NSSavePanel`, since the file chooser belongs to the system.
- Everything is drawn with the shared palette and type in `Theme.swift`, so anything new should read as part of the same system.

## SwiftPM

- Run SwiftPM commands with `--disable-sandbox` and `--cache-path /private/tmp/teya-swiftpm-cache`. Codex already provides the outer macOS sandbox.
- Add `--build-system native` to every `swift build` and `swift test`. The default build system compiles SwiftTerm's Metal shader, which needs a separate Xcode Metal toolchain that is not installed. The native system skips the shader, and the app still builds and the whole test suite still runs.
- That flag also decides how the app behaves. The native system records the SDK the app was really built against; the default one records the deployment target, and AppKit then falls back to the behaviour of that old release, where a sheet is sized once as it opens and never follows its content. A binary's stamp is `otool -l <binary> | grep -A4 LC_BUILD_VERSION`.
- Do not try to install that toolchain. `xcodebuild -downloadComponent MetalToolchain` fetches an 839 MB asset, never registers it, and the build fails the same way afterwards.
- Keep build and module caches inside the worktree or `/private/tmp`.
- SwiftPM dependency downloads require network access. If a dependency fetch is blocked, request network escalation immediately. Do not retry with a fresh cache inside the same sandbox.
- Request filesystem escalation only when a command needs access outside the worktree or `/private/tmp`.

## Scratch probes

- A throwaway probe that opens a window to measure the UI must call `window.center()` before it shows the window. An `NSWindow` built from a `contentRect` with an origin of `0, 0` lands in the bottom left corner of the screen, where it is clipped by the screen edge and reads as a broken part of the real app.
