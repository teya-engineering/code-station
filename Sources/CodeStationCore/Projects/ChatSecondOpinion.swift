import Foundation

// Other agents judge a plan or an answer before the person acts on it. Each comes back
// with a verdict and a few points, which wait on a card in Chat: only the points the
// person ticks and sends ever reach the agent that wrote the plan.
public enum ChatSecondOpinion {
    // What is being judged: a plan the agent is waiting to have approved, or an answer
    // it already gave. The id is the plan's request or the answer's message.
    public struct Subject: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case plan, answer
        }

        public var kind: Kind
        public var id: String
        public var text: String
        // What the person asked for, which the plan or answer is measured against.
        public var request: String

        public var noun: String { kind == .plan ? "plan" : "answer" }

        public init(kind: Kind, id: String, text: String, request: String) {
            self.kind = kind
            self.id = id
            self.text = text
            self.request = request
        }
    }

    public enum Focus: String, CaseIterable, Sendable {
        case wrongAssumptions, risks, missingSteps, simplerWay

        public static let standard: [Focus] = [.wrongAssumptions, .risks, .missingSteps]

        public var title: String {
            switch self {
            case .wrongAssumptions: "Wrong assumptions"
            case .risks: "Risks"
            case .missingSteps: "Missing steps"
            case .simplerWay: "A simpler way"
            }
        }

        public var ask: String {
            switch self {
            case .wrongAssumptions: "assumptions about the code or the request that are wrong"
            case .risks: "risks: data loss, double effects, security, things that break for users"
            case .missingSteps: "steps that are missing, such as a migration, a test or a rollout"
            case .simplerWay: "a simpler way to get the same result"
            }
        }
    }

    // What a reviewer is given to read. The subject and the request always go; the
    // project's files and the whole conversation are the person's choice, and the
    // conversation is off by default because it makes a reviewer think like the author.
    public struct Reading: Equatable, Sendable {
        public var files = true
        public var conversation = false

        public init(files: Bool = true, conversation: Bool = false) {
            self.files = files
            self.conversation = conversation
        }
    }

    public struct Request: Equatable, Sendable {
        public var subject: Subject
        public var focus: [Focus] = Focus.standard
        public var reading = Reading()
        // The latest turns as text, sent only when the person ticks the conversation.
        public var conversation = ""
        public var directories: [String]
        public var executable: String

        public init(subject: Subject, focus: [Focus] = Focus.standard, reading: Reading = Reading(),
                    conversation: String = "", directories: [String], executable: String) {
            self.subject = subject
            self.focus = focus
            self.reading = reading
            self.conversation = conversation
            self.directories = directories
            self.executable = executable
        }
    }

    public enum Verdict: String, Sendable, CaseIterable {
        case agrees
        case agreesWithChanges = "agrees_with_changes"
        case disagrees

        public var label: String {
            switch self {
            case .agrees: "Agrees"
            case .agreesWithChanges: "Agrees, with changes"
            case .disagrees: "Disagrees"
            }
        }

        public var symbol: String {
            switch self {
            case .agrees: "hand.thumbsup.fill"
            case .agreesWithChanges: "hand.thumbsup"
            case .disagrees: "arrow.triangle.branch"
            }
        }
    }

    // One thing a reviewer raised, on a step of the plan where it has one.
    public struct Point: Equatable, Sendable {
        public var step: Int?
        public var severity: ReviewComment.Severity
        public var text: String
    }

    public struct Reply: Equatable, Sendable {
        public var verdict: Verdict
        public var summary: String
        public var points: [Point]
    }

    public static let maxPoints = 6

    // MARK: - Asking

    public static func prompt(for request: Request) -> String {
        let subject = request.subject
        let asks = (request.focus.isEmpty ? Focus.standard : Focus.allCases.filter(request.focus.contains)).map(\.ask)
        var text = """
        Another coding agent wrote the \(subject.noun) below for a person. You are giving a second opinion before they act on it. Do not change any files or run commands that change anything.

        Look for \(asks.joined(separator: "; ")). Skip style, wording and praise. Raise at most \(maxPoints) points, the most important first. If the \(subject.noun) is sound, say so and raise nothing.
        """
        text += request.reading.files
            ? "\n\nYou may read the project's files to check the \(subject.noun) against the code."
            : "\n\nJudge from the \(subject.noun) and the request alone. Do not open the project's files."
        text += """


        Reply with only a JSON object and no other text:
        {"verdict": "agrees" | "agrees_with_changes" | "disagrees", "summary": "<one or two sentences for the person>", "points": [{"step": <number of the \(subject.kind == .plan ? "plan step" : "paragraph") it is about, or null>, "severity": "must" | "should" | "look", "text": "<one or two sentences addressed to the author>"}]}
        Use "must" for something that will break or is unsafe, "should" for a real problem worth fixing first, and "look" for something worth a second look.
        """
        if request.reading.conversation, !request.conversation.isBlank {
            text += "\n\nThe conversation so far:\n" + request.conversation
        }
        text += "\n\nWhat the person asked for:\n" + subject.request.trimmed
        text += "\n\nThe \(subject.noun):\n" + subject.text.trimmed
        return text
    }

    public static func ask(_ request: Request, reviewer: SecondOpinion.Reviewer, searchPath: String,
                    activity: @escaping @Sendable (String) -> Void = { _ in }) async -> Result<Reply, SecondOpinion.Failure> {
        guard let directory = request.directories.first else {
            return .failure(.init(message: "There is no project folder to read from."))
        }
        let prompt = prompt(for: request)
        let output = await SecondOpinion.run(agent: reviewer.agent, executable: request.executable,
                                             searchPath: searchPath, directory: directory,
                                             timeout: .seconds(420), writing: "Writing its verdict",
                                             activity: activity) { codexServers, copilotServers in
            SecondOpinion.arguments(for: reviewer, prompt: prompt,
                                    addDirectories: Array(request.directories.dropFirst()),
                                    codexServers: codexServers, copilotServers: copilotServers)
        }
        switch output {
        case .failure(let failure):
            return .failure(failure)
        case .success(let raw):
            let answer = SecondOpinion.answer(from: raw, agent: reviewer.agent)
            guard let reply = reply(in: answer) else {
                SessionLog.note("\(reviewer.agent.command) chat second opinion was unreadable: " + String(answer.prefix(400)))
                return .failure(.init(message: "Its answer was not a verdict."))
            }
            return .success(reply)
        }
    }

    // MARK: - Reading the answer

    private struct Decoded: Decodable {
        public struct Item: Decodable {
            public var step: Int?
            public var severity: String?
            public var text: String?
        }

        public var verdict: String
        public var summary: String?
        public var points: [Item]?
    }

    // The last JSON object in the text that holds a verdict this knows. Models wrap
    // their answer in a fence or a sentence, so the object is found rather than expected.
    public static func reply(in text: String) -> Reply? {
        var found: Reply?
        for candidate in SecondOpinion.jsonRuns(in: text, open: "{", close: "}") {
            guard let data = candidate.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Decoded.self, from: data),
                  let verdict = Verdict(rawValue: decoded.verdict.lowercased()) else { continue }
            let points = (decoded.points ?? []).compactMap { item -> Point? in
                guard let words = item.text?.trimmed, !words.isEmpty else { return nil }
                return Point(step: item.step.flatMap { $0 > 0 ? $0 : nil },
                             severity: item.severity.flatMap { ReviewComment.Severity(rawValue: $0.lowercased()) } ?? .look,
                             text: words)
            }
            found = Reply(verdict: verdict, summary: decoded.summary?.trimmed ?? "",
                          points: Array(points.prefix(maxPoints)))
        }
        return found
    }

    // MARK: - Sending back

    // The message the author gets: who looked, and the points the person ticked. It says
    // they are points to weigh, since the person chose them but did not write them.
    public static func feedback(_ points: [ChatOpinion.RaisedPoint], subject: Subject, names: String) -> String {
        let lines = points.map { point in
            (point.step.map { "- Step \($0). " } ?? "- ") + point.text
        }
        let lead = subject.kind == .plan
            ? "Before you start, \(names) looked at the plan. Change it for these:"
            : "\(names) looked at your answer. Take these into account:"
        return lead + "\n" + lines.joined(separator: "\n")
    }
}

