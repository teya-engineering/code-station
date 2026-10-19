import AppKit
import Foundation
import SwiftUI
import CodeStationCore

// The project's commands, behind one Run button at the end of the composer's own row.
// They belong there because running the tests for what was just written is the next
// thing that happens as much as sending another prompt is. A command run here uses this
// session's worktree, so the tests it runs are the tests for the branch it is on.
//
// The main half runs again whatever this session ran last, which is the command most
// worth a second run. The other half opens every command as a card, each saying how its
// last run went, so a failure is visible without opening anything.
//
// Every checkout's commands are here at once. A session with several of them marks each
// card with its project, since a command saved against one project always runs in that
// project's checkout anyway.
struct SessionRunButton: View {
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(ProjectStore.self) private var store
    @Environment(DialogPresenter.self) private var dialogs

    let session: ChatSession
    let edit: (ShortcutEditorRequest) -> Void

    @State private var listOpen = false
    // The card the arrow keys are on, counted from the top of the list.
    @State private var highlighted = 0
    @State private var buttonAnchor = FrameAnchor()
    @State private var listAnchor = FrameAnchor()
    @State private var listMonitor = CommandListMonitor()

    private var scope: ShortcutScope { .session(session.id) }

    var body: some View {
        let commands = commands
        if let current = current(in: commands) {
            splitButton(current, count: commands.count)
                .background(FrameAnchorView(anchor: buttonAnchor))
                .overlay(alignment: .topTrailing) {
                    list(commands, current: current)
                        .alignmentGuide(.top) { $0[.bottom] + 10 }
                }
                .background(keyShortcuts(current: current))
                .onChange(of: listOpen) { _, open in
                    open ? startListening() : listMonitor.stop()
                }
                .onDisappear { listMonitor.stop() }
        } else {
            saveButton
        }
    }

    // MARK: - The button

