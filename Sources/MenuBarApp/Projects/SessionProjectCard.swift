import SwiftUI

struct SessionProjectCard: View {
    let project: Project
    var lead: Bool? = nil
    let usesWorktree: Bool
    let report: GitFreshness.Report?
    @Binding var startPoint: SessionStartPoint
    let selectWorktree: () -> Void
    let selectProjectFolder: () -> Void
    let onChoose: () -> Void
    var detach: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProjectDot(tint: Theme.projectTint(for: project.name), size: 10)
                    Text(project.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    if let lead {
                        if lead {
                            MonoChip(text: "Lead project", size: 10, tint: Theme.accent)
                        } else {
                            Text("Attached").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let detach {
                        Button(action: detach) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Detach \(project.name) from this session")
                        .appTooltip("Detach from this session")
                    }
                }
                CheckoutModePicker(usesWorktree: usesWorktree,
                                   supportsWorktree: project.isGitRepository,
                                   selectWorktree: selectWorktree,
                                   selectProjectFolder: selectProjectFolder)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Checkout mode for \(project.name)")
            }
            .padding(16)
            if let report, report.isStale || report.dirty || (report.fetchAttempted && !report.fetched) {
                Rectangle().fill(Theme.attention.opacity(0.38)).frame(height: 1)
                FreshnessNotice(report: report, forWorktree: usesWorktree,
                                startPoint: $startPoint, onChoose: onChoose)
            }
        }
        .background(Theme.card)
        .overlay(alignment: .leading) {
            if lead == true { Rectangle().fill(Theme.accent).frame(width: 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.border))
    }
}

struct SessionCheckoutPaths: View {
    struct Entry {
        let name: String
        let branch: String?
        let path: String
    }

    let entries: [Entry]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureHeader(isExpanded: $expanded, show: "Show branch and checkout paths",
                             hide: "Hide branch and checkout paths") {
                Text("Branch and checkout paths").font(.system(size: 12))
            }
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(entries.indices, id: \.self) { index in
                        let entry = entries[index]
                        VStack(alignment: .leading, spacing: 4) {
                            if let branch = entry.branch {
                                Text("\(entry.name): \(branch)")
                            }
                            Text(entry.path)
                        }
                        .font(.mono(11.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.fold)
            }
        }
        .foregroundStyle(.secondary)
        .smoothlyResizes(when: expanded)
    }
}

struct SessionCreationImpact {
    let updates: Int
    let worktrees: Int

    var text: String {
        let folders = updates == 0
            ? "Project folders will stay unchanged during creation."
            : "Will update \(updates) project folder\(updates == 1 ? "" : "s")."
        guard worktrees > 0 else { return folders }
        return "\(folders) \(worktrees) worktree\(worktrees == 1 ? " will" : "s will") be created."
    }
}
