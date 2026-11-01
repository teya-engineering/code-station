import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExplorerNotesShelf: View {
    let scope: String
    let selected: UUID?
    let open: (UUID) -> Void
    let create: () -> Void
    @Environment(NotebookStore.self) private var notebook

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Personal notes", systemImage: "lock").font(.system(size: 11, weight: .semibold))
                Spacer()
                GlyphButton(icon: "plus", side: 26, action: create).accessibilityLabel("New personal note")
                    .appTooltip("New personal note").disabled(notebook.loadError != nil)
            }
            ForEach(Array(notebook.matching().filter { $0.scopeID == scope }.prefix(3))) { note in
                Button { open(note.id) } label: {
                    Label(note.displayTitle, systemImage: "note.text")
                        .font(.system(size: 11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).contentShape(Rectangle())
                }.buttonStyle(.plain).hoverFill(cornerRadius: 6)
                    .background(selected == note.id ? Theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityAddTraits(selected == note.id ? .isSelected : [])
                    .transition(.fadeIn)
            }
            Text("Kept on this Mac, outside your repositories.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ActionButton(title: "Browse personal notes", tone: .outlined, height: 28, size: 10, disclosure: true)
                .appMenu {
                    [.searchable(notebook.matching().map { note in
                        MenuItem(label: note.displayTitle, icon: "note.text", checked: note.id == selected,
                                 subtitle: note.scopeID == scope ? "In this workspace" : "Personal notebook",
                                 handler: { open(note.id) })
                    }, prompt: "Find a personal note", noResults: "No personal notes yet")]
                }
            if let error = notebook.loadError { Text(error).font(.system(size: 10)).foregroundStyle(Theme.deletion) }
        }
        .padding(14).background(Theme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .motion(Motion.reveal, value: notebook.notes.map(\.id))
    }
}

struct ExplorerPersonalNote: View {
    let id: UUID
    let projects: [ChangesRepository]
    let moved: (URL) -> Void
    let close: () -> Void
    let notify: (String) -> Void
    var open: (UUID) -> Void = { _ in }
    @Environment(NotebookStore.self) private var notebook
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(Dictation.self) private var dictation: Dictation?
    @Environment(\.isEnabled) private var isEnabled
    @State private var mode = MarkdownEditorMode.write
    @State private var editor = NoteEditorController()
    @State private var take: NoteDictation?
    @State private var keys = WindowKeyHandler(handlesTyping: true)
    @State private var attachmentError: String?
    @State private var importing = 0
    @State private var targeted = false
    @FocusState private var focusedAttachment: UUID?

    private var dictating: Bool { dictation?.sessionID == id && dictation?.phase != .idle }

    var body: some View {
        if let note = notebook.note(id) {
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack { location; Spacer(); actions(note) }
                    VStack(alignment: .leading) { location; HStack { Spacer(); actions(note) } }
                }.padding(12)
                TextField("Untitled note", text: Binding(get: { note.title }, set: { title in notebook.update(id) { $0.title = title } }))
                    .font(.serif(24, .semibold)).textFieldStyle(.plain).padding(14).fieldSurface(cornerRadius: 8)
                    .padding(.horizontal, 20).padding(.bottom, 10).accessibilityLabel("Personal note title")
                    .disabled(mode == .preview || dictating)
                if let error = notebook.saveError {
                    EditorSaveError(message: error, retry: { _ = notebook.flush() }, export: { export(note) })
                }
                if let dictation, let take {
                    DictationFeedback(dictation: dictation, sessionID: id, draft: take.binding,
                                      notice: dictation.notice(for: id))
                        .padding(.horizontal, 20).transition(.fadeIn)
                }
                if let attachmentError {
                    HStack {
                        WarningStrip(attachmentError, icon: "paperclip")
                        GlyphButton(icon: "xmark", side: 24) { self.attachmentError = nil }
                            .accessibilityLabel("Dismiss attachment error").padding(.trailing, 12)
                    }.transition(.fadeIn)
                }
                MarkdownEditor(documentID: id.uuidString,
                               source: Binding(get: { notebook.note(id)?.bodyMarkdown ?? "" }, set: {
                                   notebook.updateMarkdown(id, source: $0)
                                   dictation?.draftEdited(id, text: notebook.note(id)?.body.text ?? "")
                               }),
                               mode: $mode, personal: true, onLink: { _ in notify("Opened link in your browser") },
                               onFiles: importFiles, onImage: importImage, editor: editor, editable: !dictating && isEnabled)
                if !note.attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(note.attachments) { attachment in
                                NoteAttachmentTile(attachment: attachment) { preview(attachment) }
                                    .frame(width: 210).focused($focusedAttachment, equals: attachment.id)
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(focusedAttachment == attachment.id ? Theme.accent : .clear, lineWidth: 2))
                                    .transition(.fadeIn)
                            }
                        }
                        .padding(12)
                    }.fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .contain).accessibilityLabel("Note attachments")
                        .transition(.fadeIn)
                }
                HStack {
                    Text("\(note.wordCount) words").contentTransition(.numericText())
                    Label(notebook.saveError != nil ? "Could not save" : importing > 0 ? "Attaching…" : notebook.saving ? "Saving…" : "Saved on this Mac",
                          systemImage: notebook.saveError != nil ? "exclamationmark.triangle" : "lock")
                        .contentTransition(.interpolate)
                    Spacer()
                    Text(mode == .preview ? "Read only" : "Saves automatically")
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
            }
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(targeted ? Theme.accent : .clear, lineWidth: 2))
            .dropDestination(for: URL.self) { urls, _ in
                guard mode != .preview, !dictating else { return false }
                importFiles(urls); return true
            } isTargeted: { targeted = $0 && mode != .preview && !dictating }
            .motion(Motion.control, value: targeted)
            .motion(Motion.reveal, value: note.attachments.map(\.id))
            .motion(Motion.reveal, value: attachmentError)
            .motion(Motion.reveal, value: dictation?.notice(for: id))
            .background(WindowKeyAnchor(handler: keys))
            .onAppear { keys.start(handleKey) }
            .onDisappear { keys.stop(); dictation?.leave(id); _ = notebook.flush() }
            .onChange(of: mode) { _, _ in dictation?.leave(id) }
            .onChange(of: isEnabled) { _, enabled in
                if enabled { keys.start(handleKey) }
                else { keys.stop(); dictation?.leave(id) }
            }
            .onChange(of: dialogs.current?.id) { _, dialog in if dialog != nil { dictation?.leave(id) } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in _ = notebook.flush() }
            .onChange(of: notebook.saveError) { _, error in
                if error != nil { announceEditorStatus("Could not save notes. Your edits are still here. Retry or export a copy.") }
            }
        }
    }

    private var location: some View {
        Label("Personal notes · Only on this Mac", systemImage: "lock")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func actions(_ note: QuickNote) -> some View {
        HStack(spacing: 5) {
            ActionButton(title: "Move to project", tone: .outlined, height: 28, size: 11) {
                var dialog = Dialog(title: "Move to project", content: AnyView(MoveNoteToProject(
                    note: note, projects: projects, notebook: notebook,
                    close: dialogs.dismiss, moved: { url in dialogs.dismiss(); moved(url) })
                    .onDisappear { dialogs.restoreFocus() }), actions: [], width: 520)
                dialog.isModal = true; dialog.framesItself = true; dialog.fitsWindow = true; dialog.hugsContent = true
                dialogs.show(dialog)
            }.disabled(projects.isEmpty || importing > 0 || dictating)
            if let dictation {
                DictationMicButton(live: dictation.isListening(id), preparing: dictation.isPreparing(id),
                                   blocked: dictation.notice(for: id).isMicrophoneBlocked,
                                   level: dictation.level, startedAt: dictation.startedAt,
                                   download: dictation.notice(for: id).downloadFraction, action: toggleDictation)
                    .disabled(mode != .write || (dictation.phase != .idle && dictation.sessionID != id))
            }
            GlyphButton(icon: note.pinned ? "pin.fill" : "pin", side: 28, active: note.pinned) { notebook.togglePin(id) }
                .accessibilityLabel(note.pinned ? "Unpin note" : "Pin note").contentTransition(.symbolEffect(.replace))
            GlyphButton(icon: "ellipsis", side: 28)
                .appMenu {
                    [.item("Attach files", icon: "paperclip", disabled: mode == .preview || dictating, action: chooseFiles),
                     .item("Duplicate note", icon: "doc.on.doc", disabled: importing > 0 || dictating) {
                         if let copy = notebook.duplicate(id) { open(copy) }
                     },
                     .item("Export as Markdown", icon: "square.and.arrow.up") { export(note) }]
                }
                .accessibilityLabel("Note actions")
            GlyphButton(icon: "xmark", side: 28, action: close).accessibilityLabel("Close personal note")
        }
    }

    private func preview(_ attachment: NoteAttachment) {
        focusedAttachment = nil
        var dialog = Dialog(title: attachment.name,
                            content: AnyView(NoteAttachmentPreview(attachment: attachment, url: notebook.attachmentURL(attachment),
                                                                   close: dialogs.dismiss, restoreFocus: {
                                dialogs.restoreFocus(); focusedAttachment = attachment.id
                            })), actions: [], width: 650)
        dialog.isModal = true; dialog.framesItself = true; dialog.fitsWindow = true; dialog.hugsContent = true
        dialogs.show(dialog)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard let window = WindowKeyMonitor.frontmostWindow else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK { importFiles(panel.urls) }
        }
    }

    private func importFiles(_ urls: [URL]) {
        importing += 1; attachmentError = nil
        Task { @MainActor in
            defer { importing -= 1 }
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do { try await notebook.attach(url, to: id) }
                catch {
                    attachmentError = "Could not attach \(url.lastPathComponent): \(error.localizedDescription)"
                    announceEditorStatus(attachmentError!)
                }
            }
        }
    }

    private func importImage(_ data: Data) {
        importing += 1; attachmentError = nil
        Task { @MainActor in
            defer { importing -= 1 }
            do { try await notebook.attachImage(data, to: id) }
            catch {
                attachmentError = "Could not attach image: \(error.localizedDescription)"
                announceEditorStatus(attachmentError!)
            }
        }
    }

    private func toggleDictation() {
        guard let dictation, let note = notebook.note(id), mode == .write else { return }
        if dictating { dictation.stop(); return }
        guard dictation.phase == .idle, let view = editor.view else { return }
        editor.focus()
        let take = NoteDictation(note: note, store: notebook, view: view, document: NoteDocument(view.attributedString()))
        self.take = take
        dictation.toggle(DictationRequest(sessionID: id, draft: take.binding, caret: take.caret,
                                         roots: [], vocabulary: [note.title] + note.attachments.map(\.name),
                                         placeCaret: { take.placeCaret($0) }))
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isEnabled, dialogs.current == nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty, dictating {
            if [36, 76].contains(event.keyCode) { dictation?.stop(); return true }
            if event.keyCode == 53 { dictation?.throwAway(); return true }
        }
        if dictating, flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" { return true }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "d" {
            toggleDictation(); return true
        }
        return false
    }

    private func export(_ note: QuickNote) {
        exportMarkdown(note.markdown, name: note.displayTitle + ".md", dialogs: dialogs, notify: notify)
    }
}