    private func splitButton(_ current: Command, count: Int) -> some View {
        HStack(spacing: 0) {
            RunHalf(name: current.shortcut.name, state: shortcuts.state(current.run)) {
                activate(current)
            }
            .appContextMenu { commandMenu(current) }
            .appTooltip {
                Tooltip(title: shortcuts.state(current.run).isActive
                            ? "Show what \(current.shortcut.name) is printing"
                            : "Run \(current.shortcut.name) (⌘R)",
                        subtitle: current.shortcut.text)
            }

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 30)

            ListHalf(count: count, open: listOpen) { toggleList() }
                .appTooltip("Every command (⇧⌘R)")
        }
        .fixedSize()
    }

    // A project with nothing saved yet offers to save its first command where the Run
    // button would be, so the place the commands go is never a dead end.
    private var saveButton: some View {
        BarPill(fill: Theme.card) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                Text("Save a command")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
        }
        .overlay(Capsule().stroke(Theme.border))
        .appMenu(edge: .top) { newMenu }
        .appTooltip("Save a command for this project")
    }

    // MARK: - The list

    private func list(_ commands: [Command], current: Command) -> some View {
        let rows = rows(commands)
        return VStack(alignment: .trailing, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if listOpen {
                    card(row, highlighted: highlighted == index)
                        .transition(rise(order: rows.count - 1 - index))
                }
            }
        }
        .frame(width: 340, alignment: .bottomTrailing)
        // One opaque tray under every card, so the transcript never shows between or
        // through them. It stays in the layout while closed and only fades, so the cards
        // inside it still get their own staggered rise each time it opens.
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.sidebar)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.settingsBorder))
                .shadow(color: .black.opacity(0.16), radius: 18, y: 7)
        }
        .opacity(listOpen ? 1 : 0)
        .offset(y: listOpen ? 0 : 8)
        .motion(listOpen ? Motion.pop : Motion.leave, value: listOpen)
        .allowsHitTesting(listOpen)
        .background(FrameAnchorView(anchor: listAnchor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
        .accessibilityHidden(!listOpen)
    }

    @ViewBuilder private func card(_ row: Row, highlighted: Bool) -> some View {
        switch row {
        case .new:
            CommandCard(icon: "plus", name: "Save a new command",
                        detail: .plain("Name it and say what it runs"),
                        tint: nil, dashed: true, highlighted: highlighted) {
                closeList()
                edit(blankRequest)
            }
        case .saveLast(let command):
            CommandCard(icon: "square.and.arrow.down", name: "Save the agent's last command",
                        detail: .command(command),
                        tint: nil, dashed: true, highlighted: highlighted) {
                closeList()
                var request = blankRequest
                request.text = command
                edit(request)
            }
        case .command(let command):
            CommandCard(icon: command.shortcut.glyph ?? "terminal",
                        name: command.shortcut.name,
                        detail: .outcome(summary(of: command)),
                        tint: command.tint,
                        dashed: false, highlighted: highlighted) {
                closeList()
                activate(command)
            }
            .appContextMenu { commandMenu(command) }
        }
    }

    // Cards rise from the button nearest first, a beat apart, and all drop together. No
    // scale: a card carries AppKit views that cannot be laid out under one.
    private func rise(order: Int) -> AnyTransition {
        .asymmetric(
            insertion: .offset(y: 14).combined(with: .opacity)
                .animation(Motion.pop.delay(Double(order) * 0.038)),
            removal: .opacity.animation(Motion.leave))
    }

    private enum Row: Identifiable {
        case new
        case saveLast(String)
        case command(Command)

        var id: String {
            switch self {
            case .new: "new"
            case .saveLast: "save-last"
            case .command(let command): command.id.uuidString
            }
        }
    }

    private func rows(_ commands: [Command]) -> [Row] {
        var rows: [Row] = [.new]
        // The command the agent just ran is the one most worth keeping, and it has
        // already been typed once.
        if let last = SessionShortcuts.lastAgentCommand(in: session),
           !commands.contains(where: { $0.shortcut.text == last }) {
            rows.append(.saveLast(last))
        }
        rows += commands.map { .command($0) }
        return rows
    }

    private func summary(of command: Command) -> CommandRunSummary {
        CommandRunSummary(state: shortcuts.state(command.run),
                          duration: shortcuts.duration(command.run),
                          started: shortcuts.hasStarted(command.run))
    }

    // MARK: - Opening and closing

    private func toggleList() {
        listOpen ? closeList() : openList()
    }

    private func openList() {
        let commands = commands
        let rows = rows(commands)
        let current = current(in: commands)?.id
        highlighted = rows.firstIndex {
            if case .command(let command) = $0 { return command.id == current }
            return false
        } ?? 0
        listOpen = true
    }

    private func closeList() {
        listOpen = false
    }

    // The arrow keys and Return belong to the list while it is open, even with the cursor
    // still in the prompt, and Escape closes it before it can stop the turn. A click
    // anywhere else puts it away, the way a menu goes.
    private func startListening() {
        listMonitor.start(
            anchor: buttonAnchor,
            regions: [buttonAnchor, listAnchor],
            key: { key in
                let rows = rows(self.commands)
                switch key {
                case .up: highlighted = max(0, highlighted - 1)
                case .down: highlighted = min(rows.count - 1, highlighted + 1)
                case .choose:
                    guard rows.indices.contains(highlighted) else { return }
                    choose(rows[highlighted])
                case .close: closeList()
                }
            },
            outside: { closeList() })
    }

    private func choose(_ row: Row) {
        closeList()
        switch row {
        case .new: edit(blankRequest)
        case .saveLast(let command):
            var request = blankRequest
            request.text = command
            edit(request)
        case .command(let command): activate(command)
        }
    }

    // MARK: - Keys

    // ⌘R runs the last command again and ⇧⌘R opens the list.
    private func keyShortcuts(current: Command) -> some View {
        ZStack {
            Button("") { activate(current) }
                .keyboardShortcut("r", modifiers: .command)
            Button("") { toggleList() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Running

    // While a command runs, its button is the way back to what it is printing, not the
    // way to kill it. Stopping is the rarer of the two and stays in its menu and in the
    // drawer the output opens in.
    private func activate(_ command: Command) {
        if shortcuts.state(command.run).isActive {
            shortcuts.showOutput(command.run, for: scope)
        } else {
            shortcuts.start(command.run, for: scope)
            shortcuts.showOutput(command.run, for: scope)
        }
    }

    private func toggle(_ command: Command) {
        if shortcuts.state(command.run).isActive {
            shortcuts.stop(command.run)
        } else {
            activate(command)
        }
    }

    private func commandMenu(_ command: Command) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            shortcuts.state(command.run).isActive
                ? .item("Stop", action: { toggle(command) })
                : .item("Run", action: { toggle(command) }),
            .item("Show output", action: { shortcuts.showOutput(command.run, for: scope) }),
            .item("Edit", action: {
                edit(ShortcutEditorRequest(shortcut: command.shortcut,
                                           projectID: command.checkout.projectID,
                                           projectName: command.projectName))
            })
        ]
        if !command.shortcut.availableInAllProjects {
            entries.append(.separator)
            entries.append(.item("Remove", kind: .destructive, action: { confirmRemove(command) }))
        }
        return entries
    }

    // The list goes away first, or its key monitor would take the Return and Escape
    // meant for the dialog.
    private func confirmRemove(_ command: Command) {
        closeList()
        let shortcut = command.shortcut
        var rows = [Dialog.Impact.Row(title: "Saved command", detail: "Removed from this project.")]
        if shortcuts.isRunningAnywhere(shortcut.id) {
            rows.append(.init(title: "Running commands", detail: "Stopped right away."))
        }
        rows.append(.init(title: "Projects and conversations", detail: "Kept unchanged.", kept: true))
        dialogs.show(.impact("Remove \(shortcut.name)?",
                             subject: command.projectName.map { .init(name: $0) },
                             rows: rows,
                             warning: "This shortcut cannot be restored after removal.",
                             action: "Remove shortcut") {
            shortcuts.remove(shortcut.id)
        })
    }

    private var newMenu: [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("New command…", action: { edit(blankRequest) })
        ]
        if let command = SessionShortcuts.lastAgentCommand(in: session) {
            entries.append(.item("Save last terminal command",
                                 subtitle: command,
                                 action: {
                                     var request = blankRequest
                                     request.text = command
                                     edit(request)
                                 }))
        }
        return entries
    }

    // Anything made from here starts as a command for the session's own project. The
    // editor can share it with every project instead.
    private var blankRequest: ShortcutEditorRequest {
        ShortcutEditorRequest(projectID: session.projectID,
                              projectName: store.project(session.projectID)?.name)
    }

    // MARK: - The commands

    private struct Command: Identifiable {
        let shortcut: Shortcut
        let checkout: SessionProject
        let projectName: String?
        let run: ShortcutRun
        let tint: Theme.ProjectTint?

        var id: Shortcut.ID { shortcut.id }
    }

    private var commands: [Command] {
        let checkouts = store.checkoutProjects(for: session)
        let tinted = checkouts.count > 1
        return shortcuts.shortcuts(for: checkouts.map(\.projectID)).compactMap { placement in
            guard let checkout = checkouts.first(where: { $0.projectID == placement.projectID })
            else { return nil }
            let project = store.project(checkout.projectID)
            let shortcut = placement.shortcut
            return Command(
                shortcut: shortcut,
                checkout: checkout,
                projectName: project?.name,
                run: ShortcutRun(shortcut.id,
                                 in: shortcut.directory(projectPath: project?.path,
                                                        workspacePath: checkout.worktreePath)),
                tint: tinted ? Theme.projectTint(for: project?.name ?? "") : nil)
        }
    }

    // What Run offers before this session has run anything is the first command, the
    // one the project put at the top of its list.
    private func current(in commands: [Command]) -> Command? {
        let last = shortcuts.lastStarted(for: scope)
        return commands.first { $0.id == last } ?? commands.first
    }
}

