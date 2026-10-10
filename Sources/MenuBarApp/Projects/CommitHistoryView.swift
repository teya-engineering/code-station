import AppKit
import SwiftUI

@MainActor
@Observable
final class CommitHistorySelection {
    var commit: GitCommitSummary?
    var fileID: String?
    var parent: String?
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

struct CommitDayGroup: Identifiable, Equatable {
    let id: Int
    let title: String
    var commits: [GitCommitSummary]
}

// The quiet labels the navigator groups commits under. Groups follow the order git gave,
// so a commit dated out of step with its neighbours starts a group of its own instead of
// being moved away from where it sits in the history.
enum CommitDay {
    static func title(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "Older" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if date < now, calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "Earlier this week" }
        return "Older"
    }

    static func groups(_ commits: [GitCommitSummary], now: Date = Date(),
                       calendar: Calendar = .current) -> [CommitDayGroup] {
        var groups: [CommitDayGroup] = []
        for commit in commits {
            let title = title(for: commit.date, now: now, calendar: calendar)
            if groups.last?.title == title {
                groups[groups.count - 1].commits.append(commit)
            } else {
                groups.append(CommitDayGroup(id: groups.count, title: title, commits: [commit]))
            }
        }
        return groups
    }
}

// One commit read top to bottom: what it is, which files it touched, then every file's
// diff in its own card. The project is named once, in the navigator, so this page never
// repeats it.
struct CommitHistoryView: View {
    let root: String
    @Bindable var selection: CommitHistorySelection
    var back: (() -> Void)?
    @State private var loadedFiles: GitInspector.CommitFiles?
    @State private var filesRequest: String?
    @State private var collapsed: Set<String> = []
    @State private var copied = false

