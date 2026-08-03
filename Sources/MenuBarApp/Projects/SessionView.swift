import SwiftUI

// The detail pane for one Claude Code conversation: the transcript on the left tab,
// the working tree diff on the right one.
struct SessionView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    let sessionID: UUID

    private enum Tab: Hashable { case chat, changes }

    @State private var tab: Tab = .chat
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private let bottomAnchor = "transcript-bottom"

    var body: some View {
        // The sidebar can delete a session or its project while it is on screen.
        if let session = store.session(sessionID), let project = store.project(session.projectID) {
            VStack(spacing: 0) {
                header(session: session, project: project)
                Divider().overlay(Theme.hairline)
                warningStrip(for: project)

                switch tab {
                case .chat:
                    transcript(session)
                    Divider().overlay(Theme.hairline)
                    composer(project: project)
                case .changes:
                    ChangesView(project: project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.background)
            .onAppear { composerFocused = true }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("This session is gone").font(.serif(22))
            }
        }
    }

    // MARK: - Header

    private func header(session: ChatSession, project: Project) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.serif(22, .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 8) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                    Text(project.collapsedPath)
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            if runner.state(sessionID).isBusy {
                Button {
                    runner.stop(sessionID)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(ChatColor.error)
            }

            Picker("", selection: $tab) {
                Text("Chat").tag(Tab.chat)
                Text("Changes").tag(Tab.changes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.card)
    }

    @ViewBuilder private func warningStrip(for project: Project) -> some View {
        if store.isMissing(project) {
            strip("Folder not found at \(project.collapsedPath). Move it back or remove the project.")
        } else if !runner.available {
            strip("Claude Code CLI not found on PATH. Sessions cannot run until it is installed.")
        }
    }

    private func strip(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ChatColor.warningText)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(ChatColor.warningBackground)
    }

    // MARK: - Transcript

    private func transcript(_ session: ChatSession) -> some View {
        let state = runner.state(sessionID)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if session.messages.isEmpty {
                        Text("Ask for a change. Claude Code runs in the project folder, so what it edits is your working tree.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }

                    ForEach(session.messages) { message in
                        MessageView(message: message)
                    }

                    if showsThinking(session, state: state) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // A failed run belongs in the flow of the conversation, not in a dialog.
                    if case .failed(let message) = state {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(message)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ChatColor.warningText)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(ChatColor.warningBackground))
                    }

                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            .onChange(of: session.messages.count) { scrollToBottom(proxy, animated: true) }
            .onChange(of: session.messages.last?.text ?? "") { scrollToBottom(proxy, animated: false) }
            .onChange(of: session.messages.last?.tools.count ?? 0) { scrollToBottom(proxy, animated: false) }
            .onChange(of: state) { scrollToBottom(proxy, animated: true) }
        }
    }

    // While a turn is starting there is no assistant message yet, and while tools run
    // there is one with no text in it. Both should look like Claude is working.
    private func showsThinking(_ session: ChatSession, state: SessionState) -> Bool {
        guard state.isBusy else { return false }
        guard let last = session.messages.last, last.role == .assistant else { return true }
        return last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        // Animating every streamed token makes the transcript jitter, so only the
        // arrival of a whole message is worth animating.
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - Composer

    private func composer(project: Project) -> some View {
        let blocked = store.isMissing(project) || !runner.available
        let busy = runner.state(sessionID).isBusy
        let canSend = !busy && !blocked && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return HStack(alignment: .bottom, spacing: 10) {
            // A vertical-axis TextField gives us return-to-send and shift-return for a
            // newline for free; TextEditor would need an NSView to intercept the key.
            TextField(busy ? "Claude Code is working…" : "Ask Claude Code to change something", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...10)
                .focused($composerFocused)
                .disabled(busy || blocked)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.black.opacity(canSend ? 0.88 : 0.22)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send (shift-return for a new line)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.card)
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !runner.state(sessionID).isBusy else { return }
        runner.send(prompt, sessionID: sessionID, store: store)
        draft = ""
    }
}
