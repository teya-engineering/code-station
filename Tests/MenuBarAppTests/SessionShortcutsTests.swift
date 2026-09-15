import Foundation
import Testing
@testable import MenuBarApp

// The menu that promotes what the agent just ran has to read both shapes a shell call
// arrives in, since the two CLIs file the same call differently.
@MainActor
struct SessionShortcutsTests {
    @Test func readsAClaudeShellCall() {
        let session = session(with: [
            ToolUse(id: "1", name: "Read", input: #"{"file_path":"a.swift"}"#, result: ""),
            ToolUse(id: "2", name: "Bash",
                    input: #"{"command":"npm run test:unit -- billing"}"#, result: "")
        ])

        #expect(SessionShortcuts.lastAgentCommand(in: session)
            == "npm run test:unit -- billing")
    }

    // Codex hands the command over on its own rather than wrapped in JSON.
    @Test func readsACodexShellCall() {
        let session = session(with: [
            ToolUse(id: "1", name: "Bash", input: "swift build", result: "")
        ])

        #expect(SessionShortcuts.lastAgentCommand(in: session) == "swift build")
    }

    // A chip names one thing, so a script pasted into a call is not offered as one.
    @Test func skipsCommandsThatSpanSeveralLines() {
        let session = session(with: [
            ToolUse(id: "1", name: "Bash", input: "make build", result: ""),
            ToolUse(id: "2", name: "Bash", input: "cat <<EOF\nhello\nEOF", result: "")
        ])

        #expect(SessionShortcuts.lastAgentCommand(in: session) == "make build")
    }

    @Test func findsNothingInASessionThatHasRunNoCommands() {
        #expect(SessionShortcuts.lastAgentCommand(in: session(with: [])) == nil)
    }

    private func session(with tools: [ToolUse]) -> ChatSession {
        var session = ChatSession(projectID: UUID(), agent: .claudeCode)
        session.messages = [
            ChatMessage(role: .user, text: "Split the billing worker."),
            ChatMessage(role: .assistant, text: "Working on it.", tools: tools)
        ]
        return session
    }
}

// The row shares its line with the rest of the run choices, so the chips have to fit
// themselves to whatever is left of it. A chip that only half fits is a different
// command to read, so it goes behind the count instead.
@MainActor
struct ShortcutChipFitTests {
    private let gap = ShortcutChipFit.gap

    @Test func showsEverythingWhenTheRowHasTheRoom() {
        let widths: [CGFloat] = [100, 80, 60]
        let available = 240 + gap * 2

        #expect(ShortcutChipFit.shown(widths: widths, countWidth: 70,
                                      available: available) == 3)
    }

    // The count chip takes room of its own, so the last chip that would have fitted
    // without it does not.
    @Test func setsTheCountChipAsideBeforeFittingAnything() {
        let widths: [CGFloat] = [100, 80, 60]
        let available = 240 + gap * 2 - 1

        #expect(ShortcutChipFit.shown(widths: widths, countWidth: 70,
                                      available: available) == 1)
    }

    @Test func neverPlacesAChipThatOnlyPartlyFits() {
        let widths: [CGFloat] = [100, 80, 120]
        // Room for the count chip, the first chip, and all but one point of the second.
        let available = 70 + gap + 100 + gap + 79

        #expect(ShortcutChipFit.shown(widths: widths, countWidth: 70,
                                      available: available) == 1)
    }

    @Test func placesNothingWhenEvenTheFirstChipIsTooWide() {
        #expect(ShortcutChipFit.shown(widths: [100, 80], countWidth: 70,
                                      available: 120) == 0)
    }

    @Test func placesNothingWhenThereIsNothingToPlace() {
        #expect(ShortcutChipFit.shown(widths: [], countWidth: 70, available: 400) == 0)
    }

    @Test func sortsRunningThenFailedThenTheOrderTheyWereSavedIn() {
        let saved = (0..<4).map { placement(named: "\($0)") }
        let states: [ShortcutStore.State] = [
            .stopped,
            .failed("no", status: 1, at: .now),
            .finished(at: .now),
            .running(since: .now)
        ]

        let ordered = ShortcutChipFit.ordered(saved) { placement in
            states[saved.firstIndex { $0.id == placement.id }!]
        }

        #expect(ordered.map(\.shortcut.name) == ["3", "1", "0", "2"])
    }

    // A long name is capped rather than left to take the room of the commands beside it.
    @Test func capsTheWidthALongNameCanTake() {
        let long = ShortcutChipFit.chipWidth(
            name: "Regenerate the OpenAPI client and check it in",
            glyph: nil, state: .stopped, tinted: false)
        let longer = ShortcutChipFit.chipWidth(
            name: "Regenerate the OpenAPI client and check it in, then push",
            glyph: nil, state: .stopped, tinted: false)

        #expect(long == longer)
        #expect(long == ShortcutChipFit.nameWidthCap + ShortcutChipFit.horizontalPadding * 2)
    }

    // Hovering a running command swaps its name for the word that stops it, so a chip is
    // never narrower than that word however short its name.
    @Test func keepsRoomForTheWordThatStopsARun() {
        let narrow = ShortcutChipFit.chipWidth(name: "Go", glyph: nil, state: .stopped,
                                               tinted: false)
        let stop = ShortcutChipFit.chipWidth(name: "Stop", glyph: nil, state: .stopped,
                                             tinted: false)

        #expect(narrow == stop)
    }

    @Test func makesRoomForTheProjectDotAndTheStateGlyph() {
        let plain = ShortcutChipFit.chipWidth(name: "Lint", glyph: nil, state: .stopped,
                                              tinted: false)
        let tinted = ShortcutChipFit.chipWidth(name: "Lint", glyph: nil, state: .stopped,
                                               tinted: true)
        let running = ShortcutChipFit.chipWidth(name: "Lint", glyph: nil,
                                                state: .running(since: .now), tinted: false)

        #expect(tinted > plain)
        #expect(running > plain)
    }

    // The count is measured for every command at once, so the room set aside is enough
    // whichever of them end up behind it.
    @Test func sizesTheCountChipForTheWidestCountItCouldShow() {
        #expect(ShortcutChipFit.countWidth(total: 30, badged: true)
                >= ShortcutChipFit.countWidth(total: 9, badged: false))
    }

    private func placement(named name: String) -> ShortcutPlacement {
        ShortcutPlacement(shortcut: CommandShortcut(name: name, command: "true"),
                          projectID: UUID())
    }
}
