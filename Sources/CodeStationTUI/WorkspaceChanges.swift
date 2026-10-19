import CodeStationCore
import TerminalKit
import TerminalTranscript

// A workspace's changes across its members, over its screen: what each project's own
// folder has changed, the lead first, and a file's diff once one is picked. It reads them
// from the station when it opens and on `r`, and draws them as a session's Changes tab
// does.
@MainActor
final class WorkspaceChanges {
    private var view: ChangesView
    private let workspaceID: String
    private let commands: any StationInterface
    private let work: (@escaping @MainActor () async -> Void) -> Task<Void, Never>
    private let repaint: @MainActor () -> Void
    private var read: Task<Void, Never>?

    init(workspaceID: String, name: String, commands: any StationInterface, theme: TranscriptTheme,
         work: @escaping (@escaping @MainActor () async -> Void) -> Task<Void, Never>,
         repaint: @escaping @MainActor () -> Void) {
        self.workspaceID = workspaceID
        self.commands = commands
        self.work = work
        self.repaint = repaint
        view = ChangesView(sessionID: workspaceID, title: name, theme: theme)
        reload()
    }

    var place: KeyBindings.Place { view.openFile == nil ? .changes : .diff }

    func frame(size: TerminalSize) -> [String] { view.frame(size: size) }

    func close() { read?.cancel() }

    private func reload() {
        view.startLoading()
        read?.cancel()
        let id = workspaceID, commands = commands
        read = work { [weak self] in
            let checkouts = try? await commands.readWorkspaceChanges(id)
            guard let self, !Task.isCancelled else { return }
            self.view.show(checkouts.map { RemoteChanges(sessionID: id, checkouts: $0) })
            self.repaint()
        }
    }

    // `.back` when Esc has nothing left to step back to, so the workspace's screen comes
    // back.
    func handle(_ key: Key, rows: Int) -> SessionTabOutcome {
        let inDiff = view.openFile != nil
        let page = max(rows - 4, 1)
        switch key {
        case .char("r", []): reload()
        case .escape, .left, .char("q", []), .char("h", []):
            guard inDiff else { return .back }
            view.closeDiff()
        case .enter([]), .right, .char("l", []):
            if !inDiff { view.openSelected() }
        case .char("n", []) where inDiff: view.openNeighbour(by: 1)
        case .char("p", []) where inDiff: view.openNeighbour(by: -1)
        case .up, .char("k", []), .char("p", .ctrl):
            if inDiff { view.scroll(by: -1) } else { view.move(by: -1) }
        case .down, .char("j", []), .char("n", .ctrl):
            if inDiff { view.scroll(by: 1) } else { view.move(by: 1) }
        case .pageUp, .char("b", []), .char("u", .ctrl):
            if inDiff { view.scrollPage(by: -1) } else { view.move(by: -page) }
        case .pageDown, .char(" ", []), .char("f", []):
            if inDiff { view.scrollPage(by: 1) } else { view.move(by: page) }
        case .home, .char("g", []):
            if inDiff { view.scrollToTop() } else { view.moveToFirst() }
        case .end, .char("G", []):
            if inDiff { view.scrollToBottom() } else { view.moveToLast() }
        default: return .ignored
        }
        return .handled
    }
}
