import AppKit
import SwiftUI

struct MarkdownEditor: View {
    let documentID: String
    @Binding var source: String
    @Binding var mode: MarkdownEditorMode
    var basePath = ""
    var personal = false
    var onLink: (URL) -> Void = { _ in }
    var sourceEditor: AnyView?
    var onOutline: ((Int) -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onImage: ((Data) -> Void)?
    var editable: Bool
    // A host with its own header shows the mode pills there, and learns through this
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
         basePath: String = "", personal: Bool = false, onLink: @escaping (URL) -> Void = { _ in },
         sourceEditor: AnyView? = nil, onOutline: ((Int) -> Void)? = nil,
         onFiles: (([URL]) -> Void)? = nil, onImage: ((Data) -> Void)? = nil,
         editor: NoteEditorController? = nil, editable: Bool = true, canEdit: Binding<Bool>? = nil) {
        self.documentID = documentID
        self._source = source
        self._mode = mode
        self.basePath = basePath
        self.personal = personal
        self.onLink = onLink
        self.sourceEditor = sourceEditor
        self.onOutline = onOutline
        self.onFiles = onFiles
        self.onImage = onImage
        self.editable = editable
        self.canEdit = canEdit
        self._editor = State(initialValue: editor ?? NoteEditorController())
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
                    Text("Edit is off for this file. It uses Markdown that Edit cannot show, such as tables, images or HTML. Change it in Source.")
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
        MarkdownModePicker(mode: $mode, canEdit: writing != nil).disabled(!editable)
    }

    private var formatting: some View {
        HStack(spacing: 3) {
            ActionButton(title: editor.block.title, tone: .outlined, height: 28, size: 10, disclosure: true)
                .appMenu {
                    NoteDocument.Block.allCases.map { block in
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

    @ViewBuilder private var page: some View {
        switch activeMode {
        case .edit:
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label(personal ? "Personal note · Only on this Mac" : "Project document · In this working tree",
                          systemImage: personal ? "lock" : "doc.text")
                        .font(.system(size: 11)).foregroundStyle(Theme.accent)
                    if let writing {
                        NoteTextEditor(document: writing.document, controller: editor, editable: editable,
                                       onChange: { edited in
                                           let current = writing.source == source ? writing : MarkdownWritingDocument(source)
                                           source = (current ?? writing).markdown(afterEditing: edited)
                                           self.writing = MarkdownWritingDocument(source: source, document: edited)
                                       }, onFiles: onFiles ?? { _ in unsupportedPaste() },
                                       onImage: onImage ?? { _ in unsupportedPaste() },
                                       onLink: { NSWorkspace.shared.open($0); onLink($0) }, height: $height)
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
                MarkdownDocumentView(text: source, basePath: basePath, textScale: 1)
                    .environment(\.htmlPreviewLinkOpened, HTMLPreviewLinkOpenedAction(perform: onLink))
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
            Label(personal ? "Personal note" : "Part of your project", systemImage: personal ? "lock" : "doc.text")
                .font(.system(size: 11, weight: .medium))
            Text(personal ? "Saves automatically on this Mac." : "Edits stay here until you save the file.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
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

struct MarkdownModePicker: View {
    @Binding var mode: MarkdownEditorMode
    let canEdit: Bool

    var body: some View {
        let active = mode == .edit && !canEdit ? .source : mode
        HStack(spacing: 3) {
            ForEach(MarkdownEditorMode.allCases, id: \.self) { item in
                ChoicePill(title: item.rawValue, selected: active == item,
                           enabled: item != .edit || canEdit) { mode = item }
                    .opacity(item == .edit && !canEdit ? 0.45 : 1)
                    .motion(Motion.control, value: canEdit)
                    .accessibilityLabel("\(item.rawValue) Markdown")
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("Editor mode")
            .accessibilityIdentifier("markdown.modes")
            .fixedSize()
    }
}
