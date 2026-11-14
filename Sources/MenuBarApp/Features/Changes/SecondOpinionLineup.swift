import SwiftUI

// The Lineup: a second opinion drawn as the reviewers themselves. The same tiles stand
// for the action in the session header, under an answer and on a plan. In
// the header the one button also carries the whole run, from reading to findings to all
// sorted, so progress shows on the control that started it.

enum SecondOpinionLineup {
    // What a tile says about its reviewer. Every mark sits beside words that say the same.
    enum Mark: Equatable {
        case working, done, failed, findings
    }

    // Who would read it: every installed agent but the one that wrote the work.
    static func reviewers(installed: [AgentKind], author: AgentKind) -> [AgentKind] {
        installed.filter { $0 != author }
    }

    // The agents worth installing to have someone to ask, for when nobody is.
    static func installHint(author: AgentKind) -> String {
        "Install \(AgentKind.allCases.filter { $0 != author }.map(\.title).joined(separator: " or ")) to ask for a second opinion"
    }

    // The tiles for where things stand. Once asked, the lineup is whoever was asked.
    static func agents(lineup: [AgentKind], runs: [SecondOpinionRun], status: SecondOpinionStatus) -> [AgentKind] {
        if case .ready(let agents, _) = status, !agents.isEmpty { return agents }
        guard status != .ask else { return lineup }
        var seen = Set<AgentKind>()
        let asked = runs.map(\.agent).filter { seen.insert($0).inserted }
        return asked.isEmpty ? lineup : asked
    }

    static func marks(runs: [SecondOpinionRun], status: SecondOpinionStatus) -> [AgentKind: Mark] {
        switch status {
        case .ask, .settled:
            return [:]
        case .ready(let agents, _):
            return Dictionary(uniqueKeysWithValues: agents.map { ($0, .findings) })
        case .reviewing, .failed:
            // An agent on two seats wears whichever mark says the most: still working
            // outranks stopped, which outranks done.
            var marks: [AgentKind: Mark] = [:]
            for run in runs {
                let mark: Mark = switch run.state {
                case .running: .working
                case .failed: .failed
                case .finished: .done
                }
                switch (marks[run.agent], mark) {
                case (.working?, _), (.failed?, .done): continue
                default: marks[run.agent] = mark
                }
            }
            return marks
        }
    }

    // The chip's words while the run is going.
    static func readingWords(runs: [SecondOpinionRun]) -> String {
        let running = runs.filter(\.isRunning)
        if running.count == 1, running.count < runs.count {
            return "\(running[0].agent.title) is still reading"
        }
        if running.count == 1 { return running[0].activity }
        return "\(names(unique(running.map(\.agent)))) are reading"
    }

    // How far the run has got, by reviewers done out of reviewers asked.
    static func progress(runs: [SecondOpinionRun]) -> Double? {
        guard runs.count > 1 else { return nil }
        return Double(runs.count { !$0.isRunning }) / Double(runs.count)
    }

    static func settledWords(kept: Int, dismissed: Int) -> String {
        kept + dismissed == 0 ? "Nothing to raise" : "\(kept) kept, \(dismissed) dismissed"
    }

    static func names(_ agents: [AgentKind]) -> String {
        let titles = agents.map(\.title)
        guard titles.count > 1 else { return titles.first ?? "" }
        return titles.dropLast().joined(separator: ", ") + " and " + titles.last!
    }

    private static func unique(_ agents: [AgentKind]) -> [AgentKind] {
        var seen = Set<AgentKind>()
        return agents.filter { seen.insert($0).inserted }
    }
}

extension EnvironmentValues {
    // Who an answer's second opinion would go to, so the tiles under a message can show
    // them without each message working it out.
    @Entry var secondOpinionLineup: [AgentKind] = []
}

// MARK: - The tiles

