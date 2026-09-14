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
        HStack(spacing: 6) {
            ForEach(open) { terminal in
                tab(terminal)
            }

            Button {
                terminals.add(to: scope, directory: directory)
                focusTerminal = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appTooltip("New shell")
            .cursorOnHover(.arrow)

            Spacer(minLength: 12)

            closeButton
            .appTooltip("Hide the terminal (^`)")
            // The strip underneath shows the resize cursor; over the button the hand is
            // clicking, not dragging, so the arrow comes back.
            .cursorOnHover(.arrow)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
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
            HStack(spacing: 5) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                Text("Close")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .surface(hoveringClose ? Theme.field : .clear, cornerRadius: 7)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hoveringClose)
        .onHover { hoveringClose = $0 }
    }

    private func tab(_ terminal: TerminalSession) -> some View {
        let selected = terminal.id == current?.id
        return Button {
            terminals.select(terminal, in: scope)
            focusTerminal = true
        } label: {
            HStack(spacing: 6) {
                if renaming?.id == terminal.id {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 80)
                        .onSubmit { commitRename(terminal) }
                        .onExitCommand { renaming = nil }
                } else {
                    Text(terminal.name)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
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
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Theme.card : .clear)
                    .shadow(color: .black.opacity(selected ? 0.07 : 0), radius: 1, y: 0.5))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Theme.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

// The header control for a shell in the folder behind whatever is on screen. Wanting a
// shell here and wanting one in a window of its own are the same wish reached two ways,
// and the terminal setting says which one the press means, so the press acts rather than
// asking again. The other way stays on the right-click menu. It is deliberately separate
// from the tabs because the drawer can stay open alongside any of them.
struct TerminalToggle: View {
    let isOpen: Bool
    let directory: String
    let toggle: () -> Void

    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        let inDrawer = appSettings.opensTerminalInDrawer
        let lit = inDrawer && isOpen

        return Button {
            if inDrawer { toggle() } else { SystemTerminal.open(directory) }
        } label: {
            HStack(spacing: 6) {
                Text(">_")
                    .font(.mono(11, .bold))
                Text("Terminal")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(lit ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .surface(lit ? Theme.accentFill : Theme.card, cornerRadius: 10,
                     border: lit ? .clear : Theme.border)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appContextMenu { terminalEntries(isOpen: isOpen, toggle: toggle, directory: directory) }
        .appTooltip(inDrawer
                    ? "Open a shell in this folder"
                    : "Open a shell in \(SystemTerminal.appName)")
    }
}

// Both ways to reach a shell, in the order the setting puts them: what the press already
// does comes first, so the menu reads as the choice that was made plus the other one.
@MainActor func terminalEntries(isOpen: Bool,
                                toggle: @escaping () -> Void,
                                directory: String) -> [MenuEntry] {
    let here = MenuEntry.item(isOpen ? "Hide terminal here" : "Open terminal here",
                              detail: "^`",
                              action: toggle)
    let app = MenuEntry.item("Open in \(SystemTerminal.appName)") {
        SystemTerminal.open(directory)
    }
    return Preferences.terminalBundleID == nil ? [here, app] : [app, here]
}
