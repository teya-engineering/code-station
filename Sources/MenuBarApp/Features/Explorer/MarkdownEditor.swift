import AppKit
import SwiftUI

struct MarkdownEditor: View {
    let documentID: String
    @Binding var source: String
    @Binding var mode: MarkdownEditorMode
    var basePath = ""
    var onLink: (URL) -> Void = { _ in }
    var sourceEditor: AnyView?
    var onOutline: ((Int) -> Void)?
    var editable: Bool
    // A host with its own header shows the mode menu there, and learns through this
    // whether the file can open in Edit.
    var canEdit: Binding<Bool>?
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(MenuPresenter.self) private var menus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editor = NoteEditorController()
    @State private var height: CGFloat = 160
    @State private var writing: MarkdownWritingDocument?
    @State private var outlineLine: Int?

    init(documentID: String, source: Binding<String>, mode: Binding<MarkdownEditorMode>,
         basePath: String = "", onLink: @escaping (URL) -> Void = { _ in },
         sourceEditor: AnyView? = nil, onOutline: ((Int) -> Void)? = nil,
         editable: Bool = true, canEdit: Binding<Bool>? = nil) {
        self.documentID = documentID
        self._source = source
        self._mode = mode
        self.basePath = basePath
        self.onLink = onLink
        self.sourceEditor = sourceEditor
        self.onOutline = onOutline
        self.editable = editable
        self.canEdit = canEdit
        self._writing = State(initialValue: MarkdownWritingDocument(source.wrappedValue))
    }

    private var activeMode: MarkdownEditorMode { mode == .edit && writing == nil ? .source : mode }

    var body: some View {
        VStack(spacing: 0) {
            if canEdit == nil || activeMode == .edit {
                toolbar.transition(reduceMotion ? AnyTransition.opacity.animation(Motion.reveal) : .fold)
            }
            if mode != .preview && writing == nil {
                HStack(spacing: 8) {
                    Image(systemName: "curlybraces")
                    Text("Edit is off for this file. It uses Windows line endings, which Edit would change. Change it in Source.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    page
                        .id(documentID + activeMode.rawValue)
                        .transition(.headerPage(reduceMotion: reduceMotion))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if geometry.size.width >= 850 {
                        outline.frame(width: 170)
                    }
                }
                .motion(Motion.reveal, value: activeMode)
                .motion(Motion.reveal, value: documentID)
            }
        }
        .background(Theme.card)
        .motion(Motion.reveal, value: activeMode == .edit)
        .onChange(of: writing == nil, initial: true) { _, missing in canEdit?.wrappedValue = !missing }
        .onAppear { if mode == .edit && writing == nil { mode = .source } }
        .onChange(of: documentID) { _, _ in
            writing = MarkdownWritingDocument(source); outlineLine = nil
            if mode == .edit && writing == nil { mode = .source }
        }
        .onChange(of: source) { _, _ in
            if writing?.source != source { writing = MarkdownWritingDocument(source) }
            if mode == .edit && writing == nil { mode = .source }
        }
        .onChange(of: mode) { _, newMode in
            menus.dismiss()
            if newMode == .edit {
                writing = MarkdownWritingDocument(source)
                if writing == nil { mode = .source }
            }
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { formatting; Spacer(minLength: 8); if canEdit == nil { modes } }
            VStack(alignment: .leading, spacing: 4) {
                if canEdit == nil { HStack { Spacer(); modes } }
                formatting
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var modes: some View {
        MarkdownModeMenu(mode: $mode, canEdit: writing != nil).disabled(!editable)
    }

    private var formatting: some View {
        HStack(spacing: 3) {
            ActionButton(title: editor.block.title, tone: .outlined, height: 28, size: 10, disclosure: true)
                .appMenu {
                    NoteDocument.Block.allCases.filter { $0 != .literal }.map { block in
                        .item(block.title, checked: editor.block == block) { editor.setBlock(block) }
                    }
                }.accessibilityLabel("Text style")
            tool("bold", "Bold", selected: editor.bold) { editor.toggleTrait(.boldFontMask) }
            tool("italic", "Italic", selected: editor.italic) { editor.toggleTrait(.italicFontMask) }
            tool("list.bullet", "Bulleted list", selected: editor.block == .bullet) { editor.setBlock(.bullet) }
            tool("checklist", "Checklist", selected: editor.block == .checklist) { editor.setBlock(.checklist) }
            tool("link", "Insert link", action: addLink)
            tool("chevron.left.forwardslash.chevron.right", "Code block", selected: editor.block == .code) { editor.setBlock(.code) }
        }
        .opacity(activeMode == .edit ? 1 : 0)
        .allowsHitTesting(activeMode == .edit)
        .disabled(activeMode != .edit || !editable)
        .accessibilityHidden(activeMode != .edit)
        .motion(activeMode == .edit ? Motion.reveal : Motion.leave, value: activeMode)
    }

    private func tool(_ icon: String, _ label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        GlyphButton(icon: icon, side: 28, active: selected, action: action)
            .accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : []).appTooltip(label)
    }

    // A path to another file is resolved beside this document and handed to the host,
    // which knows where to show it. Anchor-only links have nowhere to go.
    private func openLink(_ url: URL) {
        guard url.scheme == nil else {
            NSWorkspace.shared.open(url)
            onLink(url)
            return
        }
        let path = url.path(percentEncoded: false)
        guard !basePath.isEmpty, !path.isEmpty else { return }
        onLink(URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: basePath, isDirectory: true)).standardizedFileURL)
    }

    @ViewBuilder private var page: some View {
        switch activeMode {
        case .edit:
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("Project document · In this working tree", systemImage: "doc.text")
                        .font(.system(size: 11)).foregroundStyle(Theme.accent)
                    if let writing {
                        NoteTextEditor(document: writing.document, controller: editor, editable: editable,
                                       onChange: { edited in
                                           let current = writing.source == source ? writing : MarkdownWritingDocument(source)
                                           source = (current ?? writing).markdown(afterEditing: edited)
                                           self.writing = MarkdownWritingDocument(source: source, document: edited)
                                       }, onFiles: { _ in unsupportedPaste() },
                                       onImage: { _ in unsupportedPaste() },
                                       onLink: openLink, height: $height)
                            .frame(minHeight: height)
                            .accessibilityLabel("Markdown document")
                    }
                }
                .padding(32).frame(maxWidth: 820).frame(maxWidth: .infinity, alignment: .center)
            }.background(Theme.card)
        case .source:
            if let sourceEditor { sourceEditor }
            else {
                CodeEditorView(documentID: documentID, text: $source, language: CodeLanguage(path: "note.md"),
                               matches: [], currentMatch: nil, revealLine: outlineLine)
            }
        case .preview:
            ScrollView {
                Group {
                    if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("This document is empty. Switch to \(writing == nil ? "Source" : "Edit") to start writing.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        MarkdownDocumentView(text: source, basePath: basePath, textScale: 1)
                            .environment(\.htmlPreviewLinkOpened, HTMLPreviewLinkOpenedAction(perform: onLink))
                    }
                }
                .padding(32).frame(maxWidth: 820).frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityLabel("Markdown preview, read only")
        }
    }

