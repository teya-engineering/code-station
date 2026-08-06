# Project Conventions

## UI

- Never use native AppKit or SwiftUI dialogs, menus or pickers. They cannot be styled and look like a piece of another program. This rules out `NSAlert`, `.alert`, `.confirmationDialog`, `.contextMenu`, `Menu`, `Picker` dropdowns and the like.
- For popup dialogs, use the in-app `Dialog` shown through `DialogPresenter` (see `Sources/MenuBarApp/Dialog.swift`).
- For dropdown selections and context menus, use `.appMenu` and `.appContextMenu` backed by `MenuPresenter` (see `Sources/MenuBarApp/ContextMenu.swift`).
- Both are drawn with the shared palette and type in `Theme.swift`, so anything new should read as part of the same system.
