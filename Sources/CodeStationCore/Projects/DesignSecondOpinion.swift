import Foundation

// Other agents look at a design's screens before it is built and pin notes to the spots
// they are about. Notes wait in a panel beside the canvas: only the ones the person keeps
// go back to the design agent, as their next prompt.
public enum DesignSecondOpinion {
    public enum Focus: String, CaseIterable, Sendable {
        case hierarchy, accessibility, copy, missingStates, fitsProduct

        public static let standard: [Focus] = [.hierarchy, .accessibility, .copy, .missingStates]

        public var title: String {
            switch self {
            case .hierarchy: "Hierarchy"
            case .accessibility: "Accessibility"
            case .copy: "Copy"
            case .missingStates: "Missing states"
            case .fitsProduct: "Fits the product"
            }
        }

        public var ask: String {
            switch self {
            case .hierarchy: "hierarchy: what draws the eye first, and whether the main action is the most visible"
            case .accessibility: "accessibility: text contrast below 4.5 to 1, small targets, meaning carried by colour alone"
            case .copy: "copy that is unclear, too long or not written for the person reading it"
            case .missingStates: "states the design does not show, such as empty, loading, error or declined"
            case .fitsProduct: "places that do not fit the rest of the product's look and patterns"
            }
        }
    }

    // What a reviewer looks at. Pictures of every screen always go; the files and the
    // design conversation are the person's to choose, and the conversation is off by
    // default because it makes a reviewer think like the author.
    public struct Reading: Equatable, Sendable {
        public var source = true
        public var conversation = false

        public init(source: Bool = true, conversation: Bool = false) {
            self.source = source
            self.conversation = conversation
        }
    }

    // A screen's pictures as the reviewer is shown them. A design with no dark style
    // has no dark picture.
    public struct Shot: Equatable, Sendable {
        public var screen: DesignScreen
        public var light: String
        public var dark: String?

        public init(screen: DesignScreen, light: String, dark: String? = nil) {
            self.screen = screen
            self.light = light
            self.dark = dark
        }
    }

    public struct Request: Equatable, Sendable {
        public var focus: [Focus] = Focus.standard
        public var reading = Reading()
        public var designDirectory: String
        public var shotsDirectory: String
        public var shots: [Shot]
        // What the person asked the design agent for, the latest first.
        public var asked: String
        public var conversation = ""
        public var executable: String

        public init(focus: [Focus] = Focus.standard, reading: Reading = Reading(), designDirectory: String,
                    shotsDirectory: String, shots: [Shot], asked: String, conversation: String = "",
                    executable: String) {
            self.focus = focus
            self.reading = reading
            self.conversation = conversation
            self.designDirectory = designDirectory
            self.shotsDirectory = shotsDirectory
            self.shots = shots
            self.asked = asked
            self.executable = executable
        }
    }

    // A spot on a screen's picture, in its CSS pixels.
    public struct Box: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    public struct Note: Equatable, Sendable {
        public var screen: String?
        public var selector: String?
        public var box: Box?
        public var category: String
        public var severity: ReviewComment.Severity
        public var text: String
    }

    public static let maxNotes = 8

    // MARK: - Asking

    public static func prompt(for request: Request) -> String {
        let asks = (request.focus.isEmpty ? Focus.standard : Focus.allCases.filter(request.focus.contains)).map(\.ask)
        let categories = Focus.allCases.map { "\"\($0.title)\"" }.joined(separator: " | ")
        var text = """
        Another agent designed the screens below for a person. You are giving a second opinion before it is built. Do not change any files or run commands that change anything.

        Look for \(asks.joined(separator: "; ")). Skip taste, praise and anything the design already does well. Raise at most \(maxNotes) notes, the most important first. If nothing is worth raising, return no notes.

        Open each picture below to look at the screen. Pictures are in CSS pixels.
        """
        for shot in request.shots {
            let size = [shot.screen.width, shot.screen.height].compactMap { $0 }.map(String.init).joined(separator: "x")
            text += "\n- Screen \"\(shot.screen.id)\" (\(shot.screen.title), \(shot.screen.path)\(size.isEmpty ? "" : ", " + size)): light \(shot.light)"
            if let dark = shot.dark { text += ", dark \(dark)" }
        }
        text += request.reading.source
            ? "\n\nThe HTML, any handoff.md and the theme are in \(request.designDirectory). Read them to check contrast and tokens, and to name the element a note is about by a CSS selector that matches it in that screen's HTML."
            : "\n\nJudge from the pictures alone. Do not open the design's files. Point at a spot with a box instead of a selector."
        text += """


        Reply with only a JSON object and no other text:
        {"notes": [{"screen": "<screen id, or null for the whole design>", "selector": "<CSS selector of the element, or null>", "box": {"x": 0, "y": 0, "width": 0, "height": 0} or null, "category": \(categories), "severity": "must" | "should" | "look", "text": "<one or two sentences addressed to the designer>"}]}
        Use "must" for something that will fail people, "should" for a real problem worth fixing before it is built, and "look" for something worth a second look.
        """
        if request.reading.conversation, !request.conversation.isBlank {
            text += "\n\nThe design conversation so far:\n" + request.conversation
        }
        if !request.asked.isBlank {
            text += "\n\nWhat the person asked for:\n" + request.asked.trimmed
        }
        return text
    }

