import SwiftUI

// The saved prompts a session can send in one click, on the icon rail above the pane.
// They sit there rather than beside the composer because a prompt is not a thing you
// watch: it goes to the agent and the answer arrives in the transcript, so it belongs
// with the other buttons that act on the session as a whole.
//
// A prompt is sent as though it had been typed. A session already working queues it
// behind the turn it is on, which is what the composer does with a typed prompt too.
struct SessionPromptShortcuts: View {
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner

    let session: ChatSession
    // The conversation a prompt lands in. A Design tab runs a conversation of its own, so
    // what is on screen is not always the session's own.
    let conversationID: UUID
    // Whether the rail has room to stand each prompt on a button of its own.
    let folded: Bool
    let edit: (ShortcutEditorRequest) -> Void

    // Past a few, a row of glyphs stops being something you read and starts being
    // something you search, and the rail has the tab deck to share its width with.
    private static let inlineLimit = 4

    var body: some View {
        let placements = placements
        if !placements.isEmpty {
            // The hairline is drawn here rather than by the rail, because whether there
            // is a group to close off is something only this view knows.
            HeaderRailDivider()
            HStack(spacing: 2) {
                if folded || placements.count > Self.inlineLimit {
                    collapsed(placements)
                } else {
                    ForEach(placements) { placement in
                        button(placement)
                    }
                }
            }
        }
    }

    private func button(_ placement: ShortcutPlacement) -> some View {
        let shortcut = placement.shortcut
        return HeaderRailButton(icon: shortcut.glyph ?? "sparkles",
                                label: shortcut.name,
                                hint: shortcut.text) {
            send(shortcut)
        }
        .appContextMenu { menu(for: placement) }
    }

    // Every prompt behind one button, for a rail with no room to stand them side by side
    // or a project that has collected more than a glance can hold.
    private func collapsed(_ placements: [ShortcutPlacement]) -> some View {
        HeaderRailButton(icon: "sparkles", label: "Send a saved prompt")
            .appMenu {
                var entries: [MenuEntry] = placements.map { placement in
                    let shortcut = placement.shortcut
                    return .item(shortcut.name,
                                 icon: shortcut.glyph,
                                 subtitle: shortcut.text,
                                 action: { send(shortcut) })
                }
                entries.append(.separator)
                entries.append(.item("New prompt…", icon: "plus",
                                     action: { edit(blankRequest) }))
                return entries
            }
    }

    private func menu(for placement: ShortcutPlacement) -> [MenuEntry] {
        let shortcut = placement.shortcut
        var entries: [MenuEntry] = [
            .item("Send", action: { send(shortcut) }),
            // The project offering the prompt, not the one that owns it, so turning
            // sharing off files a shared prompt under the project you did it from.
            .item("Edit", action: {
                edit(ShortcutEditorRequest(shortcut: shortcut,
                                           projectID: placement.projectID,
                                           projectName: store.project(placement.projectID)?.name))
            }),
            .item("New prompt…", icon: "plus", action: { edit(blankRequest) })
        ]
        // A shared prompt is the Mac's, so removing it here would take it out of every
        // other project too. The Shortcuts sheet is the one place that owns that.
        if !shortcut.availableInAllProjects {
            entries.append(.separator)
            entries.append(.item("Remove", kind: .destructive,
                                 action: { shortcuts.remove(shortcut.id) }))
        }
        return entries
    }

    // Every checkout's prompts at once, the same way the command chips gather them, so a
    // workspace session offers what each of its projects saved.
    private var placements: [ShortcutPlacement] {
        shortcuts.shortcuts(for: store.checkoutProjects(for: session).map(\.projectID),
                            kind: .prompt)
    }

    private var blankRequest: ShortcutEditorRequest {
        ShortcutEditorRequest(projectID: session.projectID,
                              projectName: store.project(session.projectID)?.name,
                              kind: .prompt)
    }

    private func send(_ shortcut: Shortcut) {
        runner.send(shortcut.text, sessionID: conversationID, store: store)
    }
}
