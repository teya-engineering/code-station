import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct PromptShortcutTests {
    @Test func insertionPreservesTheDraftAndUndoRestoresItExactly() {
        let composer = SessionComposerStore()
        let session = UUID()
        let attachment = Attachment(url: URL(fileURLWithPath: "/private/tmp/context.txt"))
        let previous = SessionComposerStore.Draft(text: "Focus on this file.  ", attachments: [attachment],
                                                  customInstructions: "Keep it short", dictated: true)
        composer.restore(previous, in: session)
        let prompt = Shortcut(name: "Review", text: "Review the diff.\nKeep the formatting.\n", kind: .prompt)

        #expect(composer.insert(prompt, in: session))
        #expect(composer.draft(session).text == previous.text + "\n\n" + prompt.text)
        #expect(composer.draft(session).attachments == previous.attachments)
        #expect(composer.draft(session).customInstructions == previous.customInstructions)
        #expect(composer.draft(session).dictated)
        let focus = composer.focusRequest(session)
        #expect(focus != nil)

        composer.undoInsertion(session)
        #expect(composer.draft(session) == previous)
        #expect(composer.focusRequest(session) != focus)
        #expect(composer.insertion(session) == nil)
    }

    @Test(arguments: ["", "Existing", "Existing\n", "Existing\n\n", "   "])
    func insertionUsesAParagraphBreakWithoutChangingExistingText(_ text: String) {
        let composer = SessionComposerStore()
        let session = UUID()
        composer.editDraft(session) { $0.text = text }
        let prompt = Shortcut(name: "Explain", text: "Explain this code", kind: .prompt)
        #expect(composer.insert(prompt, in: session))
        let expected = switch text {
        case "": prompt.text
        case "   ": "   \n\n" + prompt.text
        default: "Existing\n\n" + prompt.text
        }
        #expect(composer.draft(session).text == expected)
        composer.undoInsertion(session)
        #expect(composer.draft(session).text == text)
    }

    @Test func manualEditsExpireUndoEvenWhenTheTextIsChangedBack() {
        let composer = SessionComposerStore()
        let session = UUID()
        composer.insert(Shortcut(name: "Review", text: "Review", kind: .prompt), in: session)
        composer.editDraft(session) { $0.text += " this" }
        composer.editDraft(session) { $0.text = "Review" }
        composer.undoInsertion(session)
        #expect(composer.draft(session).text == "Review")
        #expect(composer.insertion(session) == nil)
    }

    @Test func undoOnlyRestoresTheImmediatelyPrecedingDraftInItsSession() {
        let composer = SessionComposerStore()
        let first = UUID()
        let second = UUID()
        let prompt = Shortcut(name: "Review", text: "Review", kind: .prompt)
        composer.insert(prompt, in: first)
        composer.insert(prompt, in: second)
        composer.insert(prompt, in: first)
        composer.undoInsertion(first)
        #expect(composer.draft(first).text == "Review")
        #expect(composer.insertion(second) != nil)
        composer.clearDraft(second)
        #expect(composer.insertion(second) == nil)
    }

    @Test func commandsCannotBeInsertedAsPrompts() {
        let composer = SessionComposerStore()
        let session = UUID()
        #expect(!composer.insert(Shortcut(name: "Build", text: "make"), in: session))
        #expect(composer.draft(session).isEmpty)
        #expect(composer.focusRequest(session) == nil)
    }

    @Test func creatingBothKindsFromChatKeepsTheComposerAndScopesIntact() {
        let scratch = ScratchDirectory(prefix: "prompt-shortcut-creation")
        let shortcuts = ShortcutStore(storageURL: scratch.path("shortcuts.json"), siteDefaults: SiteDefaults())
        let composer = SessionComposerStore()
        let session = UUID()
        let project = UUID()
        composer.editDraft(session) { $0.text = "Review this draft" }
        let previous = composer.draft(session)
        let draft = ShortcutDraft(request: ShortcutEditorRequest(projectID: project,
                                                                 text: previous.text, kind: .prompt))
        draft.value.name = "Review"
        draft.selectKind(.command)
        #expect(draft.value.text.isEmpty)
        draft.value.text = "make test"
        #expect(shortcuts.saveShortcut(draft.shortcut))
        #expect(shortcuts.shortcuts(for: project).first?.kind == .command)
        #expect(shortcuts.shortcuts(for: UUID()).isEmpty)

        draft.selectKind(.prompt)
        draft.value.availableInAllProjects = true
        #expect(shortcuts.saveShortcut(draft.shortcut))
        #expect(shortcuts.shortcuts(for: UUID()).first?.kind == .prompt)
        #expect(shortcuts.libraryShortcuts().first?.text == previous.text)
        #expect(composer.draft(session) == previous)
        #expect(composer.insertion(session) == nil)
    }

    @Test(arguments: [false, true])
    func insertionMovesTheCaretToTheEndWithoutSending(reduceMotion: Bool) async throws {
        let (store, scratch) = TestStore.make()
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id, seed: .init(agent: .codex))
        let runner = SessionRunner(preferences: scratch.preferences.store, paths: [:])
        let settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: scratch.preferences.store)
        let host = NSHostingView(rootView: ComposerHarness(sessionID: session.id)
            .environment(store)
            .environment(runner)
            .environment(settings)
            .environment(\._accessibilityReduceMotion, reduceMotion)
            .appOverlays())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 220),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.center()
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let field = try #require(textView(in: host))
        let prompt = Shortcut(name: "Review", text: "Review the diff 🔎", kind: .prompt)
        runner.composer.insert(prompt, in: session.id)

        #expect(await waitUntil {
            host.layoutSubtreeIfNeeded()
            return field.string == prompt.text && window.firstResponder === field
        })
        #expect(field.selectedRange() == NSRange(location: (prompt.text as NSString).length, length: 0))
        #expect(runner.queued(session.id).isEmpty)
        #expect(store.session(session.id)?.messages.isEmpty == true)

        runner.composer.undoInsertion(session.id)
        #expect(await waitUntil { field.string.isEmpty })
        #expect(field.selectedRange() == NSRange(location: 0, length: 0))
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}

private struct ComposerHarness: View {
    let sessionID: UUID
    @State private var focused = false

    var body: some View {
        Composer(sessionID: sessionID, agent: .codex, blocked: false,
                 isFocused: $focused, placeholder: "Message", onOversizedPaste: { _ in },
                 above: { EmptyView() }, accessory: { EmptyView() })
    }
}