// One second opinion on one plan or answer: the seats asked, how each is doing, and the
// points they raised, merged where two raised the same step.
public struct ChatOpinion: Identifiable, Equatable {
    public struct Lane: Equatable, Identifiable {
        public enum State: Equatable {
            case running
            case finished(ChatSecondOpinion.Verdict, summary: String)
            case failed(String)
        }

        public var reviewer: SecondOpinion.Reviewer
        public var started = Date()
        public var ended: Date?
        public var state: State = .running
        public var activity = "Reading the plan"

        public var id: SecondOpinion.Reviewer { reviewer }
        public var isRunning: Bool { state == .running }
    }

    // A reviewer's words on a point, with the seat that said them.
    public struct Voice: Equatable {
        public var reviewer: SecondOpinion.Reviewer
        public var text: String
    }

    public struct RaisedPoint: Equatable, Identifiable {
        public var id = UUID()
        public var step: Int?
        public var severity: ReviewComment.Severity
        public var voices: [Voice]
        // Only ticked points are sent. Worth-a-look points start unticked.
        public var ticked: Bool

        public var text: String { voices.first?.text ?? "" }
        public var raisedByMoreThanOne: Bool { voices.count > 1 }
    }

    public var id = UUID()
    public var subject: ChatSecondOpinion.Subject
    // The message the card is drawn after, so it stays joined to what it judged.
    public var anchor: UUID?
    public var request: ChatSecondOpinion.Request
    public var lanes: [Lane]
    public var points: [RaisedPoint] = []
    // How many points went back, once they have.
    public var sent: Int?

