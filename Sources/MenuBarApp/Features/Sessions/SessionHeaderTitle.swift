import AppKit
import SwiftUI

// The session's title on the header, which a double-click turns into a field to rename
// it in place. The draft is held by the pane rather than here, because the header is
// drawn in more than one fit and the pane can trade one for another mid-edit.
struct SessionHeaderTitle: View {
    let title: String
    let idealWidth: CGFloat
    @Binding var draft: SessionTitleDraft?
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
        TextField("Session title", text: Binding(get: { draft?.text ?? "" },
                                                 set: { draft?.text = $0 }))
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
            // A click on something that cannot take the keyboard, such as the transcript
            // or the empty header, leaves the field focused, so it is watched for here.
            .background(ClickOutsideWatcher(onClickOutside: commit))
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
            .onTapGesture(count: 2) { startEditing() }
            .appTooltip { Tooltip(title: title, subtitle: "Double-click to rename") }
            .accessibilityAddTraits(.isHeader)
            .accessibilityAction(named: "Rename") { startEditing() }
    }

    private func startEditing() {
        draft = SessionTitleDraft(original: title, text: title)
    }

    // Compared with the title the edit started from, not the one shown now. A generated
    // title can land while the field is open, and an untouched field must not put the
    // old prompt back over it.
    private func commit() {
        guard let draft else { return }
        self.draft = nil
        if draft.text.trimmed != draft.original { onRename(draft.text) }
    }

    private func cancel() {
        draft = nil
    }
}

struct SessionTitleDraft: Equatable {
    let original: String
    var text: String
}

// Watches presses through a local monitor rather than taking them, so whatever was
// clicked still gets the click.
private struct ClickOutsideWatcher: NSViewRepresentable {
    let onClickOutside: () -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onClickOutside = onClickOutside
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onClickOutside = onClickOutside
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) { view.stop() }

    final class WatcherView: NSView {
        var onClickOutside: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return stop() }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window else { return }
                    let point = self.convert(event.locationInWindow, from: nil)
                    if !self.bounds.contains(point) { self.onClickOutside?() }
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