// MARK: - The two halves

private struct RunHalf: View {
    let name: String
    let state: ShortcutStore.State
    let action: () -> Void

    @State private var hovering = false

    private var running: Bool { state.isActive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                ZStack {
                    if running {
                        RunSpinner().transition(.opacity)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .transition(.opacity)
                    }
                }
                .frame(width: 12, height: 12)
                RollingText(running ? name : "Run \(name)",
                            font: .system(size: 12.5, weight: .semibold))
                if case .running(let since) = state {
                    TimelineView(.periodic(from: since, by: 0.1)) { context in
                        Text(CommandRunSummary.elapsed(context.date.timeIntervalSince(since)))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .opacity(0.7)
                    }
                    .transition(.opacity)
                }
                KeyHint("⌘R", onFill: true)
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.leading, 11)
            .padding(.trailing, 10)
            .frame(height: 30)
            .background(Theme.accentFill.brightness(hovering ? 0.06 : 0))
            .overlay(alignment: .bottom) {
                if running { RunSweep().transition(.opacity) }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.control, value: running)
        .accessibilityLabel(running ? "Show the output of \(name)" : "Run \(name)")
    }
}

private struct ListHalf: View {
    let count: Int
    let open: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("\(count)")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .opacity(0.75)
                Chevron()
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round,
                                                       lineJoin: .round))
                    .frame(width: 8, height: 4.5)
                    // Turned inside the label, never on the button: the button carries
                    // AppKit views that cannot be laid out under a rotation.
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .motion(Motion.control, value: open)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.accentFill.brightness(hovering ? 0.06 : 0))
            .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 9, topTrailingRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .accessibilityLabel("All commands")
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}

