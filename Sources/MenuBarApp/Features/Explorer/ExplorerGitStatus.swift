import SwiftUI

// What git says about each file under the open projects, keyed by absolute path, so a
// row can carry its status badge without asking git as it draws.
@MainActor
@Observable
final class ExplorerGitStatus {
    private(set) var statuses: [String: GitStatusKind] = [:]

    func refresh(roots: [String]) async {
        var statuses: [String: GitStatusKind] = [:]
        for root in roots {
            let snapshot = await GitInspector.snapshot(at: root, lane: .interactive)
            guard !Task.isCancelled else { return }
            guard case .ready = snapshot.state else { continue }
            for file in snapshot.files {
                let path = URL(fileURLWithPath: snapshot.root).standardizedFileURL.appendingPathComponent(file.path).path
                if let relative = path.pathRelative(to: URL(fileURLWithPath: root).resolvingSymlinksInPath().path) {
                    statuses[URL(fileURLWithPath: root).appendingPathComponent(relative).path] = file.kind
                }
            }
        }
        self.statuses = statuses
    }
}

struct ExplorerStatusMark: View {
    let status: GitStatusKind
    var spelledOut = false

    var body: some View {
        Text(spelledOut ? status.label.capitalized : status.letter)
            .font(.system(size: spelledOut ? 10 : 11, weight: .semibold))
            .foregroundStyle(colour)
            .accessibilityLabel(status.label)
            .appTooltip(status.label.capitalized)
    }

    private var colour: Color {
        switch status {
        case .added, .untracked: Theme.addition
        case .deleted, .conflicted: Theme.deletion
        case .modified, .renamed: Theme.attention
        }
    }
}

struct ExplorerIcon: View {
    let symbol: String
    let label: String
    var selected = false
    // Left out when the icon opens a menu: `appMenu` brings a button of its own, and one
    // nested inside another swallows the click before the menu ever sees it.
    var action: (() -> Void)? = nil

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @State private var actOuts = 0

    var body: some View {
        Group {
            if let action {
                Button {
                    actOuts += 1
                    action()
                } label: { glyph }
                .buttonStyle(.plain)
            } else {
                glyph
            }
        }
        .hoverLift(hovering, amount: Motion.smallLift)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.control, value: selected)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .appTooltip(label)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(Typography.detail.weight(.medium))
            .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
            .contentTransition(.symbolEffect(.replace))
            .motion(Motion.control, value: symbol)
            .actOut(symbol, trigger: actOuts)
            .frame(width: 28, height: 28)
            .background(selected || (hovering && isEnabled) ? Theme.field : .clear, in: RoundedRectangle(cornerRadius: Radius.inset))
            .contentShape(Rectangle())
    }
}
