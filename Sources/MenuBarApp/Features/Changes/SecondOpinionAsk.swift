import Foundation

// What a second opinion can be about, from the narrowest thing to read to the widest.
// The ask shows them as stops along one track, and only the stops with something behind
// them: no "Not committed" when nothing is, no "Whole chat" before there is a chat.
enum SecondOpinionStop: Hashable, CaseIterable {
    case file, answer, sinceReview, uncommitted, design, conversation

    // Where the results land: a card under the answer, findings on the diff, or notes
    // pinned on the design.
    enum Kind: Hashable {
        case chat, changes, design
    }

    var kind: Kind {
        switch self {
        case .answer, .conversation: .chat
        case .file, .sinceReview, .uncommitted: .changes
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

    struct File: Equatable, Identifiable {
        var root: String
        var path: String
        var added: Int
        var removed: Int

        var id: String { root + "\u{0}" + path }
        var name: String { (path as NSString).lastPathComponent }
    }

    struct Turn: Equatable {
        var fromPerson: Bool
        var text: String
    }

    var origin: SecondOpinionOrigin = .header
    var answer: Answer?
    // Every uncommitted file, in every project the session works in.
    var files: [File] = []
    // The file picked on the Changes screen, which a review can be held to.
    var file: File?
    // A review has been sent, so what changed after it can be read on its own.
    var canReadSince = false
    // The design's screen titles. Nil when there is no design to look at.
    var designScreens: [String]?
    var turns: [Turn] = []
    // The page in view is the design, so the header's ask is about it.
    var showsDesign = false
}

enum SecondOpinionAsk {
    // MARK: Stops

    static func stops(_ facts: SecondOpinionAskFacts) -> [SecondOpinionStop] {
        var stops: [SecondOpinionStop] = []
        if facts.file != nil { stops.append(.file) }
        if facts.answer != nil { stops.append(.answer) }
        if facts.canReadSince && !facts.files.isEmpty { stops.append(.sinceReview) }
        if !facts.files.isEmpty { stops.append(.uncommitted) }
        if facts.designScreens != nil { stops.append(.design) }
        // With one answer, the whole chat is that answer and its question, which the
        // answer's own stop already reads.
        if facts.turns.count(where: { !$0.fromPerson }) > 1 { stops.append(.conversation) }
        return stops
    }

    // What a click proposes before the person changes anything. Under an answer or on a
    // file it is that thing. From the header it is named by where the work stands: a plan
    // waiting on an answer first, then the design when it is on screen, then the
    // uncommitted changes, so a review never misses work that is not committed yet.
    static func initialStop(_ facts: SecondOpinionAskFacts) -> SecondOpinionStop? {
        let stops = stops(facts)
        let preferred: [SecondOpinionStop] = switch facts.origin {
        case .answer: [.answer]
        case .file: [.file]
        case .header:
            (facts.answer?.subject.kind == .plan ? [.answer] : [])
                + (facts.showsDesign ? [.design] : [])
                + [.uncommitted, .answer, .design]
        }
        return preferred.first(where: stops.contains) ?? stops.first
    }

    // MARK: Words

    // The few words a stop wears on the track.
    static func stopTitle(_ stop: SecondOpinionStop, facts: SecondOpinionAskFacts) -> String {
        switch stop {
        case .file: "This file"
        case .answer:
            facts.answer?.subject.kind == .plan ? "This plan" : facts.answer?.picked == true ? "This answer" : "Last answer"
        case .sinceReview: "Since review"
        case .uncommitted: "Not committed"
        case .design: "Design"
        case .conversation: "Whole chat"
        }
    }

    // The subject's name over the track.
    static func title(_ stop: SecondOpinionStop, facts: SecondOpinionAskFacts) -> String {
        switch stop {
        case .file: facts.file?.name ?? "This file"
        case .answer:
            facts.answer?.subject.kind == .plan ? "This plan" : facts.answer?.picked == true ? "This answer" : "The last answer"
        case .sinceReview: "Since your last review"
        case .uncommitted: "Uncommitted changes"
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

    // The files a stop covers, which the preview lights. Nil for a stop that is not code.
    static func litFiles(_ stop: SecondOpinionStop, facts: SecondOpinionAskFacts,
                         sinceReview: Set<String>?) -> Set<String>? {
        switch stop {
        case .file: facts.file.map { [$0.id] } ?? []
        case .uncommitted: Set(facts.files.map(\.id))
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

    static func estimate(lineup: [SecondOpinion.Reviewer]) -> String {
        let chosen = seated(lineup)
        guard !chosen.isEmpty else { return "Nobody is picked to ask." }
        let minutes = chosen.map { SecondOpinion.minutes(for: $0.effort) }.max() ?? 0
        return "About \(minutes) min. You can keep working."
    }
}
