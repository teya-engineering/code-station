import Foundation

// What the agent suggests doing about one thread. A fix is already made in the working
// tree, uncommitted; the reply is the words that would go under the reviewer's. Nothing
// here has left the machine: the person decides that per thread.
struct PullRequestReviewProposal: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case fix
        case reply
        // The agent thinks the reviewer is wrong. Marked so it is read harder than a fix.
        case pushback
    }

    var threadID: Int
    var action: Action
    var reply: String
    var files: [String]
    // Only the app records ownership. JSON from the agent cannot supply a baseline.
    var changes: PullRequestReviewChanges? = nil

    private enum CodingKeys: String, CodingKey { case threadID, action, reply, files }

    init(threadID: Int, action: Action, reply: String, files: [String] = []) {
        self.threadID = threadID
        self.action = action
        self.reply = reply
        self.files = files
    }

    // Agents leave `files` out for a reply, and the reader should not fail them for it.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadID = try container.decode(Int.self, forKey: .threadID)
        action = try container.decode(Action.self, forKey: .action)
        reply = try container.decodeIfPresent(String.self, forKey: .reply) ?? ""
        files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
    }

    // Agents wrap JSON in a fence, or leave a sentence before it, often enough that the
    // array is looked for rather than assumed to be the whole text.
    static func parse(_ text: String) -> PullRequestReviewProposal? {
        for candidate in SecondOpinion.jsonArrays(in: text).reversed() {
            if let list = try? JSONDecoder().decode([PullRequestReviewProposal].self, from: Data(candidate.utf8)),
               let first = list.first {
                return first
            }
        }
        return nil
    }
}

// Asks the session for a proposal on one thread and reads it back when the turn ends.
// The agent writes a JSON file inside the checkout rather than answering in prose, so
// the answer reads the same from every agent and no permission prompt parks the turn.
@MainActor
enum PullRequestReviewDrafter {
    static let folder = ".code-station"

    enum Outcome: Equatable {
        case proposed
        case sessionGone
        case busy
        case noAnswer
        case blocked(PullRequestReviewActions.Failure)

        var failureMessage: String? {
            switch self {
            case .proposed: nil
            case .sessionGone: "The session this pull request belongs to is gone."
            case .busy: "The session is in the middle of a turn. Ask again when it is idle."
            case .noAnswer: "The agent finished without leaving a proposal. Ask again, or answer by hand."
            case .blocked(let failure): failure.message
            }
        }
    }

    static func draft(review: PullRequestReview, thread: PullRequestReviewThread, on loaded: PullRequestReviewStore.Loaded,
                      sessionID: UUID, store: ProjectStore, runner: SessionRunner,
                      reviews: PullRequestReviewStore) async -> Outcome {
        guard store.session(sessionID) != nil else { return .sessionGone }
        guard !runner.isBusy(sessionID), runner.queued(sessionID).isEmpty,
              reviews.beginWork(on: loaded.pullRequest.url) else { return .busy }
        defer { reviews.endWork(on: loaded.pullRequest.url) }
        guard reviews.proposals[thread.id]?.changes?.files.isEmpty != false else {
            return .blocked(.git("Handle the current proposal's changes before asking for another draft."))
        }
        reviews.beganDrafting(thread.id)
        defer { reviews.endedDrafting(thread.id) }
        guard let root = await PullRequestReviewActions.root(for: loaded, sessionID: sessionID, store: store) else {
            return .blocked(.noCheckout)
        }
        if let failure = PullRequestReviewActions.onPullRequestBranch(loaded, root: root) { return .blocked(failure) }

        let file = URL(fileURLWithPath: root).appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("review-proposals", isDirectory: true)
            .appendingPathComponent("\(thread.id).json")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        await GitActions.excludeFromStatus(folder, at: root)
        let baseline: PullRequestReviewChanges.Baseline
        do { baseline = try await PullRequestReviewChanges.begin(at: root) }
        catch { return .blocked(.git(error.localizedDescription)) }
        // Repository reads suspend, so another turn may have started while they ran.
        guard !runner.isBusy(sessionID), runner.queued(sessionID).isEmpty else { return .busy }
        let finished = await reviews.waitForTurnEnd(sessionID) {
            runner.send(prompt(review: review, thread: thread, pullRequest: loaded.pullRequest, file: file),
                        sessionID: sessionID)
            guard runner.state(sessionID).isBusy else {
                for queued in runner.queued(sessionID) { runner.unqueue(queued.id, sessionID: sessionID) }
                return false
            }
            return true
        }
        guard finished, !Task.isCancelled else { return .noAnswer }
        guard !runner.isBusy(sessionID) else { return .busy }
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              var proposal = PullRequestReviewProposal.parse(text) else { return .noAnswer }
        proposal.threadID = thread.id
        do {
            let changes = try await PullRequestReviewChanges.finish(baseline)
            proposal.changes = changes
            proposal.files = changes.files
            if !changes.files.isEmpty { proposal.action = .fix }
        } catch { return .blocked(.git(error.localizedDescription)) }
        reviews.setProposal(proposal)
        return .proposed
    }

    // The review's summary travels along: it is the context the thread was written in.
    static func prompt(review: PullRequestReview, thread: PullRequestReviewThread, pullRequest: PullRequest, file: URL) -> String {
        var lines = ["A reviewer (\(review.author.login)) reviewed pull request #\(pullRequest.number) (\(pullRequest.url))."]
        if !review.body.isEmpty { lines += ["", "Review summary, for context:", review.body] }
        lines += ["", "Thread \(thread.id) on \(thread.place):", "```diff", thread.diffHunk, "```"]
        lines += thread.comments.map { "\($0.author.login) wrote: \($0.body)" }
        lines += ["", """
        For the thread above, decide one of:
        - fix: the comment asks for a code change you agree with. Make the change in the working tree now. Do not stage, commit, push, or run gh. Then write a one or two sentence reply saying what you changed.
        - reply: the comment is a question or needs no code change. Write the reply.
        - pushback: you think the comment is mistaken. Do not change code. Write a short, polite reply explaining why.
        Never post anything to GitHub. The person will read every reply before it is sent.
        Only edit files in \(file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path). Preserve any edits already there.

        When done, write the file \(file.path) containing only JSON in this shape:
        [{"threadID": \(thread.id), "action": "fix" | "reply" | "pushback", "reply": "<text>", "files": ["<path changed>", ...]}]
        One entry. `files` lists the paths you edited, relative to the repository root, and is empty for reply and pushback.
        """]
        return lines.joined(separator: "\n")
    }
}