// The reviewers as overlapping tiles. Every move happens to the tiles, never to a
// button around them: AppKit cannot lay out a button with a tooltip under a rotation
// or a scale. Nothing moves at rest, and under Reduce Motion nothing moves at all.
struct LineupTiles: View {
    let agents: [AgentKind]
    var size: CGFloat = 15
    // Pointed at: the tiles fan apart and the overlap opens.
    var fanned = false
    // All sorted: the tiles close into one stack.
    var gathered = false
    var marks: [AgentKind: SecondOpinionLineup.Mark] = [:]
    // Each counts up to play its move once.
    var deals = 0
    var squashes = 0
    var shakes = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var nodding: Bool { !reduceMotion && marks.values.contains(.working) }

    var body: some View {
        HStack(spacing: spacing) {
            if agents.isEmpty {
                emptyTile
            } else {
                ForEach(Array(shown.enumerated()), id: \.element) { index, tile in
                    self.tile(tile, at: index)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private enum Tile: Hashable {
        case agent(AgentKind)
        case more(Int)
    }

    // Never wider than three tiles: two reviewers and a count for the rest.
    private var shown: [Tile] {
        guard agents.count > 2 else { return agents.map(Tile.agent) }
        return agents.prefix(2).map(Tile.agent) + [.more(agents.count - 2)]
    }

    private var spacing: CGFloat {
        gathered && !reduceMotion ? -size * 0.8 : -size * 0.36
    }

    // The fan spreads the tiles out from the middle by an offset rather than by spacing,
    // so the control keeps its width and the rail beside it stays still under the pointer.
    private func fanOffset(at index: Int) -> CGFloat {
        guard fanned, !gathered, !reduceMotion else { return 0 }
        return (CGFloat(index) - CGFloat(shown.count - 1) / 2) * size * 0.26
    }

    private func tile(_ tile: Tile, at index: Int) -> some View {
        let isFront = index == shown.count - 1
        let mark: SecondOpinionLineup.Mark? = switch tile {
        case .agent(let agent): gathered ? (isFront ? .done : nil) : marks[agent]
        case .more: nil
        }
        // Each reader dips in turn, half a beat apart. The fan's turn sits inside the nod,
        // since the nod moves an AppKit copy of the tile that cannot itself be turned.
        return Nodding(active: mark == .working && nodding, delay: Double(index) * 0.8,
                       depth: size * 0.14) {
            tileFace(tile, at: index, isFront: isFront, mark: mark)
        }
        .offset(x: fanOffset(at: index))
        .zIndex(Double(index))
    }

    private func tileFace(_ tile: Tile, at index: Int, isFront: Bool,
                          mark: SecondOpinionLineup.Mark?) -> some View {
        Group {
            switch tile {
            case .agent(let agent):
                ReviewAvatar(agent: agent, size: size, hasFindings: mark == .findings, move: deals)
            case .more(let count):
                Text("+\(count)")
                    .font(.system(size: size * 0.48, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: size * 0.3).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.3).stroke(Theme.border))
            }
        }
        .modifier(TileMoves(size: size, index: index, deals: deals, squashes: squashes,
                            shakes: mark == .failed ? shakes : 0, reduceMotion: reduceMotion))
        .rotationEffect(.degrees(fanned && !reduceMotion && shown.count > 1 ? (index == 0 ? -10 : isFront ? 9 : 0) : 0))
        // A badge on the front tile sits bottom right; on the others bottom left, so the
        // tile in front never hides it.
        .overlay(alignment: isFront ? .bottomTrailing : .bottomLeading) {
            if let mark { badge(mark).offset(x: isFront ? size * 0.22 : -size * 0.22, y: size * 0.22) }
        }
    }

    @ViewBuilder
    private func badge(_ mark: SecondOpinionLineup.Mark) -> some View {
        let side = max(8, size * 0.56)
        switch mark {
        case .done:
            Image(systemName: "checkmark").font(.system(size: side * 0.5, weight: .heavy))
                .foregroundStyle(Theme.onFill)
                .frame(width: side, height: side)
                .background(Circle().fill(Theme.dotOn))
                .overlay(Circle().stroke(Theme.card, lineWidth: 1.5))
        case .failed:
            Image(systemName: "exclamationmark").font(.system(size: side * 0.55, weight: .heavy))
                .foregroundStyle(Theme.onFill)
                .frame(width: side, height: side)
                .background(Circle().fill(Theme.warningText))
                .overlay(Circle().stroke(Theme.card, lineWidth: 1.5))
        case .working, .findings:
            EmptyView()
        }
    }

    private var emptyTile: some View {
        Image(systemName: "plus").font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size * 0.3)
                .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])))
    }
}

