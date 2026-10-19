import CoreAudio
import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

// Turning heard words into prompt text: marks said aloud are written, file names said
// aloud become code spans when the project has them, and a take lands at the caret.
struct DictationWriterTests {
    private func heard(_ words: String, volatile: String = "") -> DictationHeard {
        DictationHeard(settled: words.split(separator: " ").map { HeardWord(text: String($0)) },
                       volatile: volatile)
    }

    @Test func spokenMarksAreWrittenNotSpelled() {
        let take = DictationWriter.write(heard("make the filter comma save it full stop then test it"))
        #expect(take.text == "make the filter, save it. Then test it")
    }

    @Test func newLineBreaksTheLineWithoutASpace() {
        let take = DictationWriter.write(heard("first part new line second part"))
        #expect(take.text == "first part\nSecond part")
    }

    // The engine often punctuates on its own; a mark said on top of it replaces it
    // rather than doubling it.
    @Test func aSpokenMarkReplacesTheEnginesOwn() {
        let take = DictationWriter.write(heard("each merchant picked. comma save it"))
        #expect(take.text == "each merchant picked, save it")
    }

    @Test func ordinaryWordsThatSoundLikeMarksStay() {
        let take = DictationWriter.write(heard("keep the trial period and the colon"))
        #expect(take.text == "keep the trial period and the colon")
    }

    @Test func aFileNameSaidAloudBecomesAChipWhenItExists() {
        let files = SpokenFileNames(names: ["useDeliveryFilters.ts", "README.md"])
        let take = DictationWriter.write(heard("save it in use delivery filters dot ts comma and add a test"),
                                         files: files)
        #expect(take.text == "save it in `useDeliveryFilters.ts`, and add a test")
    }

    @Test func aFileNameStaysAsWordsWhenTheProjectHasNoSuchFile() {
        let files = SpokenFileNames(names: ["useDeliveryFilters.ts"])
        let take = DictationWriter.write(heard("update use payment filters dot ts"), files: files)
        #expect(take.text == "update use payment filters dot ts")
    }

    @Test func aFileNameTheEngineAlreadyJoinedStillMatches() {
        let files = SpokenFileNames(names: ["useDeliveryFilters.ts"])
        let take = DictationWriter.write(heard("open use delivery filters.ts, please"), files: files)
        #expect(take.text == "open `useDeliveryFilters.ts`, please")
    }

    // A name with no extension is too easily an ordinary word to turn into a file.
    @Test func namesWithoutAnExtensionAreNotMatched() {
        let files = SpokenFileNames(names: ["Makefile", "build"])
        #expect(files.isEmpty)
    }

    @Test func theGuessedTailIsMarkedAndLeftAsHeard() {
        let take = DictationWriter.write(heard("make the filter", volatile: "use delivery"))
        #expect(take.text == "make the filter use delivery")
        #expect(take.tentative == NSRange(location: 16, length: 12))
    }

    @Test func anUnsureWordIsMarkedWithoutItsPunctuation() {
        let take = DictationWriter.write(DictationHeard(settled: [
            HeardWord(text: "each"),
            HeardWord(text: "merchant,", alternatives: ["merchants", "merchant"]),
            HeardWord(text: "picked")
        ]))
        #expect(take.text == "each merchant, picked")
        #expect(take.unsure == [UnsureWord(range: NSRange(location: 5, length: 8),
                                           heard: "merchant", alternatives: ["merchants"])])
    }

    @Test func alternativesAreLinedUpWordByWord() {
        let words = DictationAlternatives.words(
            best: ["each", "merchant", "picked"],
            confidences: [0.95, 0.4, 0.9],
            alternatives: [["each", "merchants", "picked"], ["each", "merchant's", "picked"]])
        #expect(words.map(\.alternatives) == [[], ["merchants", "merchant's"], []])
    }

    // A word the engine is sure of is not asked about, even when it had another reading.
    @Test func aConfidentWordIsNotAskedAbout() {
        let words = DictationAlternatives.words(best: ["picked"], confidences: [0.97],
                                                alternatives: [["pick"]])
        #expect(words.first?.alternatives == [])
    }
}