    // Read-only like every second opinion. Codex is handed the pictures as images; the
    // others are given their folder to read them from.
    public static func arguments(for reviewer: SecondOpinion.Reviewer, request: Request, prompt: String,
                          codexServers: [DisabledMCPServer] = [], copilotServers: [String] = []) -> [String] {
        let folders = request.reading.source ? [request.shotsDirectory] : []
        var arguments = SecondOpinion.arguments(for: reviewer, prompt: prompt, addDirectories: folders,
                                                codexServers: codexServers, copilotServers: copilotServers)
        if reviewer.agent == .codex, let end = arguments.lastIndex(of: "--") {
            let images = request.shots.flatMap { [$0.light] + ($0.dark.map { [$0] } ?? []) }
            arguments.insert(contentsOf: images.flatMap { ["--image", $0] }, at: end)
        }
        return arguments
    }

    public static func ask(_ request: Request, reviewer: SecondOpinion.Reviewer, searchPath: String,
                    activity: @escaping @Sendable (String) -> Void = { _ in }) async -> Result<[Note], SecondOpinion.Failure> {
        guard !request.shots.isEmpty else { return .failure(.init(message: "No screen could be pictured.")) }
        let prompt = prompt(for: request)
        // Without the files the reviewer starts among the pictures, away from the source.
        let directory = request.reading.source ? request.designDirectory : request.shotsDirectory
        let output = await SecondOpinion.run(agent: reviewer.agent, executable: request.executable,
                                             searchPath: searchPath, directory: directory,
                                             timeout: .seconds(480), writing: "Writing its notes",
                                             activity: activity) { codexServers, copilotServers in
            arguments(for: reviewer, request: request, prompt: prompt,
                      codexServers: codexServers, copilotServers: copilotServers)
        }
        switch output {
        case .failure(let failure):
            return .failure(failure)
        case .success(let raw):
            let answer = SecondOpinion.answer(from: raw, agent: reviewer.agent)
            guard let notes = notes(in: answer) else {
                SessionLog.note("\(reviewer.agent.command) design second opinion was unreadable: " + String(answer.prefix(400)))
                return .failure(.init(message: "Its answer was not a list of notes."))
            }
            return .success(notes)
        }
    }

    // MARK: - Reading the answer

    private struct Decoded: Decodable {
        public struct Item: Decodable {
            public var screen: String?
            public var selector: String?
            public var box: Box?
            public var category: String?
            public var severity: String?
            public var text: String?
        }

        public var notes: [Item]
    }

    // The last JSON object holding a list of notes. Nil when there is none, which is not
    // the same as an empty list: that is a reviewer saying it found nothing.
    public static func notes(in text: String) -> [Note]? {
        var found: [Note]?
        for candidate in SecondOpinion.jsonRuns(in: text, open: "{", close: "}") {
            guard let data = candidate.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Decoded.self, from: data) else { continue }
            found = decoded.notes.compactMap { item in
                guard let words = item.text?.trimmed, !words.isEmpty else { return nil }
                let box = item.box.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
                return Note(screen: item.screen?.trimmed.nilIfEmpty, selector: item.selector?.trimmed.nilIfEmpty,
                            box: box, category: item.category?.trimmed.nilIfEmpty ?? "Note",
                            severity: item.severity.flatMap { ReviewComment.Severity(rawValue: $0.lowercased()) } ?? .look,
                            text: words)
            }
        }
        return found.map { Array($0.prefix(maxNotes)) }
    }

    // MARK: - Sending back

    // The prompt the design agent gets: the kept notes, each with where it is.
    public static func feedback(_ notes: [DesignOpinion.PinnedNote], screens: [DesignScreen], names: String) -> String {
        let lines = notes.map { note -> String in
            var place = "the whole design"
            if let id = note.screen {
                place = "the \(screens.first { $0.id == id }?.title ?? id) screen"
                if let selector = note.selector { place += " at `\(selector)`" }
            }
            return "- \(note.category), on \(place): \(note.text)"
        }
        return "\(names) looked at the design. Change it for these:\n" + lines.joined(separator: "\n")
    }
}

private extension String {
    public var nilIfEmpty: String? { isEmpty ? nil : self }
}

