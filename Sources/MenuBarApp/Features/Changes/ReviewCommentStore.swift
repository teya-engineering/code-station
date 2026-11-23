import Foundation
import Observation

// Every session's review: the comments not yet sent, the reviewers at work, and the
// rounds already sent. Comments and rounds are kept on disk, so a review written before
// quitting is still there after.
@MainActor
@Observable
final class ReviewCommentStore {
    private(set) var loadError: String?
    private(set) var saveError: String?
    private var comments: [UUID: [ReviewComment]] = [:]
    // Second opinions, one lane per reviewer. They outlive the Changes tab, which can be
    // closed and reopened while one runs.
    private(set) var runs: [UUID: [SecondOpinionRun]] = [:]
    // Findings dismissed since the last second opinion was asked for, so they can still be
    // shown as dismissed and brought back. Kept only while the app runs.
    private var dismissedFindings: [UUID: [ReviewComment]] = [:]
    private var rounds: [UUID: [ReviewRound]] = [:]
    // Questions answered on the Changes screen, which never go to the agent.
    private var questions: [UUID: [ReviewQuestion]] = [:]
    // What each side copy is doing while it answers, step by step. Kept only while it runs.
    private(set) var questionSteps: [UUID: [String]] = [:]
    // What each file held when a review or a reply went, by round or reply id, so the
    // answer can show what the agent changed. Kept only while the app runs.
    @ObservationIgnored private var sentTexts: [UUID: [String: String]] = [:]

    @ObservationIgnored private var tasks: [UUID: [SecondOpinion.Reviewer: Task<Void, Never>]] = [:]
    // Called with the session when its last reviewer ends on its own, not when stopped.
    @ObservationIgnored var onSecondOpinionSettled: ((UUID) -> Void)?
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let roundsURL: URL?
    @ObservationIgnored private let questionsURL: URL?
    @ObservationIgnored private let files: PersistentFileClient
    @ObservationIgnored private var questionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var saver: DebouncedSaver?
    // The files ticked off as read, kept in a file of their own beside the comments.
    @ObservationIgnored let viewed: ViewedFileStore
    // Reading files and asking git for trees is done off the main thread; tests swap in
    // their own so a round settles without touching the disk.
    @ObservationIgnored var readFile: @Sendable (String) -> String? = { path in
        try? String(contentsOfFile: path, encoding: .utf8)
    }
    // How a question is answered; tests swap in their own so nothing is run.
    @ObservationIgnored var answerQuestion: @Sendable (SideQuestion.Request, @escaping @Sendable (String) -> Void)
        async -> Result<SideQuestion.Reply, SecondOpinion.Failure> = SideQuestion.answer

    init(url: URL? = AppPaths.supportFile("review-comments.json"),
         files: PersistentFileClient = .live) {
        self.url = url
        self.files = files
        roundsURL = url.map {
            $0.deletingPathExtension().appendingPathExtension("rounds").appendingPathExtension("json")
        }
        questionsURL = url.map {
            $0.deletingPathExtension().appendingPathExtension("questions").appendingPathExtension("json")
        }
        viewed = ViewedFileStore(url: url.map {
            $0.deletingPathExtension().appendingPathExtension("viewed").appendingPathExtension("json")
        }, files: files)
        var failures: [String] = []
        func read<Value: Decodable>(_ type: Value.Type, at url: URL?) -> Value? {
            guard let url else { return nil }
            do {
                guard let data = try files.readIfPresent(url) else { return nil }
                return try PersistentFile.makeDecoder().decode(type, from: data)
            } catch let error as DecodingError {
                failures.append(PersistentFile.decodeMessage(for: url, error: error))
            } catch {
                failures.append(PersistentFile.loadMessage(for: url, error: error))
            }
            return nil
        }
        comments = read([UUID: [ReviewComment]].self, at: url) ?? [:]
        rounds = read([UUID: [ReviewRound]].self, at: roundsURL) ?? [:]
        if let stored = read([UUID: [ReviewQuestion]].self, at: questionsURL) {
            // A side copy does not outlive the app, so one cut off by quitting says so.
            questions = stored.mapValues { list in
                list.map { question in
                    var question = question
                    if question.status == .answering, let last = question.exchanges.indices.last {
                        question.exchanges[last].failure = "The app quit before it answered."
                    }
                    return question
                }
            }
        }
        loadError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        saver = DebouncedSaver { [weak self] in self?.save() }
    }

    func comments(_ sessionID: UUID) -> [ReviewComment] { comments[sessionID] ?? [] }

    func comments(_ sessionID: UUID, root: String, path: String) -> [ReviewComment] {
        comments(sessionID).filter { $0.root == root && $0.path == path }
    }