private struct MoveNoteToProject: View {
    let note: QuickNote
    let projects: [ChangesRepository]
    let notebook: NotebookStore
    let close: () -> Void
    let moved: (URL) -> Void
    @State private var projectRoot: String?
    @State private var path = "docs/notes/idea.md"
    @State private var error: String?
    @FocusState private var focus: Field?
    private enum Field: Hashable, CaseIterable { case project, path, cancel, move }
    private var project: ChangesRepository? { projects.first { $0.root == projectRoot } ?? projects.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Give this thought a home.").font(.serif(24, .medium))
            Text(note.displayTitle).font(.system(size: 14, weight: .semibold))
            Text("Turn your personal note into a Markdown file in a project.").font(.system(size: 12)).foregroundStyle(.secondary)
            ActionButton(title: project?.name ?? "Choose a project", tone: .outlined, disclosure: true)
                .appMenu { projects.map { item in .item(item.name, checked: project?.root == item.root) { projectRoot = item.root; error = nil } } }
                .focused($focus, equals: .project).accessibilityLabel("Destination project")
            TextField("docs/notes/idea.md", text: $path)
                .textFieldStyle(.plain).padding(12).fieldSurface(cornerRadius: 8)
                .focused($focus, equals: .path).accessibilityLabel("Relative Markdown path")
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(focus == .path ? Theme.accent : .clear, lineWidth: 2))
                .onChange(of: path) { _, _ in error = nil }
            Text((project?.root ?? "") + "/" + path).font(.mono(11)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 9) {
                Label("Create a Markdown file and any missing folders.", systemImage: "plus")
                Label("Replace the personal note with the file in Explorer.", systemImage: "doc.text")
                Label("Nothing is committed, pushed, or sent to an agent.", systemImage: "lock")
            }.font(.system(size: 12)).padding(14).background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
            if !note.attachments.isEmpty {
                Text("This note has attachments. Keep it personal until attachments can be copied and linked in the project.")
                    .font(.system(size: 12)).foregroundStyle(Theme.attention)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.deletion).fixedSize(horizontal: false, vertical: true) }
            HStack {
                ActionButton(title: "Keep personal", tone: .outlined, keyboardShortcut: .cancelAction, action: close)
                    .focused($focus, equals: .cancel)
                Spacer()
                ActionButton(title: "Move to project", tone: .green) {
                    guard let project else { return }
                    do { moved(try notebook.moveToProject(note.id, root: URL(fileURLWithPath: project.root), relativePath: path)) }
                    catch { self.error = error.localizedDescription; focus = .path; announceEditorStatus(error.localizedDescription) }
                }.disabled(project == nil || !note.attachments.isEmpty).focused($focus, equals: .move)
            }
        }.padding(24).background(Theme.card)
            .onAppear { focus = .path }
            .onKeyPress(keys: [.tab]) { press in
                let fields: [Field] = note.attachments.isEmpty ? Field.allCases : [.project, .path, .cancel]
                let index = fields.firstIndex(of: focus ?? .path) ?? 0
                focus = fields[(index + (press.modifiers.contains(.shift) ? fields.count - 1 : 1)) % fields.count]
                return .handled
            }
    }
}

struct EditorSaveError: View {
    let message: String
    let retry: () -> Void
    let export: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Could not save. Your edits are still here.", systemImage: "exclamationmark.triangle")
            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            HStack {
                InlineLink(title: "Retry", action: retry)
                InlineLink(title: "Export a copy", action: export)
            }
        }.font(.system(size: 12)).foregroundStyle(Theme.deletion).padding(14)
            .frame(maxWidth: .infinity, alignment: .leading).background(Theme.deletion.opacity(0.06))
    }
}

@MainActor func announceEditorStatus(_ text: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
}

@MainActor func exportMarkdown(_ source: String, name: String, dialogs: DialogPresenter, notify: @escaping (String) -> Void) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-")
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    guard let window = WindowKeyMonitor.frontmostWindow else { return }
    panel.beginSheetModal(for: window) { response in
        guard response == .OK, let url = panel.url else { return }
        do { try source.write(to: url, atomically: true, encoding: .utf8); notify("Markdown copy exported") }
        catch { dialogs.show(.notice("Could not export", message: error.localizedDescription)) }
    }
}
