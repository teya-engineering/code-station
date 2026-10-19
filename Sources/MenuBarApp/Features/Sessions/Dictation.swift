import AppKit
import CoreAudio
import Observation
import SwiftUI
import CodeStationCore

// What the composer hands over when the mic is clicked: whose draft the words go into,
// where the caret is, and what the project has in it to recognise.
struct DictationRequest {
    let sessionID: UUID
    @Binding var draft: SessionComposerStore.Draft
    let caret: Int
    let roots: [String]
    // Words the engine should expect: session names, the branch, the project's name.
    let vocabulary: [String]
    // Puts the caret back once a take settles, so typing carries on after the words.
    var placeCaret: (Int) -> Void = { _ in }
}

// Speaking a prompt into the composer. There is one microphone, so there is one of these
// for the app; it listens for at most one session at a time.
//
// Nothing here ever sends. A take only ever changes the draft, and stopping, throwing a
// take away or leaving the session all leave the prompt in the box for the person to
// send themselves.
@MainActor
@Observable
final class Dictation {
    enum Phase: Equatable { case idle, preparing, listening, stopping }

    enum Notice: Equatable {
        case listening
        case preparing(DictationDownload?)
        case nothingHeard(input: String)
        case blocked(DictationFailure)
        case waitingForPermission
        case allowed
        case unsure(count: Int, seconds: Int)
        case thrownAway
        case failed(String)
    }

    // The words of a settled take that are still worth checking, in the draft as it was
    // when they were marked. Once the draft says anything else the marks are stale.
    struct Review: Equatable {
        var text: String
        var unsure: [UnsureWord]
        var seconds: Int
    }

    private(set) var phase = Phase.idle
    private(set) var sessionID: UUID?
    private(set) var notice: Notice?
    private(set) var noticeSessionID: UUID?
    private(set) var level: Float = 0
    private(set) var startedAt: Date?
    // The grey tail while listening, in the draft's own UTF-16 offsets.
    private(set) var tentative: NSRange?
    private(set) var reviews: [UUID: Review] = [:]
    private(set) var language: Locale
    private(set) var inputName: String?
    // Every language the engine can listen in, for the menu that changes it.
    private(set) var languages: [Locale] = []

    @ObservationIgnored private let engine: SpeechSource
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var request: DictationRequest?
    @ObservationIgnored private var before = SessionComposerStore.Draft()
    @ObservationIgnored private var insertion = DictationInsertion(text: "", caret: 0)
    @ObservationIgnored private var take = WrittenTake()
    @ObservationIgnored private var files = SpokenFileNames(names: [])
    @ObservationIgnored private var heardSound = false
    @ObservationIgnored private var input: AudioDeviceID?
    @ObservationIgnored private var context: [String] = []
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var silence: Task<Void, Never>?
    @ObservationIgnored private var noticeExpiry: Task<Void, Never>?
    @ObservationIgnored private var permissionWatch: Task<Void, Never>?
    @ObservationIgnored private var thrown: (sessionID: UUID, text: String, review: Review?)?
    @ObservationIgnored private var fileNames: [String: [String]] = [:]

    // A take that hears nothing at all for this long names the input it is listening to,
    // since a muted or wrong microphone is the usual reason.
    static let silenceLimit: Duration = .seconds(6)
    static let undoWindow: Duration = .seconds(5)
    private static let languageKey = "dictationLanguage"

    init(engine: SpeechSource = SpeechEngine(), preferences: UserDefaults = .standard) {
        self.engine = engine
        self.preferences = preferences
        language = preferences.string(forKey: Self.languageKey).map(Locale.init(identifier:)) ?? .current
    }

    var languageName: String { DictationLanguages.name(of: language) }

    func isListening(_ sessionID: UUID) -> Bool {
        self.sessionID == sessionID && (phase == .listening || phase == .stopping)
    }

    func isPreparing(_ sessionID: UUID) -> Bool {
        self.sessionID == sessionID && phase == .preparing
    }

    func notice(for sessionID: UUID) -> Notice? {
        noticeSessionID == sessionID ? notice : nil
    }

    func review(_ sessionID: UUID) -> Review? { reviews[sessionID] }

    // MARK: - Starting and stopping