// The one-off moves a tile makes: standing up and dropping back when asked, a squash
// when findings land, a shake when its reviewer stops.
private struct TileMoves: ViewModifier {
    let size: CGFloat
    let index: Int
    let deals: Int
    let squashes: Int
    let shakes: Int
    let reduceMotion: Bool

    struct Lift {
        var y: CGFloat = 0
    }

    struct Squash {
        var y: CGFloat = 0
        var squash: CGFloat = 1
    }

    struct Shake {
        var x: CGFloat = 0
    }

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .keyframeAnimator(initialValue: Lift(), trigger: deals) { view, lift in
                    view.offset(y: lift.y)
                } keyframes: { _ in
                    KeyframeTrack(\.y) {
                        // Dealt out one after another, 90ms apart.
                        LinearKeyframe(0, duration: max(0.001, Double(index) * 0.09))
                        CubicKeyframe(-size * 0.4, duration: 0.18)
                        SpringKeyframe(0, duration: 0.32, spring: .bouncy)
                    }
                }
                .keyframeAnimator(initialValue: Squash(), trigger: squashes) { view, frame in
                    view.offset(y: frame.y)
                        .scaleEffect(x: 1 + (1 - frame.squash) * 0.6, y: frame.squash, anchor: .bottom)
                } keyframes: { _ in
                    KeyframeTrack(\.y) {
                        CubicKeyframe(-size * 0.25, duration: 0.16)
                        CubicKeyframe(0, duration: 0.14)
                        LinearKeyframe(0, duration: 0.26)
                    }
                    KeyframeTrack(\.squash) {
                        LinearKeyframe(1, duration: 0.28)
                        CubicKeyframe(0.82, duration: 0.1)
                        SpringKeyframe(1, duration: 0.18)
                    }
                }
                .keyframeAnimator(initialValue: Shake(), trigger: shakes) { view, frame in
                    view.offset(x: frame.x)
                } keyframes: { _ in
                    KeyframeTrack(\.x) {
                        CubicKeyframe(-size * 0.2, duration: 0.08)
                        CubicKeyframe(size * 0.2, duration: 0.1)
                        CubicKeyframe(-size * 0.14, duration: 0.1)
                        CubicKeyframe(size * 0.1, duration: 0.1)
                        CubicKeyframe(0, duration: 0.12)
                    }
                }
        }
    }
}

// Each reviewer's own move, drawn from its symbol: Copilot's plane flies out of the top
// of its tile and back in from the bottom, Codex's sparkles swell and turn, and Claude
// Code's head pulses twice, like a thought landing.
struct SymbolMove: ViewModifier {
    let agent: AgentKind?
    let size: CGFloat
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Frame {
        var y: CGFloat = 0
        var scale: CGFloat = 1
        var angle: Double = 0
    }

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            let flies = agent == .copilot
            let swells = agent == .codex
            let pulses = agent == .claudeCode
            content.keyframeAnimator(initialValue: Frame(), trigger: trigger) { view, frame in
                view.offset(y: frame.y).scaleEffect(frame.scale).rotationEffect(.degrees(frame.angle))
            } keyframes: { _ in
                KeyframeTrack(\.y) {
                    CubicKeyframe(flies ? -size : 0, duration: 0.28)
                    MoveKeyframe(flies ? size : 0)
                    SpringKeyframe(0, duration: 0.52, spring: .smooth)
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(swells ? 1.35 : pulses ? 1.18 : 1, duration: 0.2)
                    CubicKeyframe(swells ? 1.25 : 1, duration: 0.2)
                    CubicKeyframe(swells ? 1.1 : pulses ? 1.18 : 1, duration: 0.2)
                    SpringKeyframe(1, duration: 0.2, spring: .bouncy)
                }
                KeyframeTrack(\.angle) {
                    CubicKeyframe(swells ? 35 : 0, duration: 0.45)
                    SpringKeyframe(0, duration: 0.35, spring: .bouncy)
                }
            }
        }
    }
}

