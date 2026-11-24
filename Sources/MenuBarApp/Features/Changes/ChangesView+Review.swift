import AppKit
import SwiftUI

extension ChangesView {
    // MARK: - Review

    private var openFileComments: [ReviewComment] {
        guard let review, let file = shownFile else { return [] }
        return inlineComments(review, path: file.path)
    }

    // A change made from a question's answer is drawn inside the question's thread, so it
    // is left out of the cards while the question is still there.
    private func inlineComments(_ review: ReviewTarget, path: String) -> [ReviewComment] {
        let asked = Set(review.reviews.questions(review.sessionID).map(\.id))
        return review.reviews.comments(review.sessionID, root: repoRoot, path: path)
            .filter { $0.questionID.map { !asked.contains($0) } ?? true }
    }

    private var openFileQuestions: [ReviewQuestion] {
        guard let review, let file = shownFile else { return [] }
        return review.reviews.questions(review.sessionID, root: repoRoot, path: file.path)
    }

    // Questions hang under their lines the way comments do. One whose code has left the
    // diff is still in the Questions list.
    static func placeQuestions(_ questions: [ReviewQuestion], in lines: [DiffLine]) -> [Int: [ReviewQuestion]] {
        guard !questions.isEmpty else { return [:] }
        let numbered = NumberedDiffLine.lines(lines)
        var below: [Int: [ReviewQuestion]] = [:]
        for question in questions.sorted(by: { $0.created < $1.created }) where !question.isWhole {
            if let found = ReviewPlacement.locate(question.anchor, excerpt: question.excerpt,
                                                  excerptOffsets: question.excerptOffsets, in: numbered) {
                below[found.lastID, default: []].append(question)
            }
        }
        return below
    }

    // Sent comments stay under their lines as threads. One whose code has left the diff
    // is still in the review list, so it is not listed again above the diff.
    private var openFileThreads: [(round: ReviewRound, comment: ReviewComment)] {
        guard let review, let file = shownFile else { return [] }
        return review.reviews.threads(review.sessionID, root: repoRoot, path: file.path)
    }

    // Placing walks the whole diff, so `body` asks for this once and hands it to
    // everything it draws.
    var placements: DiffPlacements {
        guard let diff = model.diff else { return DiffPlacements() }
        return DiffPlacements(comments: ReviewPlacement.place(openFileComments, in: diff.lines),
                              sent: ReviewPlacement.place(openFileThreads.map(\.comment), in: diff.lines),
                              questions: Self.placeQuestions(openFileQuestions, in: diff.lines))
    }

    var pickedKeys: Set<String> {
        commentDraft.map { DiffComments.keys($0.anchor) } ?? citedAnchor.map(DiffComments.keys) ?? []
    }

    // The lines the cited reference names, while its file is the one on screen.
    private var citedAnchor: DiffAnchor? {
        guard let citation = navigation.citation, citation.root == root,
              citation.path == shownFile?.path else { return nil }
        return citation.anchor
    }

    // Every comment in the review, in the order they are read and stepped through.
    var orderedComments: [ReviewComment] {
        guard let review else { return [] }
        return ReviewOrder.sorted(review.reviews.comments(review.sessionID), roots: repositories.map(\.root))
    }

    // The id of the diff line a new comment's composer opens under: the last of its lines.
    private func lineID(for anchor: DiffAnchor, in lines: [DiffLine]) -> Int? {
        let last = anchor.lastLine ?? anchor.line
        return NumberedDiffLine.lines(lines).first { $0.side == anchor.side && $0.number == last }?.id
    }

    // The lines a thread hangs from: those with comments placed under them, and the one a
    // comment is being written about.
    private func threadLines(placement: ReviewPlacement, sent: ReviewPlacement, asked: [Int: [ReviewQuestion]],
                             lines: [DiffLine], path: String?) -> Set<Int> {
        var ids = Set(placement.below.keys).union(sent.below.keys).union(asked.keys)
        if let draft = commentDraft, draft.path == path, draft.editing == nil,
           let id = lineID(for: draft.anchor, in: lines) {
            ids.insert(id)
        }
        return ids
    }

    func threadLineIDs(_ placed: DiffPlacements) -> Set<Int> {
        guard review != nil, mode == .changes, let diff = model.diff else { return [] }
        return threadLines(placement: placed.comments, sent: placed.sent, asked: placed.questions, lines: diff.lines,
                           path: shownFile?.path)
    }