// Points up, towards where the list opens from a row this near the bottom of the window.
private struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
    }
}

// A ring turning while the command runs. With motion turned down it holds still, and the
// words beside it still say the command is running.
private struct RunSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RunSpinnerLayer(moving: !reduceMotion)
            .frame(width: 11, height: 11)
            .allowsHitTesting(false)
    }
}

private struct RunSpinnerLayer: NSViewRepresentable {
    let moving: Bool

    func makeNSView(context: Context) -> RunSpinnerView { RunSpinnerView() }

    func updateNSView(_ view: RunSpinnerView, context: Context) {
        view.update(moving: moving)
    }
}

final class RunSpinnerView: LoopLayerView {
    static let lap: CFTimeInterval = 0.8

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private(set) var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        track.fillColor = nil
        track.strokeColor = CGColor(gray: 1, alpha: 0.3)
        track.lineWidth = 1.8
        arc.fillColor = nil
        arc.strokeColor = .white
        arc.lineWidth = 1.8
        arc.lineCap = .round
        arc.strokeEnd = 0.28
        layer?.addSublayer(track)
        layer?.addSublayer(arc)
    }

    var loops: [String] { arc.animationKeys() ?? [] }

    func update(moving: Bool) {
        guard moving != self.moving else { return }
        self.moving = moving
        restartLoops()
    }

    override func layoutLayers() {
        let circle = CGPath(ellipseIn: bounds, transform: nil)
        track.frame = bounds
        track.path = circle
        arc.frame = bounds
        arc.path = circle
    }

    override func restartLoops() {
        arc.removeAnimation(forKey: "turn")
        guard moving else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = CGFloat.pi * 2
        turn.duration = Self.lap
        arc.add(LayerLoop.repeating(turn, period: Self.lap), forKey: "turn")
    }
}

// The brand yellow sweeping along the bottom edge of a running command. With motion
// turned down it is a still line instead.
private struct RunSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Rectangle().fill(Theme.brand)
            } else {
                RunSweepLayer()
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

private struct RunSweepLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> RunSweepView { RunSweepView() }

    func updateNSView(_ view: RunSweepView, context: Context) {
        view.update(colour: Theme.brand.resolve(in: context.environment).cgColor)
    }
}

final class RunSweepView: LoopLayerView {
    static let lap: CFTimeInterval = 1.1
    static let barShare: CGFloat = 0.35

