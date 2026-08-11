import SwiftUI

// A round of tool calls collected into one block rather than listed one by one. The
// label row says what the whole round amounted to, so a long run of reads can be folded
// away without losing what it found. A row inside still expands in place - an edit shows
// the diff it made, a call that started an agent shows everything that agent did, and
// everything else shows its input and output.
struct ActivitySpine: View {
    let nodes: [ToolNode]
    let projectPath: String
    let openChanges: () -> Void

    // Long rounds arrive folded: past about five calls the list is longer than the answer
    // it supports, and the summary above it says what happened anyway.
    private static let foldAbove = 5

    @State private var expanded: Set<String> = []
    @State private var collapsed: Bool?

    // A round still being written to stays open however long it gets: folding itself away
    // mid-stream would take the work off screen exactly while it is worth watching.
    private var isCollapsed: Bool {
        if let collapsed { return collapsed }
        guard !nodes.contains(where: { $0.tool.isRunning }) else { return false }
        return nodes.count > Self.foldAbove
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(summary)
                    .font(.mono(9, .semibold))
                    .kerning(1.1)
                    .foregroundStyle(.secondary)
                Rectangle().fill(Theme.border).frame(height: 1)
                Button { collapsed = !isCollapsed } label: {
                    Text(isCollapsed ? "EXPAND" : "COLLAPSE")
                        .font(.mono(9.5))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(nodes, id: \.id) { node in
                        SpineRow(
                            node: node,
                            presentation: ToolPresentationCache.presentation(
                                for: node.tool, projectPath: projectPath),
                            projectPath: projectPath,
                            isExpanded: expanded.contains(node.id),
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
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sunken))
        .animation(.easeInOut(duration: 0.12), value: expanded)
        .animation(.easeInOut(duration: 0.12), value: isCollapsed)
    }

    // What the round amounted to, in the terms the rows themselves are counted in. This
    // has to survive the fold, so it names the work rather than the calls alone: the
    // edits it made, the lines it read, and anything that failed.
    private var summary: String {
        var calls = 0
        var agents = 0
        var edits = 0
        var linesRead = 0
        var failures = 0

        for node in nodes {
            calls += 1 + node.callCount
            agents += (node.tool.startsAgents ? 1 : 0) + node.agentCount
            let presentation = ToolPresentationCache.presentation(for: node.tool,
                                                                  projectPath: projectPath)
            if presentation.added != nil || presentation.removed != nil { edits += 1 }
            if node.tool.isError { failures += 1 }
            if presentation.notesResultLineCount, let result = node.tool.result, !result.isEmpty {
                linesRead += result.components(separatedBy: "\n").count
            }
        }

        var parts = ["\(calls) TOOL CALL\(calls == 1 ? "" : "S")"]
        if agents > 0 { parts.append("\(agents) AGENT\(agents == 1 ? "" : "S")") }
        if edits > 0 { parts.append("\(edits) EDIT\(edits == 1 ? "" : "S")") }
        if linesRead > 0 { parts.append("\(linesRead) LINES READ") }
        if failures > 0 { parts.append("\(failures) FAILED") }
        return parts.joined(separator: " · ")
    }
}

private struct SpineRow: View {
    let node: ToolNode
    let presentation: ToolPresentation
    let projectPath: String
    let isExpanded: Bool
    let onToggle: () -> Void
    let openChanges: () -> Void

