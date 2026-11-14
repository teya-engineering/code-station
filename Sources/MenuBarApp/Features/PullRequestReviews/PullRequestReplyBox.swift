import SwiftUI

// Under every open thread. With a proposal it carries the agent's suggestion and the
// buttons that act on it; without one it is still the way to answer or resolve by hand,
// so nothing waits on an agent.
struct PullRequestReplyBox: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(PullRequestReviewStore.self) private var reviews
    @Environment(DialogPresenter.self) private var dialogs
    let review: PullRequestReview
    let thread: PullRequestReviewThread
    let entry: PullRequestReviewStore.Loaded
    let sessionID: UUID
    let openChanges: () -> Void
    let failed: (String) -> Void

    @State private var reply = ""
    @State private var working = false

    private var proposal: PullRequestReviewProposal? { reviews.proposals[thread.id] }
    private var fix: PullRequestReviewProposal? { proposal?.action == .fix ? proposal : nil }
    private var drafting: Bool { reviews.drafting.contains(thread.id) }
    // A permission prompt or a question in the chat holds the turn, and this tab would
    // otherwise show a spinner for as long as it takes to notice.
    private var agentNeedsYou: Bool {
        runner.question(LiveConversation.id(of: sessionID, store: store, runner: runner)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                Image(systemName: proposal == nil ? "pencil.line" : "sparkles").font(Typography.caption)
                Text(proposal == nil ? "Your reply" : "Agent proposes").font(Typography.label)
                if let action = proposal?.action { MonoChip(text: action.title, size: Typography.Size.micro, tint: action.ink) }
                Spacer(minLength: 0)
                askButton
            }
            .foregroundStyle(.secondary)
            if let fix, !fix.files.isEmpty { filesRow(fix.files) }
            if proposal?.action == .pushback {
                Text("The agent disagrees with the reviewer. Read this one twice before sending it.")
                    .font(Typography.detail).foregroundStyle(Theme.warningText)
            }
            AppTextEditor(text: $reply, placeholder: "Reply to the reviewer…", minHeight: 56)
            buttons
        }
        .padding(Space.lg)
        .surface(Theme.field, cornerRadius: Radius.card, border: Theme.hairline)
        .onAppear { reply = proposal?.reply ?? "" }
        // Asking again replaces the proposal under a box that is still on screen.
        .onChange(of: proposal?.reply) { _, text in
            if let text { reply = text }
        }
    }

    // One agent run per thread, so the answer is about this comment and nothing else.
    // Nothing it does leaves the machine: edits stay uncommitted, the reply stays here.
    @ViewBuilder private var askButton: some View {
        if drafting {
            HStack(spacing: Space.sm) {
                LoopSpinner(size: 14)
                if agentNeedsYou {
                    Text("The agent is waiting for you in the chat.").font(Typography.detail)
                    InlineLink(title: "Open chat", size: Typography.Size.detail) { store.selectSession(sessionID) }
                } else {
                    Text("Agent is working…").font(Typography.detail)
                }
            }
        } else if store.session(sessionID) != nil {
            InlineLink(title: proposal == nil ? "Ask the agent" : "Ask again", size: Typography.Size.detail, icon: "sparkles", action: ask)
                .appTooltip("The agent reads this comment, edits the checkout without committing, and writes a reply here for you to approve.")
                .disabled(reviews.busy.contains(entry.pullRequest.url) || proposal?.changes?.files.isEmpty == false)
        }
    }

    private func filesRow(_ files: [String]) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: "doc.text").font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary)
            Text(files.joined(separator: ", ")).font(Typography.data).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 4)
            InlineLink(title: "Show the diff", size: Typography.Size.detail, action: openChanges)
        }
    }

    private var buttons: some View {
        HStack(spacing: Space.md) {
            if let fix {
                ActionButton(title: "Approve: commit, push and reply", tone: .green, height: ControlHeight.md, size: Typography.Size.detail, icon: "checkmark") {
                    run(resolves: false) {
                        await PullRequestReviewActions.approve(fix, reply: reply, thread: thread, on: entry,
                                                               sessionID: sessionID, store: store)
                    }
                }
            }
            ActionButton(title: fix == nil ? "Send reply" : "Reply only", tone: .dark, height: ControlHeight.md, size: Typography.Size.detail) {
                run(resolves: false) { await PullRequestReviewActions.reply(reply, thread: thread, on: entry) }
            }
            .disabled(reply.trimmed.isEmpty)
            if working { LoopSpinner(size: 14) }
            Spacer(minLength: 0)
            // Done without a word. A fix is put back first, so nothing stray stays in the checkout.
            InlineLink(title: fix == nil ? "Resolve" : "Discard and resolve", size: Typography.Size.detail, tint: .secondary) {
                if let fix, !fix.files.isEmpty { confirmDiscard(fix) }
                else { resolve(discarding: nil) }
            }
        }
        .disabled(working || reviews.busy.contains(entry.pullRequest.url) || runner.isBusy(sessionID, store: store))
    }

    private func confirmDiscard(_ fix: PullRequestReviewProposal) {
        var rows = fix.files.map { Dialog.Impact.Row(title: $0, detail: "The proposal's edits will be removed.") }
        rows.append(.init(title: "Earlier edits and staged work", detail: "Changes made before the draft stay.", kept: true))
        dialogs.show(.impact("Discard this proposal and resolve the thread?",
                             subject: .init(name: entry.pullRequest.repository ?? "Repository"), rows: rows,
                             warning: "The proposal's edits cannot be restored from this screen.", action: "Discard and resolve") {
            resolve(discarding: fix)
        })
    }

    private func resolve(discarding fix: PullRequestReviewProposal?) {
        run(resolves: true) {
            if let fix, let failure = await PullRequestReviewActions.discard(fix, on: entry, sessionID: sessionID, store: store) {
                return failure
            }
            return await PullRequestReviewActions.setResolved(true, thread, on: entry)
        }
    }

    private func ask() {
        Task {
            let outcome = await PullRequestReviewDrafter.draft(review: review, thread: thread, on: entry,
                                                               sessionID: sessionID, store: store, runner: runner,
                                                               reviews: reviews)
            if let message = outcome.failureMessage { failed(message) }
        }
    }

    // After a click the screen says what GitHub now holds: the reply as the last word,
    // or the thread resolved. The next read says the same.
    private func run(resolves: Bool, _ work: @escaping () async -> PullRequestReviewActions.Failure?) {
        let url = entry.pullRequest.url
        guard reviews.beginWork(on: url) else { return }
        working = true
        let sent = reply
        Task {
            let failure = await work()
            working = false
            reviews.endWork(on: url)
            if let failure {
                failed(failure.message)
                return
            }
            reviews.dropProposal(thread.id)
            if resolves {
                reviews.setResolved(true, threadID: thread.id, in: sessionID)
            } else {
                reviews.noteReply(sent, threadID: thread.id, in: sessionID)
            }
        }
    }
}
