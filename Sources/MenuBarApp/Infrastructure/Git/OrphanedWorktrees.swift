import Foundation
import SwiftUI
import CodeStationCore

enum OrphanedWorktreePruning {
    static func confirmation(for worktrees: [OrphanedWorktree],
                             handler: @escaping () -> Void) -> Dialog {
        let count = worktrees.count
        return Dialog(
            title: "Prune \(counted(count, "orphaned worktree"))?",
            message: "These checkouts have no session. Any uncommitted changes in them will be lost. Branches are kept when they have unmerged commits.",
            content: AnyView(OrphanedWorktreeDetails(worktrees: worktrees)),
            actions: [
                Dialog.Action(label: "Prune all", kind: .destructive, handler: handler),
                Dialog.Action(label: "Cancel", kind: .cancel)
            ],
            width: 520)
    }
}

private struct OrphanedWorktreeDetails: View {
    let worktrees: [OrphanedWorktree]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(worktrees) { worktree in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(worktree.projectName)
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(worktree.branch ?? "Detached HEAD")
                                .font(.mono(10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(worktree.allocatedBytes > 0
                                 ? worktree.allocatedBytes.formatted(.byteCount(style: .file))
                                 : "No disk usage")
                                .font(.mono(10))
                                .foregroundStyle(.tertiary)
                        }
                        Text("LOCATION")
                            .font(.mono(8.5, .semibold))
                            .kerning(0.8)
                            .foregroundStyle(.tertiary)
                        Text(worktree.path)
                            .font(.mono(10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .surface(Theme.field, cornerRadius: 8)
                }
            }
        }
        .frame(height: min(CGFloat(worktrees.count) * 92, 260))
    }
}