    private var tool: ToolUse { node.tool }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                row
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                detail.padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The verb sits in a column of its own so a run of calls reads down the left edge as
    // a list of what was done, with the targets lining up beside it.
    private var row: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(presentation.verb)
                    .font(.mono(11.5, .semibold))
                    .lineLimit(1)
                    .frame(width: 38, alignment: .leading)
                Text(presentation.argument)
                    .font(.mono(11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                note
            }
            // A fan-out can run for many minutes behind one row, so while it does, the
            // row carries whatever its agents were last doing.
            if let live = liveLine {
                Text(live)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 48)
            }
        }
    }

    private var liveLine: String? {
        guard tool.isRunning, tool.startsAgents else { return nil }
        if let newest = node.newestDescendant, newest.tool.isRunning {
            return ToolPresentationCache.presentation(for: newest.tool, projectPath: projectPath).label
        }
        return tool.status
    }

    @ViewBuilder private var note: some View {
        if !node.children.isEmpty {
            HStack(spacing: 6) {
                if tool.isError { failed }
                Text(workDone)
                    .font(.mono(10.5))
                    .foregroundStyle(.tertiary)
            }
        } else if tool.isRunning {
            Text("running")
                .font(.mono(10.5))
                .foregroundStyle(.tertiary)
        } else if tool.isError {
            failed
        } else if let added = presentation.added, let removed = presentation.removed {
            DiffPair(added: added, removed: removed, size: 10.5)
        } else if presentation.notesResultLineCount, let result = tool.result {
            // A command that printed nothing is worth saying out loud: without it the row
            // is indistinguishable from one whose output is simply collapsed.
            Text(result.isEmpty ? "no output" : "\(lineCount(result)) lines")
                .font(.mono(10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var failed: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Theme.deletion)
    }

    // How much ran inside this call. Agents are counted separately from calls where the
    // work was handed on again, since a workflow's size is the team it put to work.
    private var workDone: String {
        let calls = node.callCount
        let agents = node.agentCount
        let work = "\(calls) call" + (calls == 1 ? "" : "s")
        guard agents > 0 else { return work }
        return "\(agents) agent" + (agents == 1 ? "" : "s") + " · " + work
    }

    @ViewBuilder private var detail: some View {
        if !node.children.isEmpty {
            agentWork
        } else if tool.isError, let result = tool.result, !result.isEmpty {
            outputBox(result, tinted: true)
        } else if !presentation.diff.isEmpty {
            EditDiffCard(presentation: presentation, openChanges: openChanges)
        } else {
            if !tool.input.isEmpty { outputBox(tool.input, tinted: false) }
            if let result = tool.result, !result.isEmpty { outputBox(result, tinted: false) }
        }
    }

    // Everything that ran inside the call, drawn as a spine of its own. The agent's own
    // words while it worked open it, and its report closes it: that report is the only
    // part of all this the conversation itself gets back.
    private var agentWork: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status = tool.status, !status.isEmpty {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            ActivitySpine(nodes: node.children, projectPath: projectPath, openChanges: openChanges)
            if let result = tool.result, !result.isEmpty {
                outputBox(result, tinted: tool.isError)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    private func outputBox(_ text: String, tinted: Bool) -> some View {
        ScrollView {
            Text(text)
                .font(.mono(11))
                .foregroundStyle(tinted ? Theme.deletion : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        // Tool output can be a whole file, so cap it and let the box scroll.
        .frame(maxHeight: 220)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(tinted ? ChatColor.warningBackground : Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .padding(.bottom, 4)
    }

    private func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.components(separatedBy: "\n").count
    }
}

// The change an edit made, shown as a small inline diff. This is a preview of the
// call's own input; the full working tree diff lives behind "Open in Changes".
private struct EditDiffCard: View {
    let presentation: ToolPresentation
    let openChanges: () -> Void

    private static let visibleLines = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            lines
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(presentation.fileName ?? presentation.argument)
                .font(.mono(12, .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let added = presentation.added, let removed = presentation.removed {
                HStack(spacing: 5) {
                    Text("+\(added)").foregroundStyle(Theme.addition)
                    Text("-\(removed)").foregroundStyle(Theme.deletion)
                }
                .font(.mono(11, .medium))
            }
            Spacer(minLength: 8)
            Button("Open in Changes", action: openChanges)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presentation.diff.prefix(Self.visibleLines)) { line in
                Text(line.marker + " " + line.text)
                    .font(.mono(11))
                    .foregroundStyle(color(line.kind))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(line.kind))
            }
            if presentation.diff.count > Self.visibleLines {
                Text("… \(presentation.diff.count - Self.visibleLines) more lines")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 6)
    }

    private func color(_ kind: ToolPresentation.Line.Kind) -> Color {
        switch kind {
        case .addition: Theme.addition
        case .deletion: Theme.deletion
        case .context: .primary
        }
    }

    private func background(_ kind: ToolPresentation.Line.Kind) -> Color {
        switch kind {
        case .addition: Theme.dotOn.opacity(0.14)
        case .deletion: Theme.deletion.opacity(0.10)
        case .context: .clear
        }
    }
}
