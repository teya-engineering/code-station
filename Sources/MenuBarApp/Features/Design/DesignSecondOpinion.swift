import AppKit
import Foundation
import WebKit

// Other agents look at a design's screens before it is built and pin notes to the spots
// they are about. Notes wait in a panel beside the canvas: only the ones the person keeps
// go back to the design agent, as their next prompt.
enum DesignSecondOpinion {
    enum Focus: String, CaseIterable, Sendable {
        case hierarchy, accessibility, copy, missingStates, fitsProduct

        static let standard: [Focus] = [.hierarchy, .accessibility, .copy, .missingStates]

        var title: String {
            switch self {
            case .hierarchy: "Hierarchy"
            case .accessibility: "Accessibility"
            case .copy: "Copy"
            case .missingStates: "Missing states"
            case .fitsProduct: "Fits the product"
            }
        }

        var ask: String {
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
    struct Reading: Equatable, Sendable {
        var source = true
        var conversation = false
    }

    // A screen's pictures as the reviewer is shown them. A design with no dark style
    // has no dark picture.
    struct Shot: Equatable, Sendable {
        var screen: DesignScreen
        var light: String
        var dark: String?
    }

    struct Request: Equatable, Sendable {
        var focus: [Focus] = Focus.standard
        var reading = Reading()
        var designDirectory: String
        var shotsDirectory: String
        var shots: [Shot]
        // What the person asked the design agent for, the latest first.
        var asked: String
        var conversation = ""
        var executable: String
    }

    // A spot on a screen's picture, in its CSS pixels.
    struct Box: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    struct Note: Equatable, Sendable {
        var screen: String?
        var selector: String?
        var box: Box?
        var category: String
        var severity: ReviewComment.Severity
        var text: String
    }

    static let maxNotes = 8

    // MARK: - Pictures

    // Each screen drawn at its own size, light and then dark, by a web view that is never
    // shown. A page taller than its screen is drawn whole, up to a limit.
    @MainActor
    static func capture(_ screens: [DesignScreen], in directory: URL, to folder: URL) async -> [Shot] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var shots: [Shot] = []
        for screen in screens {
            guard let url = DesignManifest.safeURL(for: screen, in: directory) else { continue }
            let width = CGFloat(screen.width ?? 1280)
            let height = CGFloat(screen.height ?? 800)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height),
                                    configuration: configuration)
            let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = webView
            defer { window.contentView = nil }
            webView.appearance = NSAppearance(named: .aqua)
            webView.loadFileURL(url, allowingReadAccessTo: directory)
            guard await loaded(webView) else { continue }
            if let full = try? await webView.evaluateJavaScript(
                "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)") as? Double,
               full > height {
                webView.setFrameSize(CGSize(width: width, height: min(full, 6000)))
                try? await Task.sleep(for: .milliseconds(120))
            }
            let stem = folder.appendingPathComponent(fileStem(screen.id)).path
            guard let light = await picture(of: webView, width: width) else { continue }
            let lightPath = stem + "-light.png"
            guard (try? light.write(to: URL(fileURLWithPath: lightPath))) != nil else { continue }
            webView.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(250))
            var darkPath: String?
            if let dark = await picture(of: webView, width: width), dark != light,
               (try? dark.write(to: URL(fileURLWithPath: stem + "-dark.png"))) != nil {
                darkPath = stem + "-dark.png"
            }
            shots.append(Shot(screen: screen, light: lightPath, dark: darkPath))
        }
        return shots
    }

    private static func fileStem(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let stem = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return stem.isEmpty ? "screen" : stem
    }

    @MainActor
    private static func loaded(_ webView: WKWebView) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if !webView.isLoading,
               (try? await webView.evaluateJavaScript("document.readyState")) as? String == "complete" {
                // Web fonts and images settle a moment after the document says it is done.
                try? await Task.sleep(for: .milliseconds(300))
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @MainActor
    private static func picture(of webView: WKWebView, width: CGFloat) async -> Data? {
        let configuration = WKSnapshotConfiguration()
        // One image pixel to one CSS pixel, so a box a reviewer gives lands on the page.
        configuration.snapshotWidth = NSNumber(value: Double(width))
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
        }
        guard let image else { return nil }
        // The snapshot comes back at the screen's backing scale, so it is drawn again at
        // one pixel per CSS pixel.
        let size = CGSize(width: width, height: (image.size.height * width / max(image.size.width, 1)).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Asking

    static func prompt(for request: Request) -> String {
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
    static func arguments(for reviewer: SecondOpinion.Reviewer, request: Request, prompt: String,
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

    static func ask(_ request: Request, reviewer: SecondOpinion.Reviewer, searchPath: String,
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
        struct Item: Decodable {
            var screen: String?
            var selector: String?
            var box: Box?
            var category: String?
            var severity: String?
            var text: String?
        }

        var notes: [Item]
    }

    // The last JSON object holding a list of notes. Nil when there is none, which is not
    // the same as an empty list: that is a reviewer saying it found nothing.
    static func notes(in text: String) -> [Note]? {
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
    static func feedback(_ notes: [DesignOpinion.PinnedNote], screens: [DesignScreen], names: String) -> String {
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
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// One second opinion on a design: the seats asked, how each is doing, and the notes
// they pinned, merged where two pinned the same element.
struct DesignOpinion: Identifiable, Equatable {
    struct Lane: Equatable, Identifiable {
        var reviewer: SecondOpinion.Reviewer
        var started = Date()
        var ended: Date?
        var state: ReviewLane.State = .running
        var activity = "Taking pictures of the screens"

        var id: SecondOpinion.Reviewer { reviewer }
        var isRunning: Bool { state == .running }
    }

    struct PinnedNote: Equatable, Identifiable {
        enum Status: Equatable { case pending, kept }

        var id = UUID()
        var screen: String?
        var selector: String?
        var box: DesignSecondOpinion.Box?
        var category: String
        var severity: ReviewComment.Severity
        var voices: [ChatOpinion.Voice]
        var status = Status.pending
        // The words that go back, which start as the first reviewer's and can be rewritten.
        var text: String
        var edited = false
    }

    var id = UUID()
    var request: DesignSecondOpinion.Request
    var lanes: [Lane]
    var notes: [PinnedNote] = []
    // How many notes went back, once they have.
    var sent: Int?
    var dismissed = 0

    var isRunning: Bool { lanes.contains(where: \.isRunning) }
    var kept: [PinnedNote] { notes.filter { $0.status == .kept } }
    var pending: [PinnedNote] { notes.filter { $0.status == .pending } }

    // The lanes as the header's lineup reads them, so a design's second opinion shows
    // the same way as one on the changes.
    var runs: [SecondOpinionRun] {
        lanes.map { lane in
            let state: SecondOpinionRun.State = switch lane.state {
            case .running: .running
            case .finished: .finished(found: notes.count { $0.voices.contains { $0.reviewer == lane.reviewer } })
            case .failed(let message): .failed(message)
            }
            return SecondOpinionRun(reviewer: lane.reviewer, started: lane.started, ended: lane.ended, state: state,
                                    activity: lane.activity, recent: [lane.activity],
                                    request: SecondOpinionRequest(repositories: [], executable: ""))
        }
    }

    var status: SecondOpinionStatus {
        let running = lanes.filter(\.isRunning)
        if !running.isEmpty {
            return .reviewing(agents: Self.unique(running.map(\.reviewer.agent)),
                              started: running.map(\.started).min() ?? Date(), pending: pending.count)
        }
        if pending.isEmpty, let failed = lanes.first(where: { if case .failed = $0.state { true } else { false } }) {
            return .failed(failed.reviewer.agent)
        }
        if !pending.isEmpty {
            let voices = Set(pending.flatMap { $0.voices.map(\.reviewer.agent) })
            return .ready(agents: AgentKind.allCases.filter(voices.contains), pending: pending.count)
        }
        return .settled(kept: kept.count + (sent ?? 0), dismissed: dismissed)
    }

    private static func unique(_ agents: [AgentKind]) -> [AgentKind] {
        var seen = Set<AgentKind>()
        return agents.filter { seen.insert($0).inserted }
    }

    mutating func take(_ found: [DesignSecondOpinion.Note], from reviewer: SecondOpinion.Reviewer) {
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
final class DesignOpinionStore {
    private(set) var opinions: [UUID: DesignOpinion] = [:]
    @ObservationIgnored private var tasks: [UUID: [SecondOpinion.Reviewer: Task<Void, Never>]] = [:]
    @ObservationIgnored private var captures: [UUID: Task<Void, Never>] = [:]
    // Called with the session when its last reviewer ends on its own, not when stopped.
    @ObservationIgnored var onSettled: ((UUID) -> Void)?
    // How the screens are pictured and a reviewer is asked; tests swap in their own.
    @ObservationIgnored var captureScreens: @MainActor ([DesignScreen], URL, URL) async -> [DesignSecondOpinion.Shot] = {
        await DesignSecondOpinion.capture($0, in: $1, to: $2)
    }
    @ObservationIgnored var askReviewer: @Sendable (DesignSecondOpinion.Request, SecondOpinion.Reviewer, String,
                                                    @escaping @Sendable (String) -> Void)
        async -> Result<[DesignSecondOpinion.Note], SecondOpinion.Failure> = { request, reviewer, path, activity in
            await DesignSecondOpinion.ask(request, reviewer: reviewer, searchPath: path, activity: activity)
        }

    func opinion(_ sessionID: UUID) -> DesignOpinion? { opinions[sessionID] }

    // Pictures every screen once, then asks every seat alongside the others. Asking
    // again replaces the opinion before it.
    func ask(_ request: DesignSecondOpinion.Request, screens: [DesignScreen], reviewers: [SecondOpinion.Reviewer],
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

    func retry(_ seat: SecondOpinion.Reviewer, executable: String, in sessionID: UUID) {
        guard opinions[sessionID]?.lanes.first(where: { $0.reviewer == seat })?.isRunning == false else { return }
        update(sessionID, seat: seat) { $0 = DesignOpinion.Lane(reviewer: seat, activity: "Looking at the screens") }
        start(seat, executable: executable, in: sessionID)
    }

    private func start(_ seat: SecondOpinion.Reviewer, executable: String, in sessionID: UUID) {
        guard let opinion = opinions[sessionID] else { return }
        var asked = opinion.request
        asked.executable = executable
        let searchPath = ProcessManager.searchPath
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
    func finish(_ seat: SecondOpinion.Reviewer, outcome: Result<[DesignSecondOpinion.Note], SecondOpinion.Failure>,
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
        if opinions[sessionID]?.isRunning == false { onSettled?(sessionID) }
    }

    func stop(_ seat: SecondOpinion.Reviewer, in sessionID: UUID) {
        tasks[sessionID]?[seat]?.cancel()
        tasks[sessionID]?[seat] = nil
        opinions[sessionID]?.lanes.removeAll { $0.reviewer == seat }
        if opinions[sessionID]?.lanes.isEmpty == true { dismiss(sessionID) }
    }

    func keep(_ noteID: UUID, in sessionID: UUID) {
        change(noteID, in: sessionID) { $0.status = .kept }
    }

    func edit(_ noteID: UUID, text: String, in sessionID: UUID) {
        let words = text.trimmed
        guard !words.isEmpty else { return }
        change(noteID, in: sessionID) { note in
            note.edited = note.edited || words != note.text
            note.text = words
            note.status = .kept
        }
    }

    // A dismissed note is gone for good, along with its pin.
    func dismiss(_ noteID: UUID, in sessionID: UUID) {
        guard opinions[sessionID]?.notes.contains(where: { $0.id == noteID }) == true else { return }
        opinions[sessionID]?.notes.removeAll { $0.id == noteID }
        opinions[sessionID]?.dismissed += 1
    }

    func markSent(count: Int, in sessionID: UUID) {
        opinions[sessionID]?.sent = count
        opinions[sessionID]?.notes.removeAll { $0.status == .kept }
    }

    func dismiss(_ sessionID: UUID) {
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