// MARK: - The header control

// The session header's way into a second opinion, and once asked, the run's status.
// It sits first in the dock, at a seat's height, so when it grows into a chip only what
// lies before the dock moves. At rest it is the lineup and nothing else. Pointed at, the tiles fan and the button
// names them. Once a run starts, it grows into a chip whose words carry the state, so
// it reads the same without its colours.
struct SecondOpinionLineupButton: View {
    let author: AgentKind
    let installed: [AgentKind]
    // Whether there is an answer, a change or a design to look at yet.
    var canReview = true
    let runs: [SecondOpinionRun]
    let status: SecondOpinionStatus
    let ask: () -> Void
    let open: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var deals = 0
    @State private var squashes = 0
    @State private var shakes = 0
    // A finished round's tally shows for a moment, then the control goes back to rest.
    @State private var showsTally = false

    private enum Phase: Equatable {
        case rest, reviewing, failed, ready, settled
    }

    private var phase: Phase {
        switch status {
        case .ask: .rest
        case .reviewing: .reviewing
        case .failed: .failed
        case .ready: .ready
        case .settled: .settled
        }
    }

    private var shown: Phase { phase == .settled && !showsTally ? .rest : phase }
    private var lineup: [AgentKind] { SecondOpinionLineup.reviewers(installed: installed, author: author) }
    private var canAsk: Bool { !lineup.isEmpty && canReview }

    private var restWords: String {
        if lineup.isEmpty { return SecondOpinionLineup.installHint(author: author) }
        if !canReview { return "Nothing to review yet" }
        return "\(SecondOpinionLineup.names(lineup)) check an answer, the changes or the design"
    }

    private var change: Animation {
        reduceMotion ? Motion.reveal : HeaderMotion.grow
    }

