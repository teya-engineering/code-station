import AppKit
import SwiftUI

struct ExplorerFileDetails: View {
    let node: FileNode
    let path: String
    let status: GitStatusKind?
    let text: String?
    let copyPath: () -> Void
    let openExternally: () -> Void
    let revealInFinder: () -> Void
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    Text("File details").font(Typography.body.weight(.semibold))
                    Spacer()
                    ExplorerIcon(symbol: "xmark", label: "Close file details", action: close)
                }
                Grid(alignment: .leading, horizontalSpacing: Space.xl, verticalSpacing: Space.lg) {
                    row("Type", node.isDirectory ? "Folder" : node.kind.isEmpty ? "File" : node.kind.uppercased())
                    row("Size", node.size.formatted(.byteCount(style: .file)))
                    if let text { row("Lines", String(LineIndex(text as NSString).count)) }
                    row("Status", status?.label.capitalized ?? "Unchanged")
                    if text != nil { row("Encoding", "UTF-8") }
                    if let modified = node.modified { row("Modified", modified.formatted(date: .abbreviated, time: .shortened)) }
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                Text("Location").font(Typography.caption.weight(.semibold))
                Text(path).font(Typography.data).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                InlineLink(title: "Copy path", action: copyPath)
                if let destination = node.linkDestination {
                    Text("Links to \(destination)").font(Typography.data).foregroundStyle(.secondary)
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                ActionButton(title: "Open externally", tone: .outlined, height: ControlHeight.md, size: Typography.Size.detail, action: openExternally)
                InlineLink(title: "Reveal in Finder", action: revealInFinder)
            }
            .padding(Space.xl)
        }
        .background(Theme.background)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }.font(Typography.caption)
    }
}

struct ExplorerCreateDialog: View {
    private enum Focus: Hashable { case name, cancel, create }
    let folder: Bool
    let directory: URL
    let created: (URL) -> Void
    @Environment(DialogPresenter.self) private var dialogs
    @State private var name = ""
    @State private var failure: String?
    @State private var creating = false
    @FocusState private var focused: Focus?
    @State private var keys = WindowKeyHandler(handlesTyping: true)

    private var validation: String? { name.isEmpty ? nil : FileTree.nameError(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Create in \(directory.path)").font(Typography.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(folder ? "Folder name" : "File name").font(Typography.label)
            TextField(folder ? "Folder name" : "Untitled.swift", text: $name)
                .textFieldStyle(.plain).padding(Space.md).fieldSurface(cornerRadius: Radius.control)
                .focused($focused, equals: .name).onSubmit(create)
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(focused == .name ? Theme.accent : .clear))
                .disabled(creating)
                .onChange(of: name) { failure = nil }
            if let error = failure ?? validation {
                Text(error).font(Typography.detail).foregroundStyle(Theme.deletion)
                    .accessibilityLabel("Error: \(error)")
            }
            HStack {
                Spacer()
                ActionButton(title: "Cancel", tone: .outlined, height: ControlHeight.lg, size: Typography.Size.detail) { dialogs.dismiss() }
                    .disabled(creating)
                    .focused($focused, equals: .cancel)
                    .overlay(Capsule().stroke(focused == .cancel ? Theme.accent : .clear, lineWidth: 2))
                ActionButton(title: creating ? "Creating…" : folder ? "Create folder" : "Create file",
                             tone: .green, height: ControlHeight.lg, size: Typography.Size.detail) { create() }
                    .disabled(creating || FileTree.nameError(name) != nil)
                    .focused($focused, equals: .create)
                    .overlay(Capsule().stroke(focused == .create ? Theme.accent : .clear, lineWidth: 2))
            }
        }
        .background(WindowKeyAnchor(handler: keys))
        .onAppear {
            focused = .name
            keys.start { event in
                if event.keyCode == 53 { dialogs.dismiss(); return true }
                if event.keyCode == 48 {
                    guard !creating else { return true }
                    let choices: [Focus] = FileTree.nameError(name) == nil ? [.name, .cancel, .create] : [.name, .cancel]
                    let index = choices.firstIndex(of: focused ?? .name) ?? 0
                    let step = event.modifierFlags.contains(.shift) ? -1 : 1
                    focused = choices[(index + step + choices.count) % choices.count]
                    return true
                }
                if event.keyCode == 36 {
                    if focused == .cancel { dialogs.dismiss() } else { create() }
                    return true
                }
                return false
            }
        }
        .onDisappear { keys.stop() }
    }

    private func create() {
        guard !creating, FileTree.nameError(name) == nil else { return }
        creating = true
        let dialogID = dialogs.current?.id
        if let dialogID { dialogs.setDismissalGuard(for: dialogID) { false } }
        Task {
            let result = await FileTree.create(name: name, folder: folder, in: directory)
            creating = false
            if let dialogID { dialogs.setDismissalGuard(for: dialogID) { true } }
            switch result {
            case .failed(let message): failure = message; focused = .name
            case .created(let url): dialogs.dismiss(); created(url)
            }
        }
    }
}
