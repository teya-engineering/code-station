import SwiftUI

// The files in the ask's receipt. A small review is one flat list. A big one leads with
// a map of the whole change, then one row per folder that opens onto its files, with
// a switch to the largest files and a filter across them all. The list stops at a fixed
// height and scrolls inside, so the card stays one size however big the branch is.
struct SecondOpinionChangeList: View {
    enum Arrangement { case folders, largest }

    typealias File = SecondOpinionAskFacts.File

    let receipt: ChangeReceipt
    @Binding var filter: String
    let open: (File) -> Void

    @State private var arrangement = Arrangement.folders
    @State private var opened: Set<ChangeReceipt.Folder.ID> = []
    @State private var showsAll = false
    @State private var focus: ChangeMap.Focus?
    // The map lit the rows, rather than the pointer being on a row. A row under the
    // pointer already answers with its own wash.
    @State private var focusFromMap = false
    @Namespace private var track
    @FocusState private var filterFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filtering: Bool { !filter.trimmed.isEmpty }

    var body: some View {
        if receipt.isFlat {
            scrolling {
                ForEach(Array(receipt.largest.enumerated()), id: \.element.id) { index, file in
                    fileRow(file, scale: receipt.fileScale, index: index)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Space.md) {
                ChangeMap(groups: mapGroups, focus: focus,
                          accessibilityText: "Lines changed by file, in \(counted(receipt.folders.count, "folder"))",
                          hover: { focus = $0; focusFromMap = $0 != nil },
                          open: { slice in receipt.files.first { $0.id == slice.id }.map(open) })
                tools
                    .padding(.top, Space.sm)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                            .padding(.horizontal, -Space.card)
                            .offset(y: -Space.xs)
                    }
                scrolling { arranged }
            }
        }
    }

    private var mapGroups: [ChangeMap.Group] {
        receipt.folders.map { folder in
            ChangeMap.Group(id: folder.id, label: (folder.title as NSString).lastPathComponent,
                            slices: folder.files.map {
                                ChangeMap.Slice(id: $0.id, title: $0.path, added: $0.added, removed: $0.removed)
                            })
        }
    }

    private func scrolling<Rows: View>(@ViewBuilder _ rows: () -> Rows) -> some View {
        MenuContentScrollView(maxHeight: ReviewMetrics.receiptListHeight, fade: Theme.sunken) {
            VStack(alignment: .leading, spacing: 0) { rows() }
                .padding(.horizontal, Space.sm)
        }
        .padding(.horizontal, -Space.sm)
    }

    // MARK: Tools

