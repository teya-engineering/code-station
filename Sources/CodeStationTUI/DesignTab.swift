import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// The session's Design conversation as a tab, as the GUI's Design tab drives it, minus
// the canvas a terminal cannot draw. Opening the tab starts a Design when there is none,
// as the GUI does. Over the conversation sit what the canvas holds (each screen a file
// to open in the browser), the ambition, the versions and the Build it was handed to.
//
// Keys, as in the GUI's canvas bar and composer:
// - Enter or `i` writes to the conversation; Enter sends.
// - `o` opens the screen in the browser, `s` steps to the next screen.
// - `A` steps the ambition (restrained, balanced, all out, or the app's default).
// - `v` approves the canvas as it is; `I` implements it, asking for guidance first, or
//   sends the newer version to the Build that has an older one.
// - Esc stops a running turn, and goes back to the chat otherwise.
@MainActor
final class DesignTab: SessionTabScreen {
    private let context: SessionTabContext
    private var design: RemoteDesignState?
    private var conversation: TranscriptView?
    private var events: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var screenIndex = 0
    // Said on the help line until the next key.
    private var notice: String?
    // Guidance for the Build, being typed after `I`.
    private var guidance: ComposerView?
    private var failed: String?

    init(_ context: SessionTabContext) {
        self.context = context
        load()
        // The agent writes the canvas behind the station's back, so the tab looks again
        // now and then, as the GUI's canvas does. Not counted as work from a key.
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                await self.reread()
            }
        }
    }

    var place: KeyBindings.Place {
        if guidance != nil || conversation?.composing == true { return .composer }
        if conversation?.prompt != nil { return .permission }
        return .design
    }

    var takesTyping: Bool {
        guidance != nil || conversation?.composing == true || conversation?.prompt != nil
    }

    func close() {
        events?.cancel()
        polling?.cancel()
        if let id = conversation?.sessionID {
            let commands = context.commands
            Task { await commands.closeSession(id) }
        }
    }

    // MARK: - Reading

    // Reads where the Design stands, starting one when there is none, and opens its
    // conversation.
    private func load() {
        let id = context.sessionID, commands = context.commands
        _ = context.work { [weak self] in
            do throws(StationRefusal) {
                var design = try await commands.readDesign(id)
                if design.stage == .none { design = try await commands.startDesign(id) }
                guard let self else { return }
                self.show(design)
                await self.openConversation()
            } catch {
                self?.failed = error.message
            }
            self?.context.repaint()
        }
    }

    private func reread() async {
        guard let design = try? await context.commands.readDesign(context.sessionID) else { return }
        show(design)
        context.repaint()
    }

    private func show(_ design: RemoteDesignState) {
        self.design = design
        if screenIndex >= design.screens.count { screenIndex = 0 }
    }

    // The conversation opens here unless the tab's session is that conversation, which
    // the chat already shows.
    private func openConversation() async {
        guard conversation == nil, let design, design.stage == .designing,
              design.conversationID != nil, !showsInChat(design),
              let opened = try? await context.commands.openSession(context.sessionID, conversation: .design)
        else { return }
        var view = TranscriptView(opened, theme: context.theme)
        view.keysHelp = keysHelp
        conversation = view
        let id = opened.snapshot.sessionID, commands = context.commands
        events = Task { [weak self] in
            for await event in opened.events {
                guard let self else { return }
                if self.conversation?.apply(event) == false { await commands.resync(id) }
                self.context.repaint()
            }
        }
    }

    private func showsInChat(_ design: RemoteDesignState) -> Bool {
        design.conversationIsSession || design.conversationID == context.sessionID
    }

    // MARK: - Drawing

    func frame(size: TerminalSize) -> (lines: [String], cursor: Screen.Cursor?) {
        let width = max(size.cols, 20)
        let status = statusLines(width: width)
        let room = TerminalSize(cols: width, rows: max(size.rows - status.count, 3))
        if var view = conversation, guidance == nil {
            view.notice = notice
            let (lines, cursor) = view.frame(size: room)
            conversation = view
            return (status + lines, cursor.map { Screen.Cursor(row: $0.row + status.count, col: $0.col) })
        }
        var body: [String] = []
        var cursor: Screen.Cursor?
        if let guidance {
            body.append("")
            body.append(SidebarView.paint([(" Implement this Design?", Style.bold)], width: width))
            body.append(SidebarView.paint([(" Add guidance if the canvas shows several options, or leave it blank to implement it as shown.", Style.dim)], width: width))
            body.append("")
            let (rows, at) = guidance.layout(width: max(width - 1, 3))
            cursor = Screen.Cursor(row: status.count + body.count + at.row, col: at.col + 1)
            body += rows.map { " " + $0 }
        } else if let failed {
            body = ["", SidebarView.paint([(" " + failed, Style.code(.attention, theme: context.theme))], width: width)]
        } else if let design, design.stage == .reference {
            body = ["", SidebarView.paint([(" This session builds from an approved Design.", Style.bold)], width: width),
                    SidebarView.paint([(design.conversationID == nil
                        ? " The Design it came from has been deleted; o still opens the copy it was handed."
                        : " The Design conversation it came from lives in another session.", Style.dim)], width: width)]
        } else if let design, showsInChat(design) {
            body = ["", SidebarView.paint([(" This session is the Design conversation: write to it in Chat.", Style.bold)], width: width)]
        } else {
            body = ["", SidebarView.paint([(" Opening the Design…", Style.dim)], width: width)]
        }
        let height = max(size.rows - status.count - 1, 0)
        body = Array(body.prefix(height)) + Array(repeating: "", count: max(height - body.count, 0))
        let help = notice ?? (guidance != nil ? " enter implement · esc cancel" : keysHelp)
        return (status + body + [SidebarView.paint([(help, Style.dim)], width: width)], cursor)
    }

    private var keysHelp: String {
        " enter write · o open in browser · s screen · A ambition · v approve · I implement · esc chat"
    }

    // "DESIGN · DRAWING · v2 approved · ambition Balanced" over "canvas: Canvas (index.html)
    // · 1 of 2 · build up to date", then a rule.
    private func statusLines(width: Int) -> [String] {
        guard let design else { return [] }
        let theme = context.theme
        var first: [(text: String, style: String)] = [(" DESIGN", Style.bold)]
        if design.isBusy { first.append(("  DRAWING", Style.state("RUNNING", theme: theme))) }
        if let approved = design.revisions.first(where: \.approved) {
            first.append(("  · \(approved.title) approved", ""))
        } else if design.stage == .designing {
            first.append(("  · not approved yet", Style.dim))
        }
        if let ambition = design.ambition { first.append(("  · ambition \(ambition)", "")) }

        var second: [(text: String, style: String)]
        if design.screens.isEmpty {
            second = [(design.isBusy ? " canvas: being drawn…" : " canvas: nothing drawn yet", Style.dim)]
        } else {
            let screen = design.screens[min(screenIndex, design.screens.count - 1)]
            second = [(" canvas: \(screen.title) (\(screen.path))", Style.cyan)]
            if design.screens.count > 1 { second.append(("  · \(screenIndex + 1) of \(design.screens.count)", Style.dim)) }
        }
        if design.stage == .designing {
            if design.buildID == nil {
                second.append(("  · no build yet", Style.dim))
            } else if design.buildIsCurrent {
                second.append(("  · BUILD UP TO DATE", Style.code(.state(.running), theme: theme)))
            } else {
                second.append(("  · build is behind: I to update", Style.code(.attention, theme: theme)))
            }
        }
        return [SidebarView.paint(first, width: width), SidebarView.paint(second, width: width),
                Style.dim + String(repeating: "─", count: width) + Style.reset]
    }

    // MARK: - Keys

    func handle(_ key: Key, rows: Int) -> SessionTabOutcome {
        notice = nil
        if guidance != nil { return handleInGuidance(key) }
        if conversation?.composing == true { return handleInComposer(key) }
        if let handled = handleInPrompt(key) { return handled }
        switch key {
        case .escape where conversation?.isBusy == true && conversation?.stopRequested == false:
            stopTurn()
        case .escape, .left, .char("q", []), .char("h", []): return .back
        case .enter([]), .char("i", []):
            guard conversation != nil else { return .ignored }
            conversation?.composing = true
        case .up, .char("k", []): conversation?.scroll(by: -1)
        case .down, .char("j", []): conversation?.scroll(by: 1)
        case .pageUp, .char("b", []): conversation?.scrollPage(by: -1)
        case .pageDown, .char(" ", []): conversation?.scrollPage(by: 1)
        case .home, .char("g", []): conversation?.scrollToTop()
        case .end, .char("G", []): conversation?.scrollToBottom()
        case .char("o", []): openScreen()
        case .char("s", []):
            guard let count = design?.screens.count, count > 1 else {
                notice = " The canvas has one screen."
                return .handled
            }
            screenIndex = (screenIndex + 1) % count
        case .char("A", []), .char("A", .shift): stepAmbition()
        case .char("v", []): approve()
        case .char("I", []), .char("I", .shift):
            guard let design, design.stage == .designing else { return .ignored }
            if let refusal = implementRefusal(design) {
                notice = " " + refusal
            } else if design.buildID != nil {
                implement(guidance: nil)
            } else {
                guidance = ComposerView()
            }
        case .char("r", []): Task { await reread() }
        default: return .ignored
        }
        return .handled
    }

    private func implementRefusal(_ design: RemoteDesignState) -> String? {
        if design.isBusy { return "Wait for the Design turn to finish." }
        if design.screens.isEmpty { return "There is no design on the canvas yet." }
        return nil
    }

    private func handleInGuidance(_ key: Key) -> SessionTabOutcome {
        guard var field = guidance else { return .ignored }
        switch key {
        case .escape: guidance = nil
        default:
            if field.handle(key) == .send {
                guidance = nil
                implement(guidance: field.string)
            } else {
                guidance = field
            }
        }
        return .handled
    }

    private func handleInComposer(_ key: Key) -> SessionTabOutcome {
        guard var view = conversation else { return .ignored }
        switch key {
        case .escape, .tab([]): view.composing = false
        case .pageUp: view.scrollPage(by: -1)
        case .pageDown: view.scrollPage(by: 1)
        default:
            if view.composer.handle(key) == .send {
                conversation = view
                send()
                return .handled
            }
        }
        conversation = view
        return .handled
    }

    private func handleInPrompt(_ key: Key) -> SessionTabOutcome? {
        guard let open = conversation, var prompt = open.prompt else { return nil }
        if key == .escape { return .back }
        switch prompt.handle(key) {
        case .ignored: return nil
        case .edited: conversation?.prompt = prompt
        case .answer(let answer, let answers):
            conversation?.prompt = prompt
            let commands = context.commands
            _ = context.work { [weak self] in
                do throws(StationRefusal) {
                    try await commands.answerPermission(open.sessionID, requestID: prompt.permission.id,
                                                        answer: answer, answers: answers)
                    guard let self, self.conversation?.prompt?.permission.id == prompt.permission.id else { return }
                    self.conversation?.prompt = nil
                } catch {
                    self?.notice = " " + error.message
                }
                self?.context.repaint()
            }
        }
        return .handled
    }

    // MARK: - Commands

    private func send() {
        guard let open = conversation, open.composer.hasSomethingToSend else { return }
        let text = open.composer.string, commands = context.commands
        _ = context.work { [weak self] in
            do throws(StationRefusal) {
                try await commands.sendPrompt(open.sessionID, prompt: text)
                guard let self else { return }
                if self.conversation?.composer.string == text { self.conversation?.composer.clear() }
                self.conversation?.scrollToBottom()
            } catch {
                self?.notice = " " + error.message
            }
            self?.context.repaint()
        }
    }

    private func stopTurn() {
        guard let id = conversation?.sessionID else { return }
        let commands = context.commands
        _ = context.work { [weak self] in
            do throws(StationRefusal) {
                try await commands.stopTurn(id)
                self?.conversation?.noteStopRequested()
            } catch {
                self?.notice = " " + error.message
            }
            self?.context.repaint()
        }
    }

    private func openScreen() {
        guard let design, !design.screens.isEmpty else {
            notice = " There is no design on the canvas yet."
            return
        }
        let screen = design.screens[min(screenIndex, design.screens.count - 1)]
        guard let url = URL(string: screen.url) else { return }
        context.openLink(url)
        notice = " Opened \(screen.title) in the browser."
    }

    private func stepAmbition() {
        guard let conversationID = design?.conversationID, design?.stage == .designing else { return }
        let commands = context.commands
        _ = context.work { [weak self] in
            do throws(StationRefusal) {
                let settings = try await commands.readRunSettings(conversationID)
                guard let row = settings.setting("designAmbition"), !row.choices.isEmpty else { return }
                let index = row.choices.firstIndex { $0.value == row.value } ?? 0
                let next = row.choices[(index + 1) % row.choices.count]
                _ = try await commands.changeRunSetting(conversationID, "designAmbition", to: next.value)
                self?.notice = " Ambition: \(next.title), from the next turn."
                await self?.reread()
            } catch {
                self?.notice = " " + error.message
            }
            self?.context.repaint()
        }
    }

    private func approve() {
        let id = context.sessionID, commands = context.commands
        _ = context.work { [weak self] in
            do throws(StationRefusal) {
                let design = try await commands.approveDesign(id)
                self?.show(design)
                self?.notice = " Approved \(design.revisions.first(where: \.approved)?.title ?? "the Design")."
            } catch {
                self?.notice = " " + error.message
            }
            self?.context.repaint()
        }
    }

    private func implement(guidance: String?) {
        let id = context.sessionID, commands = context.commands
        let hadBuild = design?.buildID != nil
        notice = " Preparing the Design…"
        _ = context.work { [weak self] in
            do throws(StationRefusal) {
                _ = try await commands.implementDesign(id, additionalContext: guidance)
                let design = try await commands.readDesign(id)
                self?.show(design)
                let title = design.revisions.first(where: \.approved)?.title ?? "the Design"
                self?.notice = hadBuild ? " Sent \(title) to the Build." : " Implementation started from \(title): it runs in Chat."
            } catch {
                self?.notice = " " + error.message
            }
            self?.context.repaint()
        }
    }
}
