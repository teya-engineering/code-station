# Project Instructions

## Design system

Read `docs/design-system.md` before building or changing anything a person can see. It lists the steps and the shared parts, and when to use each.

- Never write a raw size, gap, corner, colour or timing in a feature view. Take type from `Typography`, gaps from `Space`, corners from `Radius`, control heights from `ControlHeight`, shadows from `Elevation` (all in `Sources/MenuBarApp/DesignSystem/Tokens.swift`), colour from `Theme` and timing from `Motion`.
- Use the shared part when one exists (`ActionButton`, `GlyphButton`, `SectionRule`, `PaneMessage`, `SheetFooter`, `.cardSurface()` and the rest listed in the doc). Do not draw a look-alike by hand.
- If something is missing, add it to `DesignSystem` and to the doc, then use it. Do not build a one-off inside a feature.
- When you touch a view that still holds raw numbers, move what you touch onto the steps. A value between two steps goes to the nearer one.

## UI

- Never use native AppKit or SwiftUI controls that draw with the system's chrome. They cannot be styled and look like a piece of another program. This rules out `NSAlert`, `.alert`, `.confirmationDialog`, `.contextMenu`, `Menu`, `Picker` (dropdown and segmented), the built-in `Button` styles (`.bordered`, `.borderedProminent`, or no style at all), the built-in `Toggle` styles (`.switch`, `.checkbox`) and `.textFieldStyle(.roundedBorder)`.
- For popup dialogs, use the in-app `Dialog` shown through `DialogPresenter` (see `Sources/MenuBarApp/DesignSystem/Controls/Dialog.swift`).
- To confirm a deletion, use `Dialog.impact`: one row for each thing that goes (marked with a minus), one row for each thing that stays (marked with a tick), and a warning for anything that cannot be restored. When the deletion happens inside a project, task or workspace, pass it as the `subject` so its tile shows at the top.
- For dropdown selections and context menus, use `.appMenu` and `.appContextMenu` backed by `MenuPresenter` (see `Sources/MenuBarApp/DesignSystem/Controls/ContextMenu.swift`).
- For segmented choices, lay out `ChoicePill`s in an `HStack` (see `Sources/MenuBarApp/DesignSystem/Controls/Choices.swift`).
- For switches and checkboxes, use `.toggleStyle(.appSwitch)` and `.toggleStyle(.appCheckbox)` (see `Sources/MenuBarApp/DesignSystem/Controls/Toggles.swift`).
- Buttons are `.buttonStyle(.plain)` with a hand-styled label: a filled pill for the main action, a card-and-border pill for a secondary one, accent-coloured text for a small inline one. Style the label inside the button and give it a `.contentShape`, so the whole pill is clickable, not just the text.
- Text fields are `.textFieldStyle(.plain)` on a `Theme.field` background with a `Theme.border` stroke.
- The only sanctioned native surface is `NSOpenPanel`/`NSSavePanel`, since the file chooser belongs to the system.
- Everything is drawn with the shared palette and type in `Theme.swift`, so anything new should read as part of the same system.

## Motion

Anything new that the user can see or touch needs motion: a screen, a tab, a panel, a button, a row, a badge. When the user does something, the window should answer at once and show what changed and where it came from. A view that just snaps to its new state feels broken, even when it works. Plan the motion as part of the feature, not as polish for later.

- Ask two questions of every new view: how does it arrive and leave, and how does it answer the pointer and a click? Each one needs an answer.
- Use the shared curves in `Motion` (see `Sources/MenuBarApp/DesignSystem/Motion/Motion.swift`). Never write your own duration or spring. Pick by what is happening:
  - `Motion.hover` for a colour settling under the pointer.
  - `Motion.control` for a control taking a new state (a switch, a pill, a selection).
  - `Motion.reveal` for something arriving or one pane swapping for another, and `Motion.arrive` for a large surface such as a dialog card.
  - `Motion.pop` for a small mark landing, such as a badge or a count.
  - `Motion.draw` for a line drawing itself, such as an underline or a progress bar.
  - `Motion.leave` for anything put away. Leaving is always faster than arriving.
