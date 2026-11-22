import AppKit
import SwiftUI

extension ExplorerView {
    func detail(navigatorVisible: Bool) -> some View {
        GeometryReader { geometry in
            let inlineDetails = ExplorerSplitLayout.showsInlineDetails(availableWidth: geometry.size.width)
            let editorWidth = max(0, geometry.size.width
                - (detailsPresented && editor.selected != nil && inlineDetails ? ExplorerSplitLayout.detailsWidth : 0))
            let compact = editorWidth < 530
            let inset: CGFloat = compact ? 16 : 20
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    editorTabs(navigatorVisible: navigatorVisible)
                    if let node = editor.selected {
                        breadcrumbs(node, inset: inset)
                        let header = compact
                            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: Space.xxs))
                            : AnyLayout(HStackLayout(spacing: Space.xl))
                        header {
                            fileTitle(node, compact: compact)
                            fileActions(node, compact: compact)
                        }
                        .padding(.horizontal, inset)
                        .padding(.vertical, node.supportsMarkdownPreview ? 10 : compact ? 5 : 4)
                        .frame(minWidth: 0, maxWidth: .infinity,
                               minHeight: node.supportsMarkdownPreview ? (compact ? 80 : 52) : (compact ? 64 : 36),
                               alignment: .leading)
                        if editor.find.presented {
                            findBar.transition(reduceMotion ? AnyTransition.opacity.animation(Motion.reveal) : .fold)
                        }
                        if let error = editor.saveErrors[node.path] {
                            EditorSaveError(message: error, retry: { save(node) }, export: {
                                exportMarkdown(editor.draft, name: node.name, dialogs: dialogs, notify: { showNote($0) })
                            }).transition(.fadeIn)
                        }
                        // Keyed on what kind of body is showing rather than on the file, so
                        // moving between two text files keeps the same editor.
                        fileBody(node)
                            .id(node.supportsMarkdownPreview ? node.path : bodyKind(node))
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .clipped()
                            .transition(.headerPage(reduceMotion: reduceMotion))
                        if editor.isEditable { editStatus(node, width: editorWidth, inset: inset) }
                    } else {
                        PaneMessage(icon: "sidebar.left", title: "Pick a file",
                                    detail: "Choose one from the list, or press Shift twice to find it.")
                    }
                }
                // Source lines and long names must not set the minimum width of the header and footer.
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(width: editorWidth, alignment: .leading)
                if detailsPresented, let node = editor.selected, inlineDetails {
                    fileDetails(node).frame(width: ExplorerSplitLayout.detailsWidth)
                        .transition(.popover(reduceMotion: reduceMotion))
                }
            }
            .overlay(alignment: .trailing) {
                let overlaid = detailsPresented && editor.selected != nil && !inlineDetails
                ZStack(alignment: .trailing) {
                    if overlaid {
                        Color.black.opacity(0.12).onTapGesture { detailsPresented = false }
                            .transition(scrim)
                    }
                    if overlaid, let node = editor.selected {
                        fileDetails(node).frame(width: min(ExplorerSplitLayout.detailsWidth, geometry.size.width))
                            .shadow(color: .black.opacity(0.08), radius: 12, x: -4)
                            .transition(.popover(reduceMotion: reduceMotion))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .background(Theme.card)
        .motion(Motion.reveal, value: editor.selected?.path)
    }

    private func editorTabs(navigatorVisible: Bool) -> some View {
        HStack(spacing: Space.xs) {
            ExplorerIcon(symbol: "sidebar.left", label: "Toggle file navigator") {
                focusEditor = navigatorVisible
                narrowNavigator = !navigatorVisible
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: Space.xxs) {
                        ForEach(editor.documents.tabs) { node in
                            HStack(spacing: Space.xs) {
                                Button { requestSelect(node) } label: {
                                    HStack(spacing: Space.sm) {
                                        Image(systemName: icon(node)).foregroundStyle(Theme.accent)
                                        Text(node.name).lineLimit(1).truncationMode(.middle)
                                        if editor.hasUnsavedEdit(node) {
                                            Text("●").foregroundStyle(Theme.attention).accessibilityLabel("Unsaved edits")
                                                .transition(markLands)
                                        } else if isPinned(node) {
                                            Image(systemName: "pin").foregroundStyle(.secondary).accessibilityLabel("Pinned")
                                                .transition(markLands)
                                        }
                                    }
                                    .font(Typography.caption.weight(node.path == editor.selected?.path ? .semibold : .regular))
                                    .padding(.leading, Space.md).frame(height: 40).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(node.path == editor.selected?.path ? .isSelected : [])
                                ExplorerIcon(symbol: "xmark", label: "Close \(node.name)") { closeTab(node) }
                            }
                            .frame(maxWidth: 230)
                            .background(node.path == editor.selected?.path ? Theme.card : .clear)
                            .hoverFill(cornerRadius: 0)
                            .overlay(alignment: .bottom) {
                                if node.path == editor.selected?.path {
                                    Rectangle().fill(Theme.accent).frame(height: 2)
                                        .matchedGeometryEffect(id: "underline", in: tabUnderline)
                                }
                            }
                            .appTooltip(relativePath(node))
                            .id(node.path)
                            .transition(.asymmetric(insertion: .opacity.animation(Motion.reveal), removal: .opacity))
                        }
                    }
                    .motion(Motion.draw, value: editor.selected?.path)
                }.scrollIndicators(.hidden)
                .onChange(of: editor.selected?.path) { _, path in if let path { proxy.scrollTo(path) } }
            }
            ExplorerIcon(symbol: focusEditor ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         label: focusEditor ? "Exit focus mode" : "Focus editor", selected: focusEditor) {
                focusEditor.toggle()
                narrowNavigator = false
            }
        }
        .padding(.horizontal, Space.sm).frame(height: 42)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func breadcrumbs(_ node: FileNode, inset: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.sm) {
                let parts = relativePath(node).split(separator: "/").map(String.init)
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).accessibilityHidden(true) }
                    Text(part).foregroundStyle(index == parts.count - 1 ? Color.primary : .secondary)
                }
                if let target = node.linkDestination { Text("→ \(target)").foregroundStyle(.secondary) }
            }
            .font(Typography.caption).padding(.horizontal, inset).frame(height: 36)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .combine)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func fileTitle(_ node: FileNode, compact: Bool) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon(node)).foregroundStyle(Theme.accent).accessibilityHidden(true)
            HStack(spacing: Space.md) {
                Text(node.name)
                    .font(.system(size: compact ? 14 : 15, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel(node.name)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("explorer.fileTitle")
                    .appTooltip(node.name)
                if node.supportsMarkdownPreview {
                    if editor.dirty {
                        Circle().fill(Theme.attention).frame(width: 6, height: 6)
                            .accessibilityLabel("Unsaved changes")
                            .appTooltip("Unsaved changes")
                            .transition(.opacity)
                    }
                    if isPinned(node) {
                        Image(systemName: "pin.fill").font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned").transition(.opacity)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .motion(Motion.control, value: editor.dirty)
            .motion(Motion.control, value: isPinned(node))
            if let status = git.statuses[node.path] {
                ExplorerStatusMark(status: status, spelledOut: !compact)
                    .fixedSize()
                    .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.inset))
            }
            // A narrow header keeps the mode beside the title and the file actions below it.
            if compact { markdownModes(node) }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: compact ? 24 : nil, alignment: .leading)
    }

    private func fileActions(_ node: FileNode, compact: Bool) -> some View {
        HStack(spacing: compact ? 2 : 5) {
            if !compact { markdownModes(node) }
            if editor.isEditable {
                if node.supportsMarkdownPreview { markdownSave(node) }
                else { saveButtons(node) }
            }
            if node.supportsMarkdownPreview {
                Rectangle().fill(Theme.border).frame(width: 1, height: 20)
                    .padding(.horizontal, compact ? 5 : 8).accessibilityHidden(true)
            }
            ExplorerIcon(symbol: "magnifyingglass", label: keyBindings.tooltip("Find in file", for: .findInFile), action: showFind)
                .disabled(!canFind)
            if !node.supportsMarkdownPreview {
                if !node.isDirectory {
                    ExplorerIcon(symbol: isPinned(node) ? "pin.fill" : "pin", label: isPinned(node) ? "Unpin file" : "Pin file",
                                 selected: isPinned(node)) { togglePin(node) }
                }
                ExplorerIcon(symbol: "info.circle", label: "File details", selected: detailsPresented) { detailsPresented.toggle() }
            }
            ExplorerIcon(symbol: "ellipsis", label: "File actions")
                .appMenu(showsFocusRing: true) {
                    var items: [MenuEntry] = []
                    if node.supportsMarkdownPreview {
                        items += [
                            .item(isPinned(node) ? "Unpin file" : "Pin file", icon: "pin", checked: isPinned(node)) { togglePin(node) },
                            .item("File details", icon: "info.circle", checked: detailsPresented) { detailsPresented.toggle() },
                            .separator,
                            .item("Revert changes", icon: "arrow.uturn.backward", disabled: !editor.dirty || editor.saving) { revert() },
                            .separator,
                            .item("Copy path", icon: "doc.on.doc") { copyPath(node) },
                            .item("Export Markdown copy", icon: "square.and.arrow.up", disabled: !editor.isEditable) {
                                exportMarkdown(editor.draft, name: node.name, dialogs: dialogs, notify: { showNote($0) })
                            }
                        ]
                    } else {
                        items.append(.item("Copy path") { copyPath(node) })
                    }
                    return items + [.item("Open externally") { openExternally(node) },
                                    .item("Reveal in Finder") { revealInFinder(node) }]
                }
        }.fixedSize()
    }

    @ViewBuilder private func markdownModes(_ node: FileNode) -> some View {
        switch editor.preview {
        case .text, .empty:
            if node.supportsMarkdownPreview {
                MarkdownModeMenu(mode: $editor.markdownMode, canEdit: markdownCanEdit)
                    .padding(.trailing, Space.sm).transition(.fadeIn)
            }
        default: EmptyView()
        }
    }

    private var editStatusMessage: String {
        if editor.saving { return "Saving changes…" }
        if editor.dirty { return "Your edits are kept here until you save." }
        if editor.fileWasSaved { return "Saved. Your file is up to date." }
        return "Changes are written only when you save."
    }

    private func editStatus(_ node: FileNode, width: CGFloat, inset: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Image(systemName: editor.dirty ? "info.circle" : "checkmark.circle").accessibilityHidden(true)
                .contentTransition(.symbolEffect(.replace))
            Text(editStatusMessage)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .contentTransition(.interpolate)
                .accessibilityIdentifier("explorer.saveMessage")
                .onChange(of: editStatusMessage) { _, message in
                    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                         userInfo: [.announcement: message,
                                                    .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            HStack(spacing: Space.lg) {
                if node.supportsMarkdownPreview && width >= 530 {
                    Text("\(editor.draft.split(whereSeparator: \.isWhitespace).count) words")
                        .contentTransition(.numericText())
                }
                if width >= 530, !node.kind.isEmpty {
                    Text(node.kind.uppercased()).foregroundStyle(Theme.secondaryText)
                }
                if width >= 650 { Text("UTF-8").foregroundStyle(Theme.secondaryText) }
                if editor.saving { LoopSpinner(size: 10).transition(.fadeIn) }
                Text(node.supportsMarkdownPreview && editor.markdownMode == .preview ? "Read only" : saveKeys?.label ?? "")
                    .font(Font.mono(Typography.Size.micro))
                    .accessibilityLabel(editor.markdownMode == .preview ? "Read only preview"
                                        : saveKeys.map { "Save, \($0.spokenLabel)" } ?? "Save")
            }
            .font(Font.system(size: Typography.Size.micro)).fixedSize()
        }
        .motion(Motion.reveal, value: editStatusMessage)
        .font(Typography.caption).foregroundStyle(editor.dirty ? Theme.attention : Theme.accent)
        .padding(.horizontal, inset).padding(.vertical, Space.lg)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(Theme.statusBand)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func fileDetails(_ node: FileNode) -> some View {
        let current = tree.children[node.url.deletingLastPathComponent().path]?.first { $0.path == node.path } ?? node
        return ExplorerFileDetails(node: current, path: relativePath(node), status: git.statuses[node.path],
                                   text: editor.isEditable ? editor.draft : nil,
                                   copyPath: { copyPath(node) },
                                   openExternally: { openExternally(node) },
                                   revealInFinder: { revealInFinder(node) },
                                   close: { detailsPresented = false })
    }

    func closeTab(_ node: FileNode) {
        let close = {
            editor.closeTab(node, motion: reduceMotion ? nil : Motion.leave)
            rememberPlace()
        }
        if editor.hasUnsavedEdit(node) {
            var dialog = Dialog.confirm("Close unsaved file?", message: "Edits to \(node.name) have not been saved.",
                                        action: "Discard and close", cancel: "Keep editing", handler: close)
            dialog.isModal = true
            dialogs.show(dialog)
        } else { close() }
    }

    private func noteLinkOpened(_ url: URL) {
        if url.isFileURL { openLinkedFile(url); return }
        showNote(url.scheme == "mailto"
                 ? "Opened your mail app"
                 : "Opened \(url.host() ?? "the link") in your browser")
    }

    // A linked file in this project opens here. A folder, or a file outside the project,
    // has no place in the tree, so Finder shows it instead.
    private func openLinkedFile(_ url: URL) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            showNote("Could not find \(url.lastPathComponent)", icon: "questionmark.folder")
            return
        }
        guard !isFolder.boolValue, url.path.pathRelative(to: root) != nil else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            showNote("Showed \(url.lastPathComponent) in Finder")
            return
        }
        Task {
            let siblings = await FileTree.children(of: url.deletingLastPathComponent(), includeHidden: true)
            if let node = siblings.first(where: { $0.url.standardizedFileURL.path == url.path }) {
                revealAndSelect(node)
            }
        }
    }

    private func bodyKind(_ node: FileNode) -> String {
        switch editor.preview {
        case .text, .empty: "text"
        case .image: "image"
        case .binary: "binary"
        case .tooLarge: "too large"
        case .unreadable: "unreadable"
        case nil: "reading"
        }
    }

    @ViewBuilder private func fileBody(_ node: FileNode) -> some View {
        switch editor.preview {
        case .text, .empty:
            let source = CodeEditorView(documentID: node.path,
                                        text: $editor.draft,
                                        language: editor.language,
                                        matches: editor.find.presented ? editor.find.result.matches : editor.find.revealedMatches,
                                        currentMatch: editor.find.presented ? editor.find.currentMatch : nil,
                                        findQuery: editor.find.query,
                                        revealLine: editor.lineToReveal,
                                        onFind: showFind)
            if node.supportsMarkdownPreview {
                MarkdownEditor(documentID: node.path, source: $editor.draft, mode: $editor.markdownMode,
                               basePath: node.url.deletingLastPathComponent().path, onLink: noteLinkOpened,
                               sourceEditor: AnyView(source),
                               onOutline: { editor.lineToReveal = $0 }, canEdit: $markdownCanEdit)
            } else {
                source
            }
        case .image(let data):
            if let image = NSImage(data: data) {
                VStack(spacing: Space.md) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                    Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(node.size.formatted(.byteCount(style: .file)))")
                        .font(Typography.data)
                        .foregroundStyle(.secondary)
                }
                .padding(Space.xxl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PaneMessage(icon: "photo", title: "Cannot draw this image",
                            detail: node.size.formatted(.byteCount(style: .file)))
            }
        case .binary(let size):
            PaneMessage(icon: "doc.zipper", title: "Binary file",
                        detail: "\(size.formatted(.byteCount(style: .file))) of data this app cannot show as text.")
        case .tooLarge(let size):
            PaneMessage(icon: "doc.badge.ellipsis", title: "Too big to open",
                        detail: "\(size.formatted(.byteCount(style: .file))). Open it in an editor instead.")
        case .unreadable(let reason):
            VStack(spacing: Space.lg) {
                PaneMessage(icon: "exclamationmark.triangle",
                            title: node.isLink ? "Could not follow this link" : "Could not read this file", detail: reason)
                ActionButton(title: "Try again", tone: .outlined, height: ControlHeight.md, size: Typography.Size.detail) { editor.select(node) }
            }.padding(Space.xxl)
        case nil:
            if node.isDirectory {
                PaneMessage(icon: "folder", title: "Folder selected",
                            detail: "Use the left and right arrow keys to close and open folders.")
            } else {
                ChangesProgressLabel(title: "Reading file…").foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var saveKeys: KeyCombo? { keyBindings.keys(for: .saveFile) }

    private func saveButtons(_ node: FileNode) -> some View {
        HStack(spacing: Space.md) {
            ActionButton(title: "Revert", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.detail) { revert() }
                .disabled(!editor.dirty || editor.saving)
            ActionButton(title: "Save", tone: .green, height: ControlHeight.sm, size: Typography.Size.detail,
                         keyboardShortcut: saveKeys?.shortcut) {
                save(node)
            }
            .disabled(!editor.dirty)
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private func markdownSave(_ node: FileNode) -> some View {
        ZStack {
            if editor.dirty || editor.saving {
                ActionButton(title: editor.saving ? "Saving…" : "Save", tone: .green, height: ControlHeight.md, size: Typography.Size.detail,
                             shortcut: editor.saving ? nil : saveKeys?.compactLabel,
                             keyboardShortcut: saveKeys?.shortcut) { save(node) }
                    .disabled(!editor.dirty)
                    .accessibilityLabel(editor.saving ? "Saving changes" : "Save changes")
                    .appTooltip(keyBindings.tooltip("Save changes", for: .saveFile))
                    .transition(.opacity)
            } else {
                Label("Saved", systemImage: "checkmark")
                    .font(Typography.detail).foregroundStyle(Theme.accent)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("explorer.saved")
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 82, minHeight: 30)
        .motion(Motion.control, value: editor.dirty || editor.saving)
        .motion(Motion.control, value: editor.saving)
    }

    private func relativePath(_ node: FileNode) -> String {
        node.path.pathRelative(to: root) ?? node.path
    }

    private func revert() {
        let discard = {
            editor.revert()
            rememberPlace()
        }
        if let selected = editor.selected, selected.supportsMarkdownPreview {
            var dialog = Dialog.confirm("Revert your changes?",
                                        message: "Unsaved edits to \(selected.name) will be replaced with the last saved version.",
                                        action: "Revert changes", cancel: "Keep editing", handler: discard)
            dialog.isModal = true
            dialogs.show(dialog)
        } else {
            confirmDiscard(then: discard)
        }
    }

    private func confirmDiscard(then discard: @escaping () -> Void) {
        dialogs.show(.confirm("Discard changes?",
                              message: "Edits to \(editor.selected?.name ?? "this file") have not been saved.",
                              action: "Discard", cancel: "Keep editing", handler: discard))
    }

    private func save(_ node: FileNode) {
        editor.save(node, dialogs: dialogs, memory: memory) {
            rememberPlace()
            await reopenFolders()
        }
    }
}
