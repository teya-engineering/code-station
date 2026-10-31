import AppKit
import CoreAudio
import Testing
@testable import MenuBarApp

@MainActor struct NoteDictationTests {
    private let scratch = ScratchDirectory(prefix: "note-dictation-tests")
    private let preferences = TestPreferences()

    @Test func dictationInsertsAtTheCursorWithoutFlatteningRichText() async throws {
        let store = NotebookStore(directory: scratch.url)
        let id = try #require(store.create())
        let original = NoteDocument(runs: [.init(text: "Plan 👋 ", bold: true),
                                          .init(text: "tomorrow", italic: true, link: "https://example.com")])
        store.update(id) { $0.body = original }
        let view = editor(original, caret: "Plan 👋 ".utf16.count)
        view.typingAttributes = NoteDocument.attributes(bold: true)
        let take = NoteDictation(note: try #require(store.note(id)), store: store, view: view)
        let speech = NoteSpeech()
        let dictation = Dictation(engine: speech, preferences: preferences.store)
        dictation.toggle(request(take))
        #expect(await waitUntil { dictation.isListening(id) })
        speech.say("ship")
        #expect(store.note(id)?.body.text == "Plan 👋 ship tomorrow")
        speech.final = .init(settled: [.init(text: "ship"), .init(text: "it")])
        dictation.stop()
        #expect(await waitUntil { dictation.phase == .idle })
        let body = try #require(store.note(id)?.body)
        #expect(body.text == "Plan 👋 ship it tomorrow")
        #expect(body.runs.first?.bold == true)
        #expect(body.runs.last?.italic == true)
        #expect(body.runs.last?.link == "https://example.com")
        #expect(view.string == body.text)
        #expect(NotebookStore(directory: scratch.url).note(id)?.body == body)
    }

    @Test func escapeRestoresFormattingAndDiscardUndoRestoresTheTake() async throws {
        let store = NotebookStore(directory: scratch.url)
        let id = try #require(store.create())
        let original = NoteDocument(runs: [.init(text: "☑ Keep", bold: true, block: .checklist)])
        store.update(id) { $0.body = original }
        let take = NoteDictation(note: try #require(store.note(id)), store: store, view: nil)
        let speech = NoteSpeech()
        let dictation = Dictation(engine: speech, preferences: preferences.store)
        dictation.toggle(request(take))
        #expect(await waitUntil { dictation.isListening(id) })
        speech.say("this")
        dictation.throwAway()
        #expect(dictation.phase == .idle)
        #expect(store.note(id)?.body == original)
        dictation.undo()
        #expect(store.note(id)?.body.text == "☑ Keep this")
        #expect(store.note(id)?.body.runs.first?.block == .checklist)
    }

    @Test func finishingAfterChangingNotesOnlyUpdatesTheOriginalNote() async throws {
        let store = NotebookStore(directory: scratch.url)
        let first = try #require(store.create())
        let take = NoteDictation(note: try #require(store.note(first)), store: store, view: nil)
        let speech = NoteSpeech()
        let dictation = Dictation(engine: speech, preferences: preferences.store)
        dictation.toggle(request(take))
        #expect(await waitUntil { dictation.isListening(first) })
        speech.final = .init(settled: [.init(text: "remember")])
        let second = try #require(store.create())
        dictation.leave(first)
        #expect(await waitUntil { dictation.phase == .idle })
        #expect(store.selectedID == second)
        #expect(store.note(first)?.body.text == "Remember")
        #expect(store.note(second)?.body.text.isEmpty == true)
    }

    @Test func microphoneFailureAndEmptySpeechLeaveTheNoteIntact() async throws {
        let store = NotebookStore(directory: scratch.url)
        let id = try #require(store.create())
        let original = NoteDocument(runs: [.init(text: "Do not change", italic: true)])
        store.update(id) { $0.body = original }
        let take = NoteDictation(note: try #require(store.note(id)), store: store, view: nil)
        let speech = NoteSpeech()
        speech.allowed = false
        let dictation = Dictation(engine: speech, preferences: preferences.store)
        dictation.toggle(request(take))
        #expect(await waitUntil { dictation.phase == .idle })
        #expect(dictation.notice(for: id) == .blocked(.microphoneBlocked))
        #expect(store.note(id)?.body == original)
        speech.allowed = true
        dictation.toggle(request(take))
        #expect(await waitUntil { dictation.isListening(id) })
        dictation.stop()
        #expect(await waitUntil { dictation.phase == .idle })
        #expect(store.note(id)?.body == original)
    }

    @Test func uncertainWordCorrectionsKeepSurroundingFormatting() async throws {
        let store = NotebookStore(directory: scratch.url)
        let id = try #require(store.create())
        let original = NoteDocument(runs: [.init(text: "Use ", bold: true), .init(text: "today", italic: true)])
        store.update(id) { $0.body = original }
        let view = editor(original, caret: 4)
        let take = NoteDictation(note: try #require(store.note(id)), store: store, view: view)
        let speech = NoteSpeech()
        let dictation = Dictation(engine: speech, preferences: preferences.store)
        dictation.toggle(request(take))
        #expect(await waitUntil { dictation.isListening(id) })
        speech.final = .init(settled: [.init(text: "cache", alternatives: ["cash"])])
        dictation.stop()
        #expect(await waitUntil { dictation.phase == .idle })
        let word = try #require(dictation.review(id)?.unsure.first)
        dictation.choose("cash", for: word, in: id, draft: take.binding)
        #expect(store.note(id)?.body.text == "Use cash today")
        #expect(store.note(id)?.body.runs.first?.bold == true)
        #expect(store.note(id)?.body.runs.last?.italic == true)
    }

    @Test func oneTakeIsOneNativeUndoWithRedo() throws {
        let store = NotebookStore(directory: scratch.url)
        let id = try #require(store.create())
        let original = NoteDocument(runs: [.init(text: "Keep", italic: true)])
        store.update(id) { $0.body = original }
        let view = editor(original, caret: 4)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.center()
        window.contentView = view
        window.makeFirstResponder(view)
        let undo = try #require(view.undoManager)
        undo.groupsByEvent = false
        let take = NoteDictation(note: try #require(store.note(id)), store: store, view: view)
        take.binding.wrappedValue.text = "Keep this"
        take.binding.wrappedValue.text = "Keep this thought"
        #expect(!undo.canUndo)
        undo.beginUndoGrouping()
        take.binding.wrappedValue.dictated = true
        undo.endUndoGrouping()
        undo.undo()
        #expect(NoteDocument(view.attributedString()) == original)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(view.string == "Keep this thought")
        window.orderOut(nil)
    }

    private func request(_ take: NoteDictation) -> DictationRequest {
        .init(sessionID: take.noteID, draft: take.binding, caret: take.caret,
              roots: [], vocabulary: [], placeCaret: { take.placeCaret($0) })
    }

    private func editor(_ body: NoteDocument, caret: Int) -> NoteTextView {
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        view.isRichText = true
        view.allowsUndo = true
        view.textStorage?.setAttributedString(body.attributed)
        view.typingAttributes = NoteDocument.attributes()
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return view
    }
}

@MainActor private final class NoteSpeech: SpeechSource {
    var allowed = true
    var final = DictationHeard()
    private var heard: (@MainActor (DictationHeard) -> Void)?

    func say(_ text: String) { heard?(.init(settled: [.init(text: text)])) }
    func allowsMicrophone() async -> Bool { allowed }
    func resolve(_ locale: Locale) async -> Locale? { locale }
    func needsDownload(_ locale: Locale) async -> Bool { false }
    func download(_ locale: Locale, progress: @escaping @MainActor (DictationDownload) -> Void) async throws {}
    func start(_ locale: Locale, input: AudioDeviceID?, context: [String],
               heard: @escaping @MainActor (DictationHeard) -> Void,
               level: @escaping @MainActor (Float) -> Void) async throws { self.heard = heard }
    func finish() async -> DictationHeard { final }
    func cancel() {}
}