    private var tools: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: Space.xxs) {
                arrangementPill("Folders", .folders)
                arrangementPill("Largest", .largest)
            }
            .padding(Space.xxs)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control + Space.xxs))
            .motion(Motion.control, value: arrangement)
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Arrange files")
            let folds = arrangement == .folders && !filtering
            InlineLink(title: opened.isEmpty ? "Open all" : "Fold all") {
                withAnimation(Motion.reveal) {
                    opened = opened.isEmpty ? Set(receipt.folders.map(\.id)) : []
                }
            }
            .contentTransition(.opacity)
            .opacity(folds ? 1 : 0)
            .disabled(!folds)
            .accessibilityHidden(!folds)
            .motion(Motion.reveal, value: folds)
            Spacer(minLength: Space.xl)
            filterField
        }
    }

    private func arrangementPill(_ title: String, _ value: Arrangement) -> some View {
        ChoicePill(title: title, selected: arrangement == value, thumb: track) {
            guard arrangement != value else { return }
            withAnimation(Motion.reveal) {
                arrangement = value
                showsAll = false
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(Typography.caption).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter \(counted(receipt.files.count, "file"))", text: $filter)
                .textFieldStyle(.plain)
                .font(Typography.detail)
                .focused($filterFocused)
                .onExitCommand { filter = "" }
                .accessibilityLabel("Filter files")
            if !filter.isEmpty {
                GlyphButton(icon: "xmark", side: ControlHeight.xs) {
                    filter = ""
                    filterFocused = true
                }
                .accessibilityLabel("Clear the filter")
                .transition(.opacity)
            }
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.xxs)
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: ControlHeight.md)
        .fieldSurface()
        .motion(Motion.hover, value: filter.isEmpty)
    }

    // MARK: Arrangements

    // Folders, largest and a filter are different pictures of the files: the old one goes
    // at once and the new one rises in.
    private var arranged: some View {
        VStack(alignment: .leading, spacing: 0) {
            if filtering {
                filtered
            } else if arrangement == .largest {
                largest
            } else {
                ForEach(receipt.folders) { folderRows($0) }
            }
        }
        .id(filtering ? "filter" : arrangement == .largest ? "largest" : "folders")
        .transition(reduceMotion ? .opacity
                    : .asymmetric(insertion: .opacity.combined(with: .offset(y: Space.sm)), removal: .identity))
    }

    @ViewBuilder private var largest: some View {
        let files = receipt.largest
        let shown = showsAll ? files : Array(files.prefix(ChangeReceipt.largestShown))
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, file in
            fileRow(file, scale: receipt.fileScale, index: index)
        }
        if shown.count < files.count {
            InlineLink(title: "Show the other \(counted(files.count - shown.count, "file"))",
                       size: Typography.Size.caption) {
                withAnimation(Motion.reveal) { showsAll = true }
            }
            .padding(.horizontal, Space.sm)
            .frame(height: ControlHeight.md)
        }
    }

    @ViewBuilder private var filtered: some View {
        let matches = receipt.matching(filter)
        if matches.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("No file matches “\(filter.trimmed)”. Try part of a folder or file name.")
                    .font(Typography.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                InlineLink(title: "Clear the filter") { filter = "" }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
        } else {
            Text("\(matches.count) of \(counted(receipt.files.count, "file")) match")
                .font(Typography.caption).foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, file in
                fileRow(file, scale: receipt.fileScale, index: index)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder private func folderRows(_ folder: ChangeReceipt.Folder) -> some View {
        let isOpen = opened.contains(folder.id)
        let lit = focusFromMap && focus?.group == folder.id && !isOpen
        Button {
            withAnimation(Motion.reveal) {
                if isOpen { opened.remove(folder.id) } else { opened.insert(folder.id) }
            }
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: "chevron.right")
                    .font(Typography.micro)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .motion(Motion.control, value: isOpen)
                    .frame(width: Space.lg)
                folderTitle(folder)
                    .font(Typography.data)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(counted(folder.files.count, "file"))
                    .font(Typography.caption).foregroundStyle(.secondary)
                    .frame(width: ReviewMetrics.receiptCountWidth, alignment: .trailing)
                figures(added: folder.added, removed: folder.removed, scale: receipt.folderScale)
            }
            .rowFrame(lit: lit)
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.inset)
        .onPointerHover { inside in hover(inside ? ChangeMap.Focus(group: folder.id) : nil, leaving: folder.id) }
        .accessibilityLabel("Folder \(folder.title), \(counted(folder.files.count, "file")), "
                            + "\(folder.added) added, \(folder.removed) removed")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint(isOpen ? "Hides its files" : "Shows its files")
        if isOpen {
            ForEach(Array(folder.files.enumerated()), id: \.element.id) { index, file in
                fileRow(file, name: folder.name(of: file), scale: receipt.folderScale, index: index, nested: true)
            }
        }
    }

    // A folder under the shared root writes the root faded, so its own name reads first.
    private func folderTitle(_ folder: ChangeReceipt.Folder) -> Text {
        guard let root = receipt.sharedRoot, folder.title.hasPrefix(root) else { return Text(folder.title) }
        return Text("\(Text(root).foregroundStyle(.tertiary))\(String(folder.title.dropFirst(root.count)))")
    }

    // A file on its own in the list says its folder, faded, after its name. Inside an open
    // folder the name alone is enough.
    private func fileRow(_ file: File, name: String? = nil, scale: Int, index: Int, nested: Bool = false) -> some View {
        let lit = focusFromMap && focus?.slice == file.id
        let folder = (file.path as NSString).deletingLastPathComponent
        return Button { open(file) } label: {
            HStack(spacing: Space.md) {
                Image(systemName: "doc")
                    .font(Typography.caption).foregroundStyle(.tertiary)
                    .frame(width: Space.lg)
                    .padding(.leading, nested ? Space.xl : 0)
                HStack(spacing: Space.sm) {
                    highlighted(name ?? file.name)
                        .font(Typography.data)
                        .lineLimit(1)
                        .layoutPriority(1)
                    switch file.change {
                    case .new: MonoChip(text: "new", tint: Theme.addition, mono: false)
                    case .deleted: MonoChip(text: "deleted", tint: Theme.deletion, mono: false)
                    case .edited: EmptyView()
                    }
                    if name == nil && !folder.isEmpty {
                        highlighted(folder)
                            .font(Typography.data).foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                figures(added: file.added, removed: file.removed, scale: scale)
            }
            .rowFrame(lit: lit)
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.inset)
        .onPointerHover { inside in
            let group = receipt.folder(of: file)?.id ?? file.id
            hover(inside ? ChangeMap.Focus(group: group, slice: file.id) : nil, leaving: group)
        }
        .appTooltip(file.path)
        .accessibilityLabel("Open \(file.path), \(file.added) added, \(file.removed) removed"
                            + (file.change == .new ? ", new file" : file.change == .deleted ? ", deleted" : ""))
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -Space.xs))
                .animation(Motion.reveal.delay(Motion.stagger * Double(min(index, ChangeReceipt.largestShown)))),
            removal: .opacity.animation(Motion.leave)))
    }

    private func figures(added: Int, removed: Int, scale: Int) -> some View {
        HStack(spacing: Space.md) {
            DiffBar(added: added, removed: removed, scale: scale)
            DiffPair(added: added, removed: removed)
                .contentTransition(.numericText())
                .frame(width: ReviewMetrics.receiptFiguresWidth, alignment: .trailing)
        }
    }

    // The part of a name the filter matched, marked so the eye lands on it.
    private func highlighted(_ text: String) -> Text {
        var marked = AttributedString(text)
        let query = filter.trimmed
        if !query.isEmpty, let range = marked.range(of: query, options: .caseInsensitive) {
            marked[range].backgroundColor = Theme.accent.opacity(0.2)
            marked[range].foregroundColor = .primary
        }
        return Text(marked)
    }

    // A row leaving clears the focus only if it is still the one it set, since the next
    // row may already have taken it.
    private func hover(_ next: ChangeMap.Focus?, leaving group: String) {
        if let next {
            focus = next
            focusFromMap = false
        } else if focus?.group == group && !focusFromMap {
            focus = nil
        }
    }
}

private extension View {
    func rowFrame(lit: Bool) -> some View {
        padding(.horizontal, Space.sm)
            .frame(height: ControlHeight.md)
            .background(RoundedRectangle(cornerRadius: Radius.inset).fill(Color.primary.opacity(lit ? 0.05 : 0)))
            .motion(Motion.hover, value: lit)
            .contentShape(Rectangle())
    }
}
