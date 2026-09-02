import SwiftUI

// Sequential tool calls share one block, and every call in it is a card: a band naming
// its state and its tool, with the argument and what came back, and a body that opens on
// the work itself. A running command opens on a terminal showing the command and a clock;
// an edit opens on the diff it made; a call that started an agent opens on everything
// that agent did. A finished card folds down to its band, so a run of calls reads as a
// stack of receipts.
//
// The block itself folds down to a single summary line, so a finished turn reads as what
// Claude said rather than as a page of the work behind it.
struct ActivitySpine: View {
    let nodes: [ToolNode]
    let projectPath: String
    var openChanges: (() -> Void)? = nil
    // The latest block stays open while there is nothing after it, including after its
    // calls finish. New conversation activity moves this marker and folds the old block.
    var isCurrent = false
    // A nested spine already sits inside the card of the agent that made its calls, so it
    // draws in full and a size down.
    var isFoldable = true

    @Environment(\.runningAgents) private var runningAgents

    @State private var expanded: Set<String> = []
    // Nil until the reader clicks: until then the block follows the work, open while the
    // turn is on it and folded once the turn has moved on.
    @State private var showsCalls: Bool?

    // Having opened a card is asking for the block, so the fold that comes with the end of
    // the turn does not take back what the reader unfolded while the calls ran.
    private var showsRows: Bool {
        Self.rowsAreVisible(isFoldable: isFoldable,
                            userChoice: showsCalls,
                            isCurrent: isCurrent,
                            hasExpandedRows: !expanded.isEmpty)
    }

    private var hasRunningCalls: Bool {
        isCurrent && nodes.contains { $0.isWorking(agents: runningAgents) }
    }

    nonisolated static func rowsAreVisible(isFoldable: Bool, userChoice: Bool?,
                                            isCurrent: Bool,
                                            hasExpandedRows: Bool) -> Bool {
        !isFoldable || (userChoice ?? (isCurrent || hasExpandedRows))
    }

    var body: some View {
        Group {
            if isFoldable {
                foldableBlock
            } else {
                cards
            }
        }
        .smoothlyResizes(when: expanded)
        .smoothlyResizes(when: showsRows)
    }

    // Folded, the block is a sunken line saying what ran. Open, the cards carry their own
    // surfaces, so the fill goes and they sit on the page like the rest of the turn.
    private var foldableBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsRows { cards.transition(.fold) }
        }
        .padding(.horizontal, showsRows ? 2 : 13)
        .padding(.vertical, showsRows ? 0 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(showsRows ? .clear : Theme.sunken))
    }

    private var header: some View {
        DisclosureHeader(isExpanded: Binding(get: { showsRows }, set: { showsCalls = $0 }),
                         show: "Show tool calls", hide: "Hide tool calls") {
            Text(summary)
                .scaledMono(11)
                .lineLimit(1)
                .truncationMode(.tail)
            if nodes.contains(where: \.hasError) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.deletion)
            }
            Spacer(minLength: 8)
            if hasRunningCalls && !showsRows {
                RunningWord()
            }
        }
        .foregroundStyle(.secondary)
        .padding(.bottom, showsRows ? 8 : 0)
    }

    // Enough of what ran to say whether the block is worth opening, without opening it.
    private var summary: String {
        let calls = nodes.reduce(nodes.count) { $0 + $1.callCount }
        let agents = nodes.reduce(0) { $0 + ($1.tool.startsAgents ? 1 : 0) + $1.agentCount }
        var verbs: [String] = []
        for node in nodes where !verbs.contains(node.tool.name) { verbs.append(node.tool.name) }
        let named = verbs.prefix(3).joined(separator: ", ")
        return workDone(calls: calls, agents: agents) + " · " + named
            + (verbs.count > 3 ? "…" : "")
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(nodes, id: \.id) { node in
                SpineCard(
                    node: node,
                    presentation: ToolPresentationCache.presentation(
                        for: node.tool, projectPath: projectPath),
                    projectPath: projectPath,
                    isExpanded: expanded.contains(node.id),
                    small: !isFoldable,
                    onToggle: {
                        if expanded.contains(node.id) {
                            expanded.remove(node.id)
                        } else {
                            expanded.insert(node.id)
                        }
                    },
                    openChanges: openChanges)
                    .transition(.fadeIn)
            }
        }
    }
}

