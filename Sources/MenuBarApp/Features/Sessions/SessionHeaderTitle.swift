import SwiftUI

// The session's title on the header, which a double-click turns into a field to rename
// it in place. The draft is held by the pane rather than here, because the header is
// drawn in more than one fit and the pane can trade one for another mid-edit.
struct SessionHeaderTitle: View {
    let title: String
    let idealWidth: CGFloat
    @Binding var draft: String?
    let onRename: (String) -> Void

    @FocusState private var focused: Bool

    // The field and the label share an inset, so the words stay where they were when
    // one swaps for the other and only the box around them arrives.
    private static let inset: CGFloat = 5

    var body: some View {
        Group {
            if draft != nil {
                field.transition(.opacity)
            } else {
                label.transition(.opacity)
            }
        }
        .padding(.leading, -Self.inset)
        .motion(Motion.control, value: draft != nil)
    }

    private var field: some View {
        TextField("Session title", text: Binding(get: { draft ?? "" },
                                                 set: { draft = $0 }))
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 3)
            .fieldSurface(cornerRadius: 5)
            // Measured at the same width as the label, so opening the field never makes
            // the header trade its fit for a narrower one under the cursor.
            .frame(minWidth: 0, idealWidth: idealWidth, maxWidth: 360, alignment: .leading)
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onAppear { focused = true }
    }

    private var label: some View {
        // A prompt cut to a line is a label rather than a heading, so it is drawn
        // as one: the same family, a step down in size, and a step back in
        // contrast from the name it qualifies.
        Text(title)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .changingName(title)
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 3)
            .hoverFill(cornerRadius: 5)
            .frame(idealWidth: idealWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { draft = title }
            .appTooltip { Tooltip(title: title, subtitle: "Double-click to rename") }
            .accessibilityAddTraits(.isHeader)
            .accessibilityAction(named: "Rename") { draft = title }
    }

    private func commit() {
        guard let text = draft else { return }
        draft = nil
        if text.trimmed != title { onRename(text) }
    }

    private func cancel() {
        draft = nil
    }
}