    private let bar = CALayer()
    private var sweptWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        layer?.addSublayer(bar)
    }

    var loops: [String] { bar.animationKeys() ?? [] }

    func update(colour: CGColor) {
        LayerLoop.still { bar.backgroundColor = colour }
    }

    // The bar starts just off the left edge and the sweep carries it just past the right,
    // so how far it travels depends on the width, and a new width needs a new sweep.
    override func layoutLayers() {
        let width = bounds.width * Self.barShare
        bar.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
        guard bounds.width != sweptWidth else { return }
        sweptWidth = bounds.width
        restartLoops()
    }

    override func restartLoops() {
        bar.removeAnimation(forKey: "sweep")
        guard sweptWidth > 0 else { return }
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = 0
        sweep.toValue = sweptWidth * (1 + Self.barShare)
        sweep.duration = Self.lap
        // Quick out of the gate, then a long gentle finish.
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
        bar.add(LayerLoop.repeating(sweep, period: Self.lap), forKey: "sweep")
    }
}

// MARK: - A card

private struct CommandCard: View {
    enum Detail {
        case plain(String)
        case command(String)
        case outcome(CommandRunSummary)
    }

    let icon: String
    let name: String
    let detail: Detail
    let tint: Theme.ProjectTint?
    let dashed: Bool
    let highlighted: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dashed ? Color.secondary : Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(dashed ? Color.clear : Theme.sunken))
                    .overlay(alignment: .topTrailing) {
                        if let tint { ProjectDot(tint: tint, size: 6).padding(3) }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                    detailLine
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
            .background(fill)
            .overlay(RoundedRectangle(cornerRadius: 11)
                .strokeBorder(stroke,
                              style: StrokeStyle(lineWidth: highlighted ? 1.5 : 1,
                                                 dash: dashed && !highlighted ? [4, 3] : [])))
            // Only a hairline: the tray under the cards does the lifting.
            .shadow(color: .black.opacity(dashed ? 0 : 0.05), radius: 1, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .accessibilityLabel(name)
        .accessibilityValue(accessibilityDetail)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    // Every fill is solid. `field` is see-through, so it is only ever laid over a card,
    // never used on its own. A dashed row stays clear until touched, because the tray
    // under it is already opaque.
    private var fill: some View {
        let shape = RoundedRectangle(cornerRadius: 11)
        return ZStack {
            shape.fill(dashed && !hovering && !highlighted ? Color.clear : Theme.card)
            if hovering && !dashed {
                shape.fill(Theme.field.opacity(0.6))
            }
        }
    }

    private var stroke: Color {
        if highlighted { return Theme.accent }
        return dashed ? Self.dashedBorder : Theme.border
    }

    // Strong enough for the dashes to read on the tray's sidebar fill.
    private static let dashedBorder = Theme.adaptive(
        light: NSColor(srgbRed: 0.46, green: 0.42, blue: 0.34, alpha: 0.28),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))

    @ViewBuilder private var detailLine: some View {
        switch detail {
        case .plain(let text):
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        case .command(let text):
            Text(text)
                .font(.mono(10.5))
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
        case .outcome(let summary):
            // The state is in the glyph and the words as well as the colour, so it reads
            // the same to someone who cannot tell the colours apart.
            HStack(spacing: 4) {
                if let glyph = summary.glyph {
                    Image(systemName: glyph)
                        .font(.system(size: 8.5, weight: .bold))
                }
                RollingText(summary.text, font: .system(size: 11.5))
            }
            .foregroundStyle(colour(of: summary.outcome))
        }
    }

    private func colour(of outcome: CommandRunSummary.Outcome) -> Color {
        switch outcome {
        case .passed: Theme.addition
        case .failed: Theme.deletion
        case .running: Theme.dotOnText
        case .never, .stopped: .secondary
        }
    }

    private var accessibilityDetail: String {
        switch detail {
        case .plain(let text): text
        case .command(let text): text
        case .outcome(let summary): summary.text
        }
    }
}

// A key a shortcut is pressed with, drawn as a small cap.
private struct KeyHint: View {
    let keys: String
    var onFill = false

