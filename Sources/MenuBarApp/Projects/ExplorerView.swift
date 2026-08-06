import AppKit
import SwiftUI

// Every file in a session's folder, as a tree with a preview beside it. Changes only
// covers what git has something to say about; this is the whole working tree, which is
// what you want when the agent names a file you have never opened.
//
// Read-only, like Changes: nothing here creates, renames or deletes anything.
struct ExplorerView: View {
    let root: String

    // Children are kept per folder rather than as a nested tree, so a folder can be read
    // the moment it is opened and the rows on screen stay a flat list.
    @State private var children: [String: [FileNode]] = [:]
    @State private var expanded: Set<String> = []
    @State private var loadingFolders: Set<String> = []
    @State private var selected: FileNode?
    @State private var preview: FilePreview?
    @State private var loadingPreview = false
    @State private var showHidden = true
    @State private var textWidth: CGFloat = 0

    private var rootURL: URL { URL(fileURLWithPath: root) }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                tree
                Divider().overlay(Theme.hairline)
                detail
            }
        }
        .background(Theme.background)
        .task(id: root) { await openRoot() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 12))
                Text(rootURL.lastPathComponent).font(.mono(13, .medium))
            }

            if let count = children[root]?.count {
                Text("\(count) item\(count == 1 ? "" : "s")")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Hidden files", isOn: $showHidden)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .onChange(of: showHidden) { Task { await reopenFolders() } }

            Button {
                Task { await reopenFolders() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .help("Refresh")
        }
        .padding(.horizontal, 20)
        .headerBand(height: Theme.subHeaderHeight)
    }

    // MARK: - Tree

    // One visible row: the entry and how deep it sits. Folders that are shut contribute
    // nothing, so this is only ever as long as what is actually open.
    private struct Row: Identifiable {
        let node: FileNode
        let depth: Int
        var id: String { node.path }
    }

    private var rows: [Row] {
        var out: [Row] = []
        func walk(_ path: String, depth: Int) {
            for node in children[path] ?? [] {
                out.append(Row(node: node, depth: depth))
                if node.isDirectory && expanded.contains(node.path) {
                    walk(node.path, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return out
    }

    @ViewBuilder private var tree: some View {
        VStack(spacing: 0) {
            if children[root]?.isEmpty == true {
                PaneMessage(icon: "folder", title: "Empty folder",
                            detail: showHidden ? "" : "Hidden files are off.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(rows) { row in
                            treeRow(row)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(width: 300)
    }

    private func treeRow(_ row: Row) -> some View {
        let node = row.node
        let isOpen = expanded.contains(node.path)
        let isSelected = selected?.path == node.path

        return Button {
            if node.isDirectory { toggle(node) } else { select(node) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                    .opacity(node.isDirectory ? 1 : 0)

                if loadingFolders.contains(node.path) {
                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 14)
                } else {
                    Image(systemName: icon(node))
                        .font(.system(size: 11))
                        .foregroundStyle(node.isDirectory ? Theme.accent : .secondary)
                        .frame(width: 14)
                }

                Text(node.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if !node.isDirectory {
                    Text(node.size.formatted(.byteCount(style: .file)))
                        .font(.mono(10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 3)
            .padding(.trailing, 8)
            .padding(.leading, CGFloat(row.depth) * 13 + 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Theme.card : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Theme.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appContextMenu {
            [.item("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) },
             .item("Open with default app") { NSWorkspace.shared.open(node.url) },
             .item("Copy Path") {
                 NSPasteboard.general.clearContents()
                 NSPasteboard.general.setString(node.path, forType: .string)
             }]
        }
    }

    private func icon(_ node: FileNode) -> String {
        if node.isDirectory { return expanded.contains(node.path) ? "folder.fill" : "folder" }
        if FileTree.imageKinds.contains(node.kind) { return "photo" }
        return switch node.kind {
        case "swift", "kt", "java", "rs", "go", "py", "rb", "js", "ts", "c", "h", "cpp": "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "xml", "plist", "lock": "curlybraces"
        case "md", "markdown", "txt", "rtf": "doc.text"
        case "sh", "zsh", "bash", "fish": "terminal"
        case "pdf": "doc.richtext"
        case "zip", "gz", "tar", "jar": "shippingbox"
        default: "doc"
        }
    }

    // MARK: - Preview

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let node = selected {
                HStack(spacing: 10) {
                    Text(node.name).font(.serif(15, .semibold)).lineLimit(1)
                    Text(relativePath(node))
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    if loadingPreview { ProgressView().controlSize(.small) }
                    Button("Open") { NSWorkspace.shared.open(node.url) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([node.url])
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                previewBody(node)
            } else {
                PaneMessage(icon: "sidebar.left", title: "Pick a file",
                            detail: "Its contents show up here. Folders open in place.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card)
    }

    @ViewBuilder private func previewBody(_ node: FileNode) -> some View {
        switch preview {
        case .text(let lines, let truncated, let total):
            fileText(lines)
            if truncated {
                Text("Showing the first \(lines.count) lines of \(total). Open the file to see the rest.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.field)
            }
        case .image(let data):
            if let image = NSImage(data: data) {
                VStack(spacing: 10) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                    Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(node.size.formatted(.byteCount(style: .file)))")
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PaneMessage(icon: "photo", title: "Cannot draw this image",
                            detail: node.size.formatted(.byteCount(style: .file)))
            }
        case .binary(let size):
            PaneMessage(icon: "doc.zipper", title: "Binary file",
                        detail: "\(size.formatted(.byteCount(style: .file))) of data this app cannot show as text.")
        case .tooLarge(let size):
            PaneMessage(icon: "doc.badge.ellipsis", title: "Too big to preview",
                        detail: "\(size.formatted(.byteCount(style: .file))). Open it in an editor instead.")
        case .empty:
            PaneMessage(icon: "doc", title: "Empty file", detail: "0 bytes.")
        case .unreadable(let reason):
            PaneMessage(icon: "exclamationmark.triangle", title: "Could not read this file",
                        detail: reason)
        case nil:
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Line numbers and text are two columns of one monospaced font, so the rows line up
    // without measuring anything per line. Both scroll together, the gutter included:
    // pinning it would cost a second scroll view kept in step with this one.
    private func fileText(_ lines: [String]) -> some View {
        let gutter = MonoMetrics.width(of: "\(lines.count)") + 8
        return GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(chunks(lines)) { chunk in
                        HStack(alignment: .top, spacing: 12) {
                            Text(chunk.numbers)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.trailing)
                                .frame(width: gutter, alignment: .trailing)
                            Text(chunk.text)
                                .textSelection(.enabled)
                                .frame(width: max(textWidth, geometry.size.width - gutter - 36),
                                       alignment: .leading)
                        }
                        .font(.mono(11))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    // Runs of lines drawn as one Text each. A file is far too many views one line at a
    // time, and a single Text holding all of it lays the whole file out before the first
    // screen of it appears.
    private struct Chunk: Identifiable {
        let id: Int
        let numbers: String
        let text: String
    }

    private func chunks(_ lines: [String], size: Int = 100) -> [Chunk] {
        stride(from: 0, to: lines.count, by: size).map { start in
            let end = min(start + size, lines.count)
            return Chunk(
                id: start,
                numbers: (start..<end).map { "\($0 + 1)" }.joined(separator: "\n"),
                text: lines[start..<end].joined(separator: "\n"))
        }
    }

    private func relativePath(_ node: FileNode) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return node.path.hasPrefix(prefix) ? String(node.path.dropFirst(prefix.count)) : node.path
    }

    // MARK: - Actions

    // The pane is reused as the session changes, so everything the last folder left behind
    // has to go before the new one is read.
    private func openRoot() async {
        children = [:]
        expanded = []
        selected = nil
        preview = nil
        await load(root)
    }

    private func load(_ path: String) async {
        loadingFolders.insert(path)
        let nodes = await FileTree.children(of: URL(fileURLWithPath: path), includeHidden: showHidden)
        loadingFolders.remove(path)
        guard !Task.isCancelled else { return }
        children[path] = nodes
    }

    // Everything already open is read again. Anything still shut is left alone: it will be
    // read when it is opened, which is late enough to pick the change up anyway.
    private func reopenFolders() async {
        for path in ([root] + expanded) where children[path] != nil {
            await load(path)
        }
    }

    private func toggle(_ node: FileNode) {
        if expanded.contains(node.path) {
            expanded.remove(node.path)
        } else {
            expanded.insert(node.path)
            if children[node.path] == nil { Task { await load(node.path) } }
        }
    }

    private func select(_ node: FileNode) {
        selected = node
        preview = nil
        textWidth = 0
        Task {
            loadingPreview = true
            let loaded = await FileTree.preview(of: node.url)
            loadingPreview = false
            guard !Task.isCancelled, selected?.path == node.path else { return }
            preview = loaded
            if case .text(let lines, _, _) = loaded {
                textWidth = MonoMetrics.width(ofLongestIn: lines) + 24
            }
        }
    }
}

// Monospaced text is as wide as its longest line, so one measurement sizes a whole file
// without laying any of it out first.
enum MonoMetrics {
    static func width(of text: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func width(ofLongestIn lines: [String]) -> CGFloat {
        guard let longest = lines.max(by: { $0.count < $1.count }) else { return 0 }
        return width(of: longest)
    }
}
