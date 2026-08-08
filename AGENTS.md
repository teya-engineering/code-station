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

- Run SwiftPM commands with `--disable-sandbox`. Codex already provides the outer macOS sandbox.
- Keep build, module, and package caches inside the worktree or `/private/tmp`.
- Request sandbox escalation only when a command needs access outside those locations.
