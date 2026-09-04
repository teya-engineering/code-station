import SwiftUI

// Sequential tool calls share one spine. Every call keeps a one-line receipt in the
// transcript, so finishing work never takes history away or moves the prose around it.
// Detail belongs to the reader: a click opens it and another click closes it.
struct ActivitySpine: View {
    let nodes: [ToolNode]
    let projectPath: String
    var openChange: ((String) -> Void)? = nil
    var openTerminal: (() -> Void)? = nil

    @State private var expanded: Set<String> = []

    private var calls: [ToolNode] { Self.flattened(nodes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption
            ForEach(calls, id: \.id) { node in
                CallReceipt(
                    node: node,
                    presentation: ToolPresentationCache.presentation(
                        for: node.tool, projectPath: projectPath),
                    isExpanded: expanded.contains(node.id),
                    onToggle: {
                        if expanded.contains(node.id) {
                            expanded.remove(node.id)
                        } else {
                            expanded.insert(node.id)
                        }
                    },
                    openChange: openChange,
                    openTerminal: openTerminal)
                    .transition(.fadeIn)
            }
        }
        .padding(.leading, 20)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.border)
                .frame(width: 2)
                .padding(.leading, 4)
        }
        // Only a reader's click changes an opened detail. Calls arriving and finishing
        // update their permanent rows without taking ownership of this state.
        .smoothlyResizes(when: expanded)
    }

    private var caption: some View {
        HStack(spacing: 8) {
            Text(Self.summary(calls))
                .foregroundStyle(.tertiary)
            let failures = calls.count { $0.tool.isError }
            if failures > 0 {
                Text("· \(counted(failures, "failed").uppercased())")
                    .foregroundStyle(Theme.deletion)
            }
        }
        .scaledMono(10)
        .kerning(1)
        .lineLimit(1)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    nonisolated static func flattened(_ nodes: [ToolNode]) -> [ToolNode] {
        func walk(_ node: ToolNode) -> [ToolNode] {
            [node] + node.children.flatMap(walk)
        }
        return nodes.flatMap(walk).enumerated().sorted { left, right in
            left.element.order == right.element.order
                ? left.offset < right.offset
                : left.element.order < right.element.order
        }.map(\.element)
    }

    nonisolated static func summary(_ calls: [ToolNode]) -> String {
        var verbs: [String] = []
        for call in calls {
            let verb = call.tool.name.uppercased()
            if !verbs.contains(verb) { verbs.append(verb) }
        }
        let count = "\(calls.count) \(calls.count == 1 ? "CALL" : "CALLS")"
        guard !verbs.isEmpty else { return count }
        let named = verbs.prefix(3).joined(separator: ", ") + (verbs.count > 3 ? "…" : "")
        return "\(count) · \(named)"
    }
}

// The Working Set uses the same light detail surface when its compact row is clicked.
struct ToolCallExpandedDetail: View {
    let tool: ToolUse
    let projectPath: String
    let isRunning: Bool

    var body: some View {
        if isRunning {
            RunningToolIndicator(tool: tool)
        } else {
            CallDetail(
                node: ToolNode(tool: tool),
                presentation: ToolPresentationCache.presentation(
                    for: tool, projectPath: projectPath),
                openChange: nil,
                openTerminal: nil)
        }
    }
}

private struct RunningToolIndicator: View {
    @Environment(\.textScale) private var textScale

    let tool: ToolUse

