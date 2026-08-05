import SwiftUI

// A turn's tool calls drawn as one activity spine: a dot per call joined by a thin
// line, one row each. A row expands in place - an edit shows the diff it made, and
// everything else shows its input and output.
struct ActivitySpine: View {
    let tools: [ToolUse]
    let projectPath: String
    let openChanges: () -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                SpineRow(
                    tool: tool,
                    presentation: ToolPresentationCache.presentation(for: tool, projectPath: projectPath),
                    isFirst: index == 0,
                    isLast: index == tools.count - 1,
                    isExpanded: expanded.contains(tool.id),
                    onToggle: {
                        if expanded.contains(tool.id) {
                            expanded.remove(tool.id)
                        } else {
                            expanded.insert(tool.id)
                        }
                    },
                    openChanges: openChanges)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: expanded)
    }
}

private struct SpineRow: View {
    let tool: ToolUse
    let presentation: ToolPresentation
    let isFirst: Bool
    let isLast: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let openChanges: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                row
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                detail.padding(.bottom, 10)
            }
        }
        .padding(.leading, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The spine is a background so it takes the height of the row it belongs to; as
        // a sibling it would have nothing to stretch against.
        .background(alignment: .topLeading) { spine }
    }

    private var row: some View {
        HStack(spacing: 10) {
            Text(presentation.verb)
                .font(.mono(12, .semibold))
            Text(presentation.argument)
                .font(.mono(12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            note
        }
    }

    @ViewBuilder private var note: some View {
        if tool.isRunning {
            Text("running")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if tool.isError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.deletion)
        } else if let added = presentation.added, let removed = presentation.removed {
            HStack(spacing: 5) {
                Text("+\(added)").foregroundStyle(Theme.addition)
                Text("-\(removed)").foregroundStyle(Theme.deletion)
            }
            .font(.mono(11, .medium))
        } else if presentation.notesResultLineCount, let result = tool.result {
            // A command that printed nothing is worth saying out loud: without it the row
            // is indistinguishable from one whose output is simply collapsed.
            Text(result.isEmpty ? "no output" : "\(lineCount(result)) lines")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // The three parts are layered at fixed offsets rather than stacked. A shape with no
    // height of its own takes exactly the height the row offers, so the tail reaches the
    // bottom without ever asking the row how tall it is - and the row is what sizes the
    // spine in the first place, so asking back would make the two sizes depend on each
    // other.
    private var spine: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(isLast ? Color.clear : Theme.border)
                .frame(width: 1.5)
                .padding(.top, dotTop + dotSize)
            Rectangle()
                .fill(isFirst ? Color.clear : Theme.border)
                .frame(width: 1.5, height: dotTop)
            Circle()
                .fill(dotColor)
                .frame(width: dotSize, height: dotSize)
                .padding(.top, dotTop)
        }
        .frame(width: 12)
    }

    // Where the dot sits in the row, measured from the top. It lines up with the middle
    // of the row's first line of text.
    private let dotTop: CGFloat = 9
    private let dotSize: CGFloat = 7

    private var dotColor: Color {
        if tool.isRunning { return Theme.dotOn }
        if tool.isError { return Theme.deletion }
        return Theme.dotOff
    }

    @ViewBuilder private var detail: some View {
        if tool.isError, let result = tool.result, !result.isEmpty {
            outputBox(result, tinted: true)
        } else if !presentation.diff.isEmpty {
            EditDiffCard(presentation: presentation, openChanges: openChanges)
        } else {
            if !tool.input.isEmpty { outputBox(tool.input, tinted: false) }
            if let result = tool.result, !result.isEmpty { outputBox(result, tinted: false) }
        }
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