    func toggle(_ request: DictationRequest) {
        if isListening(request.sessionID) {
            stop()
        } else if phase == .idle {
            start(request)
        } else if sessionID != request.sessionID, phase == .listening {
            // Speaking into another session's box keeps what the first one heard.
            let next = request
            work = Task {
                await finishTake()
                start(next)
            }
        }
    }

    func start(_ request: DictationRequest) {
        guard phase == .idle else { return }
        self.request = request
        sessionID = request.sessionID
        reviews[request.sessionID] = nil
        thrown = nil
        phase = .preparing
        show(nil, for: request.sessionID)
        loadFiles(request.roots)
        if languages.isEmpty {
            Task { [weak self] in
                let found = await DictationLanguages.supported()
                    .sorted { DictationLanguages.name(of: $0) < DictationLanguages.name(of: $1) }
                self?.languages = found
            }
        }

        work = Task {
            guard await engine.allowsMicrophone() else {
                fail(.microphoneBlocked)
                return
            }
            guard let locale = await engine.resolve(language) else {
                fail(.languageUnsupported)
                return
            }
            if await engine.needsDownload(locale) {
                show(.preparing(nil), for: request.sessionID)
                do {
                    try await engine.download(locale) { progress in
                        guard self.phase == .preparing, self.sessionID == request.sessionID else { return }
                        self.show(.preparing(progress), for: request.sessionID)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    fail(error as? DictationFailure ?? .engine(error.localizedDescription))
                    return
                }
            }
            guard !Task.isCancelled, phase == .preparing, sessionID == request.sessionID else { return }
            await listen(locale)
        }
    }

    private func listen(_ locale: Locale) async {
        guard let request else { return }
        before = request.draft
        insertion = DictationInsertion(text: before.text, caret: request.caret)
        take = WrittenTake()
        heardSound = false
        level = 0
        inputName = (input.flatMap { id in AudioInputs.all().first { $0.id == id } } ?? AudioInputs.current())?.name
        do {
            try await engine.start(locale, input: input, context: context + request.vocabulary,
                                   heard: { [weak self] in self?.heard($0) },
                                   level: { [weak self] in self?.heardLevel($0) })
        } catch {
            fail(error as? DictationFailure ?? .engine(error.localizedDescription))
            return
        }
        guard phase == .preparing else {
            engine.cancel()
            return
        }
        phase = .listening
        startedAt = .now
        show(.listening, for: request.sessionID)
        watchForSilence()
    }

    // Return, the mic, and leaving the session all end a take the same way: the words
    // stay in the box and nothing is sent.
    func stop() {
        guard phase == .listening else {
            if phase == .preparing { cancelPreparing() }
            return
        }
        work = Task { await finishTake() }
    }

    private func finishTake() async {
        guard phase == .listening, let request else { return }
        phase = .stopping
        silence?.cancel()
        let heard = await engine.finish()
        // Thrown away while the engine was settling: the draft is already back as it was.
        guard phase == .stopping else { return }
        let seconds = max(1, Int(Date.now.timeIntervalSince(startedAt ?? .now).rounded()))
        take = DictationWriter.write(heard, files: files)
        tentative = nil
        let composed = insertion.compose(take)
        let sessionID = request.sessionID

        if take.text.isEmpty {
            request.draft = before
            show(nil, for: sessionID)
        } else {
            request.draft.text = composed.text
            request.draft.dictated = true
            let review = Review(text: composed.text,
                                unsure: take.unsure.map { $0.shifted(by: composed.offset) },
                                seconds: seconds)
            reviews[sessionID] = review.unsure.isEmpty ? nil : review
            show(review.unsure.isEmpty ? nil : .unsure(count: review.unsure.count, seconds: seconds),
                 for: sessionID)
            request.placeCaret(composed.offset + (take.text as NSString).length)
        }
        finishListening()
    }

    // Esc while listening. The draft goes back to exactly what it was before the mic was
    // clicked, and the take can be had back for a few seconds.
    func throwAway() {
        guard phase == .listening || phase == .stopping, let request else {
            if phase == .preparing { cancelPreparing() }
            return
        }
        engine.cancel()
        silence?.cancel()
        // Undo gives back what was on screen, the words still being guessed included.
        let kept = WrittenTake(text: take.text, unsure: take.unsure)
        let composed = insertion.compose(kept)
        request.draft = before
        tentative = nil
        if !kept.text.isEmpty {
            let seconds = max(1, Int(Date.now.timeIntervalSince(startedAt ?? .now).rounded()))
            let unsure = kept.unsure.map { $0.shifted(by: composed.offset) }
            thrown = (request.sessionID, composed.text,
                      unsure.isEmpty ? nil : Review(text: composed.text, unsure: unsure, seconds: seconds))
            show(.thrownAway, for: request.sessionID, for: Self.undoWindow)
        } else {
            show(nil, for: request.sessionID)
        }
        finishListening()
    }

    func undo() {
        guard let thrown, notice == .thrownAway, noticeSessionID == thrown.sessionID,
              let request, request.sessionID == thrown.sessionID else { return }
        self.thrown = nil
        request.draft.text = thrown.text
        request.draft.dictated = true
        reviews[thrown.sessionID] = thrown.review
        show(thrown.review.map { .unsure(count: $0.unsure.count, seconds: $0.seconds) }, for: thrown.sessionID)
        request.placeCaret((thrown.text as NSString).length - (insertion.tail as NSString).length)
    }

    // The session's composer is going off screen. Its take is kept rather than lost.
    func leave(_ sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        if phase == .listening { stop() } else if phase == .preparing { cancelPreparing() }
    }

    private func cancelPreparing() {
        work?.cancel()
        engine.cancel()
        if let sessionID { show(nil, for: sessionID) }
        finishListening()
    }

    private func finishListening() {
        phase = .idle
        startedAt = nil
        level = 0
        silence?.cancel()
    }

    private func fail(_ failure: DictationFailure) {
        guard let sessionID else { return }
        engine.cancel()
        finishListening()
        switch failure {
        case .engine(let message): show(.failed(message), for: sessionID)
        default: show(.blocked(failure), for: sessionID)
        }
    }

    // MARK: - What the engine reports

    private func heard(_ heard: DictationHeard) {
        guard phase == .listening, let request else { return }
        if !heard.isEmpty { noticeSound() }
        take = DictationWriter.write(heard, files: files)
        let composed = insertion.compose(take)
        request.draft.text = composed.text
        tentative = take.tentative.map { NSRange(location: $0.location + composed.offset, length: $0.length) }
    }

    private func heardLevel(_ level: Float) {
        guard phase == .listening else { return }
        self.level = level
        if level > 0.25 { noticeSound() }
    }

    private func noticeSound() {
        heardSound = true
        if case .nothingHeard = notice, let sessionID { show(.listening, for: sessionID) }
    }

    private func watchForSilence() {
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceLimit)
            guard let self, !Task.isCancelled, phase == .listening, !heardSound, let sessionID else { return }
            show(.nothingHeard(input: inputName ?? "the microphone"), for: sessionID)
        }
    }

    // MARK: - Choices from the notice row

    func chooseInput(_ input: AudioInput) {
        self.input = input.id
        guard phase == .listening, let request else { return }
        // The picker is only offered while nothing has been heard, so there is nothing in
        // the take to lose by starting it again on the new input.
        engine.cancel()
        request.draft = before
        finishListening()
        start(request)
    }

    func chooseLanguage(_ locale: Locale) {
        language = locale
        preferences.set(locale.identifier, forKey: Self.languageKey)
        guard let request, phase == .preparing || notice(for: request.sessionID).isLanguageProblem else { return }
        cancelPreparing()
        start(request)
    }

    func openPrivacySettings(_ failure: DictationFailure) {
        guard let sessionID else { return }
        NSWorkspace.shared.open(failure == .speechBlocked ? DictationPermission.speechSettings
                                                          : DictationPermission.microphoneSettings)
        show(.waitingForPermission, for: sessionID)
        permissionWatch?.cancel()
        permissionWatch = Task { [weak self] in
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.notice == .waitingForPermission else { return }
                if DictationPermission.microphoneAllowed {
                    self.show(.allowed, for: sessionID, for: .seconds(4))
                    return
                }
            }
        }
    }

    // MARK: - Checking the words

    // Any edit settles the take: a dotted word is only worth asking about while it is
    // exactly as it was heard.
    func draftEdited(_ sessionID: UUID, text: String) {
        guard let review = reviews[sessionID], review.text != text else { return }
        reviews[sessionID] = nil
        if notice(for: sessionID).isUnsure { show(nil, for: sessionID) }
    }

    func choose(_ replacement: String?, for word: UnsureWord, in sessionID: UUID,
                draft: Binding<SessionComposerStore.Draft>) {
        guard var review = reviews[sessionID],
              let index = review.unsure.firstIndex(of: word) else { return }
        review.unsure.remove(at: index)
        if let replacement, replacement != word.heard {
            let text = (review.text as NSString).replacingCharacters(in: word.range, with: replacement)
            let delta = (replacement as NSString).length - word.range.length
            review.unsure = review.unsure.map {
                $0.range.location > word.range.location ? $0.shifted(by: delta) : $0
            }
            review.text = text
            draft.wrappedValue.text = text
        }
        reviews[sessionID] = review.unsure.isEmpty ? nil : review
        show(review.unsure.isEmpty ? nil : .unsure(count: review.unsure.count, seconds: review.seconds),
             for: sessionID)
    }

    func sent(_ sessionID: UUID) {
        reviews[sessionID] = nil
        if noticeSessionID == sessionID, phase == .idle { show(nil, for: sessionID) }
    }

    // MARK: - Notices

    private func show(_ notice: Notice?, for sessionID: UUID, for lifetime: Duration? = nil) {
        noticeExpiry?.cancel()
        self.notice = notice
        noticeSessionID = notice == nil ? nil : sessionID
        if let announcement = notice?.announcement {
            AccessibilityNotification.Announcement(announcement).post()
        }
        guard let lifetime, let notice else { return }
        noticeExpiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard let self, !Task.isCancelled, self.notice == notice else { return }
            if notice == .thrownAway { self.thrown = nil }
            self.show(nil, for: sessionID)
        }
    }

    // The project's file names, read once per folder and refreshed on each take. They are
    // what a spoken file name is matched against, and the engine is told about them too.
    private func loadFiles(_ roots: [String]) {
        let known = roots.flatMap { fileNames[$0] ?? [] }
        files = SpokenFileNames(names: known)
        context = Array(Set(known)).prefix(200).map { $0 }
        Task { [weak self] in
            var names: [String] = []
            for root in roots {
                let nodes = await FileTree.files(beneath: URL(fileURLWithPath: root), includeHidden: false)
                let recent = nodes.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
                let found = recent.map(\.name)
                self?.fileNames[root] = found
                names += found
            }
            guard let self else { return }
            files = SpokenFileNames(names: names)
            if context.isEmpty { context = Array(names.prefix(200)) }
        }
    }
}