    var body: some View {
        Button {
            if shown == .rest { ask() } else { open() }
        } label: {
            label
        }
        .buttonStyle(.plain)
        .disabled(shown == .rest && !canAsk)
        .onPointerHover { hovering = $0 }
        .appTooltip {
            Tooltip(title: "Ask for a second opinion",
                    subtitle: restWords)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Ask for a second opinion")
        .accessibilityValue(accessibilityWords)
        .onChange(of: phase) { old, new in
            switch new {
            case .reviewing where old != .reviewing: deals += 1
            case .ready: squashes += 1
            case .failed: shakes += 1
            case .settled: showsTally = true
            default: break
            }
        }
        .task(id: showsTally) {
            guard showsTally else { return }
            try? await Task.sleep(for: .seconds(2.5))
            showsTally = false
        }
    }

    private var label: some View {
        HStack(spacing: Space.sm) {
            LineupTiles(agents: SecondOpinionLineup.agents(lineup: lineup, runs: runs, status: status),
                        fanned: hovering && shown == .rest && canAsk,
                        gathered: shown == .settled,
                        marks: shown == .rest ? [:] : SecondOpinionLineup.marks(runs: runs, status: status),
                        deals: deals, squashes: squashes, shakes: shakes)
                .padding(.horizontal, Space.xxs)
            words
        }
        .font(Typography.label)
        .foregroundStyle(ink)
        .lineLimit(1).fixedSize()
        .padding(.horizontal, Space.sm).frame(height: ControlHeight.md)
        .background { chipBackground }
        .overlay(alignment: .bottom) { progressBar }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        .opacity(shown == .rest && !canAsk ? 0.5 : 1)
        .motion(HeaderMotion.grow, value: shown)
        .motion(Motion.hover, value: hovering)
    }

    @ViewBuilder
    private var words: some View {
        switch status {
        case .ask,
             _ where shown == .rest:
            EmptyView()
        case .reviewing(_, let started, let pending):
            HStack(spacing: Space.sm) {
                Text(SecondOpinionLineup.readingWords(runs: runs))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(clock(from: started, to: context.date)).font(Typography.data).foregroundStyle(.tertiary)
                }
                if pending > 0 {
                    Text("\(counted(pending, "finding")) so far").fontWeight(.medium).foregroundStyle(.secondary)
                }
            }
            .transition(wordsTransition)
        case .failed(let agent):
            Text("\(agent.title) could not finish").transition(wordsTransition)
        case .ready(_, let pending):
            HStack(spacing: Space.sm) {
                Text("\(pending)").font(Typography.caption.weight(.semibold)).foregroundStyle(Theme.onFill)
                    .padding(.horizontal, Space.xs).frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Theme.attention))
                    .transition(.opacity.animation(reduceMotion ? change : HeaderMotion.grow.delay(0.12)))
                Text(pending == 1 ? "finding to look at" : "findings to look at")
            }
            .transition(wordsTransition)
        case .settled(let kept, let dismissed):
            Text(SecondOpinionLineup.settledWords(kept: kept, dismissed: dismissed)).transition(wordsTransition)
        }
    }

    private var wordsTransition: AnyTransition {
        reduceMotion ? .opacity.animation(change)
            : .asymmetric(insertion: .opacity.combined(with: .scale(scale: HeaderMotion.seed, anchor: .leading))
                              .animation(HeaderMotion.grow),
                          removal: .opacity.animation(HeaderMotion.shrink))
    }

    @ViewBuilder
    private var chipBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card)
        switch shown {
        case .rest:
            if hovering && canAsk { shape.fill(Theme.field) }
        case .reviewing, .settled:
            shape.fill(hovering ? Theme.field : Theme.card).overlay(shape.strokeBorder(Theme.border))
        case .failed:
            shape.fill(Theme.warningBackground).overlay(shape.strokeBorder(Theme.warningText.opacity(0.3)))
        case .ready:
            shape.fill(Theme.attention.opacity(hovering ? 0.16 : 0.10)).overlay(shape.strokeBorder(Theme.attention.opacity(0.5)))
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if shown == .reviewing, let progress = SecondOpinionLineup.progress(runs: runs) {
            GeometryReader { proxy in
                Capsule().fill(Theme.dotOn)
                    .frame(width: max(4, proxy.size.width * progress), height: 2)
                    .animation(change, value: progress)
            }
            .frame(height: 2)
            .padding(.horizontal, Space.sm).padding(.bottom, 1)
        }
    }

    private var ink: Color {
        switch shown {
        case .failed: Theme.warningText
        case .ready: Theme.attentionText
        default: .primary
        }
    }

    private var accessibilityWords: String {
        switch status {
        case .ask,
             _ where shown == .rest:
            restWords
        case .reviewing(_, _, let pending):
            SecondOpinionLineup.readingWords(runs: runs) + (pending > 0 ? ", \(counted(pending, "finding")) so far" : "")
        case .failed(let agent):
            "\(agent.title) could not finish"
        case .ready(_, let pending):
            "\(counted(pending, "finding")) to look at"
        case .settled(let kept, let dismissed):
            SecondOpinionLineup.settledWords(kept: kept, dismissed: dismissed)
        }
    }
}

// MARK: - Under an answer

// The tiles beside an answer's copy button: click them to ask the lineup about it.
struct AnswerLineupButton: View {
    let action: () -> Void

    @Environment(\.secondOpinionLineup) private var lineup
    @State private var hovering = false
    @State private var deals = 0

    var body: some View {
        Button {
            deals += 1
            action()
        } label: {
            LineupTiles(agents: lineup, size: 18, fanned: hovering, deals: deals)
                .padding(.horizontal, Space.sm)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .appTooltip {
            Tooltip(title: "Get a second opinion",
                    subtitle: lineup.isEmpty ? "Other agents review this answer"
                        : "\(SecondOpinionLineup.names(lineup)) review this answer")
        }
        .accessibilityLabel("Get a second opinion on this answer")
    }
}