    public var isRunning: Bool { lanes.contains(where: \.isRunning) }
    public var finishedCount: Int { lanes.count { !$0.isRunning } }
    public var ticked: [RaisedPoint] { points.filter(\.ticked) }

    // A point on a step another seat already raised joins it, so the same problem is read
    // and sent once and says that more than one reviewer saw it.
    public mutating func take(_ reply: ChatSecondOpinion.Reply, from reviewer: SecondOpinion.Reviewer) {
        for point in reply.points {
            if let step = point.step,
               let twin = points.firstIndex(where: { $0.step == step && !$0.voices.contains { $0.reviewer == reviewer } }) {
                points[twin].voices.append(Voice(reviewer: reviewer, text: point.text))
                if Self.rank(point.severity) < Self.rank(points[twin].severity) {
                    points[twin].severity = point.severity
                    points[twin].ticked = points[twin].ticked || point.severity != .look
                }
            } else {
                points.append(RaisedPoint(step: point.step, severity: point.severity,
                                          voices: [Voice(reviewer: reviewer, text: point.text)],
                                          ticked: point.severity != .look))
            }
        }
        points.sort { Self.rank($0.severity) < Self.rank($1.severity) }
    }

    private static func rank(_ severity: ReviewComment.Severity) -> Int {
        ReviewComment.Severity.allCases.firstIndex(of: severity) ?? 0
    }
}

// Every session's second opinions in Chat. Kept only while the app runs: the plan they
// judge is gone once it is answered, and the points that mattered are in the conversation.
@MainActor
@Observable
public final class ChatOpinionStore {
    public private(set) var opinions: [UUID: [ChatOpinion]] = [:]
    // Each opinion's runs, by the opinion's id.
    @ObservationIgnored private var tasks: [UUID: [SecondOpinion.Reviewer: Task<Void, Never>]] = [:]
    // How a reviewer is asked; tests swap in their own so nothing is run.
    @ObservationIgnored public var askReviewer: @Sendable (ChatSecondOpinion.Request, SecondOpinion.Reviewer, String,
                                                    @escaping @Sendable (String) -> Void)
        async -> Result<ChatSecondOpinion.Reply, SecondOpinion.Failure> = { request, reviewer, path, activity in
            await ChatSecondOpinion.ask(request, reviewer: reviewer, searchPath: path, activity: activity)
        }

    public func opinions(_ sessionID: UUID) -> [ChatOpinion] { opinions[sessionID] ?? [] }

    // The latest opinion on a subject. Asking again replaces it.
    public func opinion(on subjectID: String, in sessionID: UUID) -> ChatOpinion? {
        opinions(sessionID).last { $0.subject.id == subjectID }
    }

    @discardableResult
    public func ask(_ request: ChatSecondOpinion.Request, reviewers: [SecondOpinion.Reviewer],
             executables: [AgentKind: String], anchor: UUID?, in sessionID: UUID) -> UUID? {
        var seen = Set<SecondOpinion.Reviewer>()
        let seats = reviewers.filter { executables[$0.agent] != nil && seen.insert($0).inserted }
        guard !seats.isEmpty else { return nil }
        for earlier in opinions(sessionID) where earlier.subject.id == request.subject.id { cancel(earlier.id) }
        opinions[sessionID]?.removeAll { $0.subject.id == request.subject.id }
        let opinion = ChatOpinion(subject: request.subject, anchor: anchor, request: request,
                                  lanes: seats.map { ChatOpinion.Lane(reviewer: $0,
                                                                      activity: "Reading the \(request.subject.noun)") })
        opinions[sessionID, default: []].append(opinion)
        for seat in seats {
            start(seat, of: opinion.id, request: request,
                  executable: executables[seat.agent] ?? request.executable, in: sessionID)
        }
        return opinion.id
    }