    func diffComments(for file: GitChange?, lines: [DiffLine]) -> DiffComments? {
        guard let review else { return nil }
        let comments = file.map { inlineComments(review, path: $0.path) } ?? []
        let sent = file.map { review.reviews.threads(review.sessionID, root: repoRoot, path: $0.path).map(\.comment) } ?? []
        let asked = file.map { review.reviews.questions(review.sessionID, root: repoRoot, path: $0.path) } ?? []
        return DiffComments(threads: threadLines(placement: ReviewPlacement.place(comments, in: lines),
                                                 sent: ReviewPlacement.place(sent, in: lines),
                                                 asked: Self.placeQuestions(asked, in: lines), lines: lines,
                                                 path: file?.path))
    }

    // What hangs under each line: its cards, and the composer where one is being written.
    // An existing comment opened to edit turns into the composer in its own place.
    func threadViews(_ review: ReviewTarget, _ placed: DiffPlacements) -> [Int: AnyView] {
        guard let diff = model.diff else { return [:] }
        let placement = placed.comments
        let sent = placed.sent
        let asked = placed.questions
        let rounds = Dictionary(openFileThreads.map { ($0.comment.id, $0.round) }, uniquingKeysWith: { first, _ in first })
        var views: [Int: AnyView] = [:]
        let draftLine: Int? = {
            guard let draft = commentDraft, draft.path == shownFile?.path else { return nil }
            if let editing = draft.editing {
                return placement.below.first { $0.value.contains { $0.id == editing } }?.key
            }
            return lineID(for: draft.anchor, in: diff.lines)
        }()
        for id in threadLines(placement: placement, sent: sent, asked: asked, lines: diff.lines,
                              path: shownFile?.path) {
            let comments = placement.below[id] ?? []
            let threads = (sent.below[id] ?? []).compactMap { comment in rounds[comment.id].map { ($0, comment) } }
            views[id] = AnyView(VStack(alignment: .leading, spacing: Space.md) {
                ForEach(asked[id] ?? []) { question in
                    questionThread(question, review: review)
                }
                ForEach(threads, id: \.1.id) { round, comment in
                    thread(comment, round: round, review: review)
                }
                ForEach(comments) { comment in
                    if commentDraft?.editing == comment.id {
                        composer(review)
                    } else {
                        card(comment, review: review)
                    }
                }
                if draftLine == id, commentDraft?.editing == nil { composer(review) }
            })
        }
        return views
    }

    func revealedLine(_ placed: DiffPlacements) -> DiffReveal? {
        if commentDraft == nil, let anchor = citedAnchor, let citation = navigation.citation, let diff = model.diff,
           let id = lineID(for: DiffAnchor(side: anchor.side, line: anchor.line), in: diff.lines) {
            return DiffReveal(line: id, serial: citation.serial, key: DiffComments.key(DiffAnchor(side: anchor.side, line: anchor.line)))
        }
        if let key = freshRevealKey, let anchor = DiffComments.anchor(key), let diff = model.diff,
           let id = lineID(for: anchor, in: diff.lines) {
            return DiffReveal(line: id, serial: freshRevealSerial, key: key, flash: freshRevealFlash)
        }
        guard let focusedComment = navigation.focusedComment,
              let line = placed.comments.below.first(where: { $0.value.contains { $0.id == focusedComment } })?.key
                ?? placed.sent.below.first(where: { $0.value.contains { $0.id == focusedComment } })?.key
                ?? placed.questions.first(where: { $0.value.contains { $0.id == focusedComment } })?.key
        else { return nil }
        return DiffReveal(line: line, serial: revealSerial)
    }

