import AppKit
import SwiftUI
import WebKit

// A Design conversation keeps the agent loop on the left and turns its durable HTML
// artifact into a live canvas on the right.
struct DesignView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.textScale) private var textScale

    let sessionID: UUID
    var onOpenImplementation: (() -> Void)? = nil

    @State private var canvas = DesignCanvas()
    @State private var composerFocused = false
    @State private var conversationWidth = DesignSplitLayout.defaultConversationWidth
    @State private var dragStartConversationWidth: CGFloat?
    @State private var displayedRevisionID: UUID?
    @State private var comparingWithLive = false
    @State private var selectionEnabled = false
    @State private var snapshotRequest: DesignSnapshotRequest?
    @State private var preparingHandoff = false

    var body: some View {
        if let session = store.session(sessionID),
           let artifactURL = store.designArtifactURL(for: session) {
            let liveDirectory = artifactURL.deletingLastPathComponent()
            let displayedDirectory = displayedDirectory(for: session, live: liveDirectory)
            GeometryReader { geometry in
                let width = DesignSplitLayout.conversationWidth(
                    conversationWidth, availableWidth: geometry.size.width)

                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        conversation(session, width: width)
                            .frame(width: width)
                            .clipped()
                        Divider().overlay(Theme.hairline)
                        canvasPane(session, directory: displayedDirectory,
                                   liveDirectory: liveDirectory)
                    }

                    splitHandle(conversationWidth: width,
                                availableWidth: geometry.size.width)
                        .offset(x: width - DesignSplitLayout.handleWidth / 2)
                }
            }
            .onAppear {
                store.hold(sessionID, for: .open)
                AppNotifier.shared.clear(
                    sessionID: store.userFacingSessionID(for: sessionID))
                composerFocused = true
            }
            .onDisappear {
                store.release(sessionID, for: .open)
                runner.forgetCanvasWidth(sessionID)
            }
            .task(id: sessionID) { await store.transcriptReady(sessionID) }
            .task(id: displayedDirectory.path) { await canvas.watch(displayedDirectory) }
        } else {
            PaneMessage(icon: "paintbrush.pointed",
                        title: "This Design session is gone",
                        detail: "Choose another session from the sidebar.")
        }
    }

    private func displayedDirectory(for session: ChatSession, live: URL) -> URL {
        guard let displayedRevisionID,
              let revision = session.designRevisions.first(where: { $0.id == displayedRevisionID })
        else { return live }
        return DesignArtifacts.materialsDirectory(revision, designDirectory: live)
    }

    // MARK: - Conversation

    private func conversation(_ session: ChatSession, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("DESIGN")
                    .font(.mono(10, .semibold))
                    .kerning(1)
                Spacer(minLength: 8)
                designState
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Theme.card)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }

            designTranscript(session, width: width)
            Divider().overlay(Theme.hairline)
            designComposer(session)
        }
        .background(Theme.background)
    }

    private var designState: some View {
        let tone = SessionTone(sessionID, store: store, runner: runner)
        return HStack(spacing: 6) {
            StateLight(tone: tone, size: 6)
            Text(tone.word)
                .font(.mono(9.5, .semibold))
                .foregroundStyle(tone.colour)
        }
        .fixedSize()
    }

    private func designTranscript(_ session: ChatSession, width: CGFloat) -> some View {
        let state = runner.state(sessionID)
        let projectPath = store.workingDirectory(for: session) ?? ""
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.messages.isEmpty, !store.isTranscriptLoading(sessionID) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What should we design?")
                                .font(.serif(17))
                            Text("Describe a screen, flow, prototype, deck, diagram, or visual. "
                                 + "The agent will study this project and build it on the canvas.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 8)
                    }

                    ForEach(session.messages) { message in
                        MessageView(message: message,
                                    projectPath: projectPath,
                                    isTurnActive: state.isBusy
                                        && message.id == session.messages.last?.id,
                                    textScale: textScale,
                                    openChanges: {},
                                    availableWidth: width - 32)
                            .equatable()
                            .environment(\.runningAgents, runner.runningAgents(sessionID))
                    }

                    if let request = runner.question(sessionID) {
                        PermissionCard(request: request) { answer in
                            runner.answer(request, with: answer,
                                          sessionID: sessionID, store: store)
                        }
                        .id(request.id)
                    }

                    if state.isBusy, runner.question(sessionID) == nil {
                        HStack(spacing: 8) {
                            StateLight(tone: .running, size: 6)
                            Text("\(session.agent.title) is shaping the canvas…")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    TurnEndActions(sessionID: sessionID, state: state)

                    Color.clear.frame(height: 1).id("design-transcript-bottom")
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            // Anything new - a row, streamed text, a call, a question - sends the
            // transcript to its end.
            .onChange(of: transcriptShape(session)) {
                proxy.scrollTo("design-transcript-bottom", anchor: .bottom)
            }
        }
    }

    private struct TranscriptShape: Equatable {
        var messages: Int
        var characters: Int
        var tools: Int
        var question: String?
    }

    private func transcriptShape(_ session: ChatSession) -> TranscriptShape {
        TranscriptShape(messages: session.messages.count,
                        characters: session.messages.last?.text.count ?? 0,
                        tools: session.messages.last?.tools.count ?? 0,
                        question: runner.question(sessionID)?.id)
    }

    private func splitHandle(conversationWidth: CGFloat,
                             availableWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: DesignSplitLayout.handleWidth)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartConversationWidth ?? conversationWidth
                        dragStartConversationWidth = start
                        self.conversationWidth = DesignSplitLayout.conversationWidth(
                            start + value.translation.width,
                            availableWidth: availableWidth)
                    }
                    .onEnded { _ in dragStartConversationWidth = nil })
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .appTooltip("Drag to resize")
            .accessibilityElement()
            .accessibilityLabel("Resize Design conversation")
            .accessibilityValue("\(Int(conversationWidth)) points wide")
            .accessibilityAdjustableAction { direction in
                let change: CGFloat = switch direction {
                case .increment: 32
                case .decrement: -32
                @unknown default: 0
                }
                self.conversationWidth = DesignSplitLayout.conversationWidth(
                    conversationWidth + change,
                    availableWidth: availableWidth)
            }
    }

    private func designComposer(_ session: ChatSession) -> some View {
        let blocked = !FileManager.default.fileExists(atPath: store.workingDirectory(for: session) ?? "")
            || !runner.isAvailable(session.agent)
        let busy = runner.state(sessionID).isBusy
        return Composer(sessionID: sessionID,
                        blocked: blocked,
                        isFocused: $composerFocused,
                        placeholder: busy ? "Queue the next revision…" : "Describe what to design…",
                        inset: 12,
                        onOversizedPaste: attachPastedText,
                        onRecallUp: { runner.recallEarlier(sessionID, store: store) },
                        onRecallDown: { runner.recallLater(sessionID, store: store) },
                        above: {
                            ScrollView(.horizontal, showsIndicators: false) {
                                SessionRunSettingsControls(sessionID: sessionID)
                            }
                            let queued = runner.queued(sessionID).count
                            if queued > 0 {
                                Text(counted(queued, "revision") + " queued")
                                    .font(.mono(9.5, .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        },
                        accessory: {
                            Image(systemName: "paintbrush.pointed.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 22, height: 22)
                        })
    }

    private func attachPastedText(_ text: String) {
        guard let attachment = Attachments.fromPastedText(text) else { return }
        runner.attach([attachment], to: sessionID)
        composerFocused = true
    }

    // MARK: - Canvas

    private func canvasPane(_ session: ChatSession, directory: URL,
                            liveDirectory: URL) -> some View {
        let implementation = store.implementationSessions(for: session.id).last
        let needsImplementationUpdate = implementation.map {
            designNeedsUpdate(session, implementation: $0, liveDirectory: liveDirectory)
        } ?? false
        return VStack(spacing: 0) {
            DesignCanvasBar(canvas: canvas) {
                Text("CANVAS")
                    .font(.mono(10, .semibold))
                    .kerning(1)
                    .foregroundStyle(.secondary)
                if canvas.revision != nil {
                    StatusDot()
                    Text(canvas.selectedScreen?.path ?? "index.html")
                        .font(.mono(10.5))
                        .foregroundStyle(.secondary)
                        .appTooltip(canvas.screenURL(in: directory)?.path ?? directory.path)
                }
            } tools: {
                if !session.designRevisions.isEmpty {
                    OptionMenu(value: displayedRevision?.title ?? "Live", matchWidth: false) {
                        revisionMenu(session)
                    }
                    .fixedSize()
                }

                if canvas.revision != nil {
                    if displayedRevision == nil {
                        GlyphButton(icon: selectionEnabled ? "scope" : "cursorarrow", side: 28,
                                    active: selectionEnabled, tint: Theme.accent) {
                            selectionEnabled.toggle()
                        }
                        .appTooltip(selectionEnabled
                            ? "Stop selecting canvas elements"
                            : "Select an element to refine")
                    }

                    if displayedRevision != nil {
                        GlyphButton(icon: "rectangle.split.2x1", side: 28,
                                    active: comparingWithLive, tint: Theme.accent) {
                            comparingWithLive.toggle()
                        }
                        .appTooltip("Compare this revision with the live canvas")

                        GlyphButton(icon: "arrow.uturn.backward", side: 28, tint: Theme.accent) {
                            confirmRestore(session)
                        }
                        .appTooltip("Use this revision as the next direction")
                    } else {
                        GlyphButton(icon: "bookmark.fill", side: 28, tint: Theme.accent) {
                            preparingHandoff = true
                            snapshotRequest = DesignSnapshotRequest(purpose: .revision)
                        }
                        .disabled(preparingHandoff || runner.state(sessionID).isBusy)
                        .appTooltip("Save a Design version")

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
                                        requestImplementationSnapshot()
                                    }
                                    .disabled(preparingHandoff || runner.state(sessionID).isBusy)
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
                            .disabled(preparingHandoff || runner.state(sessionID).isBusy)
                        }
                    }
                }
            }

            if let revision = canvas.revision, let url = canvas.screenURL(in: directory) {
                if comparingWithLive, displayedRevision != nil,
                   let liveRevision = DesignArtifactRevision.read(liveDirectory),
                   let liveURL = canvas.screenURL(in: liveDirectory) {
                    HStack(spacing: 1) {
                        labelledPreview("LIVE", url: liveURL, directory: liveDirectory,
                                        revision: liveRevision, selectionEnabled: false)
                        labelledPreview(displayedRevision?.title.uppercased() ?? "REVISION",
                                        url: url, directory: directory,
                                        revision: revision, selectionEnabled: false)
                    }
                } else {
                    // The agent cannot see the canvas it draws into, so the canvas tells
                    // it how much room there is. Only the single live preview reports:
                    // the side-by-side comparison is a way of looking at the design, not
                    // a width it has to work at.
                    canvasPreview(url, directory: directory, revision: revision,
                                  selectionEnabled: displayedRevision == nil && selectionEnabled,
                                  onViewport: { runner.recordCanvasWidth($0, for: sessionID) })
                }
            } else {
                PaneMessage(icon: "rectangle.on.rectangle.angled",
                            title: "Your design will appear here",
                            detail: "Describe the first direction in the Design conversation.")
                    .background(Theme.sunken)
            }
        }
    }

    private var displayedRevision: DesignRevision? {
        guard let displayedRevisionID,
              let session = store.session(sessionID) else { return nil }
        return session.designRevisions.first { $0.id == displayedRevisionID }
    }

    private func revisionMenu(_ session: ChatSession) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("Live canvas", icon: "sparkles",
                  checked: displayedRevisionID == nil) {
                displayedRevisionID = nil
                comparingWithLive = false
            },
            .separator,
        ]
        entries += session.designRevisions.reversed().map { revision in
            .item(revision.title, icon: "clock.arrow.circlepath",
                  checked: displayedRevisionID == revision.id,
                  subtitle: revision.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                displayedRevisionID = revision.id
                comparingWithLive = false
            }
        }
        return entries
    }

    private func labelledPreview(_ label: String, url: URL, directory: URL,
                                 revision: DesignArtifactRevision,
                                 selectionEnabled: Bool) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.mono(9.5, .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.sunken)
            canvasPreview(url, directory: directory, revision: revision,
                          selectionEnabled: selectionEnabled)
        }
    }

    private func canvasPreview(_ url: URL, directory: URL,
                               revision: DesignArtifactRevision,
                               selectionEnabled: Bool,
                               onViewport: ((Double) -> Void)? = nil) -> some View {
        DesignWebView(url: url,
                      readAccessURL: directory,
                      revision: revision,
                      reloadGeneration: canvas.reloadGeneration,
                      selectionEnabled: selectionEnabled,
                      snapshotRequest: snapshotRequest,
                      onSelection: selectElement,
                      onSnapshot: receiveSnapshot,
                      onViewport: onViewport)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
    }

    private func selectElement(_ selection: DesignElementSelection) {
        let label = selection.text.isEmpty ? selection.tag.uppercased() : "\"\(selection.text)\""
        runner.editDraft(sessionID) { draft in
            let reference = "Refine \(label) at `\(selection.selector)`. "
            if draft.text.isEmpty { draft.text = reference }
            else if !draft.text.contains(selection.selector) { draft.text += "\n\n" + reference }
        }
        snapshotRequest = DesignSnapshotRequest(purpose: .selection,
                                                rect: selection.rect.insetBy(dx: -8, dy: -8))
        composerFocused = true
    }

    private func showImplementationDialog() {
        let draft = DesignImplementationDraft()
        dialogs.show(Dialog(
            title: "Implement this Design?",
            message: "Add guidance if the canvas shows multiple options, or leave this blank to implement the Design as shown.",
            content: AnyView(DesignImplementationContextEditor(draft: draft)),
            actions: [
                .init(label: "Implement", kind: .primary) {
                    requestImplementationSnapshot(additionalContext: draft.text)
                },
                .init(label: "Cancel", kind: .cancel),
            ],
            width: 460))
    }

    private func requestImplementationSnapshot(additionalContext: String? = nil) {
        guard canvas.revision != nil else { return }
        preparingHandoff = true
        snapshotRequest = DesignSnapshotRequest(purpose: .handoff,
                                                additionalContext: additionalContext)
    }

    private func receiveSnapshot(_ image: NSImage?, request: DesignSnapshotRequest) {
        guard snapshotRequest?.id == request.id else { return }
        snapshotRequest = nil
        switch request.purpose {
        case .selection:
            guard let image, let attachment = Attachments.fromImage(image, prefix: "selection")
            else { return }
            runner.attach([attachment], to: sessionID)
            composerFocused = true
        case .handoff:
            Task {
                await prepareHandoff(screenshot: image.flatMap(DesignArtifacts.pngData),
                                     additionalContext: request.additionalContext)
            }
        case .revision:
            Task { await saveRevision(screenshot: image.flatMap(DesignArtifacts.pngData)) }
        }
    }

    private func saveRevision(screenshot: Data?) async {
        guard let session = store.session(sessionID) else {
            preparingHandoff = false
            return
        }
        let source = await DesignHandoffLifecycle.sourceRevisions(for: session, store: store)
        switch store.saveDesignRevision(
            sessionID, screenshot: screenshot, sourceRevisions: source) {
        case .success(let revision):
            store.append(ChatMessage(role: .system,
                                     text: "Saved \(revision.title)."),
                         to: sessionID)
        case .failure(let failure):
            dialogs.show(.notice("Could not save the Design revision", message: failure.message))
        }
        preparingHandoff = false
    }

    private func prepareHandoff(screenshot: Data?, additionalContext: String?) async {
        guard let session = store.session(sessionID) else {
            preparingHandoff = false
            return
        }
        let revisions = await DesignHandoffLifecycle.sourceRevisions(for: session, store: store)
        switch store.approveDesign(sessionID, screenshot: screenshot,
                                   sourceRevisions: revisions) {
        case .failure(let failure):
            preparingHandoff = false
            dialogs.show(.notice("Could not prepare the Design", message: failure.message))
        case .success(let revision):
            preparingHandoff = false
            if let implementation = store.implementationSessions(for: sessionID).last {
                switch DesignHandoffLifecycle.sendLatestDesign(
                    to: implementation.id, store: store, runner: runner) {
                case .success:
                    store.append(ChatMessage(
                        role: .system,
                        text: "Sent \(revision.title) to Build."),
                        to: sessionID)
                case .failure(let failure):
                    dialogs.show(.notice(failure.title, message: failure.message))
                }
            } else {
                switch DesignHandoffLifecycle.startImplementation(
                    sessionID, revision: revision, additionalContext: additionalContext,
                    store: store, runner: runner) {
                case .success:
                    break
                case .failure(let failure):
                    dialogs.show(.notice(failure.title, message: failure.message))
                }
            }
        }
    }

    private func designNeedsUpdate(_ design: ChatSession, implementation: ChatSession,
                                   liveDirectory: URL) -> Bool {
        if store.designHasUpdated(for: implementation) { return true }
        guard let revisionID = implementation.handedOffDesignRevisionID,
              let revision = design.designRevisions.first(where: { $0.id == revisionID }) else {
            return true
        }
        let handedOff = DesignArtifacts.materialsDirectory(
            revision, designDirectory: store.designDirectory(for: design))
        return DesignArtifactRevision.read(liveDirectory)
            != DesignArtifactRevision.read(handedOff)
    }

    private func openImplementation(_ implementation: ChatSession) {
        if let onOpenImplementation {
            onOpenImplementation()
        } else {
            store.selectSession(implementation.id)
        }
    }

    private func confirmRestore(_ session: ChatSession) {
        guard let revision = displayedRevision else { return }
        dialogs.show(.confirm(
            "Use \(revision.title) as the next direction?",
            message: "The live canvas is replaced with this saved revision. Its revision history is kept.",
            action: "Use \(revision.title)", kind: .primary) {
                switch store.restoreDesignRevision(revision.id, for: session.id) {
                case .success:
                    displayedRevisionID = nil
                    comparingWithLive = false
                case .failure(let failure):
                    dialogs.show(.notice("Could not restore the Design", message: failure.message))
                }
            })
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
                }

                if let revision = canvas.revision, let url = canvas.screenURL(in: directory) {
                    DesignWebView(
                        url: url,
                        readAccessURL: directory,
                        revision: revision,
                        reloadGeneration: canvas.reloadGeneration,
                        selectionEnabled: false,
                        snapshotRequest: nil,
                        onSelection: { _ in },
                        onSnapshot: { _, _ in })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white)
                } else {
                    PaneMessage(icon: "paintbrush.pointed",
                                title: "The Design reference is unavailable",
                                detail: "Return to the source Design and create another handoff.")
                }
            }
            .task(id: directory.path) { await canvas.watch(directory) }
        } else {
            PaneMessage(icon: "paintbrush.pointed",
                        title: "The Design reference is unavailable",
                        detail: "Return to the source Design and create another handoff.")
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

    // Runs until it is cancelled, so it belongs in a task keyed on the directory.
    func watch(_ directory: URL) async {
        while !Task.isCancelled {
            let next = DesignArtifactRevision.read(directory)
            if next != revision { revision = next }
            let nextManifest = DesignManifest.read(from: directory)
            if nextManifest != manifest {
                manifest = nextManifest
                if !manifest.screens.contains(where: { $0.id == selectedScreenID }) {
                    selectedScreenID = manifest.screens.first?.id ?? DesignScreen.canvas.id
                }
            }
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
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Theme.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

enum DesignSplitLayout {
    static let defaultConversationWidth: CGFloat = 340
    static let minimumConversationWidth: CGFloat = 280
    static let minimumCanvasWidth: CGFloat = 320
    static let dividerWidth: CGFloat = 1
    static let handleWidth: CGFloat = 9

    static func conversationWidth(_ proposedWidth: CGFloat,
                                  availableWidth: CGFloat) -> CGFloat {
        let paneWidth = max(0, availableWidth - dividerWidth)
        let halfWidth = paneWidth / 2
        let minimum = min(minimumConversationWidth, halfWidth)
        let maximum = max(minimum, paneWidth - min(minimumCanvasWidth, halfWidth))
        return min(max(proposedWidth, minimum), maximum)
    }
}

struct DesignElementSelection: Equatable {
    let selector: String
    let tag: String
    let text: String
    let rect: CGRect
}

struct DesignSnapshotRequest: Equatable {
    enum Purpose: Equatable { case handoff, revision, selection }

    let id = UUID()
    let purpose: Purpose
    var rect: CGRect?
    var additionalContext: String?
}

private struct DesignWebView: NSViewRepresentable {
    let url: URL
    let readAccessURL: URL
    let revision: DesignArtifactRevision
    let reloadGeneration: Int
    let selectionEnabled: Bool
    let snapshotRequest: DesignSnapshotRequest?
    let onSelection: (DesignElementSelection) -> Void
    let onSnapshot: (NSImage?, DesignSnapshotRequest) -> Void
    // The page reports its own width rather than the view reporting its frame.
    // `window.innerWidth` is the number the design's CSS is resolved against, so it stays
    // right whatever sits between the view's bounds and the layout viewport.
    var onViewport: ((Double) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.selectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        configuration.userContentController.add(
            context.coordinator, name: Coordinator.messageName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .white
        webView.isInspectable = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSelection = onSelection
        context.coordinator.onSnapshot = onSnapshot
        context.coordinator.onViewport = onViewport
        context.coordinator.setSelection(selectionEnabled, in: webView)

        if let snapshotRequest,
           context.coordinator.snapshotID != snapshotRequest.id {
            context.coordinator.snapshotID = snapshotRequest.id
            context.coordinator.takeSnapshot(snapshotRequest, of: webView)
        }

        let fileKey = revision.files.map {
            "\($0.path):\($0.modified.timeIntervalSinceReferenceDate):\($0.size)"
        }.joined(separator: "|")
        let key = "\(url.path):\(fileKey):\(reloadGeneration)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.messageName)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageName = "codeStationDesignSelection"

        var loadedKey: String?
        var snapshotID: UUID?
        var selectionEnabled = false
        var onSelection: ((DesignElementSelection) -> Void)?
        var onSnapshot: ((NSImage?, DesignSnapshotRequest) -> Void)?
        var onViewport: ((Double) -> Void)?

        func setSelection(_ enabled: Bool, in webView: WKWebView) {
            guard selectionEnabled != enabled else { return }
            selectionEnabled = enabled
            webView.evaluateJavaScript("window.__codeStationSetSelection?.(\(enabled));")
        }

        func takeSnapshot(_ request: DesignSnapshotRequest, of webView: WKWebView) {
            let configuration = WKSnapshotConfiguration()
            if let rect = request.rect {
                let clipped = rect.intersection(webView.bounds)
                if !clipped.isNull, clipped.width > 1, clipped.height > 1 {
                    configuration.rect = clipped
                }
            }
            webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                self?.onSnapshot?(image, request)
            }
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == Self.messageName,
                  let body = message.body as? [String: Any] else { return }

            if body["kind"] as? String == "viewport" {
                if let width = body["width"] as? Double { onViewport?(width) }
                return
            }

            guard let selector = body["selector"] as? String,
                  let tag = body["tag"] as? String,
                  let rect = body["rect"] as? [String: Any],
                  let x = rect["x"] as? Double,
                  let y = rect["y"] as? Double,
                  let width = rect["width"] as? Double,
                  let height = rect["height"] as? Double else { return }
            onSelection?(DesignElementSelection(
                selector: selector,
                tag: tag,
                text: (body["text"] as? String ?? "").trimmed,
                rect: CGRect(x: x, y: y, width: width, height: height)))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(
                "window.__codeStationSetSelection?.(\(selectionEnabled));")
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable
                        (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            decisionHandler(["file", "about", "data", "blob"].contains(scheme ?? "")
                ? .allow : .cancel)
        }
    }

    private static let selectionScript = #"""
    (() => {
      var enabled = false;
      var highlighted = null;
      var previousOutline = "";
      var previousCursor = "";

      function clearHighlight() {
        if (!highlighted) return;
        highlighted.style.outline = previousOutline;
        highlighted.style.cursor = previousCursor;
        highlighted = null;
      }

      function highlight(element) {
        if (highlighted === element) return;
        clearHighlight();
        highlighted = element;
        previousOutline = element.style.outline;
        previousCursor = element.style.cursor;
        element.style.outline = "2px solid #00a86b";
        element.style.cursor = "crosshair";
      }

      function selectorFor(element) {
        if (element.id) return `#${CSS.escape(element.id)}`;
        const parts = [];
        let current = element;
        while (current && current.nodeType === Node.ELEMENT_NODE && current !== document.body) {
          let part = current.tagName.toLowerCase();
          const classes = Array.from(current.classList).filter(Boolean).slice(0, 2);
          if (classes.length) part += classes.map(value => `.${CSS.escape(value)}`).join("");
          const siblings = current.parentElement
            ? Array.from(current.parentElement.children).filter(item => item.tagName === current.tagName)
            : [];
          if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(current) + 1})`;
          parts.unshift(part);
          current = current.parentElement;
        }
        return parts.join(" > ");
      }

      var reportedWidth = 0;
      function reportViewport() {
        const width = window.innerWidth;
        if (width === reportedWidth || !width) return;
        reportedWidth = width;
        window.webkit.messageHandlers.codeStationDesignSelection.postMessage({
          kind: "viewport", width: width
        });
      }
      reportViewport();
      window.addEventListener("resize", reportViewport);

      window.__codeStationSetSelection = value => {
        enabled = Boolean(value);
        document.documentElement.style.cursor = enabled ? "crosshair" : "";
        if (!enabled) clearHighlight();
      };

      document.addEventListener("mouseover", event => {
        if (enabled) highlight(event.target);
      }, true);

      document.addEventListener("click", event => {
        if (!enabled) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        const element = event.target;
        const rect = element.getBoundingClientRect();
        window.webkit.messageHandlers.codeStationDesignSelection.postMessage({
          selector: selectorFor(element),
          tag: element.tagName.toLowerCase(),
          text: (element.innerText || element.getAttribute("aria-label") || "").trim().slice(0, 160),
          rect: {x: rect.x, y: rect.y, width: rect.width, height: rect.height}
        });
      }, true);
    })();
    """#
}
