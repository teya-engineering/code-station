import AppKit
import SwiftUI

extension ChangesView {
    // MARK: Whole change

    func openWholeChangeThread(_ id: UUID) {
        navigation.askExpanded = id
        navigation.setAskingWholeChange(true)
    }

    func closeWholeChangeCard() {
        navigation.citation = nil
        navigation.setAskingWholeChange(false)
    }

    // A follow-up goes into the thread it was started from; anything else starts a thread.
    private func askAboutWholeChange(_ text: String, review: ReviewTarget) {
        let context = questionContext(review)
        if let id = navigation.askFollowing, review.reviews.question(id, in: review.sessionID) != nil {
            review.reviews.followUp(text, to: id, context: context, in: review.sessionID)
            navigation.askExpanded = id
            announce("Asked a follow-up. The answer appears in this card.")
        } else {
            let question = ReviewQuestion.whole(root: repoRoot, agent: review.agent, question: text)
            review.reviews.ask(question, context: context, in: review.sessionID)
            navigation.askExpanded = question.id
            announce("Asked. The answer appears in this card.")
        }
        navigation.askDraft = ""
        navigation.askFollowing = nil
    }

    // The card hangs off the top of the screen, just under the header button that opens
    // it.
    var wholeChangeCard: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                if navigation.askingWholeChange, let review {
                    let threads = WholeChangeThreads.split(review.reviews.questions(review.sessionID))
                    WholeChangeAskCard(
                        navigation: navigation, open: threads.open, resolved: threads.resolved,
                        scope: changeScope,
                        agentTitle: review.agent.title,
                        forksConversation: review.agent == .claudeCode,
                        maxHeight: max(proxy.size.height - 27, 200),
                        ask: { askAboutWholeChange($0, review: review) },
                        escape: escapeWholeChangeCard,
                        close: closeWholeChangeCard) { question, expanded in
                            wholeChangeThread(question, expanded: expanded, review: review)
                        }
                        .environment(\.openURL, OpenURLAction { citeFile($0) })
                        .environment(\.linkHovered, LinkHoverAction { url in
                            navigation.citeHover = url.flatMap(resolveCitation)
                        })
                        .padding(.trailing, Space.xxl).padding(.top, Space.sm)
                        .transition(.popover(reduceMotion: reduceMotion))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private var changeScope: [WholeChangeAskScope] {
        repositories.compactMap { repository in
            let files = changes(in: repository.root)
            guard !files.isEmpty else { return nil }
            return WholeChangeAskScope(name: repository.name, files: files.count,
                                       added: files.reduce(0) { $0 + ($1.added ?? 0) },
                                       removed: files.reduce(0) { $0 + ($1.removed ?? 0) })
        }
    }

    // Esc stops an answer under way first, so the card does not vanish with it running.
    func escapeWholeChangeCard() {
        if let review, let running = WholeChangeThreads.split(review.reviews.questions(review.sessionID)).open
            .last(where: { $0.status == .answering }) {
            stopAnswering(running, review: review)
            return
        }
        closeWholeChangeCard()
    }

    // A stopped question goes back to the field to be asked in other words. A follow-up
    // is taken back from its thread; a first question takes its thread with it.
    func editWholeChangeQuestion(_ question: ReviewQuestion, review: ReviewTarget) {
        if let text = review.reviews.withdrawFollowUp(question.id, in: review.sessionID) {
            navigation.askDraft = text
            navigation.askFollowing = question.id
        } else {
            navigation.askDraft = question.exchanges.last?.question ?? question.text
            navigation.askFollowing = nil
            review.reviews.deleteQuestion(question.id, in: review.sessionID)
        }
        announce("The question is back in the field")
    }

    private func resolveCitation(_ url: URL) -> ChangeCitation? {
        ChangeCitation.resolve(url, roots: repositories.map(\.root)) { root, path in
            changes(in: root).contains { $0.path == path }
        }
    }

    func answerReferences(_ answer: String) -> [AnswerReference] {
        let names = Dictionary(repositories.map { ($0.root, $0.name) }, uniquingKeysWith: { first, _ in first })
        return ChangeCitation.references(in: answer, roots: repositories.map(\.root)) { root, path in
            changes(in: root).contains { $0.path == path }
        }
        .map { AnswerReference(citation: $0, tint: Theme.projectTint(for: names[$0.root] ?? "")) }
    }

    @ViewBuilder
    private func wholeChangeThread(_ question: ReviewQuestion, expanded: Bool, review: ReviewTarget) -> some View {
        if expanded || question.resolved {
            questionThread(question, review: review, showsBand: false, inCard: true, startFollowUp: {
                navigation.askFollowing = question.id
            })
        } else {
            WholeChangeFoldedThread(question: question, open: { navigation.askExpanded = question.id }) {
                questionBadge(question, review: review)
            }
        }
    }

    // A file named in an answer opens in the diff under the card, with the lines it names
    // lit, so the answer and the code can be read side by side. A file outside the change
    // opens the usual way.
    private func citeFile(_ url: URL) -> OpenURLAction.Result {
        guard let citation = resolveCitation(url) else { return .systemAction }
        showCitation(citation)
        return .handled
    }

    func showCitation(_ found: ChangeCitation) {
        var citation = found
        citation.serial = (navigation.citation?.serial ?? 0) + 1
        navigation.citation = citation
        if commentDraft?.text.isBlank != false { commentDraft = nil }
        guard citation.root == root else {
            selectRepository(citation.root, citation.path)
            return
        }
        if selected?.path != citation.path, let file = files.first(where: { $0.path == citation.path }) {
            mode = .changes
            select(file)
        }
        announce("Showing \(citation.fileName)" + (citation.anchor.map { ", \($0.label.lowercased())" } ?? ""))
    }

    private func questionBadge(_ question: ReviewQuestion, review: ReviewTarget) -> some View {
        let sent = question.changeID.map { review.reviews.round(sending: $0, in: review.sessionID) != nil } ?? false
        let waiting = question.changeID.map { review.reviews.comment($0, in: review.sessionID) != nil } ?? false
        let (text, ink): (String, Color) = switch question.status {
        case .answering: ("Answering…", Color.secondary)
        case .failed: ("Couldn't answer", Theme.warningText)
        case .stopped: ("Stopped", Color.secondary)
        case .answered:
            sent ? ("Became a change", Theme.accent)
                : waiting ? ("Change in review", Theme.accent)
                : question.resolved ? ("Resolved", Color.secondary) : ("Answered", Theme.plan)
        }
        return Text(text)
            .font(Typography.caption.weight(.semibold)).foregroundStyle(ink)
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
            .background(Capsule().fill(ink.opacity(0.12)))
            .lineLimit(1).fixedSize()
    }
}