extension UnsureWord {
    func shifted(by offset: Int) -> UnsureWord {
        var copy = self
        copy.range.location += offset
        return copy
    }
}

extension Optional where Wrapped == Dictation.Notice {
    var isMicrophoneBlocked: Bool {
        switch self {
        case .blocked(.microphoneBlocked), .blocked(.speechBlocked), .waitingForPermission: true
        default: false
        }
    }

    var downloadFraction: Double? {
        if case .preparing(let download) = self { return download?.fraction ?? 0 }
        return nil
    }

    var isUnsure: Bool {
        if case .unsure = self { return true }
        return false
    }

    var isLanguageProblem: Bool {
        switch self {
        case .blocked(.languageUnsupported), .blocked(.modelMissing): true
        default: false
        }
    }
}

private extension Dictation.Notice {
    // Said aloud by VoiceOver as the row changes. The listening row is left out: the mic
    // button already says it is live.
    var announcement: String? {
        switch self {
        case .listening, .preparing, .waitingForPermission: nil
        case .nothingHeard(let input): "Nothing heard from \(input)."
        case .blocked(.microphoneBlocked): "Code Station isn't allowed to use the microphone."
        case .blocked(.speechBlocked): "Code Station isn't allowed to use speech recognition."
        case .blocked: "Dictation isn't available in this language."
        case .allowed: "Microphone allowed."
        case .unsure(let count, _): count == 1 ? "1 word to check." : "\(count) words to check."
        case .thrownAway: "Threw away that take."
        case .failed(let message): message
        }
    }
}
