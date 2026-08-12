import SwiftUI

// Sequential tool calls share one block, but every call keeps its own visible row. A row
// expands in place - an edit shows the diff it made, a call that started an agent shows
// everything that agent did, and everything else shows its input and output.
//
// The block itself folds down to a single summary line, so a finished turn reads as what
// Claude said rather than as a page of the work behind it.
struct ActivitySpine: View {
    let nodes: [ToolNode]
    let projectPath: String
    let openChanges: () -> Void
    // Whether the turn is still working through this block. Its calls having all reported
    // in does not mean the work behind it is over: the model writes its next words before
    // it makes its next call, and a call interrupted mid-turn never reports in at all.
    // Only the end of the turn says the block is done.
    var isLive = false
    // A nested spine already sits behind a row the reader opened, so it draws in full.
    var isFoldable = true

    @State private var expanded: Set<String> = []
    // Nil until the reader clicks: until then the block follows the work, open while the
    // turn is on it and folded once the turn has moved on.
    @State private var showsCalls: Bool?

    // Having opened a row is asking for the block, so the fold that comes with the end of
    // the turn does not take back what the reader unfolded while the calls ran.
    private var showsRows: Bool {
        Self.rowsAreVisible(isFoldable: isFoldable,
                            userChoice: showsCalls,
                            isLive: isLive,
                            hasExpandedRows: !expanded.isEmpty)
    }

    private var hasRunningCalls: Bool {
        isLive && nodes.contains(where: \.hasRunning)
    }

    nonisolated static func rowsAreVisible(isFoldable: Bool, userChoice: Bool?,
                                            isLive: Bool,
                                            hasExpandedRows: Bool) -> Bool {
        !isFoldable || (userChoice ?? (isLive || hasExpandedRows))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isFoldable { header }
            if showsRows { rows }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, showsRows ? 11 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sunken))
        .animation(.easeInOut(duration: 0.12), value: expanded)
        .animation(.easeInOut(duration: 0.12), value: showsRows)
    }

    private var header: some View {
        Button { showsCalls = !showsRows } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showsRows ? 90 : 0))
                    .frame(width: 10)
                Text(summary)
                    .font(.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if nodes.contains(where: \.hasError) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.deletion)
                }
                Spacer(minLength: 8)
                if hasRunningCalls && !showsRows {
                    Text("running")
                        .font(.mono(10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, showsRows ? 7 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appTooltip(showsRows ? "Hide tool calls" : "Show tool calls")
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

    private var rows: some View {
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

// How much ran, said the same way wherever it is said: on a folded block, and on the row
// of a call that handed its work on. Agents are counted apart from calls, since a
// fan-out's size is the team it put to work.
private func workDone(calls: Int, agents: Int) -> String {
    let work = "\(calls) call" + (calls == 1 ? "" : "s")
    guard agents > 0 else { return work }
    return "\(agents) agent" + (agents == 1 ? "" : "s") + " · " + work
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
                Text(workDone(calls: node.callCount, agents: node.agentCount))
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
            ActivitySpine(nodes: node.children, projectPath: projectPath,
                          openChanges: openChanges, isFoldable: false)
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
                .foregroundStyle(tinted ? ChatColor.warningText : .primary)
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