// How much ran, said the same way wherever it is said: on a folded block, and on the band
// of a call that handed its work on. Agents are counted apart from calls, since a
// fan-out's size is the team it put to work.
private func workDone(calls: Int, agents: Int) -> String {
    let work = counted(calls, "call")
    guard agents > 0 else { return work }
    return counted(agents, "agent") + " · " + work
}

// The same open card the transcript draws, without its band: the Working Set puts it in a
// card of its own when a compact row is clicked, and that card names the call itself.
struct ToolCallExpandedDetail: View {
    let tool: ToolUse
    let projectPath: String
    let isRunning: Bool

    var body: some View {
        SpineCard(
            node: ToolNode(tool: tool),
            presentation: ToolPresentationCache.presentation(
                for: tool, projectPath: projectPath),
            projectPath: projectPath,
            isExpanded: true,
            onToggle: nil,
            openChanges: nil,
            working: isRunning,
            bodyOnly: true)
    }
}

// What a card's band says about its call. The word carries the state on its own, so a
// reader who cannot tell the dots apart is told the same thing.
enum SpineCardState: Equatable {
    case running, done, failed

    init(isWorking: Bool, isError: Bool) {
        self = isWorking ? .running : isError ? .failed : .done
    }

    var word: String {
        switch self {
        case .running: "RUNNING"
        case .done: "DONE"
        case .failed: "FAILED"
        }
    }

    var dot: Color {
        switch self {
        case .running, .done: Theme.dotOn
        case .failed: Theme.deletion
        }
    }
}

private struct SpineCard: View {
    @Environment(\.textScale) private var textScale
    @Environment(\.runningAgents) private var runningAgents

    let node: ToolNode
    let presentation: ToolPresentation
    let projectPath: String
    let isExpanded: Bool
    // The cards inside an agent's body are drawn a size down, so the agent's own band
    // still reads as the heading over them.
    var small = false
    let onToggle: (() -> Void)?
    let openChanges: (() -> Void)?
    var working: Bool? = nil
    // Just the body, for a host that has a band of its own.
    var bodyOnly = false

    private static let cornerRadius: CGFloat = 10

    private var tool: ToolUse { node.tool }

    // Whether there is still work behind this card. An agent sent to the background
    // answers its own call the moment it starts, so a card that stands for one cannot go
    // by its call having reported in.
    private var isWorking: Bool { working ?? node.isWorking(agents: runningAgents) }

    private var state: SpineCardState { SpineCardState(isWorking: isWorking, isError: tool.isError) }

    // A running card is open on its work whether or not it was asked for: the work is
    // what the turn is doing right now. Once it is done it folds unless the reader opened it.
    private var showsBody: Bool { bodyOnly || isWorking || isExpanded }

    private var isCommand: Bool { tool.name == "Bash" }

    // The terminal shows the command in full, so the band above it gives up its copy.
    private var bandShowsArgument: Bool { !(isCommand && showsBody) }

    private var hasDiff: Bool {
        !presentation.changes.isEmpty && !tool.isError && node.children.isEmpty
    }

