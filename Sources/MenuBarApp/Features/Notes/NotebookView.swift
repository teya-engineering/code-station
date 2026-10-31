import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotebookView: View {
    @Environment(NotebookStore.self) private var store
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(Dictation.self) private var dictation: Dictation?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var pinnedOnly = false
    @State private var focused = false
    @State private var reading = false
    @State private var editor = NoteEditorController()
    @State private var take: NoteDictation?
    @State private var closeAfterDictation = false
    @State private var keys = WindowKeyHandler(handlesTyping: true)
    @State private var attachmentError: String?
    @State private var importing = 0
    @State private var note: String?
    @State private var noteTask: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case search, title }
    private var selected: QuickNote? { store.note(store.selectedID) }
    private var matches: [QuickNote] { store.matching(query, pinnedOnly: pinnedOnly) }
    private var activeTake: Bool { take != nil && dictation?.sessionID == take?.noteID && dictation?.phase != .idle }
    private var dictating: Bool { activeTake && take?.noteID == selected?.id }
    private var sheetWidth: CGFloat { min(1080, (NSScreen.main?.visibleFrame.width ?? 1160) - 80) }
    private var sheetHeight: CGFloat { min(860, (NSScreen.main?.visibleFrame.height ?? 980) - 120) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = store.loadError ?? store.saveError {
                HStack {
                    WarningStrip(error, icon: "externaldrive.badge.exclamationmark")
                    if store.loadError == nil { InlineLink(title: "Retry") { _ = store.flush() }.padding(.trailing, 20) }
                }
            }
            HStack(spacing: 0) {
                if !focused {
                    library.frame(width: sheetWidth < 1000 ? 244 : 278)
                        .transition(.asymmetric(insertion: .opacity.animation(Motion.reveal), removal: .opacity.animation(Motion.leave)))
                    Divider().overlay(Theme.hairline)
                }
                editorPane
            }
            .motion(focused ? Motion.leave : Motion.reveal, value: focused)
        }
        .frame(width: sheetWidth)
        .frame(minHeight: min(480, sheetHeight), idealHeight: min(780, sheetHeight), maxHeight: sheetHeight)
        .background(Theme.card)
        .interactiveDismissDisabled(store.saveError != nil || importing > 0 || activeTake)
        .background(WindowKeyAnchor(handler: keys))
        .overlay(alignment: .topTrailing) {
            if let note {
                HeaderNote(icon: "checkmark", text: note)
                    .padding(.top, 96).padding(.trailing, 24)
                    .transition(.popover(reduceMotion: reduceMotion))
            }
        }
        .motion(Motion.reveal, value: note)
        .onAppear {
            if selected == nil, let first = matches.first { store.select(first.id) }
            keys.start(handleKey)
        }
        .onDisappear {
            if let take { dictation?.leave(take.noteID) }
            keys.stop(); _ = store.flush(); noteTask?.cancel()
        }
        .onChange(of: store.selectedID) { old, _ in
            if let old { dictation?.leave(old) }
        }
        .onChange(of: reading) { _, reading in
            if reading, let take { dictation?.leave(take.noteID) }
        }
        .onChange(of: dialogs.current?.id) { _, dialog in
            if dialog != nil, let take { dictation?.leave(take.noteID) }
        }
        .onChange(of: dictation?.phase) { _, phase in
            if phase == .idle, closeAfterDictation { closeAfterDictation = false; close() }
        }
        .onChange(of: store.saveError) { _, error in
            if error != nil { announce("Could not save notes. Your edits are still here. Retry or export a copy.") }
        }
        .onChange(of: store.saving) { old, saving in
            if old && !saving && store.saveError == nil { announce("Notes saved on this Mac") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            _ = store.flush()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "note.text")
                .font(.system(size: 23)).foregroundStyle(Theme.accent)
                .frame(width: 44, height: 48)
                .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Quick notes").font(.serif(32, .medium))
                Text("Your thoughts, a little closer.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            ActionButton(title: "New note", tone: .green, height: 36, size: 12, icon: "plus", shortcut: "⌘N", action: create)
                .disabled(store.loadError != nil)
            GlyphButton(icon: "xmark", side: 32, action: close)
                .accessibilityLabel("Close quick notes")
        }
        .padding(.horizontal, 26).padding(.vertical, 20)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
    }

    private var library: some View {
        VStack(spacing: 0) {
            VStack(spacing: 13) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search notes…", text: $query)
                        .textFieldStyle(.plain).focused($focus, equals: .search)
                        .accessibilityLabel("Search notes")
                    if query.isEmpty { Text("⌘F").foregroundStyle(.tertiary) }
                    else {
                        GlyphButton(icon: "xmark", side: 22) { query = "" }
                            .accessibilityLabel("Clear search")
                    }
                }
                .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 36)
                .fieldSurface(cornerRadius: 8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(focus == .search ? Theme.accent : .clear, lineWidth: 2))
                HStack(spacing: 5) {
                    ChoicePill(title: "All notes  \(store.notes.count)", selected: !pinnedOnly) { pinnedOnly = false }
                        .contentTransition(.numericText()).motion(Motion.pop, value: store.notes.count)
                    ChoicePill(title: "Pinned", selected: pinnedOnly) { pinnedOnly = true }
                    Spacer(minLength: 0)
                }
            }
            .padding(18)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if matches.isEmpty {
                        VStack(spacing: 14) {
                            PaneMessage(icon: query.isEmpty ? "note.text" : "magnifyingglass",
                                        title: !query.isEmpty ? "No notes found" : pinnedOnly ? "No pinned notes yet" : "A place for your thoughts",
                                        detail: !query.isEmpty ? "Try a different word or clear your search."
                                        : pinnedOnly ? "Pin a note to keep it close." : "Create a note to get started.")
                            if !query.isEmpty { ActionButton(title: "Clear search", tone: .outlined) { query = "" } }
                        }
                        .padding(.vertical, 24).transition(.fadeIn)
                    }
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                        let group = group(item)
                        if index == 0 || group != self.group(matches[index - 1]) {
                            Text(group).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 5)
                        }
                        NotebookRow(note: item, selected: selected?.id == item.id) {
                            store.select(item.id)
                            focus = nil
                        }
                        .transition(.fadeIn)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 16)
            }
            Label("Private. Saved on this Mac.", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
        }
        .background(Theme.sidebar)
        .accessibilityElement(children: .contain).accessibilityLabel("Note library")
    }

    private func group(_ note: QuickNote) -> String {
        if note.pinned { return "Pinned" }
        if Calendar.current.isDateInToday(note.editedAt) { return "Today" }
        if Calendar.current.isDateInYesterday(note.editedAt) { return "Yesterday" }
        return note.editedAt.formatted(date: .abbreviated, time: .omitted)
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            if let selected {
                editorTop(selected)
                if !reading {
                    toolbar
                        .transition(.asymmetric(insertion: .opacity.animation(Motion.reveal), removal: .opacity.animation(Motion.leave)))
                }
                if let dictation, let take, take.noteID == selected.id {
                    DictationFeedback(dictation: dictation, sessionID: selected.id, draft: take.binding,
                                      notice: dictation.notice(for: selected.id))
                        .padding(.horizontal, 24)
                        .transition(.fadeIn)
                }
                if let attachmentError {
                    HStack {
                        WarningStrip(attachmentError, icon: "paperclip")
                        GlyphButton(icon: "xmark", side: 24) { self.attachmentError = nil }
                            .accessibilityLabel("Dismiss attachment error").padding(.trailing, 12)
                    }
                }
                NotebookPage(note: selected, editor: editor, reading: reading, dictating: dictating, focus: $focus,
                             titleField: .title,
                             updateTitle: { title in store.update(selected.id) { $0.title = title } },
                             updateBody: { body in
                                 store.update(selected.id) { $0.body = body }
                                 dictation?.draftEdited(selected.id, text: body.text)
                                 if !activeTake, dictation?.notice(for: selected.id) == .thrownAway {
                                     dictation?.sent(selected.id)
                                 }
                             },
                             files: { importFiles($0, into: selected.id) },
                             image: { importImage($0, into: selected.id) },
                             openLink: { NSWorkspace.shared.open($0); showNote("Opened link in your browser") },
                             addFile: { chooseFiles(imagesOnly: false) },
                             preview: preview)
                    .id(selected.id)
                    .transition(.headerPage(reduceMotion: reduceMotion))
                HStack {
                    Text("\(selected.wordCount) words").contentTransition(.numericText())
                    Spacer()
                    InlineLink(title: "Export as Markdown", size: 10.5, icon: "chevron.left.forwardslash.chevron.right") { export(selected) }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 24).frame(height: 38)
                .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
            } else {
                PaneMessage(icon: "note.text", title: "Your notebook", detail: "Create a note, or choose one from the library.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .motion(Motion.reveal, value: selected?.id)
        .motion(reading ? Motion.leave : Motion.reveal, value: reading)
        .motion(Motion.reveal, value: selected.flatMap { dictation?.notice(for: $0.id) })
    }

    private func editorTop(_ selected: QuickNote) -> some View {
        HStack(spacing: 12) {
            Label(importing > 0 ? "Attaching…" : store.saving ? "Saving…" : store.saveError == nil ? "Saved on this Mac" : "Couldn’t save",
                  systemImage: store.saveError == nil ? "checkmark" : "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(store.saveError == nil ? Color.secondary : Theme.deletion)
                .contentTransition(.interpolate)
                .accessibilityLabel(store.saveError == nil ? "Note save status" : "Note save failed")
                .accessibilityValue(store.saving ? "Saving" : store.saveError == nil ? "Saved on this Mac" : "Retry saving or export a copy")
            Spacer()
            GlyphButton(icon: selected.pinned ? "pin.fill" : "pin", side: 30, active: selected.pinned) {
                withAnimation(reduceMotion ? nil : Motion.control) { store.togglePin(selected.id) }
                announce(selected.pinned ? "Note unpinned" : "Note pinned to the top")
            }
            .accessibilityLabel(selected.pinned ? "Unpin note" : "Pin note")
            .accessibilityAddTraits(selected.pinned ? .isSelected : [])
            GlyphButton(icon: focused ? "sidebar.left" : "arrow.up.left.and.arrow.down.right", side: 30, active: focused) { focused.toggle() }
                .accessibilityLabel(focused ? "Show note library" : "Focus on note")
            GlyphButton(icon: "ellipsis", side: 30)
                .appMenu {
                    [.item("Duplicate note", icon: "doc.on.doc") {
                        _ = store.duplicate(selected.id); query = ""; pinnedOnly = false; reading = false
                    }, .item("Export as Markdown", icon: "square.and.arrow.up") { export(selected) },
                     .item(reading ? "Edit note" : "Read without tools", icon: "doc.text") { reading.toggle() }]
                }
                .accessibilityLabel("Note actions")
        }
        .padding(.horizontal, 22).frame(height: 48)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Group {
                ActionButton(title: editor.block.title, tone: .outlined, height: 28, size: 10, disclosure: true)
                    .appMenu {
                        NoteDocument.Block.allCases.map { block in
                            .item(block.title, action: { editor.setBlock(block) })
                        }
                    }
                    .accessibilityLabel("Text style")
                Divider().frame(height: 18).padding(.horizontal, 4)
                tool("bold", "Bold", active: editor.bold) { editor.toggleTrait(.boldFontMask) }
                tool("italic", "Italic", active: editor.italic) { editor.toggleTrait(.italicFontMask) }
                tool("list.bullet", "Bulleted list", active: editor.block == .bullet) { editor.setBlock(.bullet) }
                tool("checklist", "Checklist", active: editor.block == .checklist) { editor.setBlock(.checklist) }
                tool("link", "Insert link", action: link)
                tool("chevron.left.forwardslash.chevron.right", "Code block", active: editor.block == .code) { editor.setBlock(.code) }
                if editor.block == .checklist {
                    Toggle("Checked", isOn: Binding(get: { editor.checked }, set: { _ in editor.toggleChecklist() }))
                        .toggleStyle(.appCheckbox).labelsHidden().accessibilityLabel("Check current checklist item")
                }
                Spacer(minLength: 0)
                tool("photo", "Add image") { chooseFiles(imagesOnly: true) }
                tool("paperclip", "Attach files") { chooseFiles(imagesOnly: false) }
            }
            .disabled(dictating)
            if let dictation, let selected {
                DictationMicButton(live: dictation.isListening(selected.id),
                                   preparing: dictation.isPreparing(selected.id),
                                   blocked: dictation.notice(for: selected.id).isMicrophoneBlocked,
                                   level: dictation.level, startedAt: dictation.startedAt,
                                   download: dictation.notice(for: selected.id).downloadFraction,
                                   action: toggleDictation)
                    .disabled(dictation.phase != .idle && dictation.sessionID != selected.id)
            }
        }
        .padding(.horizontal, 20).frame(height: 44)
        .background(Theme.background.opacity(0.45))
        .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
    }

    private func tool(_ icon: String, _ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        GlyphButton(icon: icon, side: 28, active: active, action: action)
            .accessibilityLabel(label).accessibilityAddTraits(active ? .isSelected : []).appTooltip(label)
    }

    private func create() {
        guard store.create() != nil else { return }
        query = ""; pinnedOnly = false; reading = false; focus = .title
    }

    private func toggleDictation() {
        guard !reading, let dictation, let selected else { return }
        if dictating { dictation.stop(); return }
        guard dictation.phase == .idle else { return }
        focus = nil
        editor.focus()
        let take = NoteDictation(note: selected, store: store, view: editor.view)
        self.take = take
        dictation.toggle(DictationRequest(sessionID: selected.id, draft: take.binding, caret: take.caret,
                                         roots: [], vocabulary: [selected.title] + selected.attachments.map(\.name),
                                         placeCaret: { take.placeCaret($0) }))
    }

    private func close() {
        guard importing == 0 else { showNote("Wait for your attachments to finish copying"); return }
        if activeTake { closeAfterDictation = true; dictation?.stop(); return }
        if store.loadError != nil || store.flush() { dismiss() }
        else {
            dialogs.show(.notice("Your notes could not be saved", message: "Your edits are still in memory. Retry saving, or export a Markdown copy before closing."))
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard dialogs.current == nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty, dictating {
            if event.keyCode == 36 || event.keyCode == 76 { dictation?.stop(); return true }
            if event.keyCode == 53 { dictation?.throwAway(); return true }
        }
        if dictating, flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" { return true }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "d" {
            toggleDictation(); return true
        }
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": focused = false; focus = .search; return true
        case "n": create(); return true
        default: return false
        }
    }

    private func chooseFiles(imagesOnly: Bool) {
        guard let id = selected?.id else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if imagesOnly { panel.allowedContentTypes = [.image] }
        guard let window = WindowKeyMonitor.frontmostWindow else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK { importFiles(panel.urls, into: id) }
        }
    }

    private func importFiles(_ urls: [URL], into id: UUID) {
        importing += 1
        attachmentError = nil
        Task { @MainActor in
            defer { importing -= 1 }
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do { try await store.attach(url, to: id) }
                catch { attachmentError = "Couldn’t attach \(url.lastPathComponent): \(error.localizedDescription)"; announce(attachmentError!) }
            }
        }
    }

    private func importImage(_ data: Data, into id: UUID) {
        importing += 1
        Task { @MainActor in
            defer { importing -= 1 }
            do { try await store.attachImage(data, to: id) }
            catch { attachmentError = "Couldn’t attach image: \(error.localizedDescription)"; announce(attachmentError!) }
        }
    }

    private func link() {
        var dialog = Dialog(title: "Add a link", content: AnyView(NoteLinkForm(insert: { url in
            dialogs.dismiss(); editor.insertLink(url)
        }, close: dialogs.dismiss, restoreFocus: dialogs.restoreFocus)), actions: [])
        dialog.isModal = true
        dialog.framesItself = true
        dialogs.show(dialog)
    }

    private func preview(_ attachment: NoteAttachment, restoreTrigger: @escaping () -> Void) {
        var dialog = Dialog(title: attachment.name,
                            content: AnyView(NoteAttachmentPreview(attachment: attachment, url: store.attachmentURL(attachment),
                                                                   close: dialogs.dismiss, restoreFocus: {
                                dialogs.restoreFocus(); restoreTrigger()
                            })),
                            actions: [], width: 650)
        dialog.isModal = true
        dialog.framesItself = true
        dialogs.show(dialog)
    }

    private func export(_ note: QuickNote) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.displayTitle.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.message = "Exports the note text and formatting. Attachments can be saved separately from their previews."
        guard let window = WindowKeyMonitor.frontmostWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try note.markdown.write(to: url, atomically: true, encoding: .utf8); showNote("Markdown copy exported") }
            catch { dialogs.show(.notice("Couldn’t export note", message: error.localizedDescription)) }
        }
    }

    private func showNote(_ message: String) {
        noteTask?.cancel(); note = message; announce(message)
        noteTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            note = nil
        }
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

