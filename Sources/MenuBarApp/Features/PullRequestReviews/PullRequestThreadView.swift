import AppKit
import SwiftUI

// Folded, a thread is one line: who said it, their first words, and where. Open, it is
// the code, the whole conversation and the reply box.
struct PullRequestThreadView: View {
    @Environment(PullRequestReviewStore.self) private var reviews
    @Environment(\.showExternalNote) private var showExternalNote
    let thread: PullRequestReviewThread
    let review: PullRequestReview
    let entry: PullRequestReviewStore.Loaded
    let sessionID: UUID
    let unfolded: Bool
    let toggle: () -> Void
    let openChanges: () -> Void
    let failed: (String) -> Void

    @State private var hunk: NSAttributedString?
    @State private var reopening = false

    private var answered: Bool { thread.isAnswered(by: reviews.selfLogin) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .center, spacing: Space.md) {
                DisclosureHeader(isExpanded: Binding(get: { unfolded }, set: { _ in toggle() })) { summaryLabel }
                    .frame(maxWidth: .infinity, alignment: .leading)
                GlyphButton(icon: "arrow.up.right", side: ControlHeight.xs) {
                    guard let link = thread.first?.url, let url = URL(string: link) else { return }
                    NSWorkspace.shared.open(url)
                    showExternalNote("Opened on GitHub", "arrow.up.forward.app")
                }
                .appTooltip("Open this thread on GitHub")
            }
            if unfolded {
                // The hunk is read after the thread opens, so it just appears rather than
                // moving the card a second time.
                if let hunk {
                    DiffTextView(text: hunk, fitsContent: true)
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.hairline))
                }
                Group {
                    ForEach(thread.comments) { comment in
                        CommentRow(comment: comment)
                    }
                    if entry.isOpen { footer }
                }
                .transition(.fold)
            }
        }
        .smoothlyResizes(when: unfolded)
        .padding(Space.lg)
        .surface(Theme.card, cornerRadius: Radius.card, border: Theme.hairline)
        .task(id: unfolded) {
            guard unfolded, hunk == nil else { return }
            hunk = await PullRequestReviewHunk.render(thread.diffHunk, path: thread.path)
        }
    }

    // Everything on the line is one line tall and gives way in a fixed order when the
    // card is narrow: the preview of the words shrinks first, then the file name.
    private var summaryLabel: some View {
        HStack(alignment: .center, spacing: Space.md) {
            if let author = thread.first?.author {
                PullRequestReviewerAvatar(reviewer: author, side: 18)
                Text(author.login).font(Typography.label).lineLimit(1).layoutPriority(2)
            }
            if !unfolded {
                Text(thread.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                    .font(Typography.detail).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if thread.comments.count > 1 {
                Text(counted(thread.comments.count - 1, "reply", plural: "replies"))
                    .font(Font.mono(Typography.Size.micro)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(2)
            }
            if reviews.proposals[thread.id] != nil, !answered {
                Image(systemName: "sparkles").font(Font.system(size: Typography.Size.micro)).foregroundStyle(Theme.accent)
            }
            if answered { PullRequestAnsweredTick() }
            Text(thread.place).font(Typography.data).foregroundStyle(.secondary).lineLimit(1)
                .truncationMode(.middle).layoutPriority(1)
        }
    }

    // A resolved thread can be opened again on GitHub; an open one gets the reply box.
    @ViewBuilder private var footer: some View {
        if thread.isResolved {
            HStack(spacing: Space.md) {
                PullRequestAnsweredTick()
                Text("resolved").font(Typography.detail).foregroundStyle(.secondary)
                InlineLink(title: reopening ? "Reopening…" : "Reopen", size: Typography.Size.detail, action: reopen).disabled(reopening)
            }
        } else {
            PullRequestReplyBox(review: review, thread: thread, entry: entry, sessionID: sessionID,
                                openChanges: openChanges, failed: failed)
        }
    }

    private func reopen() {
        reopening = true
        Task {
            if let failure = await PullRequestReviewActions.setResolved(false, thread, on: entry) {
                failed(failure.message)
            } else {
                reviews.setResolved(false, threadID: thread.id, in: sessionID)
            }
            reopening = false
        }
    }
}

private struct CommentRow: View {
    let comment: PullRequestReviewComment

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            PullRequestReviewerAvatar(reviewer: comment.author, side: 18)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    Text(comment.author.login).font(Typography.label)
                    if comment.author.isAutomated { MonoChip(text: "AI", size: Typography.Size.micro, tint: Theme.botStage) }
                    Text(RelativeTime.short(comment.createdAt)).font(Font.mono(Typography.Size.micro)).foregroundStyle(.secondary)
                }
                GitHubProse(comment.body)
            }
        }
        .padding(.leading, Space.xl)
    }
}