    private var request: String { "\(selection.commit?.hash ?? "")/\(selection.parent ?? "")" }
    private var result: GitInspector.CommitFiles? { filesRequest == request ? loadedFiles : nil }
    private var comparison: String {
        "\(selection.parent.map { String($0.prefix(8)) } ?? "Empty tree") → \(selection.commit?.shortHash ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let back {
                HStack {
                    InlineLink(title: "Back to history", action: back)
                    Spacer()
                }.padding(.horizontal, 28).padding(.top, 14)
            }
            if let commit = selection.commit {
                summary(commit)
                if let result {
                    if let note = result.note {
                        PaneMessage(icon: "exclamationmark.triangle", title: "Could not read commit", detail: note)
                    } else if result.files.isEmpty {
                        PaneMessage(icon: "doc", title: "No file changes",
                                    detail: "This commit has no file changes against the selected parent.")
                    } else {
                        page(commit, result.files)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                PaneMessage(icon: "clock", title: "Select a commit",
                            detail: "Pick a commit under a project in the Workspace navigator.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commit")
        .task(id: request) {
            guard let commit = selection.commit else { return }
            loadedFiles = nil
            collapsed = []
            copied = false
            let loaded = await GitInspector.commitFiles(commit.hash, parent: selection.parent, root: root)
            guard !Task.isCancelled else { return }
            if selection.parent == nil, let parent = loaded.parents.first {
                selection.parent = parent
                return
            }
            filesRequest = request
            loadedFiles = loaded
            if !loaded.files.contains(where: { $0.id == selection.fileID }) { selection.fileID = nil }
        }
    }

    // MARK: - Summary

    private func summary(_ commit: GitCommitSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(commit.subject).font(.serif(22)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text("\(commit.author) · \(commit.relativeDate)").lineLimit(1)
                Button { copyHash(commit) } label: {
                    Label(copied ? "Copied" : commit.shortHash, systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.mono(11)).foregroundStyle(.primary)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .appTooltip(commit.hash)
                .accessibilityLabel("Copy full commit hash")
                .accessibilityValue(copied ? "Copied" : commit.shortHash)
                Spacer(minLength: 0)
                parentPicker
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let result, result.note == nil, !result.files.isEmpty {
                    let added = result.files.compactMap(\.added).reduce(0, +)
                    let removed = result.files.compactMap(\.removed).reduce(0, +)
                    Text(counted(result.files.count, "file") + " changed")
                    Text("+\(added)").foregroundStyle(Theme.addition)
                    Text("-\(removed)").foregroundStyle(Theme.deletion)
                    proportion(added: added, removed: removed)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    // A menu when the commit is a merge and there is a parent to choose, plain text when not.
    @ViewBuilder private var parentPicker: some View {
        let parents = result?.parents ?? []
        let label = HStack(spacing: 5) {
            Text(comparison).font(.mono(10))
            if parents.count > 1 { Image(systemName: "chevron.down").font(.system(size: 9)) }
        }.padding(6).contentShape(Rectangle())
        if parents.count > 1 {
            label
                .appMenu {
                    parents.enumerated().map { index, parent in
                        .item("Parent \(index + 1): \(parent.prefix(8))", checked: selection.parent == parent) {
                            selection.parent = parent
                            selection.fileID = nil
                        }
                    }
                }
                .accessibilityLabel("Comparison parent: \(comparison)")
        } else {
            label.accessibilityLabel("Compared with \(comparison)")
        }
    }

    private func proportion(added: Int, removed: Int) -> some View {
        let cells = 10
        let total = added + removed
        let green = total == 0 ? 0 : Int((Double(added) / Double(total) * Double(cells)).rounded())
        let red = total == 0 ? 0 : cells - green
        return HStack(spacing: 1) {
            ForEach(0..<cells, id: \.self) { cell in
                RoundedRectangle(cornerRadius: 1)
                    .fill(cell < green ? Theme.addition : cell < green + red ? Theme.deletion : Theme.sunken)
                    .frame(width: 7, height: 9)
            }
        }.accessibilityHidden(true)
    }

    // MARK: - Files

    private func page(_ commit: GitCommitSummary, _ files: [GitChange]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    fileSummary(files) { file in
                        selection.fileID = file.id
                        collapsed.remove(file.id)
                        withAnimation(Motion.control) { proxy.scrollTo(file.id, anchor: .top) }
                        announce("Showing \(file.path)")
                    }
                    .padding(.bottom, 20)
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        Section {
                            VStack(spacing: 0) {
                                if !collapsed.contains(file.id) {
                                    CommitFileDiff(root: root, hash: commit.hash, parent: selection.parent, file: file)
                                        .background(Theme.card)
                                        .clipShape(OpenTopCard(radius: 9))
                                        .overlay(OpenTopCard(radius: 9).stroke(Theme.border))
                                }
                            }.padding(.bottom, 16)
                        } header: {
                            cardHeader(file, position: index + 1, of: files.count).id(file.id)
                        }
                    }
                }
                .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 12)
            }
        }
        .accessibilityLabel("Changed files and diffs")
    }

    private func fileSummary(_ files: [GitChange], jump: @escaping (GitChange) -> Void) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changed files").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Click a file to jump to it").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).frame(height: 36)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ForEach(files) { file in
                let current = selection.fileID == file.id
                Button { jump(file) } label: {
                    HStack(spacing: 10) {
                        kindLetter(file).frame(width: 20, alignment: .leading)
                        HStack(spacing: 8) {
                            Text(file.fileName).font(.system(size: 11.5, weight: .semibold))
                            let folder = (file.path as NSString).deletingLastPathComponent
                            if !folder.isEmpty {
                                Text(folder).font(.mono(10.5)).foregroundStyle(.secondary).truncationMode(.head)
                            }
                        }.lineLimit(1)
                        Spacer(minLength: 8)
                        counts(file)
                    }
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(current ? Theme.accent.opacity(0.1) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverFill(cornerRadius: 0)
                .appTooltip(file.path)
                .accessibilityLabel("\(file.path), \(file.kind.label)")
                .accessibilityHint("Scrolls to this file's diff")
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
    }

    private func cardHeader(_ file: GitChange, position: Int, of count: Int) -> some View {
        let isCollapsed = collapsed.contains(file.id)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: isCollapsed ? 9 : 0,
                                           bottomTrailingRadius: isCollapsed ? 9 : 0, topTrailingRadius: 9)
        return HStack(spacing: 8) {
            Button {
                if !collapsed.insert(file.id).inserted { collapsed.remove(file.id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 24, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .motion(Motion.control, value: isCollapsed)
            .accessibilityLabel("\(isCollapsed ? "Expand" : "Collapse") \(file.fileName)")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            kindLetter(file).frame(width: 20, alignment: .leading)
            Text(file.fileName).font(.system(size: 12, weight: .semibold)).lineLimit(1).layoutPriority(1)
            Text(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
                .font(.mono(10.5)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            counts(file)
            Text("\(position) of \(count)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .padding(.leading, 8)
        }
        .padding(.leading, 6).padding(.trailing, 12)
        .frame(height: 42)
        .background(Theme.card, in: shape)
        .overlay(shape.stroke(Theme.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(file.path), file \(position) of \(count)")
    }

    private func kindLetter(_ file: GitChange) -> some View {
        Text(file.kind.letter).font(.mono(10, .bold))
            .foregroundStyle(file.kind == .added ? Theme.addition : file.kind == .deleted ? Theme.deletion : Theme.accent)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func counts(_ file: GitChange) -> some View {
        if file.isBinary {
            Text("binary").font(.system(size: 10.5)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 10) {
                Text("+\(file.added ?? 0)").foregroundStyle(Theme.addition)
                Text("-\(file.removed ?? 0)").foregroundStyle(Theme.deletion)
            }.font(.mono(10.5))
        }
    }

    private func copyHash(_ commit: GitCommitSummary) {
        guard Pasteboard.copy(commit.hash) else { return }
        copied = true
        announce("Commit hash copied")
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

// The body of a file card. Each card reads its own diff, and only once the page scrolls
// it into view, so a large commit opens as fast as a small one.
private struct CommitFileDiff: View {
    let root: String
    let hash: String
    let parent: String?
    let file: GitChange
    @Environment(AppSettings.self) private var settings
    @State private var diff: FileDiff?
    @State private var text: NSAttributedString?
    @State private var expanding: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let note = diff?.note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 18)
            } else if let text {
                DiffTextView(text: text, scroll: .hold, onExpand: expand, fitsContent: true)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(18)
            }
            if let diff, diff.truncated {
                Text("Showing the first \(diff.lines.count - diff.revealed) lines of \(diff.totalLines). Run git show to see the rest.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.field)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(hash)/\(parent ?? "")/\(file.id)") {
            diff = nil
            text = nil
            let loaded = await GitInspector.commitFileDiff(hash, parent: parent, file: file, root: root)
            guard !Task.isCancelled else { return }
            diff = loaded
            await render()
        }
        .onChange(of: settings.textSize) { _, _ in Task { await render() } }
    }

    private func expand(_ key: String, _ direction: DiffExpandDirection) {
        guard !expanding.contains(key), let gap = diff?.lines.first(where: { $0.gap?.key == key })?.gap else { return }
        let identity = "\(hash)/\(parent ?? "")"
        expanding.insert(key)
        Task {
            let expansion = await GitInspector.expand(gap, direction, root: root)
            expanding.remove(key)
            guard identity == "\(hash)/\(parent ?? "")", var opened = diff,
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
            diff = opened
            await render()
        }
    }

    private func render() async {
        guard let diff, diff.note == nil else { return }
        let lines = diff.lines
        let built = await DiffText.build(lines, language: CodeLanguage(fileExtension: (file.path as NSString).pathExtension),
                                         scale: settings.textSize.scale, numbered: true)
        // More of the file can have opened while the text was built.
        guard self.diff?.lines == lines else { return }
        text = built
    }
}

// A card body that hangs under its pinned header: the sides and bottom are drawn, the top
// edge is left to the header so the two never stack into a double line.
private struct OpenTopCard: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX + radius, y: rect.maxY), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - radius), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
