import AppKit
import SwiftUI

struct FileReferencePreview: View {
    let reference: FileReference
    let roots: [String]
    let origin: CGRect?
    let openExplorer: (URL) -> Bool

    @Environment(DialogPresenter.self) private var dialogs
    @Environment(MenuPresenter.self) private var menus
    @Environment(\.textScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.keyBindings) private var keyBindings
    @State private var preview: FilePreview?
    @State private var loading = true
    @State private var revision = 0
    @State private var source = false
    @State private var finding = false
    @State private var query = ""
    @State private var sourceMatches = FileFindResult()
    @State private var sourceSelection = 0
    @State private var find = TranscriptFind()
    @State private var documentID = UUID()
    @State private var outline: [FileReferenceHeading] = []
    @State private var selectedHeading: MarkdownLocation?
    @State private var note = TransientNote()
    @State private var keys = WindowKeyHandler(handlesTyping: true)
    @State private var dialogID: UUID?
    @State private var surfaceAnchor = FrameAnchor()
    @State private var markAnchor = FrameAnchor()
    @State private var flight: Flight?
    @State private var landed: Int?
    @FocusState private var findFocused: Bool
    @FocusState private var closeFocused: Bool

    private var text: String {
        if case .text(let text) = preview { return text }
        return ""
    }
    private var canRead: Bool { !text.isEmpty }
    private var showsSource: Bool { source || !reference.isMarkdown }
    private var blockedReason: String? { reference.explorerBlockedReason(in: roots) }
    private var summary: String {
        showsSource ? FindSummary.text(query: query, matchCount: sourceMatches.matches.count,
                                      hasMore: sourceMatches.hasMore, selection: sourceSelection) : find.summary
    }
    private var hasMatches: Bool { showsSource ? !sourceMatches.matches.isEmpty : !find.result.matches.isEmpty }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                toolbar(compact: geometry.size.width < FileReferenceMetrics.compactBreakpoint)
                if finding {
                    FindBar(placeholder: "Find in document", query: $query, summary: summary,
                            hasMatches: hasMatches, focused: $findFocused, move: moveMatch, close: closeFind)
                        .transition(.fadeIn)
                }
                reading(showsOutline: geometry.size.width >= FileReferenceMetrics.outlineBreakpoint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                footer(compact: geometry.size.width < FileReferenceMetrics.compactBreakpoint)
            }
        }
        .background(Theme.card)
        .background(FrameAnchorView(anchor: surfaceAnchor))
        .overlay(alignment: .topLeading) {
            if let flight {
                FlightView(flight: flight, onLanded: { self.flight = nil; landed = 1 }) { FileReferenceMark() }
            }
        }
        .headerNote(note, top: Theme.headerHeight + Space.md)
        .environment(\.transcriptSelection, nil)
        .environment(\.transcriptFind, find)
        .environment(\.transcriptMessageID, documentID)
        .environment(\.transcriptReply, nil)
        .environment(\.fileReferenceAction, nil)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == nil, url.path.isEmpty, let fragment = url.fragment,
               let heading = outline.first(where: { $0.fragment == fragment }) {
                source = false
                selectedHeading = heading.id
                return .handled
            }
            if let file = TranscriptLink.fileReference(for: url, relativeTo: reference.url.deletingLastPathComponent().path) {
                FileReferenceActions(reference: file, roots: roots, dialogs: dialogs, textScale: textScale,
                                     openExplorer: openExplorer, note: showNote).preview(from: nil)
                return .handled
            }
            showNote("Opened the link in your browser", "arrow.up.forward.app")
            return .systemAction
        })
        .focusBoundary(active: !menus.isOpen)
        .background(WindowKeyAnchor(handler: keys))
        .onAppear {
            dialogID = dialogs.current?.id
            source = reference.line != nil
            closeFocused = true
            keys.start(handleKey)
        }
        .onDisappear { keys.stop(); find.close(); dialogs.restoreFocus() }
        .task { await startFlight() }
        .task(id: revision) { await load() }
        .onChange(of: query) { search() }
        .onChange(of: summary) {
            if finding && !query.isEmpty { AccessibilityNotification.Announcement(summary).post() }
        }
        .onChange(of: showsSource) { searchAfterLayout() }
        .task(id: find.jumpRequest) {
            await Task.yield()
            guard !Task.isCancelled, let match = find.placeCurrent() else { return }
            match.view.revealCentered(match.range)
        }
        .motion(Motion.control, value: finding)
    }

    private var header: some View {
        HStack(spacing: Space.lg) {
            FileReferenceMark()
                .background(FrameAnchorView(anchor: markAnchor))
                .landingRings(landed, colour: Theme.accent, cornerRadius: Radius.control)
            FileReferenceSubject(path: reference.url.path, showsPath: true)
            GlyphButton(icon: "xmark", action: { dialogs.dismiss() })
                .appTooltip("Close preview (Escape)")
                .accessibilityLabel("Close preview")
                .focused($closeFocused)
        }
        .padding(.horizontal, Space.pane)
        .headerBand()
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: Space.md) {
            if !compact || !finding {
                ChoicePill(title: "Preview", selected: !showsSource) { source = false }
                    .disabled(!canRead || !reference.isMarkdown)
                ChoicePill(title: "Source", selected: showsSource) { source = true }
                    .disabled(!canRead)
            }
            Spacer(minLength: 0)
            GlyphButton(icon: "magnifyingglass", active: finding, action: openFind)
                .disabled(!canRead)
                .appTooltip(keyBindings.tooltip("Find in document", for: .findInFile))
                .accessibilityLabel("Find in document")
            GlyphButton(icon: "doc.on.doc", action: { reference.copyPath(note: showNote) })
                .appTooltip("Copy path").accessibilityLabel("Copy path")
            GlyphButton(icon: "arrow.clockwise", action: { revision += 1 })
                .disabled(loading)
                .appTooltip("Reload file").accessibilityLabel("Reload file")
        }
        .padding(.horizontal, Space.pane)
        .headerBand(height: Theme.subHeaderHeight)
    }

    @ViewBuilder private func reading(showsOutline: Bool) -> some View {
        if loading && preview == nil {
            DocumentLoading()
        } else if canRead {
            HStack(spacing: 0) {
                if showsOutline && !showsSource && !outline.isEmpty {
                    outlineView.frame(width: FileReferenceMetrics.outlineWidth)
                    Divider().overlay(Theme.hairline)
                }
                Group {
                    if showsSource {
                        CodeEditorView(documentID: reference.url.path + "-\(revision)", text: .constant(text),
                                       language: CodeLanguage(path: reference.name), matches: sourceMatches.matches,
                                       currentMatch: sourceMatches.matches.indices.contains(sourceSelection) ? sourceSelection : nil,
                                       findQuery: query, revealLine: reference.line, isEditable: false, textScale: textScale,
                                       onFind: openFind)
                            .accessibilityLabel("Read-only source")
                    } else {
                        rendered
                    }
                }
                .id(showsSource)
                .transition(.headerPage(reduceMotion: reduceMotion))
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .topTrailing) {
                if loading { LoopSpinner(size: ControlHeight.xs).padding(Space.md) }
            }
        } else {
            unavailable
        }
    }

    private var rendered: some View {
        ScrollViewReader { proxy in
            ScrollView {
                MarkdownProse(text: text, projectPath: reference.url.deletingLastPathComponent().path,
                              textScale: textScale, html: true, navigable: true) {
                    MarkdownCodeBlock(segment: $0).equatable()
                }
                .padding(Space.xxxl)
                .frame(maxWidth: FileReferenceMetrics.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: selectedHeading) {
                guard let selectedHeading else { return }
                if reduceMotion { proxy.scrollTo(selectedHeading, anchor: .top) }
                else { withAnimation(Motion.reveal) { proxy.scrollTo(selectedHeading, anchor: .top) } }
            }
            .task(id: text) {
                await Task.yield()
                if let fragment = reference.fragment,
                   let heading = outline.first(where: { $0.fragment == fragment }) {
                    proxy.scrollTo(heading.id, anchor: .top)
                }
                if finding { search() }
            }
        }
    }

    private var outlineView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                SectionRule("On this page")
                ForEach(outline) { heading in
                    Button {
                        // Clear first so clicking the same heading scrolls back to it.
                        selectedHeading = nil
                        Task { @MainActor in await Task.yield(); selectedHeading = heading.id }
                    } label: {
                        Text(heading.title)
                            .font(Typography.detail)
                            .foregroundStyle(selectedHeading == heading.id ? Theme.accent : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Space.sm)
                            .padding(.leading, heading.level > 1 ? Space.md : 0)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverFill()
                    .accessibilityAddTraits(selectedHeading == heading.id ? .isSelected : [])
                }
            }
            .padding(Space.lg)
        }
        .background(Theme.background)
    }

    @ViewBuilder private var unavailable: some View {
        switch preview {
        case .empty:
            PaneMessage(icon: "doc", title: "This file is empty", detail: "There is no content in \(reference.name) yet.")
        case .image(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().padding(Space.pane)
                    .accessibilityLabel(reference.name)
            } else { recovery("This image could not be read.") }
        case .tooLarge:
            recovery("This file is larger than the 4 MiB preview limit. Open it from Finder to read it.")
        case .binary:
            recovery("This file cannot be shown as text. Open it from Finder to read it.")
        case .unreadable(let reason): recovery(reason)
        case .none, .text: recovery("Could not load this file.")
        }
    }

    private func recovery(_ detail: String) -> some View {
        PaneMessage(icon: "doc.badge.ellipsis", title: "File unavailable", detail: detail) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.md) { recoveryActions }
                VStack(spacing: Space.md) { recoveryActions }
            }
        }
    }

    @ViewBuilder private var recoveryActions: some View {
        ActionButton(title: "Try again", tone: .green, action: { revision += 1 })
            .disabled(loading)
        ActionButton(title: "Open containing folder", tone: .outlined,
                     action: { reference.openFolder(note: showNote) })
    }

    private func footer(compact: Bool) -> some View {
        var footer = SheetFooter(
            primary: SheetAction(title: "Open in Explorer", enabled: blockedReason == nil,
                                 blockedReason: blockedReason, action: {
                guard openExplorer(reference.destination) else {
                    showNote("This file is no longer available in Explorer", "exclamationmark.triangle")
                    revision += 1
                    return
                }
                dialogs.dismiss()
            }),
            secondary: SheetAction(title: "Reveal in Finder", action: { reference.reveal(note: showNote) }),
            dismiss: { dialogs.dismiss() }) {
                if !compact {
                    Label("Read-only preview", systemImage: "lock")
                        .font(Typography.caption).foregroundStyle(.secondary)
                }
            }
        footer.showsDismiss = false
        return footer
    }

    private func load() async {
        loading = true
        let result = await FileTree.preview(of: reference.url)
        guard !Task.isCancelled else { return }
        preview = result
        outline = reference.isMarkdown ? FileReferenceDocument.outline(text) : []
        loading = false
        if case .unreadable(let reason) = result { AccessibilityNotification.Announcement(reason).post() }
        searchAfterLayout()
    }

    private func openFind() {
        guard canRead else { return }
        finding = true
        $findFocused.request()
        searchAfterLayout()
    }

    private func closeFind() {
        finding = false
        query = ""
        find.close()
        sourceMatches = FileFindResult()
        closeFocused = true
    }

    private func search() {
        guard finding else { return }
        if showsSource {
            find.close()
            sourceMatches = FileFind.search(query, in: text)
            sourceSelection = 0
        } else {
            find.searchDocument(query, messageID: documentID)
        }
    }

    private func searchAfterLayout() {
        Task { @MainActor in
            await Task.yield()
            search()
        }
    }

    private func moveMatch(_ offset: Int) {
        if showsSource {
            let count = sourceMatches.matches.count
            if count > 0 { sourceSelection = (sourceSelection + offset + count) % count }
        } else { find.move(by: offset) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard dialogs.current?.id == dialogID, !menus.isOpen else { return false }
        if keys.pressed(.findInFile, event) { openFind(); return true }
        if event.keyCode == 53 {
            if finding { closeFind() } else { dialogs.dismiss() }
            return true
        }
        return false
    }

    private func showNote(_ text: String, _ icon: String) {
        note.show(text, icon: icon)
        AccessibilityNotification.Announcement(text).post()
    }

    private func startFlight() async {
        await Task.yield()
        guard !reduceMotion, let origin, let surface = surfaceAnchor.frame(), let mark = markAnchor.frame() else { return }
        flight = Flight(from: origin.offsetBy(dx: -surface.minX, dy: -surface.minY),
                        to: mark.offsetBy(dx: -surface.minX, dy: -surface.minY))
    }
}