    var body: some View {
        if bodyOnly {
            cardBody
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let onToggle {
                    Button(action: onToggle) { band }
                        .buttonStyle(.plain)
                } else {
                    band
                }
                if showsBody {
                    Divider().overlay(Theme.hairline)
                    cardBody.transition(.fold)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(Theme.card, cornerRadius: Self.cornerRadius,
                     border: state == .running ? Theme.dotOn.opacity(0.35) : Theme.border)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            // A call reporting in folds the body away, drops the band's tint and stills
            // the dot all at once. Animating that keeps a finished command from snapping
            // shut under the eye that was reading it.
            .smoothlyResizes(when: showsBody)
            .smoothlyResizes(when: state)
        }
    }

    // MARK: - Band

    // The band is tinted the way the NOW panel of the Working Set is while its call runs,
    // so the one card still moving is picked out of the stack.
    private var band: some View {
        HStack(spacing: 10) {
            dot
            Text("\(state.word) · \(tool.name.uppercased())")
                .kerning(1)
                .scaledMono(small ? 9.5 : 10.5, .bold)
                .foregroundStyle(state == .running
                                 ? AnyShapeStyle(Theme.addition)
                                 : AnyShapeStyle(.primary))
                .lineLimit(1)
                .fixedSize()
            if bandShowsArgument {
                Text(presentation.argument)
                    .scaledMono(11.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            meta
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: (small ? 32 : 38) * textScale)
        .background(state == .running ? Theme.dotOn.opacity(0.07) : Theme.statusBand)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var dot: some View {
        if state == .running {
            PulsingDot(size: 8)
        } else {
            Circle()
                .fill(state.dot)
                .frame(width: 8, height: 8)
        }
    }

    private var accessibilityLabel: String {
        var parts = [state.word.lowercased(), tool.name]
        if !presentation.argument.isEmpty { parts.append(presentation.argument) }
        if let note = noteText { parts.append(note) }
        if let clock = clockText { parts.append(clock) }
        return parts.joined(separator: ", ")
    }

    // What came back and how long it took, at the right of the band.
    private var meta: some View {
        HStack(spacing: 6) {
            if let added = presentation.added, let removed = presentation.removed,
               node.children.isEmpty, !tool.isError {
                // A command can change a whole set of files at once, and how many is as
                // much of the story as how many lines moved.
                if presentation.changedFiles > 1 {
                    Text("\(presentation.changedFiles) files")
                        .scaledMono(10.5)
                        .foregroundStyle(.tertiary)
                }
                DiffPair(added: added, removed: removed, size: 10.5 * textScale)
            } else if let note = noteText {
                Text(note)
                    .scaledMono(10.5)
                    .foregroundStyle(.tertiary)
            }
            if hasClock {
                Text("·")
                    .scaledMono(10.5)
                    .foregroundStyle(.tertiary)
                clock
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var noteText: String? {
        if !node.children.isEmpty {
            return workDone(calls: node.callCount, agents: node.agentCount)
        }
        if isWorking || tool.isError { return nil }
        if let added = presentation.added, let removed = presentation.removed {
            let files = presentation.changedFiles > 1 ? "\(presentation.changedFiles) files, " : ""
            return "\(files)+\(added) −\(removed)"
        }
        if presentation.notesResultLineCount, let result = tool.result {
            // A command that printed nothing is worth saying out loud: without it the band
            // is indistinguishable from one whose output is simply folded away.
            return result.isEmpty ? "no output" : counted(lineCount(result), "line")
        }
        return nil
    }

    private var hasClock: Bool {
        isWorking ? tool.startedAt != nil : tool.duration != nil
    }

    // Ticking while the call runs, then the span it took once it has reported in. A
    // background agent's call reports in at once, so its clock runs on from the start.
    @ViewBuilder private var clock: some View {
        if isWorking, let startedAt = tool.startedAt {
            ElapsedTime(since: startedAt, size: 10.5, scaled: true)
        } else if let text = clockText {
            Text(text)
                .scaledMono(10.5)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    private var clockText: String? {
        if isWorking {
            return tool.startedAt.map { ElapsedTime.reading(Date().timeIntervalSince($0)) }
        }
        return tool.duration.map(ElapsedTime.duration)
    }

    // MARK: - Body

    @ViewBuilder private var cardBody: some View {
        if tool.startsAgents {
            agentWork
        } else if isCommand {
            terminal
            if hasDiff { diffs }
        } else if hasDiff, presentation.diffIsTheInput {
            // An edit's input is the change itself, so the diff is the whole of it.
            diffs
        } else if tool.isError, let result = tool.result, !result.isEmpty {
            plain(result, tinted: true)
        } else {
            if !tool.input.isEmpty { plain(tool.input, tinted: false) }
            if hasDiff { diffs }
            if let result = tool.result, !result.isEmpty {
                if !tool.input.isEmpty { Divider().overlay(Theme.hairline) }
                plain(result, tinted: false)
            }
        }
    }

    // The command as the shell saw it, then what it printed. The band's argument is the
    // same command squeezed onto one line; this is the real thing, so a multi-line script
    // keeps its lines.
    private var terminal: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("$")
                        .foregroundStyle(Theme.terminalDim)
                    Text(command)
                        .fontWeight(.semibold)
                        .textSelection(.enabled)
                }
                if isWorking {
                    // The CLI hands a command's output over whole once it ends, so while
                    // it runs there is nothing to print yet but the prompt waiting.
                    BlinkingCursor()
                } else if let result = tool.result {
                    if result.isEmpty {
                        Text("no output")
                            .foregroundStyle(Theme.terminalDim)
                    } else {
                        Text(result)
                            .foregroundStyle(tool.isError ? Theme.terminalFailure : Theme.terminalText)
                            .textSelection(.enabled)
                    }
                }
            }
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        // Output can be a whole build log, so cap it and let the body scroll. The cap
        // follows the text, so the body shows about the same number of lines at any size.
        .frame(maxHeight: 240 * textScale)
        .scaledMono(12)
        .foregroundStyle(Theme.terminalText)
        .background(Theme.terminal)
    }

    private var command: String {
        ToolPresentation.shellCommand(in: tool.input) ?? tool.input
    }

    // A command that changed several files gets a diff for each, in the order git listed
    // them. They sit in the body without frames of their own, one over the other.
    private var diffs: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presentation.changes) { change in
                if change.id != presentation.changes.first?.id {
                    Divider().overlay(Theme.hairline)
                }
                EditDiffCard(change: change, openChanges: openChanges, framed: false)
            }
        }
    }

    // Everything that ran inside the call, drawn as a spine of its own. The agent's own
    // words while it worked open it, and its report closes it: that report is the only
    // part of all this the conversation itself gets back.
    private var agentWork: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let status = tool.status, !status.isEmpty {
                Text(status)
                    .scaledText(11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            if !node.children.isEmpty {
                ActivitySpine(nodes: node.children, projectPath: projectPath,
                              openChanges: openChanges, isFoldable: false)
                    .padding(.horizontal, 10)
                    .padding(.top, tool.status?.isEmpty == false ? 0 : 10)
                    .padding(.bottom, 10)
            }
            if let result = tool.result, !result.isEmpty {
                plain(result, tinted: tool.isError)
            }
        }
    }

    private func plain(_ text: String, tinted: Bool) -> some View {
        ScrollView {
            Text(text)
                .scaledMono(11)
                .foregroundStyle(tinted ? AnyShapeStyle(Theme.warningText) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        // Tool output can be a whole file, so cap it and let the box scroll. The cap
        // follows the text, so the box shows about the same number of lines at any size.
        .frame(maxHeight: 220 * textScale)
        .background(tinted ? Theme.warningBackground : .clear)
    }

    private func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.components(separatedBy: "\n").count
    }
}

// The block cursor a shell leaves at the prompt while a command runs. Held steady under
// Reduce Motion, like the dot on the band above it.
private struct BlinkingCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.textScale) private var textScale
    @State private var hidden = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.terminalText)
            .frame(width: 7 * textScale, height: 13 * textScale)
            .opacity(hidden ? 0 : 0.8)
            .animation(reduceMotion
                       ? nil
                       : .linear(duration: 0.55).repeatForever(autoreverses: true),
                       value: hidden)
            .onAppear { hidden = !reduceMotion }
            .accessibilityHidden(true)
    }
}

