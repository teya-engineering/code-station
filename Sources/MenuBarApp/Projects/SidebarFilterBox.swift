import SwiftUI

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
// for someone who only wants to trim this rail without leaving its context.
struct SidebarFilterBar: View {
    @Binding var box: SidebarFilterBox
    @FocusState.Binding var focused: Bool
    let openCommandPalette: () -> Void

    var body: some View {
        Group {
            if box.showsField { field } else { commandPaletteButton }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var commandPaletteButton: some View {
        Button(action: openCommandPalette) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("Filter projects, sessions, actions")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("⌘K")
                    .font(.mono(9.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .fieldSurface(cornerRadius: 9)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .hoverLift()
        .accessibilityLabel("Filter projects, sessions, and actions")
        .appTooltip("Filter Code Station (command-K)")
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
            Text("⌘F")
                .font(.mono(9.5))
                .foregroundStyle(.tertiary)
            Button {
                let wasEmpty = box.text.isEmpty
                box.closeOrClear()
                if wasEmpty { focused = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .appTooltip(box.text.isEmpty ? "Close project filter" : "Clear filter")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .fieldSurface(cornerRadius: 9)
        .onChange(of: box.text) { _, _ in box.typed() }
    }
}
