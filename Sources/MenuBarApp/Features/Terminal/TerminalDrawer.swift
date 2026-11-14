import AppKit
import SwiftUI

// A real shell in the folder behind the current project or session. It shares the screen
// with the main content rather than replacing it. Dragging the tab strip resizes it.
// Closing it leaves every shell running, so a build survives being put away.
struct TerminalDrawer: View {
    @Environment(TerminalStore.self) private var terminals
    let scope: TerminalScope
    let directory: String
    @Binding var focusTerminal: Bool

    @State private var renaming: TerminalSession?
    @State private var draftName = ""
    // Height while a drag is in flight; the store keeps it once the drag ends.
    @State private var dragHeight: CGFloat?
    // Height at the moment the drag began; the translation is measured from there.
    @State private var dragStartHeight: CGFloat?

    private var open: [TerminalSession] { terminals.sessions(for: scope) }
    private var current: TerminalSession? { terminals.selection(for: scope) }
    private var height: CGFloat { dragHeight ?? terminals.height(for: scope) }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            strip
            Divider().overlay(Theme.hairline)
            if let current {
                TerminalScreen(terminal: current, isFocused: $focusTerminal)
                    .frame(height: height)
            }
        }
        .background(Theme.card)
        .onAppear { terminals.setDrawerVisible(true, for: scope) }
        .onDisappear { terminals.setDrawerVisible(false, for: scope) }
    }

    // MARK: - Strip

    private var strip: some View {
        HStack(spacing: Space.sm) {
            ForEach(open) { terminal in
                tab(terminal)
                    .transition(.asymmetric(insertion: .fadeIn, removal: .fold))
            }

            Button {
                terminals.add(to: scope, directory: directory)
                focusTerminal = true
            } label: {
                Image(systemName: "plus")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, Space.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .appTooltip("New shell")
            .cursorOnHover(.arrow)

            Spacer(minLength: 12)

            closeButton
            .appTooltip("Hide the terminal (^`)")
            // The strip underneath shows the resize cursor; over the button the hand is
            // clicking, not dragging, so the arrow comes back.
            .cursorOnHover(.arrow)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .motion(Motion.reveal, value: open.map(\.id))
        .background(Theme.card)
        .contentShape(Rectangle())
        // The strip doubles as the resize handle, which is where the hand naturally
        // goes when the drawer is the wrong size.
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? height
                    dragStartHeight = start
                    dragHeight = max(TerminalStore.minimumHeight, start - value.translation.height)
                }
                .onEnded { _ in
                    if let dragHeight { terminals.setHeight(dragHeight, for: scope) }
                    dragHeight = nil
                    dragStartHeight = nil
                })
        .cursorOnHover(.resizeUpDown)
    }

    // Closing only puts the drawer away; every shell keeps running.
    @State private var hoveringClose = false

    private var closeButton: some View {
        Button {
            terminals.setOpen(false, for: scope, directory: directory)
            focusTerminal = false
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: "xmark")
                    .font(Typography.micro)
                Text("Close")
                    .font(Typography.label)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs)
            .surface(hoveringClose ? Theme.field : .clear, cornerRadius: Radius.control)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .hoverLift(hoveringClose)
        .motion(Motion.hover, value: hoveringClose)
        .onPointerHover { hoveringClose = $0 }
    }

    private func tab(_ terminal: TerminalSession) -> some View {
        let selected = terminal.id == current?.id
        return Button {
            terminals.select(terminal, in: scope)
            focusTerminal = true
        } label: {
            HStack(spacing: Space.sm) {
                if renaming?.id == terminal.id {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(Typography.label)
                        .frame(width: 80)
                        .onSubmit { commitRename(terminal) }
                        .onExitCommand { renaming = nil }
                } else {
                    Text(terminal.name)
                        .font(Typography.detail.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                }
                // A tab only gets a dot while a command actually holds its terminal,
                // so a background build is visible without opening the tab.
                if terminal.isBusy {
                    Circle().fill(Theme.dotOn).frame(width: 6, height: 6)
                } else if !terminal.isRunning {
                    Circle().fill(Theme.dotOff).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs)
            .background(
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(selected ? Theme.card : .clear)
                    .elevation(selected ? .raised : .none))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(selected ? Theme.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .motion(Motion.control, value: selected)
        // A fill rather than a lift: while it is renamed the tab holds a text field,
        // which AppKit cannot lay out under a scale.
        .hoverFill(cornerRadius: Radius.control)
        .onTapGesture(count: 2) { startRename(terminal) }
        .appContextMenu {
            var entries: [MenuEntry] = [
                .item("Rename…") { startRename(terminal) },
                .item("Clear") { terminal.clear() }
            ]
            if open.count > 1 {
                entries.append(.separator)
                entries.append(.item("Close", kind: .destructive) {
                    terminals.close(terminal, in: scope)
                })
            }
            return entries
        }
    }

    // MARK: - Renaming

    private func startRename(_ terminal: TerminalSession) {
        draftName = terminal.name
        renaming = terminal
    }

    private func commitRename(_ terminal: TerminalSession) {
        if !draftName.isBlank { terminal.name = draftName.trimmed }
        renaming = nil
    }
}

// The header control for a shell in the folder behind whatever is on screen. A shell in
// the drawer and a shell in a window of its own are the same wish reached two ways, so the
// press offers both rather than picking one; the terminal setting only says which of them
// the menu names first. The keyboard shortcut still reaches the drawer in one stroke.
struct TerminalToggle: View {
    let isOpen: Bool
    let directory: String
    let toggle: () -> Void

    @Environment(\.showExternalNote) private var showExternalNote
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(">_")
                .font(Typography.data.weight(.semibold))
            Text("Terminal")
                .font(Typography.label)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(isOpen ? Theme.onFill.opacity(0.75) : Color.secondary)
        }
        .foregroundStyle(isOpen ? Theme.onFill : Color.primary)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .surface(isOpen ? Theme.accentFill.opacity(hovering ? 0.86 : 1) : hovering ? Theme.field : Theme.card,
                 cornerRadius: Radius.card, border: isOpen ? .clear : Theme.border)
        .contentShape(Rectangle())
        .motion(Motion.control, value: isOpen)
        // Lifted inside the menu's button, so the tooltip outside it is never scaled.
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .appMenu {
            terminalEntries(isOpen: isOpen, toggle: toggle, directory: directory,
                            note: showExternalNote.show)
        }
        .appTooltip("Open a shell here or in \(SystemTerminal.appName)")
    }
}

// Both ways to reach a shell, in the order the setting puts them: the one the setting
// prefers comes first, so the menu reads as the choice that was made plus the other one.
// The system terminal opens over the window, so `note` is how the click shows in it.
@MainActor func terminalEntries(isOpen: Bool,
                                toggle: @escaping () -> Void,
                                directory: String,
                                note: ((_ text: String, _ icon: String) -> Void)? = nil) -> [MenuEntry] {
    let here = MenuEntry.item(isOpen ? "Hide terminal here" : "Open terminal here",
                              icon: "terminal",
                              subtitle: "A shell in the drawer, beside what you were reading.",
                              detail: "^`",
                              action: toggle)
    let app = MenuEntry.item("Open in \(SystemTerminal.appName)",
                             icon: "macwindow",
                             subtitle: "A shell in a window of its own.") {
        SystemTerminal.open(directory)
        note?("Opened a shell in \(SystemTerminal.appName)", "arrow.up.forward.app")
    }
    return Preferences.terminalBundleID == nil ? [here, app] : [app, here]
}