    var body: some View {
        HStack(spacing: 8) {
            PulsingDot(size: 7)
            Text("RUNNING")
                .scaledMono(10, .bold)
                .kerning(1)
                .foregroundStyle(Theme.accent)
            Spacer(minLength: 8)
            if let startedAt = tool.startedAt {
                ElapsedTime(since: startedAt, size: 11, scaled: true)
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(height: 26 * textScale)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Running \(tool.name)")
    }
}

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

private struct CallReceipt: View {
    @Environment(\.textScale) private var textScale
    @Environment(\.runningAgents) private var runningAgents

    let node: ToolNode
    let presentation: ToolPresentation
    let isExpanded: Bool
    let onToggle: () -> Void
    let openChange: ((String) -> Void)?
    let openTerminal: (() -> Void)?

    private var tool: ToolUse { node.tool }
    private var isWorking: Bool { node.isWorking(agents: runningAgents) }
    private var state: SpineCardState {
        SpineCardState(isWorking: isWorking, isError: tool.isError)
    }
    private var canExpand: Bool {
        !isWorking && CallDetail.hasContent(node: node, presentation: presentation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if canExpand {
                Button(action: onToggle) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
            if isExpanded && canExpand {
                CallDetail(
                    node: node,
                    presentation: presentation,
                    openChange: openChange,
                    openTerminal: openTerminal)
                    .padding(.leading, 17)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    .transition(.fold)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            statusDot
            Text(tool.name.uppercased())
                .kerning(1)
                .scaledMono(10, .bold)
                .foregroundStyle(verbColour)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 40 * textScale, alignment: .leading)
            Text(subject)
                .scaledMono(11.5)
                .foregroundStyle(isWorking ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            outcome
            if canExpand {
                Text(isExpanded ? "▾" : "▸")
                    .scaledMono(11)
                    .foregroundStyle(isExpanded ? AnyShapeStyle(.secondary)
                                                 : AnyShapeStyle(.tertiary))
                    .frame(width: 8 * textScale)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26 * textScale)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(canExpand ? (isExpanded ? "expanded" : "collapsed") : "")
    }

    @ViewBuilder private var statusDot: some View {
        if state == .running {
            PulsingDot(size: 7)
        } else {
            Circle()
                .fill(state.dot)
                .frame(width: 7, height: 7)
        }
    }

    private var verbColour: AnyShapeStyle {
        switch state {
        case .running: AnyShapeStyle(Theme.accent)
        case .failed: AnyShapeStyle(Theme.deletion)
        case .done: AnyShapeStyle(.primary)
        }
    }

    private var subject: String {
        if !presentation.argument.isEmpty { return presentation.argument }
        return tool.status ?? ""
    }

    @ViewBuilder private var outcome: some View {
        if isWorking {
            HStack(spacing: 5) {
                Text("running")
                if let startedAt = tool.startedAt {
                    Text("·")
                    ElapsedTime(since: startedAt, size: 11, scaled: true)
                        .foregroundStyle(Theme.accent)
                }
            }
            .scaledMono(11)
            .foregroundStyle(Theme.accent)
            .fixedSize()
        } else if let added = presentation.added, let removed = presentation.removed,
                  !tool.isError {
            HStack(spacing: 6) {
                if presentation.changedFiles > 1 {
                    Text(counted(presentation.changedFiles, "file"))
                        .scaledMono(11)
                        .foregroundStyle(.tertiary)
                }
                DiffPair(added: added, removed: removed, size: 11 * textScale,
                         weight: .regular)
                duration
            }
            .fixedSize()
        } else {
            HStack(spacing: 5) {
                if let note = outcomeNote {
                    Text(note)
                        .scaledMono(11)
                        .foregroundStyle(tool.isError
                                         ? AnyShapeStyle(Theme.deletion)
                                         : AnyShapeStyle(.tertiary))
                }
                duration
            }
            .fixedSize()
        }
    }

    @ViewBuilder private var duration: some View {
        if let value = tool.duration {
            if outcomeNote != nil || presentation.added != nil {
                Text("·")
                    .scaledMono(11)
                    .foregroundStyle(.tertiary)
            }
            Text(ElapsedTime.duration(value))
                .scaledMono(11)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    private var outcomeNote: String? {
        if tool.isError { return tool.exitCode.map { "exit \($0)" } ?? "failed" }
        if node.callCount > 0 { return counted(node.callCount, "call") }
        guard presentation.notesResultLineCount, let result = tool.result else { return nil }
        return counted(Self.lineCount(result), "line")
    }

    private var accessibilityLabel: String {
        var parts = [state.word.lowercased(), tool.name]
        if !subject.isEmpty { parts.append(subject) }
        if let outcomeNote { parts.append(outcomeNote) }
        if let duration = tool.duration { parts.append(ElapsedTime.duration(duration)) }
        return parts.joined(separator: ", ")
    }

    nonisolated static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.components(separatedBy: "\n").count
    }
}

private struct CallDetail: View {
    let node: ToolNode
    let presentation: ToolPresentation
    let openChange: ((String) -> Void)?
    let openTerminal: (() -> Void)?

    private var tool: ToolUse { node.tool }
    private var isCommand: Bool { tool.name == "Bash" }
    private var hasDiff: Bool {
        !presentation.changes.isEmpty && !tool.isError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCommand {
                ToolOutputCard(label: "OUTPUT",
                               text: tool.result ?? "",
                               isFailure: tool.isError,
                               openTerminal: openTerminal)
            }
            if hasDiff {
                ForEach(presentation.changes) { change in
                    EditDiffCard(
                        change: change,
                        targetPath: presentation.diffIsTheInput
                            ? presentation.filePath ?? presentation.argument
                            : change.name,
                        openChange: openChange)
                }
            } else if !isCommand, let result = tool.result {
                ToolOutputCard(label: tool.startsAgents ? "AGENT REPORT" : "OUTPUT",
                               text: result,
                               isFailure: tool.isError,
                               openTerminal: nil)
            } else if !isCommand, let status = tool.status, !status.isEmpty {
                ToolOutputCard(label: "STATUS",
                               text: status,
                               isFailure: tool.isError,
                               openTerminal: nil)
            }
        }
    }

    nonisolated static func hasContent(node: ToolNode,
                                        presentation: ToolPresentation) -> Bool {
        if !presentation.changes.isEmpty && !node.tool.isError { return true }
        if node.tool.name == "Bash" { return node.tool.result != nil }
        if node.tool.result != nil { return true }
        return node.tool.status?.isEmpty == false
    }
}

private struct ToolOutputCard: View {
    @Environment(\.textScale) private var textScale

    let label: String
    let text: String
    let isFailure: Bool
    let openTerminal: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(label)
                    .scaledMono(10.5, .bold)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let openTerminal {
                    ActivityLink(title: "open in Terminal ↗", action: openTerminal)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30 * textScale)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                Text(text.isEmpty ? "No output" : text)
                    .scaledMono(11.5)
                    .foregroundStyle(isFailure
                                     ? AnyShapeStyle(Theme.deletion)
                                     : AnyShapeStyle(.secondary))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(maxHeight: 220 * textScale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.sunken, cornerRadius: 8, border: Theme.border)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ActivityLink: View {
    let title: String
    var size: CGFloat = 10.5
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .scaledMono(size, .medium)
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// One file's worth of what a call changed, shown as a small inline preview. The full
// working tree diff stays in Changes and the link opens it on this file.
private struct EditDiffCard: View {
    @Environment(\.textScale) private var textScale

    let change: ToolPresentation.FileChange
    let targetPath: String
    let openChange: ((String) -> Void)?

    private static let visibleLines = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            lines
        }
        .surface(Theme.sunken, cornerRadius: 8, border: Theme.border)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(change.name)
                .scaledMono(10.5, .bold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let openChange {
                ActivityLink(title: "open in Changes →") {
                    openChange(targetPath)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30 * textScale)
    }

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
                    .scaledMono(11)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func row(_ line: ToolPresentation.Line) -> some View {
        if line.kind == .gap {
            Text("⋯")
                .scaledMono(11.5)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 8) {
                if gutterWidth > 0 {
                    Text(line.number.map(String.init) ?? "")
                        .scaledMono(11.5)
                        .foregroundStyle(.tertiary)
                        .frame(width: gutterWidth, alignment: .trailing)
                }
                Text(line.marker)
                    .scaledMono(11.5, .semibold)
                    .foregroundStyle(markerColor(line.kind))
                Text(line.text)
                    .scaledMono(11.5)
                    .foregroundStyle(lineColor(line.kind))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(line.kind))
        }
    }

    private func markerColor(_ kind: ToolPresentation.Line.Kind) -> Color {
        switch kind {
        case .addition: Theme.addition
        case .deletion: Theme.deletion
        case .context, .gap: Color.secondary
        }
    }

    private func lineColor(_ kind: ToolPresentation.Line.Kind) -> Color {
        switch kind {
        case .addition: Theme.addition
        case .deletion: Theme.deletion
        case .context, .gap: Color.secondary
        }
    }

    private func background(_ kind: ToolPresentation.Line.Kind) -> Color {
        switch kind {
        case .addition: Theme.addition.opacity(0.09)
        case .deletion: Theme.deletion.opacity(0.08)
        case .context, .gap: Color.clear
        }
    }
}

// The agents the running turn still has out, by the id the CLI gave them. It travels in
// the environment because a message does not otherwise redraw when agents come and go.
private struct RunningAgentsKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    var runningAgents: Set<String> {
        get { self[RunningAgentsKey.self] }
        set { self[RunningAgentsKey.self] = newValue }
    }
}
