import AppKit
import SwiftUI
import CodeStationCore

struct ReviewBarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(Theme.accent)
            configuration.title
        }
    }
}

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
        HStack(alignment: .top, spacing: 16) {
            if let before {
                side(before, title: before == after ? "UNCHANGED" : "BEFORE")
            }
            if let after, after != before {
                side(after, title: before == nil ? "NEW" : "AFTER")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func side(_ data: Data, title: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.mono(11, .medium))
                .foregroundStyle(.secondary)
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(data.count.formatted(.byteCount(style: .file)))")
                    .font(.mono(11))
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
            .font(.mono(11, .bold))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.16)))
            .appTooltip(kind.label)
    }
}
