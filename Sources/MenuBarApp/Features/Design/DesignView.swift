import AppKit
import SwiftUI
import CodeStationCore

// A Design session's canvas and its tools, with the conversation floating over them.
struct DesignView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs

    let sessionID: UUID
    var onOpenImplementation: (() -> Void)? = nil

    @State private var canvas = DesignCanvas()
    @State private var composerFocused = false
    @State private var conversationExpanded = false
    @State private var conversationMinimized = false
    @State private var designEmpty = false
    @State private var selectionEnabled = false
    @State private var snapshotRequest: DesignSnapshotRequest?
    @State private var preparingHandoff = false
    // When a prompt last left this composer, so the bubble it becomes can lift into place.
    @State private var promptSentAt: Date?
    @State private var designWindow = DesignWindow()
    // The note whose pin and card are lit, from hovering either.
    @State private var hotNote: UUID?
    // The note whose pin was just clicked, so the panel scrolls to its card.
    @State private var revealedNote: UUID?

    var body: some View {
        if let session = store.session(sessionID),
           let artifactURL = store.designArtifactURL(for: session) {
            let directory = artifactURL.deletingLastPathComponent()
            canvasColumn(session, directory: directory)
            .onAppear {
                store.hold(sessionID, for: .open)
                AppNotifier.shared.clear(
                    sessionID: store.userFacingSessionID(for: sessionID))
                // A design that already exists is what the user came back to look at,
                // so the panel starts as a small tab instead of covering it.
                // With nothing on the canvas yet, the conversation is all there is to show,
                // so it fills the pane.
                canvas.refresh(directory)
                designEmpty = canvas.screenURL(in: directory) == nil
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    conversationExpanded = designEmpty
                    conversationMinimized = !designEmpty
                }
                composerFocused = designEmpty
            }
            .onChange(of: canvas.revision == nil || canvas.screenURL(in: directory) == nil) { _, empty in
                guard empty != designEmpty else { return }
                designEmpty = empty
                conversationMinimized = false
                conversationExpanded = empty
            }
            .onDisappear {
                store.release(sessionID, for: .open)
                runner.forgetCanvasWidth(sessionID)
                designWindow.close()
            }
            .task(id: sessionID) { await store.transcriptReady(sessionID) }
            .task(id: directory.path) { await canvas.watch(directory) }
        } else {
            PaneMessage(icon: "paintbrush.pointed",
                        title: "This Design session is gone",
                        detail: "Choose another session from the sidebar.")
        }
    }

    private var latestPromptID: UUID? {
        store.session(sessionID)?.messages.last(where: { $0.role == .user })?.id
    }

    // MARK: - Composer

    private func composerPlaceholder(_ session: ChatSession) -> String {
        if runner.state(sessionID).isBusy { return "Queue a follow-up…" }
        return session.messages.isEmpty ? "Describe what to design…" : "Refine this design…"
    }

    // MARK: - Canvas

    private func canvasColumn(_ session: ChatSession, directory: URL) -> some View {
        let implementation = store.implementationSessions(for: session.id).last
        let needsImplementationUpdate = implementation.map {
            designNeedsUpdate(session, implementation: $0, directory: directory)
        } ?? false
        let busy = runner.state(sessionID).isBusy
        return VStack(spacing: 0) {
            DesignCanvasBar(canvas: canvas) {
                if canvas.revision != nil {
                    Text(canvas.selectedScreen?.path ?? "index.html")
                        .font(.mono(10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .appTooltip(canvas.screenURL(in: directory)?.path ?? directory.path)
                }
            } tools: {
                if canvas.revision != nil {
                    GlyphButton(icon: selectionEnabled ? "scope" : "cursorarrow", side: 28,
                                active: selectionEnabled, tint: Theme.accent) {
                        selectionEnabled.toggle()
                        // A pick lands in the composer, so the panel has to be open to show it.
                        if selectionEnabled { conversationMinimized = false }
                    }
                    .appTooltip(selectionEnabled
                        ? "Stop selecting canvas elements"
                        : "Select an element to refine")
                    .accessibilityLabel("Select an element to refine")

                    GlyphButton(icon: "arrow.up.left.and.arrow.down.right", side: 28,
                                active: designWindow.isOpen, tint: Theme.accent) {
                        openDesignWindow(session, directory: directory)
                    }
                    .appTooltip(designWindow.isOpen
                        ? "Bring design window to front"
                        : "Open design in a separate window")
                    .accessibilityLabel("Full screen")

                    SecondOpinionButton(usual: Preferences.secondOpinionLineup().map(\.agent)) {
                        askForSecondOpinion(session, directory: directory)
                    }
                    .appTooltip("Ask other agents to look at every screen")

                    if let implementation {
                        if onOpenImplementation == nil {
                            ActionButton(title: "Build", tone: .outlined,
                                         height: 28, size: 11,
                                         icon: "arrow.right") {
                                openImplementation(implementation)
                            }
                        }

                        if needsImplementationUpdate {
                            ActionButton(
                                title: preparingHandoff ? "Preparing…" : "Update build",
                                tone: .green, height: 28, size: 11,
                                icon: preparingHandoff ? "hourglass" : "arrow.triangle.2.circlepath") {
                                    implement()
                                }
                                .disabled(preparingHandoff || busy)
                        } else {
                            MonoChip(text: "BUILD UP TO DATE", size: 8.5,
                                     tint: Theme.accent)
                        }
                    } else {
                        ActionButton(title: preparingHandoff ? "Preparing…" : "Implement",
                                     tone: .green, height: 28, size: 11,
                                     icon: preparingHandoff ? "hourglass" : "hammer.fill") {
                            showImplementationDialog()
                        }
                        .disabled(preparingHandoff || busy)
                    }
                }
            }

            HStack(spacing: 0) {
                GeometryReader { geometry in
                    let toolbarHeight = canvas.revision != nil && canvas.screenURL(in: directory) != nil
                        ? DesignWebView.toolbarHeight : 0
                    let workspace = CGSize(width: geometry.size.width,
                                           height: max(0, geometry.size.height - toolbarHeight))
                    // A sibling rather than an overlay of the canvas: an overlay is rebuilt each
                    // time the canvas switches between its placeholders and the page, which would
                    // throw away the composer, its focus and the transcript's scroll position.
                    ZStack(alignment: .bottom) {
                        canvasContent(session, directory: directory, busy: busy)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        DesignConversation(session: session, size: workspace,
                                           conversationExpanded: $conversationExpanded,
                                           conversationMinimized: $conversationMinimized,
                                           composerFocused: $composerFocused,
                                           promptSentAt: $promptSentAt,
                                           designEmpty: designEmpty,
                                           selectionEnabled: selectionEnabled,
                                           placeholder: composerPlaceholder(session),
                                               showsDesignAmbition: true)
                            .padding(DesignConversationLayout.inset(in: workspace))
                            .padding(.bottom, toolbarHeight)
                    }
                }
                if let opinion = runner.designOpinions.opinion(sessionID) {
                    opinionPanel(opinion)
                        .frame(width: 320)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .motion(Motion.reveal, value: runner.designOpinions.opinion(sessionID) == nil)
        }
    }

    @ViewBuilder
    private func canvasContent(_ session: ChatSession, directory: URL, busy: Bool) -> some View {
        if let revision = canvas.revision, let url = canvas.screenURL(in: directory) {
            // The agent cannot see the canvas it draws into, so the canvas tells it how
            // much room there is.
            DesignWebView(url: url,
                          readAccessURL: directory,
                          screen: canvas.selectedScreen,
                          revision: revision,
                          reloadGeneration: canvas.reloadGeneration,
                          selectionEnabled: selectionEnabled,
                          snapshotRequest: snapshotRequest,
                          onSelection: selectElement,
                          onSnapshot: receiveSnapshot,
                          onViewport: { runner.recordCanvasWidth($0, for: sessionID) },
                          pins: pins,
                          hotPin: hotNote?.uuidString,
                          onPin: { id in
                              hotNote = UUID(uuidString: id)
                              revealedNote = hotNote
                          },
                          onPinHover: { id in hotNote = id.flatMap(UUID.init(uuidString:)) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
        } else if busy {
            PaneMessage(icon: "paintbrush.pointed",
                        title: "Building the design",
                        detail: "It appears here as soon as \(session.agent.title) writes it.")
                .background(Theme.sunken)
        } else {
            PaneMessage(icon: "rectangle.on.rectangle.angled",
                        title: "Your design appears here",
                        detail: "Describe what to design in the prompt below.")
                .background(Theme.sunken)
        }
    }

    private func openDesignWindow(_ session: ChatSession, directory: URL) {
        designWindow.show(
            title: session.title,
            content: DesignWindowView(canvas: canvas,
                                      directory: directory,
                                      label: "Canvas",
                                      onClose: { designWindow.close() }))
    }

    private func selectElement(_ selection: DesignElementSelection) {
        runner.composer.editDraft(sessionID) { draft in
            let reference = selection.reference(at: "`\(selection.selector)`")
            if draft.text.isEmpty { draft.text = reference }
            else if !draft.text.contains(selection.selector) { draft.text += "\n\n" + reference }
        }
        snapshotRequest = DesignSnapshotRequest(purpose: .selection,
                                                rect: selection.rect.insetBy(dx: -8, dy: -8))
        conversationMinimized = false
        composerFocused = true
    }

    private func receiveSnapshot(_ image: NSImage?, request: DesignSnapshotRequest) {
        guard snapshotRequest?.id == request.id else { return }
        snapshotRequest = nil
        switch request.purpose {
        case .selection:
            guard let image, let attachment = Attachments.fromImage(image, prefix: "selection")
            else { return }
            runner.composer.attach([attachment], to: sessionID)
            composerFocused = true
        case .handoff:
            Task {
                await prepareHandoff(screenshot: image.flatMap(DesignArtifacts.pngData),
                                     additionalContext: request.additionalContext)
            }
        }
    }

    // MARK: - Second opinion

    // The notes on the screen in view, as pins. With one screen, a note that names no
    // screen it knows is still about this one.
    private var pins: [DesignPin] {
        guard let opinion = runner.designOpinions.opinion(sessionID) else { return [] }
        let current = canvas.selectedScreen?.id
        let known = Set(canvas.manifest.screens.map(\.id))
        return opinion.notes.enumerated().compactMap { index, note in
            let here = note.screen == current
                || (canvas.manifest.screens.count == 1 && note.screen.map { !known.contains($0) } == true)
            guard here, note.selector != nil || note.box != nil else { return nil }
            return DesignPin(id: note.id.uuidString, selector: note.selector, box: note.box,
                             severity: note.severity.rawValue, number: index + 1,
                             label: "Note \(index + 1), \(note.category): \(note.text)")
        }
    }

    private func askForSecondOpinion(_ session: ChatSession, directory: URL) {
        let installed = AgentKind.allCases.filter { runner.executable(for: $0) != nil }
        let author = runner.author(of: session)
        let screens = canvas.manifest.screens
        dialogs.show(Dialog(
            title: "Ask for a second opinion",
            content: AnyView(DesignOpinionAsk(
                screenCount: screens.count, author: author, installed: installed,
                ask: { lineup, focus, reading in
                    dialogs.dismiss()
                    let executables = Dictionary(uniqueKeysWithValues: installed.compactMap { agent in
                        runner.executable(for: agent).map { (agent, $0) }
                    })
                    let shots = FileManager.default.temporaryDirectory
                        .appendingPathComponent("code-station-design-review-\(UUID().uuidString)", isDirectory: true)
                    let asked = session.messages.filter { $0.role == .user }.suffix(3).reversed()
                        .map(\.text).joined(separator: "\n\n")
                    runner.designOpinions.ask(
                        DesignSecondOpinion.Request(focus: focus, reading: reading,
                                                    designDirectory: directory.path, shotsDirectory: shots.path,
                                                    shots: [], asked: asked,
                                                    conversation: reading.conversation
                                                        ? SideQuestion.recentChat(session.messages) : "",
                                                    executable: ""),
                        screens: screens, reviewers: lineup, executables: executables, in: sessionID)
                })),
            actions: [], width: 620, framesItself: true))
    }

    private func opinionPanel(_ opinion: DesignOpinion) -> some View {
        let opinions = runner.designOpinions
        return DesignOpinionPanel(
            opinion: opinion, screens: canvas.manifest.screens, currentScreen: canvas.selectedScreen?.id,
            hotNote: $hotNote,
            revealedNote: $revealedNote,
            showScreen: { canvas.select($0) },
            keep: { opinions.keep($0, in: sessionID) },
            edit: { opinions.edit($0, text: $1, in: sessionID) },
            dismissNote: { opinions.dismiss($0, in: sessionID) },
            send: {
                let names = Array(NSOrderedSet(array: opinion.lanes.map(\.reviewer.agent.title))) as? [String] ?? []
                let text = DesignSecondOpinion.feedback(opinion.kept, screens: canvas.manifest.screens,
                                                        names: names.joined(separator: " and "))
                runner.send(text, sessionID: sessionID, store: store)
                opinions.markSent(count: opinion.kept.count, in: sessionID)
                promptSentAt = Date()
            },
            retry: { seat in
                guard let executable = runner.executable(for: seat.agent) else { return }
                opinions.retry(seat, executable: executable, in: sessionID)
            },
            stop: { opinions.stop($0, in: sessionID) },
            close: {
                hotNote = nil
                opinions.dismiss(sessionID)
            })
    }

    // MARK: - Implementation

    private func showImplementationDialog() {
        let draft = DesignImplementationDraft()
        dialogs.show(Dialog(
            title: "Implement this Design?",
            message: "Add guidance if the canvas shows multiple options, or leave this blank to implement the Design as shown.",
            content: AnyView(DesignImplementationContextEditor(draft: draft)),
            actions: [
                .init(label: "Implement", kind: .primary) {
                    implement(additionalContext: draft.text)
                },
                .init(label: "Cancel", kind: .cancel),
            ],
            width: 460))
    }

    // Hands over the canvas as it is now. If an earlier handoff already saved these
    // exact files, that copy is approved again rather than saved a second time.
    private func implement(additionalContext: String? = nil) {
        guard canvas.revision != nil, let session = store.session(sessionID) else { return }
        preparingHandoff = true
        let directory = store.designDirectory(for: session)
        if let saved = session.designRevisions
            .sorted(by: { $0.number > $1.number })
            .first(where: { DesignArtifacts.matchesLive($0, designDirectory: directory) }) {
            switch store.approveDesignRevision(saved.id, for: sessionID) {
            case .success(let approved):
                handOver(approved, additionalContext: additionalContext)
            case .failure(let failure):
                preparingHandoff = false
                dialogs.show(.notice("Could not prepare the Design", message: failure.message))
            }
            return
        }
        snapshotRequest = DesignSnapshotRequest(purpose: .handoff,
                                                additionalContext: additionalContext)
    }

    private func prepareHandoff(screenshot: Data?, additionalContext: String?) async {
        guard let session = store.session(sessionID) else {
            preparingHandoff = false
            return
        }
        let revisions = await DesignHandoffLifecycle.sourceRevisions(for: session, store: store)
        switch store.approveDesign(sessionID, screenshot: screenshot,
                                   sourceRevisions: revisions, promptID: latestPromptID) {
        case .failure(let failure):
            preparingHandoff = false
            dialogs.show(.notice("Could not prepare the Design", message: failure.message))
        case .success(let revision):
            handOver(revision, additionalContext: additionalContext)
        }
    }

    private func handOver(_ revision: DesignRevision, additionalContext: String?) {
        preparingHandoff = false
        if let implementation = store.implementationSessions(for: sessionID).last {
            switch DesignHandoffLifecycle.sendLatestDesign(
                to: implementation.id, store: store, runner: runner) {
            case .success:
                store.append(ChatMessage(role: .system, text: "Sent the design to Build."),
                             to: sessionID)
            case .failure(let failure):
                dialogs.show(.notice(failure.title, message: failure.message))
            }
        } else {
            switch DesignHandoffLifecycle.startImplementation(
                sessionID, revision: revision, additionalContext: additionalContext,
                store: store, runner: runner) {
            case .success:
                onOpenImplementation?()
            case .failure(let failure):
                dialogs.show(.notice(failure.title, message: failure.message))
            }
        }
    }

    private func designNeedsUpdate(_ design: ChatSession, implementation: ChatSession,
                                   directory: URL) -> Bool {
        if store.designHasUpdated(for: implementation) { return true }
        guard let revisionID = implementation.handedOffDesignRevisionID,
              let revision = design.designRevisions.first(where: { $0.id == revisionID }) else {
            return true
        }
        let handedOff = DesignArtifacts.materialsDirectory(revision, designDirectory: directory)
        return DesignArtifactRevision.read(directory) != DesignArtifactRevision.read(handedOff)
    }

    private func openImplementation(_ implementation: ChatSession) {
        if let onOpenImplementation {
            onOpenImplementation()
        } else {
            store.selectSession(implementation.id)
        }
    }
}



@MainActor
@Observable
private final class DesignImplementationDraft {
    var text = ""
}

private struct DesignImplementationContextEditor: View {
    @Bindable var draft: DesignImplementationDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("ADDITIONAL CONTEXT", style: .field)
            AppTextEditor(
                text: $draft.text,
                placeholder: "For example: use the second checkout option and keep the current navigation.",
                minHeight: 96)
                .frame(height: 96)
        }
        .padding(.top, 6)
    }
}

struct DesignReferenceView: View {
    @Environment(ProjectStore.self) private var store

    let sessionID: UUID

    @State private var canvas = DesignCanvas()
    @State private var designWindow = DesignWindow()

    var body: some View {
        if let session = store.session(sessionID),
           let directory = store.implementationDesignDirectory(for: session) {
            VStack(spacing: 0) {
                DesignCanvasBar(canvas: canvas) {
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("APPROVED DESIGN")
                        .font(.mono(10, .semibold))
                        .kerning(1)
                    if let title = revisionTitle(session) {
                        MonoChip(text: title.uppercased(), size: 8.5, tint: Theme.accent)
                    }
                } tools: {
                    if let sourceID = session.sourceDesignSessionID,
                       store.session(sourceID) != nil {
                        ActionButton(title: "Edit Design", tone: .outlined,
                                     height: 28, size: 11, icon: "arrow.up.right") {
                            store.selectSession(sourceID)
                        }
                    }

                    if canvas.revision != nil {
                        ActionButton(title: "Full Screen",
                                     tone: designWindow.isOpen ? .sunken : .outlined,
                                     height: 28, size: 11, icon: "macwindow") {
                            openDesignWindow(session, directory: directory)
                        }
                        .appTooltip(designWindow.isOpen
                            ? "Bring design window to front"
                            : "Open design in a separate window")
                    }
                }

                if let revision = canvas.revision, let url = canvas.screenURL(in: directory) {
                    DesignWebView(
                        url: url,
                        readAccessURL: directory,
                        screen: canvas.selectedScreen,
                        revision: revision,
                        reloadGeneration: canvas.reloadGeneration,
                        selectionEnabled: false,
                        snapshotRequest: nil,
                        onSelection: { _ in },
                        onSnapshot: { _, _ in })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white)
                } else {
                    unavailable(session)
                }
            }
            .task(id: directory.path) { await canvas.watch(directory) }
            .onDisappear { designWindow.close() }
        } else {
            unavailable(store.session(sessionID))
        }
    }

    private func openDesignWindow(_ session: ChatSession, directory: URL) {
        designWindow.show(
            title: session.title,
            content: DesignWindowView(canvas: canvas,
                                      directory: directory,
                                      label: revisionTitle(session) ?? "Approved design",
                                      onClose: { designWindow.close() }))
    }

    // Whether there is a way out of this depends on the Design the session was handed:
    // one that is still around can be opened and handed off again, while a deleted one
    // leaves nothing to point at, so saying otherwise would send the reader hunting.
    @ViewBuilder private func unavailable(_ session: ChatSession?) -> some View {
        let title = "The Design reference is unavailable"
        if let sourceID = session?.sourceDesignSessionID, store.session(sourceID) != nil {
            PaneMessage(icon: "paintbrush.pointed", title: title,
                        detail: "Return to the source Design and create another handoff.") {
                ActionButton(title: "Open Design", tone: .outlined, icon: "arrow.up.right") {
                    store.selectSession(sourceID)
                }
                .padding(.top, 4)
            }
        } else {
            PaneMessage(
                icon: "paintbrush.pointed", title: title,
                detail: "The Design session it came from has been deleted, so there is nothing left to show here. The work in this session is unaffected.")
        }
    }

    private func revisionTitle(_ session: ChatSession) -> String? {
        if let revisionID = session.handedOffDesignRevisionID,
           let sourceSessionID = session.sourceDesignSessionID,
           let sourceSession = store.session(sourceSessionID),
           let revision = sourceSession.designRevisions.first(where: { $0.id == revisionID }) {
            return revision.title
        }
        if let revision = store.approvedDesignRevision(for: session) { return revision.title }
        return session.handedOffDesignRevisionID == nil ? nil : "Approved"
    }
}

// What a canvas is showing: the design's files on disk, the screens they make up, and
// which one is on view. The agent writes those files behind the app's back and nothing
// announces the change, so whichever pane shows a design keeps one of these and polls it.
@MainActor
@Observable
final class DesignCanvas {
    private(set) var revision: DesignArtifactRevision?
    private(set) var manifest = DesignManifest.singleScreen
    private(set) var selectedScreenID = DesignScreen.canvas.id
    // Counted up to load the same files again.
    private(set) var reloadGeneration = 0

    var selectedScreen: DesignScreen? {
        manifest.screens.first { $0.id == selectedScreenID } ?? manifest.screens.first
    }

    func screenURL(in directory: URL) -> URL? {
        selectedScreen.flatMap { DesignManifest.safeURL(for: $0, in: directory) }
    }

    var screenMenu: [MenuEntry] {
        manifest.screens.map { screen in
            .item(screen.title, icon: "rectangle", checked: screen.id == selectedScreenID,
                  subtitle: screen.path) { self.selectedScreenID = screen.id }
        }
    }

    func reload() { reloadGeneration += 1 }

    func select(_ screenID: String) {
        guard manifest.screens.contains(where: { $0.id == screenID }) else { return }
        selectedScreenID = screenID
    }

    func refresh(_ directory: URL) {
        let next = DesignArtifactRevision.read(directory)
        if next != revision { revision = next }
        let nextManifest = DesignManifest.read(from: directory)
        if nextManifest != manifest {
            manifest = nextManifest
            if !manifest.screens.contains(where: { $0.id == selectedScreenID }) {
                selectedScreenID = manifest.screens.first?.id ?? DesignScreen.canvas.id
            }
        }
    }

    // Runs until it is cancelled, so it belongs in a task keyed on the directory.
    func watch(_ directory: URL) async {
        while !Task.isCancelled {
            refresh(directory)
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
        }
    }
}

// The bar over a canvas: what the pane calls it on the left, and on the right the screen
// picker when the design has more than one screen, the pane's own tools, and a reload.
struct DesignCanvasBar<Leading: View, Tools: View>: View {
    let canvas: DesignCanvas
    @ViewBuilder let leading: Leading
    @ViewBuilder let tools: Tools

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 10)
            if canvas.manifest.screens.count > 1 {
                OptionMenu(value: canvas.selectedScreen?.title ?? "Screen", matchWidth: false) {
                    canvas.screenMenu
                }
                .fixedSize()
            }
            tools
            if canvas.revision != nil {
                GlyphButton(icon: "arrow.clockwise", side: 28, tint: Theme.accent) {
                    canvas.reload()
                }
                .appTooltip("Reload canvas")
            }
        }
        .canvasBar()
    }
}

extension View {
    // The strip of tools over a page in the pane. A design's canvas and a running app both
    // sit under one, so they read as the same kind of page.
    func canvasBar() -> some View {
        padding(.horizontal, 14)
            .frame(height: DesignSplitLayout.barHeight)
            .background(Theme.card)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
    }
}

enum DesignSplitLayout {
    static let barHeight: CGFloat = 42
}

struct DesignElementSelection: Equatable {
    let selector: String
    let tag: String
    let text: String
    let rect: CGRect
}

struct DesignSnapshotRequest: Equatable {
    enum Purpose: Equatable { case handoff, selection }

    let id = UUID()
    let purpose: Purpose
    var rect: CGRect?
    var additionalContext: String?
}
