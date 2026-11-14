import AppKit
import SwiftUI

// A changed picture side by side with its last committed version. A file with only one
// side, new or deleted, gets that side on its own.
struct ImageDiffView: View {
    let before: Data?
    let after: Data?

    init(images: DiffImages) {
        before = images.before
        after = images.after
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            if let before {
                side(before, title: before == after ? "UNCHANGED" : "BEFORE")
            }
            if let after, after != before {
                side(after, title: before == nil ? "NEW" : "AFTER")
            }
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func side(_ data: Data, title: String) -> some View {
        VStack(spacing: Space.md) {
            Text(title)
                .font(Typography.data.weight(.medium))
                .foregroundStyle(.secondary)
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(data.count.formatted(.byteCount(style: .file)))")
                    .font(Typography.data)
                    .foregroundStyle(.secondary)
            } else {
                PaneMessage(icon: "photo", title: "Cannot draw this image",
                            detail: data.count.formatted(.byteCount(style: .file)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
@Observable
final class BranchDraft {
    var name = ""
}

struct BranchNameEditor: View {
    @Bindable var draft: BranchDraft
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Branch name", text: $draft.name)
            .appTextField()
            .focused($focused)
            .task { focused = true }
    }
}

struct StatusChip: View {
    let kind: GitStatusKind

    private var color: Color {
        switch kind {
        case .modified: Theme.secret
        case .added, .untracked: Theme.dotOn
        case .deleted, .conflicted: Theme.deletion
        case .renamed: Theme.accent
        }
    }

    var body: some View {
        Text(kind.letter)
            .font(Typography.data.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: Radius.inset).fill(color.opacity(0.16)))
            .appTooltip(kind.label)
    }
}
