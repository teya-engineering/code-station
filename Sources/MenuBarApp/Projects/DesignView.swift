import AppKit
import SwiftUI
import WebKit

// A Design conversation keeps the agent loop on the left and turns its durable HTML
// artifact into a live canvas on the right.
struct DesignView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(\.textScale) private var textScale

    let sessionID: UUID

    @State private var artifactRevision: DesignArtifactRevision?
    @State private var reloadGeneration = 0
    @State private var composerFocused = false
    @State private var dropTargeted = false
    @State private var conversationWidth = DesignSplitLayout.defaultConversationWidth
    @State private var dragStartConversationWidth: CGFloat?

    var body: some View {
        if let session = store.session(sessionID),
           let artifactURL = store.designArtifactURL(for: session) {
            GeometryReader { geometry in
                let width = DesignSplitLayout.conversationWidth(
                    conversationWidth, availableWidth: geometry.size.width)

                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        conversation(session, width: width)
                            .frame(width: width)
                            .clipped()
                        Divider().overlay(Theme.hairline)
                        canvas(artifactURL)
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
            .onDisappear { store.release(sessionID, for: .open) }
            .task(id: sessionID) { await store.transcriptReady(sessionID) }
            .task(id: artifactURL.path) { await watchArtifact(artifactURL) }
        } else {
            PaneMessage(icon: "paintbrush.pointed",
                        title: "This Design session is gone",
                        detail: "Choose another session from the sidebar.")
        }
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
                                .foregroundStyle(ChatColor.warningText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Spacer(minLength: 0)
                                ActionButton(title: "Dismiss", tone: .outlined,
                                             height: 27, size: 11) {
                                    runner.dismissFailure(sessionID)
                                }
                            }
                        }
                        .padding(11)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(ChatColor.warningBackground))
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
                        runner.stop(sessionID, store: store)
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

    private func canvas(_ artifactURL: URL) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("CANVAS")
                    .font(.mono(10, .semibold))
                    .kerning(1)
                    .foregroundStyle(.secondary)
                if artifactRevision != nil {
                    StatusDot()
                    Text("index.html")
                        .font(.mono(10.5))
                        .foregroundStyle(.secondary)
                        .appTooltip(artifactURL.path)
                }

                Spacer(minLength: 10)

                if artifactRevision != nil {
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

            if let artifactRevision {
                canvasPreview(artifactURL, revision: artifactRevision)
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

    private func canvasPreview(_ url: URL, revision: DesignArtifactRevision) -> some View {
        DesignWebView(url: url,
                      revision: revision,
                      reloadGeneration: reloadGeneration)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
    }

    private func watchArtifact(_ url: URL) async {
        while !Task.isCancelled {
            let revision = DesignArtifactRevision.read(url)
            if revision != artifactRevision { artifactRevision = revision }
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
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

struct DesignArtifactRevision: Equatable {
    let modified: Date
    let size: Int

    static func read(_ url: URL) -> DesignArtifactRevision? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true,
              let modified = values.contentModificationDate else { return nil }
        return DesignArtifactRevision(modified: modified, size: values.fileSize ?? 0)
    }
}

private struct DesignWebView: NSViewRepresentable {
    let url: URL
    let revision: DesignArtifactRevision
    let reloadGeneration: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .white
        webView.isInspectable = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let key = "\(url.path):\(revision.modified.timeIntervalSinceReferenceDate):"
            + "\(revision.size):\(reloadGeneration)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedKey: String?

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable
                        (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            decisionHandler(["file", "about", "data", "blob"].contains(scheme ?? "")
                ? .allow : .cancel)
        }
    }
}
