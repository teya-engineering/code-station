import SwiftUI
import CodeStationCore

struct ChangesReviewNavigator: View {
    let review: ReviewTarget
    let orderedComments: [ReviewComment]
    let navigation: ChangesNavigationMemory
    let fileLabel: (ReviewComment) -> String
    let focus: (ReviewComment) -> Void

    private var focusedComment: UUID? { navigation.focusedComment }
    private var reviewFilter: ReviewFilter {
        get { navigation.reviewFilter }
        nonmutating set { navigation.reviewFilter = newValue }
    }

    var body: some View {
        let all = orderedComments.filter { !$0.isPending }
        let list = all.filter(reviewFilter.admits)
        let threads = review.reviews.threads(review.sessionID)
        VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 4) {
                filterPill("All", .all, count: all.count)
                filterPill("Yours", .yours, count: all.count { $0.reviewer == nil })
                filterPill("From reviewers", .reviewers, count: all.count { $0.reviewer != nil })
            }
            .padding(.horizontal, 12).padding(.top, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if list.isEmpty && threads.isEmpty {
                            VStack(spacing: 6) {
                                if reviewFilter == .reviewers {
                                    Text("Nothing from reviewers yet").font(.system(size: 12.5, weight: .semibold))
                                    Text("Ask for a second opinion from the review bar. What you keep shows up here.")
                                } else {
                                    Text("No changes waiting").font(.system(size: 12.5, weight: .semibold))
                                    Text("Click a line number and choose Request a change, turn a question's suggestion into a change, or ask another agent for a second opinion.")
                                }
                            }
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 12)
                        }
                        if !threads.isEmpty, !list.isEmpty {
                            ReviewGroupHeader(title: "Not sent yet", count: list.count)
                        }
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, comment in
                            if index == 0 || ReviewRound.fileKey(root: list[index - 1].root, path: list[index - 1].path)
                                != ReviewRound.fileKey(root: comment.root, path: comment.path) {
                                HStack(spacing: 6) {
                                    Text(fileLabel(comment)).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text("\(all.count { $0.root == comment.root && $0.path == comment.path })")
                                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 6).padding(.top, index == 0 ? 2 : 8)
                            }
                            reviewItem(comment)
                                .id(comment.id)
                        }
                        if !threads.isEmpty {
                            ReviewGroupHeader(title: "Sent to \(review.agent.title)", count: threads.count)
                            ForEach(threads.reversed(), id: \.comment.id) { round, comment in
                                threadItem(comment, round: round, agent: review.agent)
                                    .id(comment.id)
                            }
                        }
                    }
                    .padding(10)
                }
                .onChange(of: focusedComment) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    // A sent comment in the list: where it is, where it stands, and the last word on it.
    private func threadItem(_ comment: ReviewComment, round: ReviewRound, agent: AgentKind) -> some View {
        let isFocused = focusedComment == comment.id
        let unread = round.unread.contains(comment.id)
        let status = round.status(comment.id)
        let last = round.replies(comment.id).last
        let lines = comment.onFile ? "" : comment.lastLine.map { "\(comment.line)–\($0)" } ?? "\(comment.line)"
        return Button { focus(comment) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if unread { Circle().fill(Theme.plan).frame(width: 6, height: 6) }
                    (Text(fileLabel(comment)).foregroundStyle(.primary).fontWeight(.medium) + Text(" " + lines))
                        .font(.mono(10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    ReviewStatusChip(status: status)
                }
                ReviewText(text: comment.body, size: 12, lineLimit: 1)
                if let last, !last.body.isBlank {
                    Text((last.author == .agent ? agent.title : "You") + ": " + last.body)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isFocused ? Theme.accent.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isFocused ? Theme.accent.opacity(0.3) : .clear))
            .opacity(status == .resolved ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 8)
        .accessibilityLabel(ReviewThreadView.spokenName(status: status, comment: comment,
                                                        fileName: fileLabel(comment), unread: unread))
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    private func filterPill(_ title: String, _ filter: ReviewFilter, count: Int) -> some View {
        ChoicePill(title: "\(title) \(count)", selected: reviewFilter == filter) { reviewFilter = filter }
    }

    private func reviewItem(_ comment: ReviewComment) -> some View {
        let isFocused = focusedComment == comment.id
        return Button { focus(comment) } label: {
            HStack(alignment: .top, spacing: 8) {
                ReviewAvatars(comment: comment, size: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(comment.authorName).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        Text(comment.onFile ? "file" : comment.lastLine.map { "\(comment.line)–\($0)" } ?? "\(comment.line)")
                            .font(.mono(10.5)).foregroundStyle(.secondary)
                        if comment.kind == .question { QuestionTag() }
                        if let severity = comment.severity { SeverityChip(severity: severity) }
                    }
                    ReviewText(text: comment.body, size: 11.5, lineLimit: 2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isFocused ? Theme.accent.opacity(0.08) : .clear))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(comment.isPending ? Theme.attention.opacity(0.6) : isFocused ? Theme.accent.opacity(0.3) : .clear,
                                  style: StrokeStyle(lineWidth: 1, dash: comment.isPending ? [4, 3] : []))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 8)
        .accessibilityLabel(comment.spokenName + ". " + comment.body)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

}

struct ReviewGroupHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6).padding(.top, 8)
        .accessibilityAddTraits(.isHeader)
    }

}