private struct NotebookRow: View {
    let note: QuickNote
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                Text(note.displayTitle).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(note.body.text.isEmpty ? "Start writing your first thought…" : note.body.text)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(note.editedAt.formatted(date: .omitted, time: .shortened))
                    Spacer()
                    if !note.attachments.isEmpty { Label("\(note.attachments.count)", systemImage: "paperclip") }
                }
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.accent.opacity(0.22) : .clear))
            .overlay(alignment: .leading) {
                if selected { RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3).padding(.vertical, 15) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain).hoverFill(cornerRadius: 9)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(note.displayTitle + (note.pinned ? ", pinned" : ""))
        .motion(Motion.control, value: selected)
    }
}

private struct NotebookPage<Field: Hashable>: View {
    let note: QuickNote
    let editor: NoteEditorController
    let reading: Bool
    let dictating: Bool
    var focus: FocusState<Field?>.Binding
    let titleField: Field
    let updateTitle: (String) -> Void
    let updateBody: (NoteDocument) -> Void
    let files: ([URL]) -> Void
    let image: (Data) -> Void
    let openLink: (URL) -> Void
    let addFile: () -> Void
    let preview: (NoteAttachment, @escaping () -> Void) -> Void
    @State private var editorHeight: CGFloat = 160
    @State private var targeted = false
    @FocusState private var focusedAttachment: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TextField("Untitled note", text: Binding(get: { note.title }, set: { updateTitle($0) }))
                    .font(.system(size: 30, weight: .semibold)).textFieldStyle(.plain)
                    .focused(focus, equals: titleField).disabled(reading)
                    .onSubmit { editor.focus() }
                    .accessibilityLabel("Note title")
                HStack(spacing: 15) {
                    Text("Edited \(note.editedAt.formatted(date: .abbreviated, time: .shortened))")
                    Label("Only on this Mac", systemImage: "lock")
                }
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                ZStack(alignment: .topLeading) {
                    if note.body.text.isEmpty {
                        Text("Start writing your first thought…").font(.system(size: 14)).foregroundStyle(.tertiary)
                            .padding(.top, 3).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    NoteTextEditor(document: note.body, controller: editor, editable: !reading && !dictating,
                                   onChange: updateBody, onFiles: files, onImage: image, onLink: openLink,
                                   height: $editorHeight)
                        .frame(minHeight: editorHeight)
                }
                if !note.attachments.isEmpty || !reading {
                    HStack(spacing: 8) {
                        Label("Attachments\(note.attachments.isEmpty ? "" : " (\(note.attachments.count))")", systemImage: "paperclip")
                            .contentTransition(.numericText()).motion(Motion.pop, value: note.attachments.count)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        if !reading { InlineLink(title: "Add file", size: 11, action: addFile) }
                    }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), alignment: .top)], alignment: .leading, spacing: 10) {
                        ForEach(note.attachments) { attachment in
                            NoteAttachmentTile(attachment: attachment) {
                                focusedAttachment = nil
                                preview(attachment) { focusedAttachment = attachment.id }
                            }
                                .focused($focusedAttachment, equals: attachment.id)
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(focusedAttachment == attachment.id ? Theme.accent : .clear, lineWidth: 2))
                                .transition(.fadeIn)
                        }
                    }
                    .motion(Motion.reveal, value: note.attachments.map(\.id))
                    if note.attachments.isEmpty && !reading {
                        Text("Drop a file here, or paste an image into your note.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 42).padding(.vertical, 30)
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(targeted ? Theme.accent : .clear, lineWidth: 2))
        .dropDestination(for: URL.self) { urls, _ in
            guard !reading else { return false }; files(urls); return true
        } isTargeted: { targeted = !reading && $0 }
    }
}

private struct NoteLinkForm: View {
    let insert: (String) -> Void
    let close: () -> Void
    let restoreFocus: () -> Void
    @State private var url = ""
    private enum Field: Hashable { case url, insert, cancel }
    @FocusState private var focused: Field?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a link").font(.serif(20, .semibold))
            TextField("https://example.com", text: $url)
                .textFieldStyle(.plain).padding(10).fieldSurface(cornerRadius: 7)
                .focused($focused, equals: .url).accessibilityLabel("Link URL")
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused == .url ? Theme.accent : .clear, lineWidth: 2))
                .onSubmit { if NoteDocument.safeLink(url) != nil { insert(url) } }
            Text("Use an https, http, or mailto link.").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                ActionButton(title: "Cancel", tone: .outlined, keyboardShortcut: .cancelAction, action: close)
                    .focused($focused, equals: .cancel)
                Spacer()
                ActionButton(title: "Insert link", tone: .green) { insert(url) }
                    .disabled(NoteDocument.safeLink(url) == nil).focused($focused, equals: .insert)
            }
        }
        .padding(22).background(Theme.card)
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
