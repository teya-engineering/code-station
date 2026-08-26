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

    @State private var artifactRevision: DesignArtifactRevision?
    @State private var reloadGeneration = 0
    @State private var composerFocused = false
    @State private var dropTargeted = false
    @State private var conversationWidth = DesignSplitLayout.defaultConversationWidth
    @State private var dragStartConversationWidth: CGFloat?
    @State private var manifest = DesignManifest.singleScreen
    @State private var selectedScreenID = DesignScreen.canvas.id
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
                        canvas(session, directory: displayedDirectory,
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
            .task(id: displayedDirectory.path) { await watchArtifact(displayedDirectory) }
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
                .foregroundStyle(tone == .idle ? Color.secondary : tone.colour)
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

                    if case .failed(let message) = state {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(message)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.warningText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Spacer(minLength: 0)
                                if runner.canContinueAfterFailure(sessionID, store: store) {
                                    ActionButton(title: "Continue", height: 27, size: 11) {
                                        runner.continueAfterFailure(sessionID, store: store)
                                    }
                                }
                                ActionButton(title: "Dismiss", tone: .outlined,
                                             height: 27, size: 11) {
                                    runner.dismissFailure(sessionID)
                                }
                            }
                        }
                        .padding(11)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(Theme.warningBackground))
                    }

                    // Nothing went wrong, so a stop gets a button under its transcript note
                    // rather than a card of its own.
                    if runner.canContinueAfterStop(sessionID, store: store) {
                        HStack {
                            Spacer(minLength: 0)
                            ActionButton(title: "Continue", tone: .outlined,
                                         height: 27, size: 11) {
                                runner.continueAfterStop(sessionID, store: store)
                            }
                        }
                    }

                    Color.clear.frame(height: 1).id("design-transcript-bottom")
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.messages.count) {
                proxy.scrollTo("design-transcript-bottom", anchor: .bottom)
            }
            .onChange(of: session.messages.last?.text.count ?? 0) {
                proxy.scrollTo("design-transcript-bottom", anchor: .bottom)
            }
            .onChange(of: session.messages.last?.tools.count ?? 0) {
                proxy.scrollTo("design-transcript-bottom", anchor: .bottom)
            }
            .onChange(of: runner.question(sessionID)?.id) {
                proxy.scrollTo("design-transcript-bottom", anchor: .bottom)
            }
        }
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
        let workingDirectory = store.workingDirectory(for: session) ?? ""
        let blocked = !FileManager.default.fileExists(atPath: workingDirectory)
            || !runner.isAvailable(session.agent)
        let state = runner.state(sessionID)
        let canSend = !blocked && !runner.draft(sessionID).isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            AttachmentChip(url: attachment.url) {
                                runner.editDraft(sessionID) { draft in
                                    draft.attachments.removeAll { $0.id == attachment.id }
                                }
                            }
                        }
                    }
                }
            }

            if !runner.queued(sessionID).isEmpty {
                Text("\(runner.queued(sessionID).count) revision"
                     + (runner.queued(sessionID).count == 1 ? "" : "s") + " queued")
                    .font(.mono(9.5, .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ComposerField(text: draft,
                              isFocused: $composerFocused,
                              placeholder: state.isBusy
                                ? "Queue the next revision…"
                                : "Describe what to design…",
                              isEnabled: !blocked,
                              onSubmit: send,
                              onOversizedPaste: attachPastedText,
                              trailingAccessory: {
                                  Image(systemName: "paintbrush.pointed.fill")
                                      .font(.system(size: 12, weight: .semibold))
                                      .foregroundStyle(Theme.accent)
                                      .frame(width: 22, height: 22)
                              })

                if canSend {
                    Button(action: send) {
                        Image(systemName: state.isBusy ? "arrow.up.to.line" : "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.accentFill))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .appTooltip(state.isBusy ? "Queue this revision" : "Design")
                }

                if state == .stopping {
                    Image(systemName: "hourglass")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.field))
                } else if state.isBusy {
                    Button {
                        runner.stop(sessionID)
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.deletion))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .appTooltip("Stop this revision")
                }
            }
        }
        .padding(12)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(Theme.accent, lineWidth: dropTargeted ? 2 : 0)
            .padding(5))
        .pasteAttachments(enabled: composerFocused && !blocked) { attach($0) }
        .dropDestination(for: URL.self) { urls, _ in
            guard !blocked else { return false }
            attach(Attachments.fromDrop(urls))
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var attachments: [Attachment] { runner.draft(sessionID).attachments }

    private var draft: Binding<String> {
        Binding(get: { runner.draft(sessionID).text },
                set: { text in runner.editDraft(sessionID) { $0.text = text } })
    }

    private func attach(_ found: [Attachment]) {
        runner.editDraft(sessionID) { draft in
            for item in found where !draft.attachments.contains(where: { $0.url == item.url }) {
                draft.attachments.append(item)
            }
        }
        composerFocused = true
    }

    private func attachPastedText(_ text: String) {
        guard let attachment = Attachments.fromPastedText(text) else { return }
        attach([attachment])
    }

    private func send() {
        let draft = runner.draft(sessionID)
        guard !draft.isEmpty else { return }
        runner.send(draft.text,
                    attachments: draft.attachments,
                    customInstructions: draft.customInstructions,
                    sessionID: sessionID,
                    store: store)
        runner.clearDraft(sessionID)
    }

    // MARK: - Canvas

    private func canvas(_ session: ChatSession, directory: URL,
                        liveDirectory: URL) -> some View {
        let implementation = store.implementationSessions(for: session.id).last
        let needsImplementationUpdate = implementation.map {
            designNeedsUpdate(session, implementation: $0, liveDirectory: liveDirectory)
        } ?? false
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("CANVAS")
                    .font(.mono(10, .semibold))
                    .kerning(1)
                    .foregroundStyle(.secondary)
                if artifactRevision != nil {
                    StatusDot()
                    Text(selectedScreen?.path ?? "index.html")
                        .font(.mono(10.5))
                        .foregroundStyle(.secondary)
                        .appTooltip(screenURL(in: directory)?.path ?? directory.path)
                }

                Spacer(minLength: 10)

                if manifest.screens.count > 1 {
                    HStack(spacing: 5) {
                        Text(selectedScreen?.title ?? "Screen")
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                    .appMenu { screenMenu }
                }

                if !session.designRevisions.isEmpty {
                    HStack(spacing: 5) {
                        Text(displayedRevision?.title ?? "Live")
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(displayedRevision == nil ? Color.secondary : Theme.accent)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                    .appMenu { revisionMenu(session) }
                }

                if artifactRevision != nil {
                    if displayedRevision == nil {
                        Button {
                            selectionEnabled.toggle()
                        } label: {
                            Image(systemName: selectionEnabled ? "scope" : "cursorarrow")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(selectionEnabled ? .white : Theme.accent)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(selectionEnabled ? Theme.accentFill : Theme.card))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .appTooltip(selectionEnabled
                            ? "Stop selecting canvas elements"
                            : "Select an element to refine")
                    }

                    if displayedRevision != nil {
                        Button { comparingWithLive.toggle() } label: {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(comparingWithLive ? .white : Theme.accent)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(comparingWithLive ? Theme.accentFill : Theme.card))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .appTooltip("Compare this revision with the live canvas")

                        Button { confirmRestore(session) } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .appTooltip("Use this revision as the next direction")
                    } else {
                        Button {
                            preparingHandoff = true
                            snapshotRequest = DesignSnapshotRequest(purpose: .revision)
                        } label: {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
                                requestImplementationSnapshot()
                            }
                            .disabled(preparingHandoff || runner.state(sessionID).isBusy)
                        }
                    }

                    Button { reloadGeneration += 1 } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .appTooltip("Reload canvas")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Theme.card)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }

            if let artifactRevision, let url = screenURL(in: directory) {
                if comparingWithLive, displayedRevision != nil,
                   let liveRevision = DesignArtifactRevision.read(liveDirectory),
                   let liveURL = screenURL(in: liveDirectory) {
                    HStack(spacing: 1) {
                        labelledPreview("LIVE", url: liveURL, directory: liveDirectory,
                                        revision: liveRevision, selectionEnabled: false)
                        labelledPreview(displayedRevision?.title.uppercased() ?? "REVISION",
                                        url: url, directory: directory,
                                        revision: artifactRevision, selectionEnabled: false)
                    }
                } else {
                    // The agent cannot see the canvas it draws into, so the canvas tells
                    // it how much room there is. Only the single live preview reports:
                    // the side-by-side comparison is a way of looking at the design, not
                    // a width it has to work at.
                    canvasPreview(url, directory: directory, revision: artifactRevision,
                                  selectionEnabled: displayedRevision == nil && selectionEnabled,
                                  onViewport: { runner.recordCanvasWidth($0, for: sessionID) })
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Your design will appear here")
                        .font(.serif(19))
                    Text("Describe the first direction in the Design conversation.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.sunken)
            }
        }
    }

    private var displayedRevision: DesignRevision? {
        guard let displayedRevisionID,
              let session = store.session(sessionID) else { return nil }
        return session.designRevisions.first { $0.id == displayedRevisionID }
    }

    private var selectedScreen: DesignScreen? {
        manifest.screens.first { $0.id == selectedScreenID } ?? manifest.screens.first
    }

    private var screenMenu: [MenuEntry] {
        manifest.screens.map { screen in
            .item(screen.title, icon: "rectangle",
                  checked: screen.id == selectedScreenID,
                  subtitle: screen.path) {
                selectedScreenID = screen.id
            }
        }
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

    private func screenURL(in directory: URL) -> URL? {
        guard let screen = selectedScreen else { return nil }
        return DesignManifest.safeURL(for: screen, in: directory)
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
                      reloadGeneration: reloadGeneration,
                      selectionEnabled: selectionEnabled,
                      snapshotRequest: snapshotRequest,
                      onSelection: selectElement,
                      onSnapshot: receiveSnapshot,
                      onViewport: onViewport)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
    }

    private func watchArtifact(_ directory: URL) async {
        while !Task.isCancelled {
            let revision = DesignArtifactRevision.read(directory)
            let nextManifest = DesignManifest.read(from: directory)
            if revision != artifactRevision { artifactRevision = revision }
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

    private func requestImplementationSnapshot() {
        guard artifactRevision != nil else { return }
        preparingHandoff = true
        snapshotRequest = DesignSnapshotRequest(purpose: .handoff)
    }

    private func receiveSnapshot(_ image: NSImage?, request: DesignSnapshotRequest) {
        guard snapshotRequest?.id == request.id else { return }
        snapshotRequest = nil
        switch request.purpose {
        case .selection:
            guard let image, let attachment = Attachments.fromImage(image, prefix: "selection")
            else { return }
            attach([attachment])
        case .handoff:
            Task { await prepareHandoff(screenshot: image.flatMap(DesignArtifacts.pngData)) }
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
            showFailure(title: "Could not save the Design revision", message: failure.message)
        }
        preparingHandoff = false
    }

    private func prepareHandoff(screenshot: Data?) async {
        guard let session = store.session(sessionID) else {
            preparingHandoff = false
            return
        }
        let revisions = await DesignHandoffLifecycle.sourceRevisions(for: session, store: store)
        switch store.approveDesign(sessionID, screenshot: screenshot,
                                   sourceRevisions: revisions) {
        case .failure(let failure):
            preparingHandoff = false
            showFailure(title: "Could not prepare the Design", message: failure.message)
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
                    showFailure(title: failure.title, message: failure.message)
                }
            } else {
                switch DesignHandoffLifecycle.startImplementation(
                    sessionID, revision: revision, store: store, runner: runner) {
                case .success:
                    break
                case .failure(let failure):
                    showFailure(title: failure.title, message: failure.message)
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
        dialogs.show(Dialog(
            title: "Use \(revision.title) as the next direction?",
            message: "The live canvas is replaced with this saved revision. Its revision history is kept.",
            actions: [
                .init(label: "Use \(revision.title)", kind: .primary) {
                    switch store.restoreDesignRevision(revision.id, for: session.id) {
                    case .success:
                        displayedRevisionID = nil
                        comparingWithLive = false
                    case .failure(let failure):
                        showFailure(title: "Could not restore the Design",
                                    message: failure.message)
                    }
                },
                .init(label: "Cancel", kind: .cancel),
            ]))
    }

    private func showFailure(title: String, message: String) {
        dialogs.show(Dialog(title: title, message: message,
                            actions: [.init(label: "OK", kind: .cancel)]))
    }
}

struct DesignReferenceView: View {
    @Environment(ProjectStore.self) private var store

    let sessionID: UUID

    @State private var artifactRevision: DesignArtifactRevision?
    @State private var manifest = DesignManifest.singleScreen
    @State private var selectedScreenID = DesignScreen.canvas.id
    @State private var reloadGeneration = 0

    var body: some View {
        if let session = store.session(sessionID),
           let directory = store.implementationDesignDirectory(for: session) {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("APPROVED DESIGN")
                        .font(.mono(10, .semibold))
                        .kerning(1)
                    if let title = revisionTitle(session) {
                        MonoChip(text: title.uppercased(), size: 8.5, tint: Theme.accent)
                    }
                    Spacer(minLength: 10)
                    if manifest.screens.count > 1 {
                        HStack(spacing: 5) {
                            Text(selectedScreen?.title ?? "Screen")
                                .font(.system(size: 11, weight: .semibold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                        .appMenu { screenMenu }
                    }
                    if let sourceID = session.sourceDesignSessionID,
                       store.session(sourceID) != nil {
                        ActionButton(title: "Edit Design", tone: .outlined,
                                     height: 28, size: 11, icon: "arrow.up.right") {
                            store.selectSession(sourceID)
                        }
                    }
                    Button { reloadGeneration += 1 } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .appTooltip("Reload Design")
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(Theme.card)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }

                if let artifactRevision,
                   let screen = selectedScreen,
                   let url = DesignManifest.safeURL(for: screen, in: directory) {
                    DesignWebView(
                        url: url,
                        readAccessURL: directory,
                        revision: artifactRevision,
                        reloadGeneration: reloadGeneration,
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
            .task(id: directory.path) { await watch(directory) }
        } else {
            PaneMessage(icon: "paintbrush.pointed",
                        title: "The Design reference is unavailable",
                        detail: "Return to the source Design and create another handoff.")
        }
    }

    private var selectedScreen: DesignScreen? {
        manifest.screens.first { $0.id == selectedScreenID } ?? manifest.screens.first
    }

    private var screenMenu: [MenuEntry] {
        manifest.screens.map { screen in
            .item(screen.title, icon: "rectangle", checked: screen.id == selectedScreenID,
                  subtitle: screen.path) { selectedScreenID = screen.id }
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

    private func watch(_ directory: URL) async {
        while !Task.isCancelled {
            let revision = DesignArtifactRevision.read(directory)
            let nextManifest = DesignManifest.read(from: directory)
            if revision != artifactRevision { artifactRevision = revision }
            if nextManifest != manifest {
                manifest = nextManifest
                if !manifest.screens.contains(where: { $0.id == selectedScreenID }) {
                    selectedScreenID = manifest.screens.first?.id ?? DesignScreen.canvas.id
                }
            }
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
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
                text: (body["text"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
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