struct DictationInsertionTests {
    @Test func wordsGoInAtTheCaretBetweenWhatWasTyped() {
        let insertion = DictationInsertion(text: "Before. After", caret: 7)
        let composed = insertion.compose(WrittenTake(text: "do this"))
        #expect(composed.text == "Before. Do this After")
        #expect(composed.offset == 8)
    }

    @Test func wordsAfterTypedTextCarryOnTheSentence() {
        let insertion = DictationInsertion(text: "Rename the button and ", caret: 22)
        #expect(insertion.compose(WrittenTake(text: "make it green")).text
                == "Rename the button and make it green")
    }

    @Test func anEmptyTakeLeavesTheTextExactly() {
        let text = "half typed  \n with odd spacing "
        let insertion = DictationInsertion(text: text, caret: 4)
        #expect(insertion.compose(WrittenTake()).text == text)
        #expect(insertion.original == text)
    }
}

// The take's life in the composer, with an engine that hears whatever the test says.
@MainActor
struct DictationControllerTests {
    private let testPreferences = TestPreferences()
    private let runner: SessionRunner
    private let sessionID = UUID()
    private let speech = ScriptedSpeech()

    init() {
        runner = SessionRunner(preferences: testPreferences.store, persistentAgentSessions: false, paths: [:])
    }

    private func makeDictation() -> Dictation {
        Dictation(engine: speech, preferences: UserDefaults(suiteName: "DictationTests-\(UUID())")!)
    }

    private func start(_ dictation: Dictation, caret: Int) async {
        dictation.toggle(DictationRequest(sessionID: sessionID, draft: runner.composer.draftBinding(sessionID),
                                          caret: caret, roots: [], vocabulary: []))
        #expect(await waitUntil { dictation.isListening(sessionID) })
    }

    private var draft: SessionComposerStore.Draft { runner.composer.draft(sessionID) }

    private func words(_ text: String) -> [HeardWord] {
        text.split(separator: " ").map { HeardWord(text: String($0)) }
    }

    @Test func stoppingKeepsTheWordsAndNeverSends() async {
        let dictation = makeDictation()
        runner.composer.editDraft(sessionID) { $0.text = "Typed first." }
        await start(dictation, caret: 12)

        speech.say(DictationHeard(settled: words("make it"), volatile: "green now"))
        #expect(draft.text == "Typed first. Make it green now")
        #expect(dictation.tentative == NSRange(location: 21, length: 9))

        speech.final = DictationHeard(settled: words("make it green now"))
        dictation.stop()
        #expect(await waitUntil { dictation.phase == .idle })

        #expect(draft.text == "Typed first. Make it green now")
        #expect(draft.dictated)
        #expect(runner.queued(sessionID).isEmpty)
        #expect(dictation.tentative == nil)
    }

    @Test func throwingAwayRestoresTheDraftExactlyAndCanBeUndone() async {
        let dictation = makeDictation()
        let typed = "half typed  \n with odd spacing "
        runner.composer.editDraft(sessionID) { $0.text = typed }
        await start(dictation, caret: 4)

        speech.say(DictationHeard(settled: words("add a test")))
        #expect(draft.text != typed)

        dictation.throwAway()
        #expect(draft.text == typed)
        #expect(!draft.dictated)
        #expect(speech.cancelled)
        #expect(dictation.notice(for: sessionID) == .thrownAway)

        dictation.undo()
        #expect(draft.text == "half add a test typed  \n with odd spacing ")
        #expect(draft.dictated)
    }

    @Test func escapeWhileTheTakeSettlesStillRestoresTheDraft() async {
        let dictation = makeDictation()
        runner.composer.editDraft(sessionID) { $0.text = "keep me" }
        await start(dictation, caret: 7)
        speech.final = DictationHeard(settled: words("late words"))
        speech.holdsFinish = true

        dictation.stop()
        #expect(await waitUntil { speech.isHolding })
        dictation.throwAway()
        speech.releaseFinish()
        #expect(await waitUntil { dictation.phase == .idle })
        try? await Task.sleep(for: .milliseconds(50))

        #expect(draft.text == "keep me")
        #expect(!draft.dictated)
    }

    @Test func aTakeThatHeardNothingLeavesTheDraftAlone() async {
        let dictation = makeDictation()
        runner.composer.editDraft(sessionID) { $0.text = "keep me" }
        await start(dictation, caret: 7)

        dictation.stop()
        #expect(await waitUntil { dictation.phase == .idle })
        #expect(draft.text == "keep me")
        #expect(!draft.dictated)
        #expect(dictation.notice(for: sessionID) == nil)
    }

