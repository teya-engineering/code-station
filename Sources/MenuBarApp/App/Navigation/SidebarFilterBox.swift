import SwiftUI
import CodeStationCore

// The sidebar's filter box: what has been typed, and the three pieces of state that hang
// off it. They move together, so they are held together. Clearing the text has to decide
// whether the rail jumps back to the current row, and opening a row while filtering has
// to remember which one so that row's sessions stay whole.
//
// `SidebarFilter` is the matching rule this hands out. This is the control around it.
struct SidebarFilterBox {
    // Bound straight to the text field, so it is the one part a person writes directly.
    var text = ""

    // Whether the narrow tree field was opened deliberately. The field also stays up on
    // its own while there is text in it, which is what `showsField` folds together.
    private(set) var isFieldOpen = false

    // The one container opened while filtering. Its sessions are shown whole rather than
    // narrowed, so a row the filter matched can be explored without clearing the box.
    private(set) var revealedContainerID: UUID?

    // Set when a disclosure cleared the filter rather than a person. That clear must not
    // also jump the rail back to the current row: the click already said where to look.
    private(set) var clearedForDisclosure = false

    var filter: SidebarFilter { SidebarFilter(text) }
    var query: String { filter.query }
    var isActive: Bool { filter.isActive }
    var showsField: Bool { isFieldOpen || !text.isEmpty }

    // Whatever was typed makes the reveal stale: it was granted to a row the old query
    // matched, and the new one may not match it at all.
    mutating func typed() {
        revealedContainerID = nil
    }

    // Cleared by a person, or by navigation that needs the whole rail back.
    mutating func clear() {
        text = ""
    }

    // Cleared by opening or closing a row while filtering. The rail must not then chase
    // the current row, so this leaves a note for the clear that follows.
    mutating func clearForDisclosure() {
        clearedForDisclosure = true
        text = ""
    }

    // Answers once whether the clear that just happened came from a disclosure, and
    // forgets it. A note left standing would swallow the next clear a person made.
    mutating func wasClearedForDisclosure() -> Bool {
        defer { clearedForDisclosure = false }
        return clearedForDisclosure
    }

    // Only meaningful while filtering: with the whole rail showing there is nothing for a
    // reveal to widen.
    mutating func reveal(_ containerID: UUID) {
        guard isActive else { return }
        revealedContainerID = containerID
    }

    func revealsEverything(in containerID: UUID) -> Bool {
        revealedContainerID == containerID
    }

    mutating func openField() {
        isFieldOpen = true
    }

    // The close button empties a box that has something in it, and closes one that is
    // already empty, so the same button never needs a second press to get out of the way.
    mutating func closeOrClear() {
        if text.isEmpty {
            isFieldOpen = false
        } else {
            text = ""
        }
    }
}

// The visible control opens the app-wide filter. Command-F keeps the narrower tree filter
// for someone who only wants to trim this rail without leaving its context, except while a
// file is open for reading: there the stroke searches the file and the hint says so by
// going away.
struct SidebarFilterBar: View {
    @Binding var box: SidebarFilterBox
    @FocusState.Binding var focused: Bool
    let openCommandPalette: () -> Void
    // False while a file on screen answers for Command-F. Naming a stroke that lands
    // somewhere else reads as a broken shortcut rather than as one being shared.
    let showsShortcutHint: Bool

    @Environment(GlobalCommandPaletteController.self) private var commandPalette
    @FocusState private var commandFocused: Bool
    @State private var hovering = false

    var body: some View {
        Group {
            if box.showsField { field } else { commandPaletteButton }
        }
        .padding(.horizontal, 14)
        .onChange(of: commandPalette.sidebarFocusRequest) { _, _ in
            if box.showsField { focused = true }
            else { commandFocused = true }
        }
    }

    private var commandPaletteButton: some View {
        Button(action: openCommandPalette) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
                Text("Search Code Station")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("⌘ K")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .surface(Theme.sunken, cornerRadius: 4)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .surface(Theme.card, cornerRadius: 9,
                     border: hovering ? Theme.accent.opacity(0.45) : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .sidebarFocusRing($commandFocused)
        .onHover { hovering = $0 }
        .hoverLift()
        .accessibilityLabel("Search Code Station")
        .accessibilityHint("Search projects, sessions, and actions. Command-K.")
        .appTooltip("Search Code Station (command-K)")
    }

    private var field: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Filter projects and sessions", text: $box.text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .accessibilityLabel("Filter projects and sessions")
                .onExitCommand(perform: closeOrClear)
            if showsShortcutHint {
                Text("⌘F")
                    .font(.mono(9.5))
                    .foregroundStyle(.tertiary)
            }
            Button(action: closeOrClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sidebarFocusRing()
            .hoverLift(amount: Motion.smallLift)
            .accessibilityLabel(box.text.isEmpty ? "Close sidebar filter" : "Clear sidebar filter")
            .appTooltip(box.text.isEmpty ? "Close project filter" : "Clear filter")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .fieldSurface(cornerRadius: 9)
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(focused ? Theme.accent : .clear, lineWidth: 2)
            .allowsHitTesting(false))
        .onChange(of: box.text) { _, _ in box.typed() }
    }

    private func closeOrClear() {
        let wasEmpty = box.text.isEmpty
        box.closeOrClear()
        if wasEmpty {
            focused = false
            commandFocused = true
        } else {
            focused = true
        }
    }
}