    init(_ keys: String, onFill: Bool = false) {
        self.keys = keys
        self.onFill = onFill
    }

    var body: some View {
        Text(keys)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(onFill ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(onFill ? Color.white.opacity(0.16) : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(onFill ? Color.clear : Theme.border))
            .accessibilityHidden(true)
    }
}

// MARK: - How a run went

// One command's last run, in the words its card shows: "Passed 12 min ago in 38s",
// "Failed just now in 4.2s", "Never run".
struct CommandRunSummary: Equatable {
    enum Outcome { case never, running, passed, failed, stopped }

    let state: ShortcutStore.State
    let duration: TimeInterval?
    let started: Bool
    var now = Date()

    var outcome: Outcome {
        switch state {
        case .running: .running
        case .finished: .passed
        case .failed: .failed
        case .stopped: started ? .stopped : .never
        }
    }

    var text: String {
        switch state {
        case .running: return "Running now"
        case .stopped: return started ? "Stopped" : "Never run"
        case .finished(let at): return sentence("Passed", at: at)
        case .failed(_, _, let at): return sentence("Failed", at: at)
        }
    }

    var glyph: String? {
        switch outcome {
        case .passed: "checkmark"
        case .failed: "xmark"
        case .running: "circle.fill"
        case .stopped: "stop.fill"
        case .never: nil
        }
    }

    private func sentence(_ verb: String, at: Date) -> String {
        let when = Self.ago(now.timeIntervalSince(at))
        guard let duration else { return "\(verb) \(when)" }
        return "\(verb) \(when) in \(Self.length(duration))"
    }

    // "just now", "12 min ago", "3 h ago", "2 d ago".
    static func ago(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }

    // "4.2s", "38s", "1m 12s", "1h 5m": tenths only while they still matter.
    static func length(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return "\(Int(seconds))s" }
        let whole = Int(seconds)
        if whole < 3_600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3_600)h \(whole % 3_600 / 60)m"
    }

    // The clock on a running button: "4.2s" for the first minute, then "1:12".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds)
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

// MARK: - Keys and clicks while the list is open

// Catches the keys the open list answers, and the click that lands anywhere else. A
// local monitor sees them before the prompt field does, which is what lets the arrows
// move through the list while the cursor is still in the prompt.
@MainActor
final class CommandListMonitor {
    enum Key { case up, down, choose, close }

    private var token: Any?

    func start(anchor: FrameAnchor, regions: [FrameAnchor],
               key: @escaping (Key) -> Void, outside: @escaping () -> Void) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let window = anchor.view?.window, event.window === window else { return false }
                if event.type == .leftMouseDown {
                    guard let content = window.contentView else { return false }
                    let point = FrameAnchor.fromTop(event.locationInWindow, in: content)
                    if !regions.contains(where: { $0.frame()?.contains(point) == true }) {
                        outside()
                    }
                    return false
                }
                guard WindowKeyMonitor.routes(to: window, frontmost: NSApp.keyWindow),
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                      let pressed = Self.key(for: event.keyCode) else { return false }
                key(pressed)
                return true
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    private static func key(for code: UInt16) -> Key? {
        switch code {
        case 126: .up
        case 125: .down
        case 36, 76: .choose
        case 53: .close
        default: nil
        }
    }
}

// MARK: - Output

// Where a chip's run went, docked under the content the way the terminal is. It is a
// captured log rather than a shell: the point of a shortcut is that it reports how it
// ended, which a live terminal cannot be asked.
struct ShortcutOutputDrawer: View {
    @Environment(ShortcutStore.self) private var shortcuts

    let run: ShortcutRun
    let onClose: () -> Void