    @Test func aBlockedMicrophoneSaysWhatToDoAndChangesNothing() async {
        speech.allowed = false
        let dictation = makeDictation()
        runner.composer.editDraft(sessionID) { $0.text = "keep me" }
        dictation.toggle(DictationRequest(sessionID: sessionID, draft: runner.composer.draftBinding(sessionID),
                                          caret: 7, roots: [], vocabulary: []))

        #expect(await waitUntil { dictation.notice(for: sessionID) == .blocked(.microphoneBlocked) })
        #expect(dictation.phase == .idle)
        #expect(!speech.started)
        #expect(draft.text == "keep me")
    }

    @Test func aMissingLanguageModelIsFetchedThenListeningStarts() async {
        speech.needsModel = true
        let dictation = makeDictation()
        await start(dictation, caret: 0)
        #expect(speech.downloaded)
        #expect(dictation.notice(for: sessionID) == .listening)
    }

    @Test func pickingAnAlternativeFixesTheWordAndClearsItsMark() async {
        let dictation = makeDictation()
        await start(dictation, caret: 0)
        speech.final = DictationHeard(settled: [HeardWord(text: "each"),
                                                HeardWord(text: "merchant", alternatives: ["merchants"]),
                                                HeardWord(text: "picked")])
        dictation.stop()
        #expect(await waitUntil { dictation.phase == .idle })

        let review = dictation.review(sessionID)
        #expect(review?.unsure.map(\.heard) == ["merchant"])
        #expect(dictation.notice(for: sessionID) == .unsure(count: 1, seconds: review?.seconds ?? 0))

        if let word = review?.unsure.first {
            dictation.choose("merchants", for: word, in: sessionID, draft: runner.composer.draftBinding(sessionID))
        }
        #expect(draft.text == "Each merchants picked")
        #expect(dictation.review(sessionID) == nil)
        #expect(dictation.notice(for: sessionID) == nil)
    }

    @Test func typingOverTheTakeSettlesTheUnsureWords() async {
        let dictation = makeDictation()
        await start(dictation, caret: 0)
        speech.final = DictationHeard(settled: [HeardWord(text: "merchant", alternatives: ["merchants"])])
        dictation.stop()
        #expect(await waitUntil { dictation.review(sessionID) != nil })

        dictation.draftEdited(sessionID, text: "Merchant ID")
        #expect(dictation.review(sessionID) == nil)
        #expect(dictation.notice(for: sessionID) == nil)
    }

    @Test func leavingTroubleshootKeepsTheFinalWordsInTheBriefOnly() async {
        let dictation = makeDictation()
        let problemID = UUID()
        let evidence = Attachment(url: URL(fileURLWithPath: "/private/tmp/error.log"))
        runner.composer.editDraft(sessionID) { $0.text = "Unsent chat prompt" }
        runner.composer.editBrief(sessionID) {
            $0.problem = "Requests fail."
            $0.attachments = [evidence]
            $0.incidentTime = "Last hour"
            $0.mcpServersEnabled = false
        }
        dictation.toggle(DictationRequest(sessionID: problemID,
                                          draft: runner.composer.problemBinding(sessionID),
                                          caret: 14, roots: [], vocabulary: []))
        #expect(await waitUntil { dictation.isListening(problemID) })
        speech.say(DictationHeard(settled: words("check the logs")))
        #expect(runner.composer.brief(sessionID).problem == "Requests fail. Check the logs")

        speech.final = DictationHeard(settled: words("check the error logs"))
        dictation.leave(problemID)
        #expect(await waitUntil { dictation.phase == .idle })

        let brief = runner.composer.brief(sessionID)
        #expect(brief.problem == "Requests fail. Check the error logs")
        #expect(brief.dictated)
        #expect(brief.attachments == [evidence])
        #expect(brief.incidentTime == "Last hour")
        #expect(!brief.mcpServersEnabled)
        #expect(draft.text == "Unsent chat prompt")
        #expect(!draft.dictated)
        #expect(runner.queued(sessionID).isEmpty)
    }

