import SwiftUI

struct NoteLinkForm: View {
    let insert: (String) -> Void
    let close: () -> Void
    let restoreFocus: () -> Void
    @State private var url = ""
    private enum Field: Hashable { case url, insert, cancel }
    @FocusState private var focused: Field?
    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Add a link").font(Typography.display)
            TextField("https://example.com", text: $url)
                .textFieldStyle(.plain).padding(Space.md).fieldSurface(cornerRadius: Radius.control)
                .focused($focused, equals: .url).accessibilityLabel("Link URL")
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(focused == .url ? Theme.accent : .clear, lineWidth: 2))
                .onSubmit { if NoteDocument.safeLink(url) != nil { insert(url) } }
            Text("Use an https, http, or mailto link.").font(Typography.caption).foregroundStyle(.secondary)
            HStack {
                ActionButton(title: "Cancel", tone: .outlined, keyboardShortcut: .cancelAction, action: close)
                    .focused($focused, equals: .cancel)
                Spacer()
                ActionButton(title: "Insert link", tone: .green) { insert(url) }
                    .disabled(NoteDocument.safeLink(url) == nil).focused($focused, equals: .insert)
            }
        }
        .padding(Space.xxl).background(Theme.card)
        .onKeyPress(keys: [.tab]) { press in
            let fields: [Field] = NoteDocument.safeLink(url) == nil ? [.url, .cancel] : [.url, .cancel, .insert]
            let index = fields.firstIndex(of: focused ?? .url) ?? 0
            focused = fields[(index + (press.modifiers.contains(.shift) ? fields.count - 1 : 1)) % fields.count]
            return .handled
        }
        .onAppear { focused = .url }
        .onDisappear(perform: restoreFocus)
    }
}