    private func thread(_ comment: ReviewComment, round: ReviewRound, review: ReviewTarget) -> some View {
        let focused = navigation.focusedComment == comment.id
        return ReviewThreadView(
            round: round, comment: comment, agent: review.agent, fileName: fileLabel(comment),
            working: review.isBusy(), showsQuote: false, focused: focused,
            projectPath: repoRoot, textScale: appSettings.textSize.scale,
            reply: { replyInThread($0, to: comment, round: round, review: review) },
            resolve: {
                review.reviews.resolve(comment.id, round: round.id, in: review.sessionID)
                announce("Resolved")
            },
            reopen: { review.reviews.reopen(comment.id, round: round.id, in: review.sessionID) })
            .padding(.bottom, Space.xxs)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.card))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(focused ? Theme.accent : Theme.border, lineWidth: focused ? 2 : 1))
            .onTapGesture {
                navigation.focusedComment = comment.id
                review.reviews.markRead(comment.id, in: review.sessionID)
            }
    }

    // A reply goes to the agent at once, as a turn of its own about those lines.
    private func replyInThread(_ text: String, to comment: ReviewComment, round: ReviewRound, review: ReviewTarget) {
        let names = projectNames
        Task {
            guard let prompt = await review.reviews.reply(text, to: comment.id, round: round.id, in: review.sessionID,
                                                          projectNames: names) else { return }
            let busy = review.isBusy()
            review.send(prompt)
            announce(busy ? "Reply queued for \(review.agent.title)" : "Reply sent to \(review.agent.title)")
        }
    }

    private func card(_ comment: ReviewComment, review: ReviewTarget, showsLines: Bool = true) -> some View {
        ReviewCommentCard(comment: comment, focused: navigation.focusedComment == comment.id, showsLines: showsLines,
                          onEdit: { openComment(comment) },
                          onDelete: { deleteComment(comment) },
                          onKeep: { keep(comment) },
                          onDismiss: { dismiss(comment) })
            .onTapGesture { navigation.focusedComment = comment.id }
    }

    @ViewBuilder private func composer(_ review: ReviewTarget) -> some View {
        if let draft = commentDraft {
            let editing = draft.editing.flatMap { review.reviews.comment($0, in: review.sessionID) }
            let finding = editing?.isPending == true ? editing : nil
            ReviewComposer(
                text: Binding(get: { commentDraft?.text ?? "" }, set: { commentDraft?.text = $0 }),
                kind: Binding(get: { commentDraft?.kind ?? .change }, set: { commentDraft?.kind = $0 }),
                title: finding.map { "Edit \($0.authorName)'s finding" } ?? (editing == nil ? "New comment" : "Edit comment"),
                linesLabel: draft.anchor.label,
                agentTitle: review.agent.title,
                action: finding != nil ? "Keep with my edits" : editing == nil ? "Add comment" : "Save",
                stretches: editing == nil,
                place: place(root: repoRoot, path: draft.path, anchor: draft.anchor),
                forksConversation: review.agent == .claudeCode,
                onDelete: editing != nil && finding == nil ? { if let editing { deleteComment(editing) } } : nil,
                onSave: saveComment,
                onCancel: { commentDraft = nil })
        }
    }

    func pickLine(_ anchor: DiffAnchor, extending: Bool) {
        guard let file = shownFile else { return }
        if let id = reattaching {
            moveUnplaced(id, to: anchor)
            return
        }
        coachSeen = true
        navigation.focusedComment = nil
        // A saved comment keeps the lines it was left on, so only a new one stretches.
        if extending, let draft = commentDraft, draft.path == file.path, draft.editing == nil {
            let stretched = draft.anchor.extended(to: anchor)
            let quote = excerpt(stretched)
            commentDraft?.anchor = stretched
            commentDraft?.excerpt = quote.text
            commentDraft?.excerptOffsets = quote.offsets
        } else {
            openDraft(at: anchor, in: file)
        }
    }

    // A drag down the numbers picks the whole run at once.
    func pickRange(_ anchor: DiffAnchor) {
        guard let file = shownFile else { return }
        if let id = reattaching {
            moveUnplaced(id, to: anchor)
            return
        }
        coachSeen = true
        navigation.focusedComment = nil
        openDraft(at: anchor, in: file)
    }

    // A note part way written moves to the new lines rather than being dropped.
    private func openDraft(at anchor: DiffAnchor, in file: GitChange) {
        let quote = excerpt(anchor)
        if let draft = commentDraft, draft.path == file.path, draft.editing == nil, !draft.text.isBlank {
            commentDraft?.anchor = anchor
            commentDraft?.excerpt = quote.text
            commentDraft?.excerptOffsets = quote.offsets
        } else {
            commentDraft = CommentDraft(anchor: anchor, path: file.path, excerpt: quote.text,
                                        excerptOffsets: quote.offsets)
        }
    }

    // A diff read again under a note being written can have moved its lines. The note
    // follows its code there, so it is still saved against the lines it was written for.
    func followDraft() {
        guard let draft = commentDraft, draft.editing == nil, draft.path == shownFile?.path,
              let lines = model.diff?.lines,
              let found = ReviewPlacement.locate(draft.anchor, excerpt: draft.excerpt,
                                                 excerptOffsets: draft.excerptOffsets,
                                                 in: NumberedDiffLine.lines(lines)),
              found.anchor != draft.anchor else { return }
        commentDraft?.anchor = found.anchor
    }

    private func openComment(_ comment: ReviewComment) {
        guard comment.root == repoRoot else {
            focus(comment)
            return
        }
        if selected?.path != comment.path, let file = files.first(where: { $0.path == comment.path }) {
            mode = .changes
            select(file)
        }
        navigation.focusedComment = nil
        commentDraft = CommentDraft(anchor: comment.anchor, path: comment.path,
                                    excerpt: comment.excerpt, excerptOffsets: comment.excerptOffsets,
                                    text: comment.body, kind: comment.kind, editing: comment.id)
    }

    // The code a comment is about, quoted with it so the agent sees what was meant even
    // if the lines have moved by the time it reads them.
    private func excerpt(_ anchor: DiffAnchor) -> (text: String, offsets: [Int]) {
        NumberedDiffLine.excerpt(anchor, in: model.diff?.lines ?? [])
    }

    private func saveComment() {
        guard let review, let draft = commentDraft, !draft.text.isBlank else { return }
        if let id = draft.editing {
            let wasPending = review.reviews.comment(id, in: review.sessionID)?.isPending == true
            review.reviews.update(id, body: draft.text.trimmed, kind: draft.kind, in: review.sessionID)
            commentDraft = nil
            if wasPending {
                announce("Kept with your edits")
                afterTriage(from: id)
                return
            }
            announce("Comment saved")
        } else if draft.kind == .question {
            let question = ReviewQuestion(root: repoRoot, path: draft.path, anchor: draft.anchor, excerpt: draft.excerpt,
                                          excerptOffsets: draft.excerptOffsets, agent: review.agent,
                                          question: draft.text.trimmed)
            review.reviews.ask(question, context: questionContext(review), in: review.sessionID)
            commentDraft = nil
            navigation.focusedComment = question.id
            announce("Asked. The answer appears under the lines and stays here.")
        } else {
            commentDraft = nil
            sendChange(ReviewComment(root: repoRoot, path: draft.path, anchor: draft.anchor,
                                     excerpt: draft.excerpt, body: draft.text.trimmed,
                                     excerptOffsets: draft.excerptOffsets, kind: draft.kind),
                       review: review)
        }
    }

    private func deleteComment(_ comment: ReviewComment) {
        guard let review else { return }
        review.reviews.remove(comment.id, from: review.sessionID)
        if commentDraft?.editing == comment.id { commentDraft = nil }
        if navigation.focusedComment == comment.id { navigation.focusedComment = nil }
        announce("Comment deleted")
    }

    // MARK: Moving through the review

    // Puts a comment in focus and brings it on screen, opening its file, or its project,
    // first if it is elsewhere.
    func focus(_ comment: ReviewComment) {
        navigation.focusedComment = comment.id
        revealSerial += 1
        review?.reviews.markRead(comment.id, in: review?.sessionID ?? UUID())
        if commentDraft?.editing != nil || commentDraft?.text.isBlank != false { commentDraft = nil }
        guard comment.root == repoRoot else {
            selectRepository(comment.root, comment.path)
            return
        }
        if selected?.path != comment.path, let file = files.first(where: { $0.path == comment.path }) {
            mode = .changes
            select(file)
        }
        announce(comment.spokenName)
    }

    private func step(_ by: Int) {
        let list = orderedComments
        guard let next = ReviewOrder.step(from: list.contains { $0.id == navigation.focusedComment } ? navigation.focusedComment : nil,
                                          by: by, in: list) else { return }
        focus(next)
    }

    // After a finding is sorted, focus moves on to the next one still waiting, so a whole
    // set can be sorted from the keyboard without looking for the next.
    private func afterTriage(from id: UUID) {
        guard let review else { return }
        let ordered = orderedComments
        let pending = ordered.filter(\.isPending)
        guard !pending.isEmpty else {
            navigation.focusedComment = nil
            showToast("All findings sorted. \(counted(review.reviews.kept(review.sessionID).count, "comment")) ready to send.")
            return
        }
        // The next waiting one after where this one stood, going round to the first.
        let after = ordered.firstIndex { $0.id == id }.map { index in
            ordered[(index + 1)...].first(where: \.isPending)
        } ?? nil
        focus(after ?? pending[0])
    }

    private func keep(_ comment: ReviewComment) {
        guard let review else { return }
        review.reviews.keep(comment.id, in: review.sessionID)
        announce("Kept \(comment.authorName)'s finding")
        afterTriage(from: comment.id)
    }

    private func dismiss(_ comment: ReviewComment) {
        guard let review, let gone = review.reviews.dismiss(comment.id, from: review.sessionID) else { return }
        let sessionID = review.sessionID
        let reviews = review.reviews
        afterTriage(from: comment.id)
        showToast("Dismissed \(comment.authorName)'s finding", action: "Undo") {
            reviews.restore(gone.comment, at: gone.index, to: sessionID)
            focus(gone.comment)
        }
    }

    // The keys that move through a review and sort what is in it. Single letters only
    // count while a finding is in focus and nothing is being typed.
    func handleReviewKey(_ event: NSEvent) -> Bool {
        guard dialogs.current == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if reviewKeys.pressed(.branches, event) {
            showBranches()
            return true
        }
        if reviewKeys.pressed(.commitSelected, event), mode == .changes {
            openCommitDialog()
            return true
        }
        let typing = WindowKeyHandler.isTyping(event.window?.firstResponder)
        if review != nil, !typing, flags == .shift, event.charactersIgnoringModifiers == "?" {
            if navigation.askingWholeChange { closeWholeChangeCard() } else { navigation.setAskingWholeChange(true) }
            return true
        }
        // The card has the first claim on Escape over the review behind it.
        if navigation.askingWholeChange, !typing, flags.isEmpty, event.keyCode == 53 {
            escapeWholeChangeCard()
            return true
        }
        guard !WindowKeyHandler.isTyping(event.window?.firstResponder), let review, mode == .changes else { return false }
        if reviewKeys.pressed(.toggleViewed, event), let file = shownFile {
            if !model.loadingDiff { toggleViewed(file, in: root, advance: true) }
            return true
        }
        if reviewKeys.pressed(.nextNotViewed, event) {
            openNextNotViewed(after: shownFile)
            return true
        }
        if flags == .option, event.keyCode == 125 || event.keyCode == 126 {
            step(event.keyCode == 125 ? 1 : -1)
            return true
        }
        if flags.isEmpty, event.keyCode == 53, let id = navigation.focusedComment,
           let question = review.reviews.question(id, in: review.sessionID), question.status == .answering {
            stopAnswering(question, review: review)
            return true
        }
        guard flags.isEmpty, let id = navigation.focusedComment,
              let comment = review.reviews.comment(id, in: review.sessionID) else { return false }
        if event.keyCode == 53 {
            navigation.focusedComment = nil
            return true
        }
        guard comment.isPending else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "k": keep(comment)
        case "e": openComment(comment)
        case "d": dismiss(comment)
        default: return false
        }
        return true
    }

    func showToast(_ text: String, action title: String? = nil, perform: (() -> Void)? = nil) {
        toast = ReviewToast(text: text, actionTitle: title, action: perform)
        announce(text)
    }

    // MARK: Comments that lost their lines

    private func moveUnplaced(_ id: UUID, to anchor: DiffAnchor) {
        guard let review else { return }
        let quote = excerpt(anchor)
        review.reviews.move(id, to: anchor, excerpt: quote.text, offsets: quote.offsets, in: review.sessionID)
        reattaching = nil
        navigation.focusedComment = id
        revealSerial += 1
        showToast("Moved to \(anchor.label.lowercased())")
    }

    func unplacedComments(_ comments: [ReviewComment], review: ReviewTarget) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(comments) { comment in
                HStack(alignment: .top, spacing: Space.md) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.attentionText)
                    VStack(alignment: .leading, spacing: Space.md) {
                        (Text("This comment's code is no longer in the diff.").fontWeight(.semibold)
                         + Text(" It was on \(comment.anchor.label.lowercased()). It still goes with your review."))
                            .font(Typography.detail)
                            .fixedSize(horizontal: false, vertical: true)
                        card(comment, review: review)
                        if !comment.excerpt.isBlank {
                            Text(comment.excerpt).font(Typography.data).foregroundStyle(.secondary).lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Space.md).background(RoundedRectangle(cornerRadius: Radius.inset).fill(Theme.sunken))
                        }
                        HStack(spacing: Space.lg) {
                            if reattaching == comment.id {
                                Text("Click a line number to move the comment there.")
                                    .font(Typography.label).foregroundStyle(Theme.accent)
                                InlineLink(title: "Cancel", tint: Color.secondary) { reattaching = nil }
                            } else {
                                ActionButton(title: "Move to a line", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.detail,
                                             icon: "scope") {
                                    reattaching = comment.id
                                    announce("Click a line number to move the comment there")
                                }
                                InlineLink(title: "Leave it as a file comment", tint: Color.secondary) {
                                    review.reviews.keepOnFile(comment.id, in: review.sessionID)
                                    showToast("It stays in the review as a comment on the whole file")
                                }
                                InlineLink(title: "Delete", tint: Theme.deletion) { deleteComment(comment) }
                            }
                        }
                    }
                }
                .padding(Space.lg)
                .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.attention.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Theme.attention.opacity(0.3)))
            }
        }
        .padding(.horizontal, Space.xxl).padding(.bottom, Space.md)
    }

    func fileComments(_ comments: [ReviewComment], review: ReviewTarget) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(comments) { comment in
                if commentDraft?.editing == comment.id {
                    composer(review)
                } else {
                    card(comment, review: review)
                }
            }
        }
        .padding(.horizontal, Space.xxl).padding(.bottom, Space.md)
    }

    // The first time the diff takes comments, a note says how.
    var coachMark: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Ask or comment on any line").font(Typography.body.weight(.semibold))
            Text("Click a line number to ask a question or request a change. Drag down the numbers to cover several lines. Questions are answered here; changes wait until you send them to \(review?.agent.title ?? "the agent").")
                .font(Typography.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                InlineLink(title: "Got it") { coachSeen = true }
            }
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.lg)
        .frame(width: 300)
        .floatingCard(cornerRadius: Radius.card)
        .accessibilityElement(children: .contain)
    }

    // MARK: Replies

    // The first thread with an answer not yet read.
    func nextUnread() {
        guard let review,
              let next = review.reviews.threads(review.sessionID).first(where: { $0.round.unread.contains($0.comment.id) })
        else { return }
        focus(next.comment)
    }

    // MARK: Clearing and sending

    func confirmClear(_ review: ReviewTarget, kept: Int, pending: Int) {
        let what = counted(kept, "comment") + (pending > 0 ? " and \(counted(pending, "finding"))" : "")
        dialogs.show(.impact(
            "Clear the review?",
            rows: [
                .init(title: what, detail: "Everything not yet sent"),
                .init(title: "The changes themselves", detail: "Nothing in the files is touched", kept: true)
            ],
            warning: "Comments that have not been sent cannot be brought back.",
            compact: true,
            action: "Clear review") {
                review.reviews.clear(review.sessionID)
                commentDraft = nil
                navigation.focusedComment = nil
                showToast("Review cleared")
            })
    }

    private var projectNames: [String: String] {
        Dictionary(repositories.map { ($0.root, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private func fileLabel(_ comment: ReviewComment) -> String {
        fileLabel(root: comment.root, path: comment.path)
    }

    func fileLabel(root: String, path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard repositories.count > 1 else { return name }
        return (projectNames[root] ?? (root as NSString).lastPathComponent) + " · " + name
    }

    // The project, file and lines a question or a new note is about, as its band names them.
    private func place(root: String, path: String, anchor: DiffAnchor?) -> String {
        let project = projectNames[root] ?? (root as NSString).lastPathComponent
        guard let anchor, !path.isEmpty else { return project + " · whole change" }
        let lines = anchor.lastLine.map { "\(anchor.line)–\($0)" } ?? "\(anchor.line)"
        return project + " · " + (path as NSString).lastPathComponent + " " + lines + (anchor.side == .old ? " (removed)" : "")
    }

    func previewSend(_ review: ReviewTarget, startsOnMessage: Bool = false) {
        let kept = ReviewOrder.sorted(review.reviews.kept(review.sessionID), roots: repositories.map(\.root))
        guard !kept.isEmpty else { return }
        let carried = Set(kept.filter { $0.why != nil }.compactMap(\.questionID))
        let leftOut = review.reviews.questions(review.sessionID).count { !carried.contains($0.id) }
        let names = projectNames
        let busy = review.isBusy()
        dialogs.show(Dialog(
            title: "Send your review to \(review.agent.title)",
            message: "It goes to the session as one message. Anything you untick stays in the review for later.",
            content: AnyView(SendReviewSheet(
                agentTitle: review.agent.title, comments: kept,
                pendingCount: review.reviews.pending(review.sessionID).count, busy: busy,
                questionsLeftOut: leftOut, startsOnMessage: startsOnMessage,
                fileName: fileLabel,
                prompt: { ReviewPrompt.feedback($0, projectNames: names, note: $1) },
                lookFirst: { openFindings(review) },
                send: { sendReview(review, comments: $0, note: $1) })),
            actions: [],
            width: 620))
    }

    // Each review goes as a round of its own, so Chat can show it as one card and say
    // afterwards what came of each comment. Comments left unticked stay for the next.
    func sendReview(_ review: ReviewTarget, comments: [ReviewComment], note: String) {
        guard !comments.isEmpty else { return }
        let prompt = ReviewPrompt.feedback(comments, projectNames: projectNames, note: note)
        let busy = review.isBusy()
        review.reviews.recordRound(comments, prompt: prompt, note: note,
                                   roots: repositories.map(\.root), in: review.sessionID)
        review.send(prompt)
        if let editing = commentDraft?.editing, comments.contains(where: { $0.id == editing }) { commentDraft = nil }
        navigation.focusedComment = nil
        let asked = review.reviews.questions(review.sessionID).count
        let stayed = asked == 0 ? "" : asked == 1 ? ". 1 question stayed here" : ". \(asked) questions stayed here"
        showToast((busy ? "\(counted(comments.count, "comment")) queued for \(review.agent.title)"
                        : "Sent \(counted(comments.count, "comment")) to \(review.agent.title)") + stayed,
                  action: "Open Chat", perform: review.openChat)
    }

    // A new change goes on its own, at once, as a round of its own. The rest of the
    // review stays where it is.
    private func sendChange(_ change: ReviewComment, review: ReviewTarget) {
        let prompt = ReviewPrompt.feedback([change], projectNames: projectNames, note: "")
        let busy = review.isBusy()
        review.reviews.recordRound([change], prompt: prompt, note: "",
                                   roots: repositories.map(\.root), in: review.sessionID)
        review.send(prompt)
        showToast(busy ? "Change queued for \(review.agent.title)" : "Sent the change to \(review.agent.title)",
                  action: "Open Chat", perform: review.openChat)
    }

    // MARK: Questions

    func questionContext(_ review: ReviewTarget) -> QuestionContext {
        let conversation = review.conversation()
        return QuestionContext(agent: review.agent, executable: review.executable(review.agent),
                               directory: conversation?.directory ?? repoRoot,
                               repositories: reviewRepositories,
                               conversationID: conversation?.claudeSessionID,
                               recentChat: conversation?.recentChat ?? "")
    }

    func questionThread(_ question: ReviewQuestion, review: ReviewTarget, showsBand: Bool = true,
                                inCard: Bool = false, startFollowUp: (() -> Void)? = nil) -> some View {
        let focused = navigation.focusedComment == question.id
        let reviews = review.reviews
        let sessionID = review.sessionID
        let waiting = question.changeID.flatMap { reviews.comment($0, in: sessionID) }
        let round = waiting == nil ? question.changeID.flatMap { reviews.round(sending: $0, in: sessionID) } : nil
        let sent = round?.comments.first { $0.id == question.changeID }
        return QuestionThreadView(
            question: question,
            place: place(root: question.root, path: question.path, anchor: question.isWhole ? nil : question.anchor),
            steps: reviews.questionSteps[question.id] ?? [],
            showsBand: showsBand, focused: focused,
            projectPath: repoRoot, textScale: appSettings.textSize.scale,
            change: waiting ?? sent, changeSent: sent == nil ? nil : round?.sent,
            followUp: {
                reviews.followUp($0, to: question.id, context: questionContext(review), in: sessionID)
                announce("Asked a follow-up")
            },
            resolve: {
                reviews.setResolved(question.id, true, in: sessionID)
                announce("Resolved")
            },
            reopen: { reviews.setResolved(question.id, false, in: sessionID) },
            retry: { reviews.retryQuestion(question.id, context: questionContext(review), in: sessionID) },
            delete: { removeQuestion(question, review: review) },
            stop: { stopAnswering(question, review: review) },
            askAgain: { askAgain(question, review: review) },
            makeChange: question.isWhole ? nil : {
                guard let change = reviews.makeChange(from: question.id, in: sessionID) else { return }
                sendChange(change, review: review)
            },
            takeOut: {
                reviews.takeOutOfReview(question.id, in: sessionID)
                announce("Taken out of the review")
            },
            editChange: { text in
                if let id = question.changeID { reviews.update(id, body: text, in: sessionID) }
            },
            sendsQuestion: { on in
                if let id = question.changeID { reviews.setSendsQuestion(on, change: id, in: sessionID) }
            },
            startFollowUp: startFollowUp,
            editQuestion: inCard ? { editWholeChangeQuestion(question, review: review) } : nil,
            references: inCard ? { answerReferences($0) } : { _ in [] },
            showReference: { showCitation($0) },
            hoverReference: { navigation.citeHover = $0 })
            // In the card a thread sits flat on it, since a card inside a card is only
            // another edge to read past.
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(inCard ? .clear : Theme.card))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card)
                .stroke(inCard ? .clear : focused ? Theme.plan : Theme.border, lineWidth: focused && !inCard ? 2 : 1))
            .onTapGesture { navigation.focusedComment = question.id }
    }

    // Stopping is cheap and asking again undoes it, so it needs no confirming.
    func stopAnswering(_ question: ReviewQuestion, review: ReviewTarget) {
        review.reviews.stopAnswering(question.id, in: review.sessionID)
        showToast("Stopped answering \u{201C}\(question.text.trimmed)\u{201D}", action: "Ask again") {
            navigation.focusedComment = question.id
            askAgain(question, review: review)
        }
    }

    private func askAgain(_ question: ReviewQuestion, review: ReviewTarget) {
        review.reviews.askAgain(question.id, context: questionContext(review), in: review.sessionID)
        if toast?.actionTitle == "Ask again" { toast = nil }
        announce("Asked again")
    }

    // Removing takes effect at once and an undo puts the question back where it was.
    private func removeQuestion(_ question: ReviewQuestion, review: ReviewTarget) {
        let reviews = review.reviews
        let sessionID = review.sessionID
        let index = reviews.questions(sessionID).firstIndex { $0.id == question.id } ?? 0
        if navigation.askFollowing == question.id { navigation.askFollowing = nil }
        reviews.deleteQuestion(question.id, in: sessionID)
        if navigation.focusedComment == question.id { navigation.focusedComment = nil }
        showToast("Removed \u{201C}\(question.text.trimmed)\u{201D}", action: "Undo") {
            reviews.restoreQuestion(question, at: index, in: sessionID)
            navigation.askExpanded = question.id
        }
    }

    // Puts a question in focus and brings it on screen. One about the whole change has no
    // lines, so it opens in the card instead.
    func focus(_ question: ReviewQuestion) {
        navigation.focusedComment = question.id
        revealSerial += 1
        guard !question.isWhole else {
            openWholeChangeThread(question.id)
            return
        }
        guard question.root == repoRoot else {
            selectRepository(question.root, question.path)
            return
        }
        if selected?.path != question.path, let file = files.first(where: { $0.path == question.path }) {
            mode = .changes
            select(file)
        }
        announce(question.spokenName)
    }

    // MARK: Review list

    // Where the focused comment stands in the whole review, with the way to the next.
    var commentNavigation: some View {
        let list = orderedComments
        let index = list.firstIndex { $0.id == navigation.focusedComment }
        let here = openFileComments.count
        return HStack(spacing: Space.xs) {
            Text(index.map { "Comment \($0 + 1) of \(list.count)" }
                 ?? counted(list.count, "comment") + (here > 0 ? ", \(here) here" : ""))
                .font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
            GlyphButton(icon: "chevron.up", side: ControlHeight.sm) { step(-1) }
                .appTooltip("Previous comment  ⌥↑")
                .accessibilityLabel("Previous comment")
            GlyphButton(icon: "chevron.down", side: ControlHeight.sm) { step(1) }
                .appTooltip("Next comment  ⌥↓")
                .accessibilityLabel("Next comment")
        }
    }
}