    func count(_ sessionID: UUID, root: String, path: String) -> Int {
        comments(sessionID, root: root, path: path).count
    }

    func kept(_ sessionID: UUID) -> [ReviewComment] { comments(sessionID).filter { !$0.isPending } }

    func pending(_ sessionID: UUID) -> [ReviewComment] { comments(sessionID).filter(\.isPending) }

    func comment(_ id: UUID, in sessionID: UUID) -> ReviewComment? {
        comments[sessionID]?.first { $0.id == id }
    }

    func add(_ comment: ReviewComment, to sessionID: UUID) {
        comments[sessionID, default: []].append(comment)
        saver?.schedule()
    }

    func add(_ added: [ReviewComment], to sessionID: UUID) {
        guard !added.isEmpty else { return }
        comments[sessionID, default: []].append(contentsOf: added)
        saver?.schedule()
    }

    // Saving a finding the person rewrote keeps it: the words are now partly theirs.
    func update(_ id: UUID, body: String, kind: ReviewComment.Kind? = nil, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        comments[sessionID]?[index].body = body
        if let kind { comments[sessionID]?[index].kind = kind }
        if comments[sessionID]?[index].isPending == true {
            comments[sessionID]?[index].status = .kept
            comments[sessionID]?[index].edited = true
        }
        saver?.schedule()
    }

    // Moves a comment whose code left the diff onto lines picked by hand, or keeps it on
    // the file as a whole.
    func move(_ id: UUID, to anchor: DiffAnchor, excerpt: String, offsets: [Int], in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        comments[sessionID]?[index].side = anchor.side
        comments[sessionID]?[index].line = anchor.line
        comments[sessionID]?[index].lastLine = anchor.lastLine
        comments[sessionID]?[index].excerpt = excerpt
        comments[sessionID]?[index].excerptOffsets = offsets
        comments[sessionID]?[index].onFile = false
        saver?.schedule()
    }

    func keepOnFile(_ id: UUID, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        comments[sessionID]?[index].onFile = true
        saver?.schedule()
    }

    func remove(_ id: UUID, from sessionID: UUID) {
        comments[sessionID]?.removeAll { $0.id == id }
        if comments[sessionID]?.isEmpty == true { comments[sessionID] = nil }
        saver?.schedule()
    }

    // Takes away the comments that were just sent, and only those: one that arrived while
    // the preview was open was never part of the prompt, so it stays for the next one.
    func remove(_ ids: Set<UUID>, from sessionID: UUID) {
        comments[sessionID]?.removeAll { ids.contains($0.id) }
        if comments[sessionID]?.isEmpty == true { comments[sessionID] = nil }
        saver?.schedule()
    }

    func clear(_ sessionID: UUID) {
        comments[sessionID] = nil
        dismissedFindings[sessionID] = nil
        saver?.schedule()
    }

    // The session is gone, so is everything about its review.
    func remove(_ sessionID: UUID) {
        stopSecondOpinion(sessionID)
        runs[sessionID] = nil
        clear(sessionID)
        rounds[sessionID] = nil
        for question in questions(sessionID) { cancelAnswer(question.id) }
        questions[sessionID] = nil
        viewed.remove(sessionID)
        saver?.schedule()
    }

    @discardableResult
    func flush() -> Bool {
        if saver?.isPending == true { saver?.flush() }
        else if saveError != nil { save() }
        let viewedSaved = viewed.flush()
        return loadError == nil && saveError == nil && viewedSaved
    }

    // MARK: - Sorting findings

    func keep(_ id: UUID, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        comments[sessionID]?[index].status = .kept
        saver?.schedule()
    }

