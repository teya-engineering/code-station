import AppKit
import SwiftUI

// A real shell in the session's folder, opened from the header button. It shares the
// screen with the conversation rather than replacing it, so watching a build and
// reading what Claude Code did are the same glance. Dragging the tab strip resizes it.
// Closing it leaves every shell running, so a build survives being put away.
struct TerminalDrawer: View {
    @Environment(TerminalStore.self) private var terminals
    let sessionID: UUID
    let directory: String
    @Binding var focusTerminal: Bool

    @State private var renaming: TerminalSession?
    @State private var draftName = ""
    // Height while a drag is in flight; the store keeps it once the drag ends.
    @State private var dragHeight: CGFloat?

    private var open: [TerminalSession] { terminals.sessions(for: sessionID) }
    private var current: TerminalSession? { terminals.selection(for: sessionID) }
    private var height: CGFloat { dragHeight ?? terminals.height(for: sessionID) }

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
    }

    // MARK: - Strip

    private var strip: some View {
        HStack(spacing: 6) {
            ForEach(open) { terminal in
                tab(terminal)
            }

            Button {
                terminals.add(to: sessionID, directory: directory)
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
            .help("New shell")

            Spacer(minLength: 12)

            Button("Close") {
                terminals.setOpen(false, for: sessionID, directory: directory)
                focusTerminal = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
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
                    dragHeight = max(TerminalStore.minimumHeight, height - value.translation.height)
                }
                .onEnded { _ in
                    if let dragHeight { terminals.setHeight(dragHeight, for: sessionID) }
                    dragHeight = nil
                })
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
    }

    private func tab(_ terminal: TerminalSession) -> some View {
        let selected = terminal.id == current?.id
        return Button {
            terminals.select(terminal, in: sessionID)
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
                    .fill(selected ? Color.white : .clear)
                    .shadow(color: .black.opacity(selected ? 0.07 : 0), radius: 1, y: 0.5))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Theme.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onTapGesture(count: 2) { startRename(terminal) }
        .contextMenu {
            Button("Rename…") { startRename(terminal) }
            Button("Clear") { terminal.clear() }
            if open.count > 1 {
                Divider()
                Button("Close", role: .destructive) { terminals.close(terminal, in: sessionID) }
            }
        }
    }

    // MARK: - Renaming

    private func startRename(_ terminal: TerminalSession) {
        draftName = terminal.name
        renaming = terminal
    }

    private func commitRename(_ terminal: TerminalSession) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { terminal.name = trimmed }
        renaming = nil
    }
}

// The header control that opens and shuts the terminal. It sits beside Chat/Changes
// but is deliberately its own button: the terminal is not a third place to be, it is
// something you pull up alongside wherever you already are.
struct TerminalToggle: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(">_")
                    .font(.mono(11, .bold))
                Text("Terminal")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isOpen ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isOpen ? Theme.accent : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isOpen ? .clear : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Hide the terminal (^`)" : "Show the terminal (^`)")
    }
}