- Animate with `.motion(_:value:)`, not `.animation(_:value:)`. It turns the motion off when the user has asked macOS for less motion. Every transition must also take `reduceMotion` and fall back to a plain fade, the way the transitions in `HeaderMotion` do.
- Buttons, dropdowns and pills lift under the pointer with `.hoverLift`. A row in a list or a menu uses `.hoverFill` instead, so it does not push the rows around it. Track hover with `.onPointerHover`, so a scroll that drags rows under a still pointer does not light them all up.
- A new tab page uses `.headerPage`. A panel opened from a button uses `.popover`: it fades in and lifts a few points into place in one movement. A panel from a window edge uses `.drawer(from:)`. Plain inserted content uses `.fadeIn`, and content that closes onto nothing uses `.fold` (see `HeaderMotion.swift` and `Hover.swift`).
- When a glyph button is clicked, its symbol plays its part once with `.actOut`. A glyph that changes meaning, such as copy turning into a tick, uses `.contentTransition(.symbolEffect(.replace))`. Text or a number that changes in place uses a `.contentTransition` rather than a hard swap.
- When a click does its work outside the window, such as opening Finder or a browser, nothing in the window moves. Show a `HeaderNote` so the click still leaves a trace.
- A loop that runs while something is working (a spinner, a pulse) is played by Core Animation through `LayerLoop`, not by a SwiftUI clock or `TimelineView`. A SwiftUI clock lays out the whole window again on every frame.
- Never scale or rotate a view that holds AppKit-backed parts, such as a button with `.appTooltip`. AppKit cannot lay it out under a transform and the app crashes with a NaN frame. Fade it or move it with an offset instead. Never scale anything from zero for the same reason.
- When one heavy pane replaces another, the old one goes at once and only the new one moves in. Two large panes drawn over each other while they fade is slow and looks muddy.
- Keep it short and quiet. Motion confirms what the user did. It never makes them wait, never blocks a click, and never plays for something the user did not cause, such as text streaming in or a background refresh.
- Check the motion in the running app, both with and without Reduce Motion, before calling the work done.

## Docker

- Support every common way of running containers on a Mac, not just Docker Desktop: Docker Desktop, Rancher Desktop, Podman (with its docker socket), Colima and OrbStack. Never assume the engine behind the `docker` CLI is Docker itself.
- Do not assume a tool comes bundled. Compose may be the `docker compose` plugin, the standalone `docker-compose`, or `podman compose`, and a plugin link can point at a tool that has since been removed. Try the usual shape first and fall back to the others.
- Engines answer the same command in slightly different ways. Podman, for example, fails a whole `ps --size` when it cannot measure one container. Keep a plainer fallback for anything that one engine rejects, and test against more than one engine when changing a docker command.

## SwiftPM

- Run builds, tests and development runs through `./Scripts/swiftpm.sh`, with `--disable-sandbox` and `--cache-path /private/tmp/teya-swiftpm-cache`. Codex already provides the outer macOS sandbox.
- The script uses SwiftPM's default build system and passes the installed SDK version to the linker. SwiftTerm embeds its shader source, so builds do not need the separate Metal shader toolchain.
- Use `--force-resolved-versions` when a build must use `Package.resolved` without changing dependency versions.
- When changing the build setup, check that the binary records the SDK it was built against with `otool -l <binary> | grep -A4 LC_BUILD_VERSION`. AppKit uses that version to choose behaviour such as sheet resizing.
- Keep build and module caches inside the worktree or `/private/tmp`.
- SwiftPM dependency downloads require network access. If a dependency fetch is blocked, request network escalation immediately. Do not retry with a fresh cache inside the same sandbox.
- Request filesystem escalation only when a command needs access outside the worktree or `/private/tmp`.

## Scratch probes

- A throwaway probe that opens a window to measure the UI must call `window.center()` before it shows the window. An `NSWindow` built from a `contentRect` with an origin of `0, 0` lands in the bottom left corner of the screen, where it is clipped by the screen edge and reads as a broken part of the real app.
