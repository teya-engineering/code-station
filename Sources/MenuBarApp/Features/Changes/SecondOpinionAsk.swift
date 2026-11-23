import Foundation

// Subjects and file scopes share the existing review routes. The ask presents the
// subject separately from its comparison and supporting context.
enum SecondOpinionStop: Hashable, CaseIterable {
    case file, answer, sinceReview, uncommitted, branch, design, conversation

    // Where the results land: a card under the answer, findings on the diff, or notes
    // pinned on the design.
    enum Kind: Hashable {
        case chat, changes, design
    }

    var kind: Kind {
        switch self {
        case .answer, .conversation: .chat
        case .file, .sinceReview, .uncommitted, .branch: .changes
        case .design: .design
        }
    }
}

// Where the ask was opened from. Each way in proposes its own subject first.
enum SecondOpinionOrigin: Equatable {
    case header, answer, file
}

// Everything the ask needs to know about the session, read once as it opens.
struct SecondOpinionAskFacts: Equatable {
    struct Answer: Equatable {
        var subject: ChatSecondOpinion.Subject
        // The answer the person pointed at, rather than the latest one.
        var picked: Bool
    }

    struct File: Equatable, Identifiable, Sendable {
        var root: String
        var path: String
        var added: Int
        var removed: Int

        var id: String { root + "\u{0}" + path }
        var name: String { (path as NSString).lastPathComponent }
    }

    // What the branch changes from the base the Changes screen compares it with,
    // committed or not.
    struct Branch: Equatable {
        // The base's name, such as origin/main.
        var base: String
        var files: [File]
        var bases: [String: String] = [:]
    }

    struct Turn: Equatable {
        var fromPerson: Bool
        var text: String
    }

    var origin: SecondOpinionOrigin = .header
    var answer: Answer?
    // Every uncommitted file, in every project the session works in.
    var files: [File] = []
    // Nil while the Changes screen compares with the last commit, or when the branch
    // changes nothing that is not also uncommitted.
    var branch: Branch?
    // The file picked on the Changes screen, which a review can be held to. While that
    // screen compares with a base, its counts are against the base too.
    var file: File?
    // A review has been sent, so what changed after it can be read on its own.
    var canReadSince = false
    // The design's screen titles. Nil when there is no design to look at.
    var designScreens: [String]?
    var turns: [Turn] = []
    // The page in view is the design, so the header's ask is about it.
    var showsDesign = false
    var showsChanges = false
    var repositories: [ReviewRepository] = []
    var compareRefs: [String: String] = [:]
    var headRoots: Set<String> = []
    var reviewTrees: [String: String] = [:]
}

enum SecondOpinionAsk {
    // MARK: Stops

    static func stops(_ facts: SecondOpinionAskFacts) -> [SecondOpinionStop] {
        var stops: [SecondOpinionStop] = []
        if facts.file != nil { stops.append(.file) }
        if facts.answer != nil { stops.append(.answer) }
        if facts.canReadSince { stops.append(.sinceReview) }
        if !facts.files.isEmpty || !facts.repositories.isEmpty { stops.append(.uncommitted) }
        if facts.branch?.files.isEmpty == false { stops.append(.branch) }
        if facts.designScreens != nil { stops.append(.design) }
        if facts.turns.contains(where: { !$0.fromPerson }) { stops.append(.conversation) }
        return stops
    }

    // What a click proposes before the person changes anything. Under an answer or on a
    // file it is that thing. From the header it is named by where the work stands: a plan
    // waiting on an answer first, then the design when it is on screen, then the changes
    // as the Changes screen compares them: the whole branch when it shows that, else the
    // uncommitted changes, so a review never misses work that is not committed yet.
    static func initialStop(_ facts: SecondOpinionAskFacts, defaults: SecondOpinionDefaults? = nil) -> SecondOpinionStop? {
        let stops = stops(facts)
        if let defaults, facts.origin == .header, !facts.showsChanges, !facts.showsDesign,
           facts.answer?.subject.kind != .plan, facts.answer != nil {
            return defaults.chatSubject == .conversation && stops.contains(.conversation) ? .conversation : .answer
        }
        let preferred: [SecondOpinionStop] = switch facts.origin {
        case .answer: [.answer]
        case .file: [.file]
        case .header:
            (facts.answer?.subject.kind == .plan ? [.answer] : [])
                + (facts.showsDesign ? [.design] : [])
                + [.branch, .uncommitted, .answer, .design]
        }
        return preferred.first(where: stops.contains) ?? stops.first
    }

    // MARK: Words

    // The short label used when choosing a subject or scope.
    static func stopTitle(_ stop: SecondOpinionStop, facts: SecondOpinionAskFacts) -> String {
        switch stop {
        case .file: "This file"
        case .answer:
            facts.answer?.subject.kind == .plan ? "This plan" : facts.answer?.picked == true ? "This answer" : "Last answer"
        case .sinceReview: "Since review"
        case .uncommitted: "Not committed"
        case .branch: "Whole branch"
        case .design: "Design"
        case .conversation: "Whole chat"
        }
    }

