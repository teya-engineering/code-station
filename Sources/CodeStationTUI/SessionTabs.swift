import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// The tabs over an open session, as the GUI's destination deck: Chat, Design,
// Troubleshoot, Changes and Explorer, in the order the station lists them in the header,
// reached with the number keys by position. Chat is the transcript itself; every other
// tab draws its own screen in the main pane, under the top bar.
//
// Adding a tab's screen:
// 1. Write a class conforming to `SessionTabScreen`, in a file of its own. It reaches the
//    station through the `SessionTabContext` it is made with.
// 2. Return it from `SessionTabs.screen(for:context:)` in place of the placeholder.
// 3. Give it a `KeyBindings.Place` and a section listing its keys.
// Nothing in `TUIApp` changes: it hands keys to the tab on screen and draws its frame.

// One tab's screen in the main pane.
@MainActor
protocol SessionTabScreen: AnyObject {
    // Where the person is, for the key list to start with this tab's keys.
    var place: KeyBindings.Place { get }
    func frame(size: TerminalSize) -> (lines: [String], cursor: Screen.Cursor?)
    // The keys the tab takes. The number keys and the other session-wide keys are
    // handled before it is asked, unless `takesTyping` says it is taking text.
    func handle(_ key: Key, rows: Int) -> SessionTabOutcome
    // Whether keys are typing text in the tab now, so the number keys are left to it.
    var takesTyping: Bool { get }
    // The tab is going off screen; anything it still waits on is let go.
    func close()
}

extension SessionTabScreen {
    var takesTyping: Bool { false }
    func close() {}
}

enum SessionTabOutcome {
    case handled
    case ignored
    // The tab has nothing left to step back to: the chat comes back.
    case back
}

// What a tab's screen can reach: the session it is for, the station, and the app's
// ways of running station work and drawing again once that work has answered.
@MainActor
struct SessionTabContext {
    let sessionID: String
    let title: String
    let commands: any StationInterface
    let theme: TranscriptTheme
    // Runs station work off the key that asked for it, counted until it is seen
    // through, as every command from a key is.
    let work: (@escaping @MainActor () async -> Void) -> Task<Void, Never>
    let repaint: @MainActor () -> Void
    // The environment the TUI reads `$EDITOR` and the like from.
    var environment: [String: String] = [:]
    // Hands the terminal to a program and waits for it (see `Handoff`): its exit status,
    // or nil when this TUI has no terminal to hand over.
    var handoff: @MainActor (Handoff) async -> Int32? = { _ in nil }
    // Opens a web link, such as a pull request, through the client's host services.
    var openLink: @MainActor (URL) -> Void = { _ in }
}

enum SessionTabs {
    // The tabs a header names, or every tab for a host that predates the list.
    static func tabs(of header: RemoteHeader) -> [RemoteSessionTab] {
        header.tabs ?? RemoteSessionTab.Kind.allCases.map {
            RemoteSessionTab(kind: $0, title: title(of: $0))
        }
    }

    static func title(of kind: RemoteSessionTab.Kind) -> String {
        switch kind {
        case .chat: "Chat"
        case .design: "Design"
        case .troubleshoot: "Troubleshoot"
        case .changes: "Changes"
        case .explorer: "Explorer"
        }
    }

    // The tab the number key picks, by its position in the row: `1` is the first.
    static func tab(forNumber key: Key, in header: RemoteHeader) -> RemoteSessionTab.Kind? {
        guard case .char(let character, let mods) = key, mods.isEmpty,
              let number = character.wholeNumberValue, number >= 1 else { return nil }
        let tabs = tabs(of: header)
        return number <= tabs.count ? tabs[number - 1].kind : nil
    }

    // The screen each tab draws. Chat has none: it is the transcript.
    @MainActor
    static func screen(for kind: RemoteSessionTab.Kind, context: SessionTabContext) -> (any SessionTabScreen)? {
        switch kind {
        case .chat: nil
        case .changes: ChangesTab(context)
        case .explorer: ExplorerTab(context)
        case .design: DesignTab(context)
        case .troubleshoot: TroubleshootTab(context)
        }
    }
}