// One file's worth of what a call changed, shown as a small inline diff. This is a
// preview: the full working tree diff lives behind "Open in Changes". Framed, it is a
// card of its own; unframed, it fills the body of the card it belongs to.
private struct EditDiffCard: View {
    @Environment(\.textScale) private var textScale

    let change: ToolPresentation.FileChange
    let openChanges: (() -> Void)?
    var framed = true

    private static let visibleLines = 120

    var body: some View {
        if framed {
            content
                .cardSurface(cornerRadius: 10)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            lines
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(change.name)
                .scaledMono(12, .semibold)
                .lineLimit(1)
                .truncationMode(.middle)
            DiffPair(added: change.added, removed: change.removed,
                     size: 11 * textScale, weight: .medium)
            Spacer(minLength: 8)
            if let openChanges {
                InlineLink(title: "Open in Changes", size: 11, action: openChanges)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // The gutter is sized for the highest line the diff reaches, so the numbers stay in
    // a column and the code starts in the same place on every row.
    private var gutterWidth: CGFloat {
        let highest = change.lines.compactMap(\.number).max() ?? 0
        guard highest > 0 else { return 0 }
        return CGFloat(max(2, String(highest).count)) * 7 * textScale
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(change.lines.prefix(Self.visibleLines)) { line in
                row(line)
            }
            if change.lines.count > Self.visibleLines {
                Text("… \(change.lines.count - Self.visibleLines) more lines")
                    .scaledText(11)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func row(_ line: ToolPresentation.Line) -> some View {
        if line.kind == .gap {
            // The lines a diff skipped between two hunks. Nothing to say about them but
            // that they are there.
            Text("⋯")
                .scaledMono(11)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 6) {
                if gutterWidth > 0 {
                    Text(line.number.map(String.init) ?? "")
                        .scaledMono(11)
                        .foregroundStyle(.tertiary)
                        .frame(width: gutterWidth, alignment: .trailing)
                }
                Text(line.marker)
                    .scaledMono(11, .semibold)
                    .foregroundStyle(markerColor(line.kind))
                code(line)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(line.kind))
        }
    }

    // The band says added or removed; the code itself keeps its syntax colours, so a
    // diff reads as code first and as a change second. Each line is coloured on its own,
    // since an edit can start in the middle of anything and carrying state between its
    // lines would guess wrong as often as right.
    @ViewBuilder private func code(_ line: ToolPresentation.Line) -> some View {
        if let language = change.language, line.text.utf8.count <= CodeHighlight.sizeLimit {
            Text(CodeHighlight.highlight(line.text, language: language))
                .scaledMono(11)
                .foregroundStyle(.primary)
        } else {
            Text(line.text)
                .scaledMono(11)
                .foregroundStyle(.primary)
        }
    }

    private func markerColor(_ kind: ToolPresentation.Line.Kind) -> Color {
        switch kind {
        case .addition: Theme.addition
        case .deletion: Theme.deletion
        case .context, .gap: .secondary
        }
    }

    private func background(_ kind: ToolPresentation.Line.Kind) -> Color {
        switch kind {
        case .addition: Theme.dotOn.opacity(0.14)
        case .deletion: Theme.deletion.opacity(0.10)
        case .context, .gap: .clear
        }
    }
}

// The agents the running turn still has out, by the id the CLI gave them. It travels in
// the environment because the cards that need it sit at the bottom of the transcript, and
// a message is drawn again only when the message itself changes - which the agents coming
// and going does not do.
private struct RunningAgentsKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    var runningAgents: Set<String> {
        get { self[RunningAgentsKey.self] }
        set { self[RunningAgentsKey.self] = newValue }
    }
}
