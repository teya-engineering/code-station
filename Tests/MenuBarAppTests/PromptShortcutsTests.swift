import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The prompt rail shares the header with the tab deck, so what it draws has to answer to
// the room it has: nothing at all when a project saved no prompts, a button each while
// they fit, and one button standing for all of them once they do not.
@MainActor
struct PromptShortcutsTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let shortcuts: ShortcutStore

    init() {
        (store, scratch) = TestStore.make()
        shortcuts = ShortcutStore(storageURL: scratch.path("shortcuts.json"),
                                  siteDefaults: SiteDefaults())
    }

    // A project with no prompts must not leave a hairline or a gap behind: the rail
    // should read exactly as it did before prompts existed.
    @Test func drawsNothingForAProjectThatSavedNoPrompts() throws {
        let session = try session(named: "lantern")
        _ = shortcuts.add(name: "Lint", text: "npm run lint", projectID: session.projectID)

        #expect(width(for: session) == 0)
    }

    // Each prompt is its own button up to the limit, so the rail grows a button's worth
    // at a time and every prompt stays one click away.
    @Test func standsEachPromptOnItsOwnButtonWhileTheyFit() throws {
        let session = try session(named: "lantern")

        var widths: [CGFloat] = []
        for index in 1...4 {
            _ = shortcuts.add(name: "Prompt \(index)", text: "Do thing \(index).",
                              kind: .prompt, projectID: session.projectID)
            widths.append(width(for: session))
        }

        #expect(widths == widths.sorted())
        #expect(widths[0] > 0)
        #expect(widths[3] > widths[0])
    }

    // Past a few, a row of glyphs stops being something you read, so the rail hands them
    // all to one button rather than squeezing the tab deck beside it.
    @Test func collapsesPastTheLimitAndWheneverTheRailIsFolded() throws {
        let session = try session(named: "lantern")
        for index in 1...4 {
            _ = shortcuts.add(name: "Prompt \(index)", text: "Do thing \(index).",
                              kind: .prompt, projectID: session.projectID)
        }
        let inline = width(for: session)
        let folded = width(for: session, folded: true)

        _ = shortcuts.add(name: "Prompt 5", text: "Do thing 5.", kind: .prompt,
                          projectID: session.projectID)

        #expect(folded < inline)
        #expect(width(for: session) == folded)
        #expect(width(for: session, folded: true) == folded)
    }

    // A prompt shared with every project is offered by each of them, so a session sees it
    // beside the ones its own project saved.
    @Test func offersSharedPromptsAlongsideTheProjectsOwn() throws {
        let session = try session(named: "lantern")
        _ = shortcuts.add(name: "Review", text: "Review my working tree.", kind: .prompt,
                          projectID: session.projectID)
        let own = width(for: session)

        _ = shortcuts.add(name: "Tidy", text: "Tidy what you just wrote.", kind: .prompt,
                          availableInAllProjects: true)

        #expect(width(for: session) > own)
    }

    private func session(named name: String) throws -> ChatSession {
        let project = try TestStore.project(in: store, named: name)
        return store.newSession(in: project.id)
    }

    private func width(for session: ChatSession, folded: Bool = false) -> CGFloat {
        let view = SessionPromptShortcuts(session: session,
                                          conversationID: session.id,
                                          folded: folded,
                                          edit: { _ in })
            .environment(store)
            .environment(shortcuts)
            .environment(SessionRunner())
            .environment(TooltipPresenter())
            .environment(MenuPresenter())
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return host.fittingSize.width
    }
}