    // The subject's name in the preview.
    static func title(_ stop: SecondOpinionStop, facts: SecondOpinionAskFacts) -> String {
        switch stop {
        case .file: facts.file?.name ?? "This file"
        case .answer:
            facts.answer?.subject.kind == .plan ? "This plan" : facts.answer?.picked == true ? "This answer" : "The last answer"
        case .sinceReview: "Since your last review"
        case .uncommitted: "Uncommitted changes"
        case .branch: "Changes from " + (facts.branch?.base ?? "the base")
        case .design: "The design"
        case .conversation: "The whole conversation"
        }
    }

    // The fact beside the name. Code also shows its lines added and removed.
    static func fact(_ stop: SecondOpinionStop, facts: SecondOpinionAskFacts) -> String? {
        switch stop {
        case .file: nil
        case .answer: "and what you asked"
        case .sinceReview: "only what changed after it was sent"
        case .uncommitted: counted(facts.files.count, "file")
        case .branch: counted(facts.branch?.files.count ?? 0, "file")
        case .design: counted(facts.designScreens?.count ?? 0, "screen") + ", light and dark"
        case .conversation:
            counted(facts.turns.count(where: { !$0.fromPerson }), "turn") + ", checked against what you asked"
        }
    }

    // The subject as it reads inside a sentence.
    static func phrase(_ stop: SecondOpinionStop, facts: SecondOpinionAskFacts) -> String {
        switch stop {
        case .file: facts.file?.name ?? "this file"
        case .answer:
            facts.answer?.subject.kind == .plan ? "this plan" : facts.answer?.picked == true ? "this answer" : "the last answer"
        case .sinceReview: "what changed since your last review"
        case .uncommitted: "the uncommitted changes"
        case .branch: "everything this branch changes from " + (facts.branch?.base ?? "its base")
        case .design: "the design"
        case .conversation: "the whole conversation"
        }
    }

    // The sentence a click proposes, for the tooltip on each way in.
    static func proposal(_ stop: SecondOpinionStop?, facts: SecondOpinionAskFacts,
                         reviewers: [AgentKind]) -> String {
        guard let stop else { return "Nothing to review yet" }
        guard !reviewers.isEmpty else { return "Another agent reviews " + phrase(stop, facts: facts) }
        return SecondOpinionLineup.names(reviewers) + (reviewers.count > 1 ? " review " : " reviews ")
            + phrase(stop, facts: facts)
    }

    // The files the preview lists for a code stop. The branch and a file picked on it are
    // counted against the base, the rest against the last commit.
    static func files(_ stop: SecondOpinionStop, facts: SecondOpinionAskFacts) -> [SecondOpinionAskFacts.File] {
        switch stop {
        case .branch, .file: facts.branch?.files ?? facts.files
        default: facts.files
        }
    }

    // The files a stop covers, which the preview lights. Nil for a stop that is not code.
    static func litFiles(_ stop: SecondOpinionStop, facts: SecondOpinionAskFacts,
                         sinceReview: Set<String>?) -> Set<String>? {
        switch stop {
        case .file: facts.file.map { [$0.id] } ?? []
        case .uncommitted: Set(facts.files.map(\.id))
        case .branch: Set((facts.branch?.files ?? []).map(\.id))
        case .sinceReview: sinceReview ?? []
        case .answer, .design, .conversation: nil
        }
    }

    // MARK: The button

    // Each seat once, in the order picked. Two seats can run one agent on two models.
    static func seated(_ lineup: [SecondOpinion.Reviewer]) -> [SecondOpinion.Reviewer] {
        var seen = Set<SecondOpinion.Reviewer>()
        return lineup.filter { seen.insert($0).inserted }
    }

    // The Ask button names who is asked, or says what is missing.
    static func askTitle(lineup: [SecondOpinion.Reviewer], hasFocus: Bool) -> String {
        let chosen = seated(lineup)
        guard !chosen.isEmpty else { return "Pick a reviewer" }
        guard hasFocus else { return "Pick what to look for" }
        var seen = Set<AgentKind>()
        let agents = chosen.map(\.agent).filter { seen.insert($0).inserted }
        if chosen.count == agents.count && agents.count <= 2 {
            return "Ask " + agents.map(\.title).joined(separator: " and ")
        }
        return "Ask \(chosen.count) reviewers"
    }

    // What the reviewers can reach, under the tray. With MCP servers open it says they
    // get only the tools a server marks read-only, since the mark is the server's word.
    static func safety(_ kind: SecondOpinionStop.Kind, usesServers: Bool, author: AgentKind) -> String {
        let open = "They can use the tools your MCP servers mark read-only."
        switch (kind, usesServers) {
        case (.chat, false):
            return "Read-only, and without your MCP servers. \(author.title) sees nothing they say until you send it."
        case (.chat, true):
            return "They can read files but not change them. \(open) \(author.title) sees nothing they say until you send it."
        case (.changes, false):
            return "They can read files but not change them, and run without your MCP servers."
        case (.changes, true):
            return "They can read files but not change them. " + open
        case (.design, false):
            return "They look and read. They cannot change the design or use your MCP servers."
        case (.design, true):
            return "They look and read, and cannot change the design. " + open
        }
    }

    static func blockedReason(lineup: [SecondOpinion.Reviewer], hasFocus: Bool) -> String? {
        guard !lineup.isEmpty else { return "Choose at least one reviewer." }
        guard hasFocus else { return "Choose what to look for or add a note." }
        return nil
    }
}