    // A seat that could not finish asks again with the same request.
    public func retry(_ seat: SecondOpinion.Reviewer, of id: UUID, executable: String, in sessionID: UUID) {
        guard let opinion = opinions(sessionID).first(where: { $0.id == id }),
              opinion.lanes.first(where: { $0.reviewer == seat })?.isRunning == false else { return }
        update(id, in: sessionID, seat: seat) { lane in
            lane = ChatOpinion.Lane(reviewer: seat, activity: "Reading the \(opinion.subject.noun)")
        }
        start(seat, of: id, request: opinion.request, executable: executable, in: sessionID)
    }

    private func start(_ seat: SecondOpinion.Reviewer, of id: UUID, request: ChatSecondOpinion.Request,
                       executable: String, in sessionID: UUID) {
        var asked = request
        asked.executable = executable
        let searchPath = ExecutableSearch.searchPath
        let ask = askReviewer
        tasks[id, default: [:]][seat] = Task { [weak self, asked] in
            let outcome = await ask(asked, seat, searchPath) { [weak self] text in
                Task { @MainActor in self?.update(id, in: sessionID, seat: seat) { $0.activity = text } }
            }
            guard !Task.isCancelled else { return }
            self?.finish(id, seat: seat, outcome: outcome, in: sessionID)
        }
    }

    // Stopping a seat drops its lane: there is nothing it came to. An opinion with no
    // seats left goes too.
    public func stop(_ seat: SecondOpinion.Reviewer, of id: UUID, in sessionID: UUID) {
        tasks[id]?[seat]?.cancel()
        tasks[id]?[seat] = nil
        guard let index = opinions[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        opinions[sessionID]?[index].lanes.removeAll { $0.reviewer == seat }
        if opinions[sessionID]?[index].lanes.isEmpty == true { dismiss(id, in: sessionID) }
    }

    // Called by each seat's run when it ends; tests call it directly.
    public func finish(_ id: UUID, seat: SecondOpinion.Reviewer,
                outcome: Result<ChatSecondOpinion.Reply, SecondOpinion.Failure>, in sessionID: UUID) {
        guard let index = opinions[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        tasks[id]?[seat] = nil
        if case .success(let reply) = outcome { opinions[sessionID]?[index].take(reply, from: seat) }
        update(id, in: sessionID, seat: seat) { lane in
            lane.ended = Date()
            switch outcome {
            case .success(let reply): lane.state = .finished(reply.verdict, summary: reply.summary)
            case .failure(let failure): lane.state = .failed(failure.message)
            }
        }
    }

    public func toggle(_ pointID: UUID, of id: UUID, in sessionID: UUID) {
        guard let index = opinions[sessionID]?.firstIndex(where: { $0.id == id }),
              let point = opinions[sessionID]?[index].points.firstIndex(where: { $0.id == pointID }) else { return }
        opinions[sessionID]?[index].points[point].ticked.toggle()
    }

    public func markSent(_ id: UUID, count: Int, in sessionID: UUID) {
        guard let index = opinions[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        opinions[sessionID]?[index].sent = count
    }

    public func dismiss(_ id: UUID, in sessionID: UUID) {
        cancel(id)
        opinions[sessionID]?.removeAll { $0.id == id }
        if opinions[sessionID]?.isEmpty == true { opinions[sessionID] = nil }
    }

    // The session is gone, so is everything said about it.
    public func remove(_ sessionID: UUID) {
        for opinion in opinions(sessionID) { cancel(opinion.id) }
        opinions[sessionID] = nil
    }

    private func cancel(_ id: UUID) {
        for task in (tasks[id] ?? [:]).values { task.cancel() }
        tasks[id] = nil
    }

    private func update(_ id: UUID, in sessionID: UUID, seat: SecondOpinion.Reviewer,
                        _ change: (inout ChatOpinion.Lane) -> Void) {
        guard let index = opinions[sessionID]?.firstIndex(where: { $0.id == id }),
              let lane = opinions[sessionID]?[index].lanes.firstIndex(where: { $0.reviewer == seat }) else { return }
        change(&opinions[sessionID]![index].lanes[lane])
    }
}