    @Test func discardingAndUndoingTroubleshootDictationPreservesOtherBriefEdits() async {
        let dictation = makeDictation()
        let problemID = UUID()
        runner.composer.editBrief(sessionID) { $0.problem = "Requests fail." }
        dictation.toggle(DictationRequest(sessionID: problemID,
                                          draft: runner.composer.problemBinding(sessionID),
                                          caret: 14, roots: [], vocabulary: []))
        #expect(await waitUntil { dictation.isListening(problemID) })
        speech.say(DictationHeard(settled: words("check the logs")))
        runner.composer.editBrief(sessionID) { $0.incidentTime = "Last hour" }

        dictation.throwAway()
        #expect(runner.composer.brief(sessionID).problem == "Requests fail.")
        #expect(!runner.composer.brief(sessionID).dictated)
        #expect(runner.composer.brief(sessionID).incidentTime == "Last hour")

        dictation.undo()
        #expect(runner.composer.brief(sessionID).problem == "Requests fail. Check the logs")
        #expect(runner.composer.brief(sessionID).dictated)
        #expect(runner.composer.brief(sessionID).incidentTime == "Last hour")
        #expect(draft.isEmpty)
    }

    @Test func correctingTroubleshootDictationUpdatesTheBriefOnly() async {
        let dictation = makeDictation()
        let problemID = UUID()
        let problem = runner.composer.problemBinding(sessionID)
        runner.composer.editDraft(sessionID) { $0.text = "Unsent chat prompt" }
        dictation.toggle(DictationRequest(sessionID: problemID, draft: problem,
                                          caret: 0, roots: [], vocabulary: []))
        #expect(await waitUntil { dictation.isListening(problemID) })
        speech.final = DictationHeard(settled: [HeardWord(text: "each"),
                                                HeardWord(text: "merchant", alternatives: ["merchants"])])
        dictation.stop()
        #expect(await waitUntil { dictation.phase == .idle })

        if let word = dictation.review(problemID)?.unsure.first {
            dictation.choose("merchants", for: word, in: problemID, draft: problem)
        }
        #expect(runner.composer.brief(sessionID).problem == "Each merchants")
        #expect(dictation.review(problemID) == nil)
        #expect(dictation.review(sessionID) == nil)
        #expect(draft.text == "Unsent chat prompt")
    }

    @Test func aSpokenPromptCarriesItsTagIntoTheTranscript() throws {
        let prompt = SessionRunner.QueuedPrompt(text: "make it green", attachments: [],
                                                customInstructions: nil, dictated: true)
        #expect(prompt.transcriptMessages.first?.dictated == true)

        // Conversations written before the tag existed still read.
        let old = #"{"id":"6F1C7B9E-2D4A-4C0B-9E55-0B7E1D2A3C4F","role":"user","text":"hi","tools":[],"date":0}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
        #expect(message.dictated == nil)
    }
}

@MainActor
private final class ScriptedSpeech: SpeechSource {
    var allowed = true
    var needsModel = false
    var final = DictationHeard()
    private(set) var started = false
    private(set) var cancelled = false
    private(set) var downloaded = false
    private var heard: (@MainActor (DictationHeard) -> Void)?

    func say(_ words: DictationHeard) { heard?(words) }

    func allowsMicrophone() async -> Bool { allowed }
    func resolve(_ locale: Locale) async -> Locale? { locale }
    func needsDownload(_ locale: Locale) async -> Bool { needsModel }

    func download(_ locale: Locale, progress: @escaping @MainActor (DictationDownload) -> Void) async throws {
        progress(DictationDownload(fraction: 0.5, completedBytes: 59_000_000, totalBytes: 118_000_000))
        downloaded = true
    }

    func start(_ locale: Locale, input: AudioDeviceID?, context: [String],
               heard: @escaping @MainActor (DictationHeard) -> Void,
               level: @escaping @MainActor (Float) -> Void) async throws {
        started = true
        self.heard = heard
    }

    var holdsFinish = false
    private var held: CheckedContinuation<Void, Never>?

    var isHolding: Bool { held != nil }

    func releaseFinish() {
        held?.resume()
        held = nil
    }

    func finish() async -> DictationHeard {
        if holdsFinish { await withCheckedContinuation { held = $0 } }
        return final
    }
    func cancel() { cancelled = true }
}
