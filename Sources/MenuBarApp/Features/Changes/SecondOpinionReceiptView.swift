import SwiftUI

struct SecondOpinionReceiptView: View {
    let run: SecondOpinionRun
    var compact = false

    private var scope: SecondOpinionRequest.Scope { run.request.scope }
    private var base: String { scope.isSinceReview ? "Review snapshot" : scope.base ?? "HEAD" }
    private var subject: String {
        if case .file(_, let path, _) = scope { return path }
        return scope.isSinceReview ? "Since your last review" : "Code changes"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if !compact {
                Text("What was reviewed").font(Typography.title)
                    .accessibilityAddTraits(.isHeader)
                ComparisonRange(base: base, includesCommits: scope.base != nil, snapshot: scope.isSinceReview)
            }
            Text(subject).font(Typography.label).lineLimit(2).truncationMode(.middle)
            Text(base + " → working tree").font(Typography.data).foregroundStyle(.secondary)
            if let files = run.reviewedFiles {
                HStack(spacing: Space.md) {
                    Text(counted(files.count, "file") + " reviewed").font(Typography.caption)
                    DiffPair(added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed })
                }
            }
            if !compact {
                LabeledRow("Project files") { Text("Read-only") }
                LabeledRow("Conversation") { Text("Not included") }
                LabeledRow("MCP tools") { Text(run.request.servers == nil ? "Off" : "Read-only tools") }
                Text("Asked to look for").font(Typography.label)
                FlowRow(spacing: Space.sm) {
                    ForEach(run.request.focus, id: \.self) { focus in
                        Text(focus.title).font(Typography.caption)
                            .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
                            .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.tag))
                    }
                }
                if !run.request.note.isBlank {
                    Text(run.request.note).font(Typography.detail).foregroundStyle(.secondary)
                }
            }
        }
        .font(Typography.caption)
        .padding(Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
