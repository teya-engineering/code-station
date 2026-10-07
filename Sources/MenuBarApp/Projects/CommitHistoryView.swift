import AppKit
import SwiftUI

@MainActor
@Observable
final class CommitHistorySelection {
    var commit: GitCommitSummary?
    var fileID: String?
    var parent: String?
    var search = ""
    var showingDetail = false

    func select(_ value: GitCommitSummary) {
        if commit?.id != value.id {
            commit = value
            fileID = nil
            parent = nil
        }
        showingDetail = true
    }
}

struct CommitHistoryView: View {
    let root: String
    let commits: [GitCommitSummary]
    @Bindable var selection: CommitHistorySelection
    @Environment(AppSettings.self) private var settings
    @State private var loadedFiles: GitInspector.CommitFiles?
    @State private var filesRequest: String?
    @State private var diffRequest: String?
    @State private var loadedDiff: FileDiff?
    @State private var text: NSAttributedString?
    @State private var filesVisible = false
    @State private var expanding: Set<String> = []
    @State private var scroll = DiffTextView.Scroll.top
    @FocusState private var focus: Focus?
    private enum Focus { case commits, files }

    private var filtered: [GitCommitSummary] {
        commits.filter { selection.search.isEmpty || $0.subject.localizedCaseInsensitiveContains(selection.search)
            || $0.hash.localizedCaseInsensitiveContains(selection.search) }
    }
    private var result: GitInspector.CommitFiles? { filesRequest == request ? loadedFiles : nil }
    private var fileRequest: String { request + "/" + (file?.id ?? "") }
    private var diff: FileDiff? { diffRequest == fileRequest ? loadedDiff : nil }
    private var file: GitChange? { result?.files.first { $0.id == selection.fileID } }
    private var comparison: String { "\(selection.parent.map { String($0.prefix(8)) } ?? "Empty tree") → \(selection.commit?.shortHash ?? "")" }
    private var request: String { "\(selection.commit?.hash ?? "")/\(selection.parent ?? "")" }

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 850
            HStack(spacing: 0) {
                if !narrow || !selection.showingDetail {
                    historyList
                        .frame(width: narrow ? nil : 270)
                    if !narrow { Rectangle().fill(Theme.border).frame(width: 1) }
                }
                if !narrow || selection.showingDetail {
                    VStack(spacing: 0) {
                        if narrow {
                            HStack {
                                InlineLink(title: "Back to history") { selection.showingDetail = false }
                                Spacer()
                                InlineLink(title: filesVisible ? "Hide files" : "Show files") { filesVisible.toggle() }
                            }.padding(12)
                        }
                        if let commit = selection.commit {
                            summary(commit)
                            if let result {
                                if let note = result.note {
                                    PaneMessage(icon: "exclamationmark.triangle", title: "Could not read commit", detail: note)
                                } else if result.files.isEmpty {
                                    PaneMessage(icon: "doc", title: "No file changes", detail: "This commit has no file changes against the selected parent.")
                                } else {
                                    HStack(spacing: 0) {
                                        if !narrow || filesVisible {
                                            fileList(result.files).frame(width: narrow ? nil : 230)
                                            Rectangle().fill(Theme.border).frame(width: 1)
                                        }
                                        if !narrow || !filesVisible { fileDiff }
                                    }
                                }
                            } else {
                                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else {
                            PaneMessage(icon: "clock", title: "Select a commit", detail: "Choose a commit to review its files.")
                        }
                    }.frame(maxWidth: .infinity).background(Theme.card)
                }
            }
        }
        .background(Theme.background)
        .task(id: request) {
            guard let commit = selection.commit else { return }
            loadedFiles = nil; loadedDiff = nil; text = nil
            let loaded = await GitInspector.commitFiles(commit.hash, parent: selection.parent, root: root)
            guard !Task.isCancelled else { return }
            if selection.parent == nil, let parent = loaded.parents.first {
                selection.parent = parent
                return
            }
            filesRequest = request
            loadedFiles = loaded
            if !loaded.files.contains(where: { $0.id == selection.fileID }) {
                selection.fileID = loaded.files.first?.id
            }
        }
        .task(id: fileRequest) {
            loadedDiff = nil; text = nil; scroll = .top
            guard let commit = selection.commit, let file else { return }
            let loaded = await GitInspector.commitFileDiff(commit.hash, parent: selection.parent, file: file, root: root)
            guard !Task.isCancelled else { return }
            diffRequest = fileRequest
            loadedDiff = loaded
            render()
        }
        .onChange(of: settings.textSize) { _, _ in render() }
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            TextField("Search commits", text: $selection.search).appTextField().padding(12)
                .accessibilityLabel("Search commits by title or hash")
            Text("Recent commits").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { commit in
                            Button {
                                focus = .commits
                                selection.select(commit)
                                announce(commit.subject)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(commit.subject).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    HStack {
                                        Text(commit.shortHash).font(.mono(10))
                                        Spacer(minLength: 4)
                                        Text(commit.relativeDate).font(.system(size: 10)).lineLimit(1)
                                    }.foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 11).frame(height: 53)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .surface(selection.commit?.id == commit.id ? Theme.card : .clear, cornerRadius: 6,
                                         border: selection.commit?.id == commit.id ? Theme.accent.opacity(0.4) : .clear)
                                .overlay(alignment: .leading) {
                                    if selection.commit?.id == commit.id { Rectangle().fill(Theme.accent).frame(width: 3).padding(.vertical, 8) }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).id(commit.id)
                                .appTooltip(commit.subject)
                                .accessibilityAddTraits(selection.commit?.id == commit.id ? .isSelected : [])
                        }
                        if filtered.isEmpty { Text("No matching commits").foregroundStyle(.secondary).padding() }
                    }.padding(8)
                }
                .onChange(of: selection.commit?.id) { _, id in if let id { proxy.scrollTo(id) } }
            }
            .focusable().focused($focus, equals: .commits).focusEffectDisabled()
            .onMoveCommand { direction in
                guard direction == .up || direction == .down,
                      let index = RowStep.destination(from: filtered.firstIndex { $0.id == selection.commit?.id },
                                                      step: direction == .up ? -1 : 1, count: filtered.count) else { return }
                selection.select(filtered[index]); announce(filtered[index].subject)
            }
        }.accessibilityLabel("Commit history")
    }

    private func summary(_ commit: GitCommitSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(commit.subject).font(.serif(22, .semibold)).textSelection(.enabled)
            HStack {
                Text("\(commit.author) · \(commit.relativeDate)").font(.system(size: 11)).foregroundStyle(.secondary)
                Button { Pasteboard.copy(commit.hash); announce("Commit hash copied") } label: {
                    Label(commit.shortHash, systemImage: "doc.on.doc").font(.mono(11)).padding(6)
                        .surface(Theme.field, cornerRadius: 6).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Copy full commit hash")
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                if let result, result.note == nil {
                    Text(counted(result.files.count, "file") + " changed")
                    Text("+\(result.files.compactMap(\.added).reduce(0, +))").foregroundStyle(Theme.addition)
                    Text("-\(result.files.compactMap(\.removed).reduce(0, +))").foregroundStyle(Theme.deletion)
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Text(comparison).font(.mono(10))
                    if (result?.parents.count ?? 0) > 1 { Image(systemName: "chevron.down").font(.system(size: 10)) }
                }.foregroundStyle(.secondary).padding(6).contentShape(Rectangle())
                    .appMenu {
                        (result?.parents ?? []).enumerated().map { index, parent in
                            .item("Parent \(index + 1): \(parent.prefix(8))", checked: selection.parent == parent) {
                                selection.parent = parent; selection.fileID = nil
                            }
                        }
                    }.accessibilityLabel("Comparison parent: \(comparison)")
            }.font(.system(size: 11))
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func fileList(_ files: [GitChange]) -> some View {
        VStack(spacing: 0) {
            Text("Changed files · \(files.count)").font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(files) { file in
                            Button { focus = .files; selectFile(file) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(file.kind.letter).font(.mono(10, .bold)).foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(file.fileName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                        Text((file.path as NSString).deletingLastPathComponent).font(.system(size: 10))
                                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        if file.isBinary { Text("Binary").font(.system(size: 10)) }
                                        else {
                                            HStack {
                                                Text("+\(file.added ?? 0)").foregroundStyle(Theme.addition)
                                                Text("-\(file.removed ?? 0)").foregroundStyle(Theme.deletion)
                                            }.font(.mono(10))
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(10)
                                    .surface(selection.fileID == file.id ? Theme.accent.opacity(0.1) : .clear, cornerRadius: 7,
                                             border: selection.fileID == file.id ? Theme.accent.opacity(0.3) : .clear)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(file.id).appTooltip(file.path)
                                .accessibilityLabel("\(file.path), \(file.kind.label)")
                                .accessibilityAddTraits(selection.fileID == file.id ? .isSelected : [])
                        }
                    }.padding(8)
                }.onChange(of: selection.fileID) { _, id in if let id { proxy.scrollTo(id) } }
            }.focusable().focused($focus, equals: .files).focusEffectDisabled()
                .onMoveCommand { direction in
                    if direction == .up { moveFile(-1) }
                    if direction == .down { moveFile(1) }
                }
        }.background(Theme.background).accessibilityLabel("Files in selected commit")
    }

    private var fileDiff: some View {
        VStack(spacing: 0) {
            if let file {
                HStack {
                    Text(file.fileName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    let index = result?.files.firstIndex { $0.id == file.id } ?? 0
                    Text("\(index + 1) / \(result?.files.count ?? 0)").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button { moveFile(-1) } label: { Image(systemName: "arrow.up").padding(7).contentShape(Rectangle()) }
                        .buttonStyle(.plain).disabled(index == 0).accessibilityLabel("Previous file")
                    Button { moveFile(1) } label: { Image(systemName: "arrow.down").padding(7).contentShape(Rectangle()) }
                        .buttonStyle(.plain).disabled(index + 1 == result?.files.count).accessibilityLabel("Next file")
                }.padding(.horizontal, 16).frame(height: 49)
                Text(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
                    .font(.mono(10)).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                if let note = diff?.note {
                    PaneMessage(icon: "doc", title: "Preview unavailable", detail: note)
                } else if diff != nil, let text {
                    DiffTextView(text: text, scroll: scroll, onExpand: expand)
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                if let diff, diff.truncated {
                    Text("Showing the first \(diff.lines.count - diff.revealed) lines of \(diff.totalLines). Run git show to see the rest.")
                        .font(.system(size: 11)).padding(8)
                }
                HStack {
                    Text("Unified diff")
                    Spacer()
                    Text("Read-only commit snapshot")
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(10).background(Theme.statusBand)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectFile(_ file: GitChange) {
        selection.fileID = file.id
        filesVisible = false
        announce("Selected \(file.path)")
    }

    private func moveFile(_ step: Int) {
        guard let files = result?.files,
              let index = RowStep.destination(from: files.firstIndex { $0.id == selection.fileID }, step: step, count: files.count) else { return }
        selectFile(files[index])
    }

    private func expand(_ key: String, _ direction: DiffExpandDirection) {
        guard !expanding.contains(key), let gap = diff?.lines.first(where: { $0.gap?.key == key })?.gap else { return }
        let identity = request + (selection.fileID ?? "")
        expanding.insert(key)
        Task {
            let expansion = await GitInspector.expand(gap, direction, root: root)
            expanding.remove(key)
            guard identity == request + (selection.fileID ?? ""), var opened = diff,
                  let index = opened.lines.firstIndex(where: { $0.gap?.key == key }) else { return }
            if let remaining = expansion.gap {
                opened.lines[index].gap = remaining
                opened.lines.insert(contentsOf: expansion.lines, at: direction == .up ? index + 1 : index)
                opened.revealed += expansion.lines.count
            } else {
                opened.lines.replaceSubrange(index...index, with: expansion.lines)
                opened.revealed += expansion.lines.count - 1
            }
            for i in opened.lines.indices { opened.lines[i].id = i }
            loadedDiff = opened
            scroll = direction == .down ? .follow : .hold
            render()
        }
    }

    private func render() {
        guard let diff else { return }
        text = DiffText.attributed(diff.lines, language: file.flatMap { CodeLanguage(fileExtension: ($0.path as NSString).pathExtension) },
                                   scale: settings.textSize.scale, numbered: true)
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