// How one reviewer's lane stands: still working, done with what it came to, or failed
// with why. The GUI draws it as a lane; the state is kept here with the opinions.
public enum ReviewLaneState: Equatable, Sendable {
    case running
    case finished(String)
    case failed(String)
}

// One second opinion on a design: the seats asked, how each is doing, and the notes
// they pinned, merged where two pinned the same element.
public struct DesignOpinion: Identifiable, Equatable {
    public struct Lane: Equatable, Identifiable {
        public var reviewer: SecondOpinion.Reviewer
        public var started = Date()
        public var ended: Date?
        public var state: ReviewLaneState = .running
        public var activity = "Taking pictures of the screens"

        public var id: SecondOpinion.Reviewer { reviewer }
        public var isRunning: Bool { state == .running }
    }

    public struct PinnedNote: Equatable, Identifiable {
        public enum Status: Equatable { case pending, kept }

        public var id = UUID()
        public var screen: String?
        public var selector: String?
        public var box: DesignSecondOpinion.Box?
        public var category: String
        public var severity: ReviewComment.Severity
        public var voices: [ChatOpinion.Voice]
        public var status = Status.pending
        // The words that go back, which start as the first reviewer's and can be rewritten.
        public var text: String
        public var edited = false
    }

    public var id = UUID()
    public var request: DesignSecondOpinion.Request
    public var lanes: [Lane]
    public var notes: [PinnedNote] = []
    // How many notes went back, once they have.
    public var sent: Int?

    public var isRunning: Bool { lanes.contains(where: \.isRunning) }
    public var kept: [PinnedNote] { notes.filter { $0.status == .kept } }
    public var pending: [PinnedNote] { notes.filter { $0.status == .pending } }

    public mutating func take(_ found: [DesignSecondOpinion.Note], from reviewer: SecondOpinion.Reviewer) {
        for note in found {
            let voice = ChatOpinion.Voice(reviewer: reviewer, text: note.text)
            if let selector = note.selector,
               let twin = notes.firstIndex(where: {
                   $0.screen == note.screen && $0.selector == selector && !$0.voices.contains { $0.reviewer == reviewer }
               }) {
                notes[twin].voices.append(voice)
                if Self.rank(note.severity) < Self.rank(notes[twin].severity) { notes[twin].severity = note.severity }
            } else {
                notes.append(PinnedNote(screen: note.screen, selector: note.selector, box: note.box,
                                        category: note.category, severity: note.severity,
                                        voices: [voice], text: note.text))
            }
        }
        notes.sort { Self.rank($0.severity) < Self.rank($1.severity) }
    }

    private static func rank(_ severity: ReviewComment.Severity) -> Int {
        ReviewComment.Severity.allCases.firstIndex(of: severity) ?? 0
    }
}

// Each Design session's latest second opinion. Kept only while the app runs, like the
// ones in Chat.
@MainActor
@Observable
public final class DesignOpinionStore {
    public private(set) var opinions: [UUID: DesignOpinion] = [:]
    @ObservationIgnored private var tasks: [UUID: [SecondOpinion.Reviewer: Task<Void, Never>]] = [:]
    @ObservationIgnored private var captures: [UUID: Task<Void, Never>] = [:]
    // How the screens are pictured and a reviewer is asked; tests swap in their own.
    // Pictures need a web view, which only the GUI has, so it hands this in. A front end
    // without one leaves it empty and its reviewers see no screens.
    @ObservationIgnored public var captureScreens: @MainActor ([DesignScreen], URL, URL) async -> [DesignSecondOpinion.Shot] = { _, _, _ in [] }
    @ObservationIgnored public var askReviewer: @Sendable (DesignSecondOpinion.Request, SecondOpinion.Reviewer, String,
                                                    @escaping @Sendable (String) -> Void)
        async -> Result<[DesignSecondOpinion.Note], SecondOpinion.Failure> = { request, reviewer, path, activity in
            await DesignSecondOpinion.ask(request, reviewer: reviewer, searchPath: path, activity: activity)
        }

    public func opinion(_ sessionID: UUID) -> DesignOpinion? { opinions[sessionID] }

    // Pictures every screen once, then asks every seat alongside the others. Asking
    // again replaces the opinion before it.
    public func ask(_ request: DesignSecondOpinion.Request, screens: [DesignScreen], reviewers: [SecondOpinion.Reviewer],
             executables: [AgentKind: String], in sessionID: UUID) {
        var seen = Set<SecondOpinion.Reviewer>()
        let seats = reviewers.filter { executables[$0.agent] != nil && seen.insert($0).inserted }
        guard !seats.isEmpty else { return }
        dismiss(sessionID)
        let opinion = DesignOpinion(request: request, lanes: seats.map { DesignOpinion.Lane(reviewer: $0) })
        opinions[sessionID] = opinion
        let capture = captureScreens
        captures[sessionID] = Task { [weak self] in
            let shots = await capture(screens, URL(fileURLWithPath: request.designDirectory),
                                      URL(fileURLWithPath: request.shotsDirectory))
            guard !Task.isCancelled, let self, self.opinions[sessionID]?.id == opinion.id else { return }
            self.opinions[sessionID]?.request.shots = shots
            for seat in seats {
                self.update(sessionID, seat: seat) { $0.activity = "Looking at \(counted(shots.count, "screen"))" }
                self.start(seat, executable: executables[seat.agent] ?? request.executable, in: sessionID)
            }
        }
    }