    private static let bottom = "shortcut-drawer-bottom"

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            strip
            Divider().overlay(Theme.hairline)
            ScrollViewReader { scroller in
                ScrollView {
                    Text(text)
                        .font(.mono(11))
                        .foregroundStyle(log.isEmpty ? AnyShapeStyle(.secondary)
                                                     : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .onChange(of: log) { _, _ in
                    scroller.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            .frame(height: 240)
        }
        .background(Theme.card)
        .interruptOnControlC(isEnabled: shortcuts.state(run).isActive) {
            shortcuts.stop(run)
        }
    }

    private var strip: some View {
        HStack(spacing: 8) {
            Text("OUTPUT")
                .font(.mono(10.5, .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            if let name = shortcuts.shortcut(run.shortcutID)?.name {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            Text(status)
                .font(.mono(10.5))
                .foregroundStyle(statusColour)
                .lineLimit(1)

            Spacer(minLength: 12)

            // Kept in the row whether or not anything is running, so the way to stop a
            // command is always in the same place. The chip that opens this panel no
            // longer stops anything, and a control that comes and goes is one the reader
            // has to find again every time they need it.
            let running = shortcuts.state(run).isActive
            stripButton("Stop", tint: Theme.deletion, enabled: running) {
                shortcuts.stop(run)
            }
            .appTooltip(running ? "Stop this command (^C)" : "Nothing is running")

            if !log.isEmpty {
                stripButton("Clear", tint: Theme.accent) { shortcuts.clearLog(run) }
            }

            // Named for what it does, since the row beside it stops the command and the
            // two must not read as the same thing: this only puts the panel away, and
            // whatever is running carries on.
            stripButton("Close output", tint: Theme.deletion, action: onClose)
                .appTooltip("Hide this panel. Anything running keeps running.")
                .accessibilityLabel("Hide the output")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.card)
    }

    private func stripButton(_ title: String, tint: Color, enabled: Bool = true,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .hoverLift()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private var log: String { shortcuts.log(run) }

    private var text: String {
        if !log.isEmpty { return log }
        switch shortcuts.state(run) {
        case .stopped: return "Run this shortcut to see its output."
        case .running: return "Waiting for output…"
        case .finished: return "Finished without output."
        case .failed(let message, _, _): return message
        }
    }

    private var status: String {
        switch shortcuts.state(run) {
        case .stopped: "not running"
        case .running(let since): "running · \(RelativeTime.duration(since: since))"
        case .finished: "exit 0"
        case .failed(_, let code, _): code.map { "exit \($0)" } ?? "failed"
        }
    }

    private var statusColour: Color {
        switch shortcuts.state(run) {
        case .failed: Theme.deletion
        case .finished: Theme.addition
        default: .secondary
        }
    }
}

// The stroke that ends a running command, wherever the reader's hands happen to be.
// The pane prints a command the way a shell does, so ^C is what anyone watching it
// reaches for, and there is no text field in it to type that into. A monitor is what
// catches it: the drawer never holds the keyboard, since the composer beside it does.
private struct InterruptCatcher: ViewModifier {
    let isEnabled: Bool
    let interrupt: () -> Void

    @State private var monitor = WindowKeyMonitor(.control, "c")

    func body(content: Content) -> some View {
        content
            .background(WindowAnchor(monitor: monitor))
            .onChange(of: isEnabled, initial: true) { _, enabled in
                guard enabled else { return monitor.stop() }
                monitor.start {
                    interrupt()
                    return true
                }
            }
            .onDisappear { monitor.stop() }
    }
}

extension View {
    func interruptOnControlC(isEnabled: Bool,
                             interrupt: @escaping () -> Void) -> some View {
        modifier(InterruptCatcher(isEnabled: isEnabled, interrupt: interrupt))
    }
}

// MARK: - Promoting what the agent ran

enum SessionShortcuts {
    // The last shell command the agent ran in this session, for the menu entry that
    // turns it into a saved shortcut. Only single-line commands are offered: a saved
    // command names one thing, and a heredoc pasted into one is not that.
    static func lastAgentCommand(in session: ChatSession) -> String? {
        for message in session.messages.reversed() where message.role == .assistant {
            for tool in message.tools.reversed() where tool.name == "Bash" {
                guard let command = ToolPresentation.shellCommand(in: tool.input)?.trimmed,
                      !command.isEmpty, !command.contains("\n") else { continue }
                return command
            }
        }
        return nil
    }
}