    // Puts a kept finding back among those still to look at.
    func reopen(_ id: UUID, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }),
              comments[sessionID]?[index].reviewer != nil else { return }
        comments[sessionID]?[index].status = .pending
        saver?.schedule()
    }

    // Hands the finding back with where it was, so Undo can put it back in its place.
    @discardableResult
    func dismiss(_ id: UUID, from sessionID: UUID) -> (comment: ReviewComment, index: Int)? {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }),
              let comment = comments[sessionID]?.remove(at: index) else { return nil }
        if comments[sessionID]?.isEmpty == true { comments[sessionID] = nil }
        if comment.isPending { dismissedFindings[sessionID, default: []].append(comment) }
        saver?.schedule()
        return (comment, index)
    }

    func restore(_ comment: ReviewComment, at index: Int? = nil, to sessionID: UUID) {
        guard self.comment(comment.id, in: sessionID) == nil else { return }
        dismissedFindings[sessionID]?.removeAll { $0.id == comment.id }
        var list = comments[sessionID] ?? []
        list.insert(comment, at: min(index ?? list.count, list.count))
        comments[sessionID] = list
        saver?.schedule()
    }

    // A finding on lines another reviewer already raised joins that one as a second
    // voice, so the same problem is read, kept and sent once.
    @discardableResult
    func addFindings(_ found: [ReviewComment], from agent: AgentKind, to sessionID: UUID) -> Int {
        var added = 0
        for var finding in found {
            // Two seats of one agent on different models are different voices too.
            let twin = comments[sessionID]?.firstIndex { other in
                guard other.reviewer != nil,
                      !other.voices.contains(where: { $0.agent == agent && $0.model == finding.reviewerModel })
                else { return false }
                return other.root == finding.root && other.path == finding.path
                    && other.anchor == finding.anchor
            }
            if let twin {
                comments[sessionID]?[twin].also.append(.init(agent: agent, body: finding.body, model: finding.reviewerModel))
                if let severity = finding.severity, let existing = comments[sessionID]?[twin].severity,
                   Self.rank(severity) < Self.rank(existing) {
                    comments[sessionID]?[twin].severity = severity
                }
            } else {
                finding.status = .pending
                comments[sessionID, default: []].append(finding)
                added += 1
            }
        }
        if !found.isEmpty { saver?.schedule() }
        return added
    }

    private static func rank(_ severity: ReviewComment.Severity) -> Int {
        ReviewComment.Severity.allCases.firstIndex(of: severity) ?? 0
    }

    // MARK: - Second opinion

    func runs(_ sessionID: UUID) -> [SecondOpinionRun] { runs[sessionID] ?? [] }

    func dismissedFindings(_ sessionID: UUID) -> [ReviewComment] { dismissedFindings[sessionID] ?? [] }

    // Every finding from a reviewer the person has yet to send: those still to look at,
    // those kept, and those dismissed since the last ask.
    func findings(_ sessionID: UUID) -> [ReviewComment] {
        comments(sessionID).filter { $0.reviewer != nil } + dismissedFindings(sessionID)
    }

    // A new ask starts clean: lanes that already finished and findings already dismissed
    // belong to the one before. Nothing happens while a reviewer is still at work.
    func beginSecondOpinion(_ sessionID: UUID) {
        guard !isReviewing(sessionID) else { return }
        runs[sessionID] = nil
        dismissedFindings[sessionID] = nil
    }

    func isReviewing(_ sessionID: UUID) -> Bool { runs(sessionID).contains(where: \.isRunning) }

    func isReviewing(_ sessionID: UUID, reviewer: SecondOpinion.Reviewer) -> Bool {
        runs(sessionID).contains { $0.reviewer == reviewer && $0.isRunning }
    }

    // Each seat gets a lane of its own and runs alongside the others. One already at
    // work is left to it.
    func startSecondOpinion(_ sessionID: UUID, reviewer: SecondOpinion.Reviewer, request: SecondOpinionRequest) {
        guard !isReviewing(sessionID, reviewer: reviewer), !request.repositories.isEmpty else { return }
        let run = SecondOpinionRun(reviewer: reviewer, started: Date(), request: request)
        var lanes = runs(sessionID).filter { $0.reviewer != reviewer }
        lanes.append(run)
        runs[sessionID] = lanes
        let searchPath = ProcessManager.searchPath
        tasks[sessionID, default: [:]][reviewer] = Task { [weak self] in
            var patches = await SecondOpinion.patches(for: request)
            if case .file(let root, let path, _) = request.scope {
                patches = patches.filter { $0.root == root && $0.path == path }
            }
            guard !Task.isCancelled else { return }
            self?.setActivity("Reading \(counted(patches.count, "changed file"))", reviewer: reviewer, in: sessionID)
            let outcome: Result<[ReviewComment], SecondOpinion.Failure>
            if patches.isEmpty {
                outcome = .failure(.init(message: request.scope.isSinceReview
                    ? "Nothing changed since the last review." : "There are no changes to review."))
            } else {
                outcome = await SecondOpinion.review(
                    patches, reviewer: reviewer, executable: request.executable, searchPath: searchPath,
                    repositories: request.repositories.map { (root: $0.root, name: $0.name) },
                    focus: request.focus, note: request.note, sinceReview: request.scope.isSinceReview,
                    base: request.scope.base,
                    servers: request.servers,
                    activity: { [weak self] text in
                        Task { @MainActor in self?.setActivity(text, reviewer: reviewer, in: sessionID) }
                    })
            }
            guard !Task.isCancelled, let self else { return }
            self.finishSecondOpinion(sessionID, reviewer: reviewer, outcome: outcome)
        }
    }

    func retrySecondOpinion(_ sessionID: UUID, reviewer: SecondOpinion.Reviewer) {
        guard let run = runs(sessionID).first(where: { $0.reviewer == reviewer }), !run.isRunning else { return }
        startSecondOpinion(sessionID, reviewer: reviewer, request: run.request)
    }

    // Stopping a reviewer drops its lane: there is nothing it came to.
    func stopSecondOpinion(_ sessionID: UUID, reviewer: SecondOpinion.Reviewer) {
        tasks[sessionID]?[reviewer]?.cancel()
        tasks[sessionID]?[reviewer] = nil
        runs[sessionID]?.removeAll { $0.reviewer == reviewer }
        if runs[sessionID]?.isEmpty == true { runs[sessionID] = nil }
    }

    func stopSecondOpinion(_ sessionID: UUID) {
        for task in (tasks[sessionID] ?? [:]).values { task.cancel() }
        tasks[sessionID] = nil
        runs[sessionID]?.removeAll(where: \.isRunning)
        if runs[sessionID]?.isEmpty == true { runs[sessionID] = nil }
    }

    private func setActivity(_ text: String, reviewer: SecondOpinion.Reviewer, in sessionID: UUID) {
        guard let index = runs[sessionID]?.firstIndex(where: { $0.reviewer == reviewer && $0.isRunning }),
              var run = runs[sessionID]?[index], run.activity != text else { return }
        run.activity = text
        run.recent = Array((run.recent + [text]).suffix(3))
        runs[sessionID]?[index] = run
    }

    // Called by the run when it ends; tests call it directly with what a reviewer said.
    func finishSecondOpinion(_ sessionID: UUID, reviewer: SecondOpinion.Reviewer,
                             outcome: Result<[ReviewComment], SecondOpinion.Failure>) {
        tasks[sessionID]?[reviewer] = nil
        if case .success(let found) = outcome { addFindings(found, from: reviewer.agent, to: sessionID) }
        guard let index = runs[sessionID]?.firstIndex(where: { $0.reviewer == reviewer }) else { return }
        runs[sessionID]?[index].ended = Date()
        switch outcome {
        case .success(let found): runs[sessionID]?[index].state = .finished(found: found.count)
        case .failure(let failure): runs[sessionID]?[index].state = .failed(failure.message)
        }
        if !isReviewing(sessionID) { onSecondOpinionSettled?(sessionID) }
    }

    // MARK: - Rounds

    func rounds(_ sessionID: UUID) -> [ReviewRound] { rounds[sessionID] ?? [] }

    func round(prompt: String, in sessionID: UUID) -> ReviewRound? {
        let text = prompt.trimmed
        return rounds(sessionID).last { $0.prompt == text }
    }

    // The thread a reply of yours belongs to, while the agent has yet to answer it.
    func awaitingReply(prompt: String, in sessionID: UUID) -> (round: ReviewRound, commentID: UUID)? {
        let text = prompt.trimmed
        for round in rounds(sessionID).reversed() {
            for (commentID, replies) in round.replies where replies.last?.author == .you && replies.last?.prompt == text {
                return (round, commentID)
            }
        }
        return nil
    }

    // Whether a prompt was a reply in a thread, answered or not, so Chat can leave it to
    // the thread instead of showing it as a message of its own.
    func isThreadReply(prompt: String, in sessionID: UUID) -> Bool {
        let text = prompt.trimmed
        return rounds(sessionID).contains { round in
            round.replies.values.contains { $0.contains { $0.author == .you && $0.prompt == text } }
        }
    }

    // Reviews sent from Changes, matched to the messages that carried them. Each shows as
    // one card where its prompt would be. The answers the agent wrote under each comment's
    // heading live in the card's threads, so they are cut from the turn's text, and a reply
    // sent in a thread is left to the thread instead of showing as a message of its own.
    func sentReviews(in messages: [ChatMessage], sessionID: UUID)
        -> (cards: [UUID: ReviewRound], hidden: Set<UUID>, cuts: [UUID: Int]) {
        let rounds = rounds(sessionID)
        guard !rounds.isEmpty else { return ([:], [], [:]) }
        var cards: [UUID: ReviewRound] = [:]
        var hidden: Set<UUID> = []
        var cuts: [UUID: Int] = [:]
        for (index, message) in messages.enumerated() where message.role == .user {
            let prompt = message.text.trimmed
            let count: Int
            let settled: Bool
            if let round = rounds.last(where: { $0.prompt == prompt }) {
                cards[message.id] = round
                count = round.comments.count
                settled = round.isSettled
            } else if isThreadReply(prompt: prompt, in: sessionID) {
                hidden.insert(message.id)
                count = 1
                settled = awaitingReply(prompt: prompt, in: sessionID) == nil
            } else {
                continue
            }
            guard let reply = messages[(index + 1)...].prefix(while: { $0.role != .user })
                .last(where: { $0.role == .assistant }) else { continue }
            // While the turn runs, only text under a heading is known to be an answer.
            let cut = settled ? ReviewAnswers.read(reply, count: count)?.start : ReviewAnswers.split(reply.text)?.start
            guard let cut else { continue }
            if reply.cut(at: cut).isEmpty { hidden.insert(reply.id) } else { cuts[reply.id] = cut }
        }
        return (cards, hidden, cuts)
    }

    // Every sent comment on one file, with the round it went in, oldest first.
    func threads(_ sessionID: UUID, root: String, path: String) -> [(round: ReviewRound, comment: ReviewComment)] {
        threads(sessionID).filter { $0.comment.root == root && $0.comment.path == path }
    }

    func threads(_ sessionID: UUID) -> [(round: ReviewRound, comment: ReviewComment)] {
        rounds(sessionID).flatMap { round in round.comments.map { (round, $0) } }
    }

    func unreadCount(_ sessionID: UUID) -> Int {
        rounds(sessionID).reduce(0) { $0 + $1.unread.count }
    }

    // The trees the latest round recorded, for a reviewer asked to read only what
    // changed after it. Nil until a review has gone and its trees are in.
    func latestTrees(_ sessionID: UUID) -> [String: String]? {
        guard let trees = rounds(sessionID).last?.trees, !trees.isEmpty else { return nil }
        return trees
    }

    // Records a review as it is sent and takes its comments out of the one being written.
    // What each file and project held is read in the background and filled in after.
    @discardableResult
    func recordRound(_ sent: [ReviewComment], prompt: String, note: String,
                     roots: [String], in sessionID: UUID) -> ReviewRound {
        let round = ReviewRound(prompt: prompt.trimmed, note: note.trimmed, comments: ReviewOrder.sorted(sent, roots: roots))
        rounds[sessionID, default: []].append(round)
        remove(Set(sent.map(\.id)), from: sessionID)
        saver?.schedule()
        let files = Set(sent.map { ReviewRound.fileKey(root: $0.root, path: $0.path) })
        Task { [weak self] in
            guard let texts = await self?.readFiles(files) else { return }
            var trees: [String: String] = [:]
            for root in roots {
                if let tree = await TreeSnapshots.shared.record(at: root) { trees[root] = tree }
            }
            self?.fillRound(round.id, texts: texts, trees: trees, in: sessionID)
        }
        return round
    }

    private func readFiles(_ files: Set<String>) async -> [String: String] {
        let read = readFile
        return await Task.detached(priority: .utility) {
            var texts: [String: String] = [:]
            for file in files { texts[file] = read(file) }
            return texts
        }.value
    }

    private func fillRound(_ id: UUID, texts: [String: String], trees: [String: String], in sessionID: UUID) {
        sentTexts[id] = texts
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        rounds[sessionID]?[index].fileDigests.merge(texts.mapValues(ReviewRound.digest)) { old, _ in old }
        rounds[sessionID]?[index].trees.merge(trees) { old, _ in old }
        saver?.schedule()
    }

    // A turn has ended. If it took a review, each comment is checked against the files
    // as they are now and gets its answer from what the agent wrote. If it took a reply in
    // a thread, the agent's answer joins that thread. Any other turn changes nothing.
    func turnEnded(_ sessionID: UUID, prompt: String, reply: ChatMessage? = nil) async {
        if let round = round(prompt: prompt, in: sessionID), !round.isSettled {
            await settle(round, reply: reply, in: sessionID)
        } else if let waiting = awaitingReply(prompt: prompt, in: sessionID) {
            await answer(waiting.commentID, round: waiting.round, prompt: prompt.trimmed, reply: reply, in: sessionID)
        }
    }

    private func settle(_ round: ReviewRound, reply: ChatMessage?, in sessionID: UUID) async {
        let read = readFile
        let comments = round.comments
        let digests = round.fileDigests
        let before = sentTexts[round.id] ?? [:]
        let checked = await Task.detached(priority: .utility) {
            var outcomes: [UUID: ReviewRound.Outcome] = [:]
            var diffs: [UUID: [ReviewDiffLine]] = [:]
            for comment in comments {
                let key = ReviewRound.fileKey(root: comment.root, path: comment.path)
                let now = read(key)
                outcomes[comment.id] = ReviewRound.outcome(for: comment, fileText: now, digestAtSend: digests[key])
                if let old = before[key], let now {
                    diffs[comment.id] = ReviewDiffLine.near(comment, before: old, after: now)
                }
            }
            return (outcomes, diffs)
        }.value
        let answers = reply.flatMap { ReviewAnswers.read($0, count: comments.count) }?.answers ?? [:]
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.id == round.id }),
              rounds[sessionID]?[index].isSettled == false else { return }
        rounds[sessionID]?[index].outcomes = checked.0
        for (offset, comment) in comments.enumerated() {
            let answer = answers[offset + 1]
            let diff = checked.1[comment.id] ?? []
            guard answer != nil || !diff.isEmpty else { continue }
            rounds[sessionID]?[index].replies[comment.id, default: []].append(ReviewReply(
                author: .agent, body: answer?.body ?? "", suggestion: answer?.suggestion,
                diff: diff, changedFile: checked.0[comment.id] == .changed))
            rounds[sessionID]?[index].unread.insert(comment.id)
        }
        sentTexts[round.id] = nil
        saver?.schedule()
    }

    private func answer(_ commentID: UUID, round: ReviewRound, prompt: String, reply: ChatMessage?,
                        in sessionID: UUID) async {
        guard let comment = round.comments.first(where: { $0.id == commentID }),
              let mine = round.replies(commentID).last else { return }
        let key = ReviewRound.fileKey(root: comment.root, path: comment.path)
        let read = readFile
        let now = await Task.detached(priority: .utility) { read(key) }.value
        let before = sentTexts[mine.id]?[key]
        let changed = before != nil && now != nil && before != now
        let diff = changed ? ReviewDiffLine.near(comment, before: before!, after: now!) : []
        let number = round.number(commentID) ?? 1
        let answers = reply.flatMap { ReviewAnswers.read($0, count: 1) }?.answers ?? [:]
        let answer = answers[number] ?? (answers.count == 1 ? answers.values.first : nil)
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.id == round.id }),
              rounds[sessionID]?[index].replies(commentID).last?.prompt == prompt else { return }
        rounds[sessionID]?[index].replies[commentID, default: []].append(ReviewReply(
            author: .agent, body: answer?.body ?? "", suggestion: answer?.suggestion,
            diff: diff, changedFile: changed))
        if changed { rounds[sessionID]?[index].outcomes?[commentID] = .changed }
        rounds[sessionID]?[index].unread.insert(commentID)
        sentTexts[mine.id] = nil
        saver?.schedule()
    }

    // A reply in a thread goes to the agent at once. Hands back the prompt to send, once
    // what the file holds now has been read, so the answer can show what the agent changed.
    func reply(_ text: String, to commentID: UUID, round roundID: UUID, in sessionID: UUID,
               projectNames: [String: String] = [:]) async -> String? {
        guard !text.isBlank,
              let index = rounds[sessionID]?.firstIndex(where: { $0.id == roundID }),
              let round = rounds[sessionID]?[index],
              let comment = round.comments.first(where: { $0.id == commentID }),
              let number = round.number(commentID) else { return nil }
        let prompt = ReviewPrompt.reply(text, to: comment, number: number, earlier: round.replies(commentID),
                                        projectNames: projectNames).trimmed
        let mine = ReviewReply(author: .you, body: text.trimmed, prompt: prompt)
        rounds[sessionID]?[index].replies[commentID, default: []].append(mine)
        rounds[sessionID]?[index].resolved.remove(commentID)
        rounds[sessionID]?[index].unread.remove(commentID)
        saver?.schedule()
        sentTexts[mine.id] = await readFiles([ReviewRound.fileKey(root: comment.root, path: comment.path)])
        return prompt
    }

    func resolve(_ commentID: UUID, round roundID: UUID, in sessionID: UUID) {
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.id == roundID }) else { return }
        rounds[sessionID]?[index].resolved.insert(commentID)
        rounds[sessionID]?[index].unread.remove(commentID)
        saver?.schedule()
    }

    func reopen(_ commentID: UUID, round roundID: UUID, in sessionID: UUID) {
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.id == roundID }) else { return }
        rounds[sessionID]?[index].resolved.remove(commentID)
        saver?.schedule()
    }

    func markRead(_ commentID: UUID, in sessionID: UUID) {
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.unread.contains(commentID) }) else { return }
        rounds[sessionID]?[index].unread.remove(commentID)
        saver?.schedule()
    }

    // MARK: - Questions

    func questions(_ sessionID: UUID) -> [ReviewQuestion] { questions[sessionID] ?? [] }

    func questions(_ sessionID: UUID, root: String, path: String) -> [ReviewQuestion] {
        questions(sessionID).filter { $0.root == root && $0.path == path }
    }

    func question(_ id: UUID, in sessionID: UUID) -> ReviewQuestion? {
        questions[sessionID]?.first { $0.id == id }
    }

    func isAnswering(_ id: UUID) -> Bool { questionTasks[id] != nil }

    // A question goes at once to a side copy of the session. Nothing about it reaches the
    // main conversation.
    func ask(_ question: ReviewQuestion, context: QuestionContext, in sessionID: UUID) {
        questions[sessionID, default: []].append(question)
        saver?.schedule()
        startAnswer(question.id, context: context, in: sessionID)
    }

    func followUp(_ text: String, to id: UUID, context: QuestionContext, in sessionID: UUID) {
        guard !text.isBlank, let index = questionIndex(id, in: sessionID),
              questions[sessionID]?[index].status != .answering else { return }
        questions[sessionID]?[index].exchanges.append(.init(question: text.trimmed))
        questions[sessionID]?[index].resolved = false
        saver?.schedule()
        startAnswer(id, context: context, in: sessionID)
    }

    func retryQuestion(_ id: UUID, context: QuestionContext, in sessionID: UUID) {
        guard let index = questionIndex(id, in: sessionID),
              let last = questions[sessionID]?[index].exchanges.indices.last,
              questions[sessionID]?[index].status == .failed else { return }
        questions[sessionID]?[index].exchanges[last].failure = nil
        saver?.schedule()
        startAnswer(id, context: context, in: sessionID)
    }

    // Ends the side copy's run at once. The fork id stays, so asking again goes on in the
    // same conversation.
    func stopAnswering(_ id: UUID, in sessionID: UUID) {
        guard let index = questionIndex(id, in: sessionID),
              let last = questions[sessionID]?[index].exchanges.indices.last,
              questions[sessionID]?[index].status == .answering else { return }
        let reached = questionSteps[id] ?? []
        cancelAnswer(id)
        questions[sessionID]?[index].exchanges[last].stopped = Date()
        questions[sessionID]?[index].exchanges[last].stoppedSteps = reached
        saver?.schedule()
    }

    func askAgain(_ id: UUID, context: QuestionContext, in sessionID: UUID) {
        guard let index = questionIndex(id, in: sessionID),
              let last = questions[sessionID]?[index].exchanges.indices.last,
              questions[sessionID]?[index].status == .stopped else { return }
        questions[sessionID]?[index].exchanges[last].stopped = nil
        questions[sessionID]?[index].exchanges[last].stoppedSteps = nil
        saver?.schedule()
        startAnswer(id, context: context, in: sessionID)
    }

    func deleteQuestion(_ id: UUID, in sessionID: UUID) {
        cancelAnswer(id)
        questions[sessionID]?.removeAll { $0.id == id }
        if questions[sessionID]?.isEmpty == true { questions[sessionID] = nil }
        saver?.schedule()
    }

    // Puts a removed question back where it was, for an undo.
    func restoreQuestion(_ question: ReviewQuestion, at index: Int, in sessionID: UUID) {
        guard self.question(question.id, in: sessionID) == nil else { return }
        var list = questions[sessionID] ?? []
        list.insert(question, at: min(max(index, 0), list.count))
        questions[sessionID] = list
        saver?.schedule()
    }

    // Takes back the last follow-up in a thread that is not answering, and gives its words
    // back so they can be asked again in other words. The first question is never taken,
    // since without it there is no thread.
    func withdrawFollowUp(_ id: UUID, in sessionID: UUID) -> String? {
        guard let index = questionIndex(id, in: sessionID),
              let question = questions[sessionID]?[index],
              question.exchanges.count > 1, question.status != .answering else { return nil }
        let withdrawn = questions[sessionID]?[index].exchanges.removeLast()
        saver?.schedule()
        return withdrawn?.question
    }

    func setResolved(_ id: UUID, _ resolved: Bool, in sessionID: UUID) {
        guard let index = questionIndex(id, in: sessionID) else { return }
        questions[sessionID]?[index].resolved = resolved
        saver?.schedule()
    }

    // The answer's suggestion becomes a change on the question's lines. The question and
    // answer go along, so the agent knows why it is asked to make it.
    @discardableResult
    func makeChange(from id: UUID, in sessionID: UUID) -> ReviewComment? {
        guard let index = questionIndex(id, in: sessionID), let question = questions[sessionID]?[index],
              !question.isWhole, let suggestion = question.suggestion else { return nil }
        if let existing = question.changeID.flatMap({ comment($0, in: sessionID) }) { return existing }
        var change = ReviewComment(root: question.root, path: question.path, anchor: question.anchor,
                                   excerpt: question.excerpt, body: suggestion,
                                   excerptOffsets: question.excerptOffsets)
        change.questionID = id
        change.why = question.why
        add(change, to: sessionID)
        questions[sessionID]?[index].changeID = change.id
        return change
    }

    func takeOutOfReview(_ questionID: UUID, in sessionID: UUID) {
        guard let index = questionIndex(questionID, in: sessionID),
              let changeID = questions[sessionID]?[index].changeID else { return }
        remove(changeID, from: sessionID)
        questions[sessionID]?[index].changeID = nil
        saver?.schedule()
    }

    func setSendsQuestion(_ on: Bool, change commentID: UUID, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == commentID }),
              let questionID = comments[sessionID]?[index].questionID else { return }
        comments[sessionID]?[index].why = on ? question(questionID, in: sessionID)?.why : nil
        saver?.schedule()
    }

    // The round a comment went in, once it has been sent.
    func round(sending commentID: UUID, in sessionID: UUID) -> ReviewRound? {
        rounds(sessionID).first { round in round.comments.contains { $0.id == commentID } }
    }

    private func questionIndex(_ id: UUID, in sessionID: UUID) -> Int? {
        questions[sessionID]?.firstIndex { $0.id == id }
    }

    private func cancelAnswer(_ id: UUID) {
        questionTasks[id]?.cancel()
        questionTasks[id] = nil
        questionSteps[id] = nil
    }

    private func startAnswer(_ id: UUID, context: QuestionContext, in sessionID: UUID) {
        guard let question = question(id, in: sessionID) else { return }
        cancelAnswer(id)
        guard let executable = context.executable else {
            finishAnswer(id, in: sessionID, outcome: .failure(.init(message: "\(context.agent.title) is not installed.")))
            return
        }
        questionSteps[id] = []
        let request = SideQuestion.Request(question: question, context: context, executable: executable,
                                           searchPath: ProcessManager.searchPath)
        let answer = answerQuestion
        questionTasks[id] = Task { [weak self] in
            let outcome = await answer(request) { step in
                Task { @MainActor in self?.addStep(step, to: id) }
            }
            guard !Task.isCancelled else { return }
            self?.finishAnswer(id, in: sessionID, outcome: outcome)
        }
    }

    private func addStep(_ step: String, to id: UUID) {
        guard questionTasks[id] != nil, questionSteps[id]?.last != step else { return }
        questionSteps[id, default: []].append(step)
    }

    // Called by the run when it ends; tests call it directly with what a side copy said.
    func finishAnswer(_ id: UUID, in sessionID: UUID, outcome: Result<SideQuestion.Reply, SecondOpinion.Failure>) {
        questionTasks[id] = nil
        questionSteps[id] = nil
        guard let index = questionIndex(id, in: sessionID),
              let last = questions[sessionID]?[index].exchanges.indices.last else { return }
        switch outcome {
        case .success(let reply):
            questions[sessionID]?[index].exchanges[last].answer = reply.answer
            questions[sessionID]?[index].exchanges[last].suggestion = reply.suggestion
            questions[sessionID]?[index].exchanges[last].answered = Date()
            if let fork = reply.forkID { questions[sessionID]?[index].forkID = fork }
        case .failure(let failure):
            questions[sessionID]?[index].exchanges[last].failure = failure.message
        }
        saver?.schedule()
    }

    private func save() {
        // Comments, sent rounds and questions refer to each other. A failed read keeps
        // the whole set protected rather than saving a partial view of the review.
        guard loadError == nil else {
            saveError = "Reviews were not saved because the existing review files could not be loaded."
            return
        }
        do {
            if let url {
                if comments.isEmpty { try files.removeIfPresent(url) }
                else { try files.write(PersistentFile.makeEncoder().encode(comments), url) }
            }
            if let roundsURL {
                if rounds.isEmpty { try files.removeIfPresent(roundsURL) }
                else { try files.write(PersistentFile.makeEncoder().encode(rounds), roundsURL) }
            }
            if let questionsURL {
                if questions.isEmpty { try files.removeIfPresent(questionsURL) }
                else { try files.write(PersistentFile.makeEncoder().encode(questions), questionsURL) }
            }
            saveError = nil
        } catch {
            saveError = "Reviews could not be saved: \(error.localizedDescription)"
            SessionLog.note("could not save review comments: \(error.localizedDescription)")
        }
    }
}