    private var outline: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On this page").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(MarkdownHeading.read(source)) { heading in
                        Button { showHeading(heading) } label: {
                            Text(heading.title).font(.system(size: 11)).foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(7).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).hoverFill(cornerRadius: 5)
                        .accessibilityHint(activeMode == .edit ? "Jump to heading" : "Show heading in Markdown source")
                    }
                }
            }
        }.padding(18).overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1) }
    }

    private func showHeading(_ heading: MarkdownHeading) {
        if activeMode == .edit, let view = editor.view,
           let title = MarkdownWritingDocument("# " + heading.title)?.document.text {
            let range = (view.string as NSString).range(of: title)
            if range.location != NSNotFound {
                editor.focus(); view.setSelectedRange(range); view.scrollRangeToVisible(range)
                return
            }
        }
        outlineLine = heading.line
        onOutline?(heading.line)
        mode = .source
    }

    private func unsupportedPaste() {
        dialogs.show(.notice("Paste a Markdown link in Source", message: "Images and files are not embedded by the Markdown editor. Add a link to a file in your project using Source mode."))
    }

    private func addLink() {
        var dialog = Dialog(title: "Add a link", content: AnyView(NoteLinkForm(insert: { url in
            dialogs.dismiss(); editor.insertLink(url)
        }, close: dialogs.dismiss, restoreFocus: dialogs.restoreFocus)), actions: [])
        dialog.isModal = true; dialog.framesItself = true
        dialogs.show(dialog)
    }
}

struct MarkdownModeMenu: View {
    @Binding var mode: MarkdownEditorMode
    let canEdit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let active = mode == .edit && !canEdit ? .source : mode
        ActionButton(title: active.rawValue, tone: .outlined, height: 30, size: 12,
                     icon: icon(active), disclosure: true)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .appMenu(showsFocusRing: true) {
                MarkdownEditorMode.allCases.map { item in
                    .item(item.rawValue, icon: icon(item), checked: active == item,
                          subtitle: description(item), disabled: item == .edit && !canEdit) { mode = item }
                }
            }
            .accessibilityLabel("Markdown mode: \(active.rawValue)")
            .accessibilityIdentifier("markdown.modes")
            .appTooltip("Markdown mode")
            .motion(Motion.control, value: active)
            .fixedSize()
    }

    private func icon(_ mode: MarkdownEditorMode) -> String {
        switch mode {
        case .edit: "pencil"
        case .source: "chevron.left.forwardslash.chevron.right"
        case .preview: "eye"
        }
    }

    private func description(_ mode: MarkdownEditorMode) -> String {
        switch mode {
        case .edit: canEdit ? "Formatted writing" : "Windows line endings: use Source"
        case .source: "Markdown syntax"
        case .preview: "Read-only document"
        }
    }
}