    public func retry(_ seat: SecondOpinion.Reviewer, executable: String, in sessionID: UUID) {
        guard opinions[sessionID]?.lanes.first(where: { $0.reviewer == seat })?.isRunning == false else { return }
        update(sessionID, seat: seat) { $0 = DesignOpinion.Lane(reviewer: seat, activity: "Looking at the screens") }
        start(seat, executable: executable, in: sessionID)
    }

    private func start(_ seat: SecondOpinion.Reviewer, executable: String, in sessionID: UUID) {
        guard let opinion = opinions[sessionID] else { return }
        var asked = opinion.request
        asked.executable = executable
        let searchPath = ExecutableSearch.searchPath
        let ask = askReviewer
        let id = opinion.id
        tasks[sessionID, default: [:]][seat] = Task { [weak self, asked] in
            let outcome = await ask(asked, seat, searchPath) { [weak self] text in
                Task { @MainActor in
                    guard self?.opinions[sessionID]?.id == id else { return }
                    self?.update(sessionID, seat: seat) { $0.activity = text }
                }
            }
            guard !Task.isCancelled, let self, self.opinions[sessionID]?.id == id else { return }
            self.finish(seat, outcome: outcome, in: sessionID)
        }
    }

    // Called by each seat's run when it ends; tests call it directly.
    public func finish(_ seat: SecondOpinion.Reviewer, outcome: Result<[DesignSecondOpinion.Note], SecondOpinion.Failure>,
                in sessionID: UUID) {
        tasks[sessionID]?[seat] = nil
        if case .success(let notes) = outcome { opinions[sessionID]?.take(notes, from: seat) }
        update(sessionID, seat: seat) { lane in
            lane.ended = Date()
            switch outcome {
            case .success(let notes): lane.state = .finished(notes.isEmpty ? "Nothing worth raising" : counted(notes.count, "note"))
            case .failure(let failure): lane.state = .failed(failure.message)
            }
        }
    }

    public func stop(_ seat: SecondOpinion.Reviewer, in sessionID: UUID) {
        tasks[sessionID]?[seat]?.cancel()
        tasks[sessionID]?[seat] = nil
        opinions[sessionID]?.lanes.removeAll { $0.reviewer == seat }
        if opinions[sessionID]?.lanes.isEmpty == true { dismiss(sessionID) }
    }

    public func keep(_ noteID: UUID, in sessionID: UUID) {
        change(noteID, in: sessionID) { $0.status = .kept }
    }

    public func edit(_ noteID: UUID, text: String, in sessionID: UUID) {
        let words = text.trimmed
        guard !words.isEmpty else { return }
        change(noteID, in: sessionID) { note in
            note.edited = note.edited || words != note.text
            note.text = words
            note.status = .kept
        }
    }

    // A dismissed note is gone for good, along with its pin.
    public func dismiss(_ noteID: UUID, in sessionID: UUID) {
        opinions[sessionID]?.notes.removeAll { $0.id == noteID }
    }

    public func markSent(count: Int, in sessionID: UUID) {
        opinions[sessionID]?.sent = count
        opinions[sessionID]?.notes.removeAll { $0.status == .kept }
    }

    public func dismiss(_ sessionID: UUID) {
        captures[sessionID]?.cancel()
        captures[sessionID] = nil
        for task in (tasks[sessionID] ?? [:]).values { task.cancel() }
        tasks[sessionID] = nil
        if let folder = opinions[sessionID]?.request.shotsDirectory {
            try? FileManager.default.removeItem(atPath: folder)
        }
        opinions[sessionID] = nil
    }

    private func change(_ noteID: UUID, in sessionID: UUID, _ edit: (inout DesignOpinion.PinnedNote) -> Void) {
        guard let index = opinions[sessionID]?.notes.firstIndex(where: { $0.id == noteID }) else { return }
        edit(&opinions[sessionID]!.notes[index])
    }

    private func update(_ sessionID: UUID, seat: SecondOpinion.Reviewer, _ change: (inout DesignOpinion.Lane) -> Void) {
        guard let index = opinions[sessionID]?.lanes.firstIndex(where: { $0.reviewer == seat }) else { return }
        change(&opinions[sessionID]!.lanes[index])
    }
}
