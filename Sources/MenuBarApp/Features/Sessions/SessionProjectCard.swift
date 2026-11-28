import SwiftUI

struct SessionProjectCard: View {
    let project: Project
    var lead: Bool? = nil
    let usesWorktree: Bool
    let report: GitFreshness.Report?
    @Binding var startPoint: SessionStartPoint
    @Binding var carryChanges: Bool
    @Binding var updateDefaultBranch: Bool
    let selectWorktree: () -> Void
    let selectProjectFolder: () -> Void
    let onChoose: () -> Void
    // A fetch the user asked to run again, while it runs.
    let retry: FreshnessRetries.Attempt?
    // The retry just got through to origin.
    let reachedOrigin: Bool
    let retryFetch: () -> Void
    let stopFetch: () -> Void
    var detach: (() -> Void)? = nil
    // Off where the project is already named beside the card, so it is not said twice.
    var showsName = true
    // What the card is still waiting to hear about this project, while it waits.
    var waiting: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsNotice: Bool {
        guard let report else { return false }
        return report.isStale || report.dirty || report.fetchFailed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.lg) {
                if showsName {
                    HStack(spacing: Space.md) {
                        ProjectDot(tint: Theme.projectTint(for: project.name), size: 10)
                        Text(project.name)
                            .font(Typography.title)
                            .lineLimit(1)
                        if let lead {
                            if lead {
                                MonoChip(text: "Lead project", size: Typography.Size.micro, tint: Theme.accent)
                            } else {
                                Text("Attached").font(Typography.detail).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let detach {
                            Button(action: detach) {
                                Image(systemName: "xmark")
                                    .font(Typography.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverLift(amount: Motion.smallLift)
                            .accessibilityLabel("Detach \(project.name) from this session")
                            .appTooltip("Detach from this session")
                        }
                    }
                }
                CheckoutModePicker(usesWorktree: usesWorktree,
                                   supportsWorktree: project.isGitRepository,
                                   selectWorktree: selectWorktree,
                                   selectProjectFolder: selectProjectFolder)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Checkout mode for \(project.name)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.xl)
            if reachedOrigin, let report {
                ReachedOriginRow(report: report)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .fadeIn, removal: .fold))
            }
            if let waiting {
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    HStack(spacing: Space.md) {
                        LoopSpinner()
                        Text(waiting)
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.lg)
                }
                .accessibilityElement(children: .combine)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .fadeIn, removal: .fold))
            }
            if let report, showsNotice {
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.attention.opacity(0.38)).frame(height: 1)
                    FreshnessNotice(report: report, forWorktree: usesWorktree,
                                    projectPath: project.path, startPoint: $startPoint,
                                    carryChanges: $carryChanges,
                                    updateDefaultBranch: $updateDefaultBranch, onChoose: onChoose,
                                    retry: retry, retryFetch: retryFetch, stopFetch: stopFetch)
                }
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .fadeIn, removal: .fold))
            }
        }
        .smoothlyResizes(when: showsNotice)
        .smoothlyResizes(when: reachedOrigin)
        .smoothlyResizes(when: waiting)
        .background(Theme.card)
        .overlay(alignment: .leading) {
            if lead == true { Rectangle().fill(Theme.accent).frame(width: 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.floating))
        .overlay(RoundedRectangle(cornerRadius: Radius.floating).stroke(Theme.border))
    }
}

struct SessionCheckoutPath {
    let name: String
    let branch: String?
    let path: String
}

struct SessionCheckoutPaths<BranchField: View>: View {
    let entries: [SessionCheckoutPath]
    @ViewBuilder let branchField: BranchField
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureHeader(isExpanded: $expanded, show: "Show branch and checkout paths",
                             hide: "Hide branch and checkout paths") {
                Text("Branch and checkout paths").font(Typography.detail)
            }
            .foregroundStyle(.secondary)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            // Keep the field mounted so closing the section does not cancel branch validation.
            VStack(alignment: .leading, spacing: Space.md) {
                branchField
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(entries.indices, id: \.self) { index in
                        let entry = entries[index]
                        VStack(alignment: .leading, spacing: Space.xs) {
                            if let branch = entry.branch {
                                Text("\(entry.name): \(branch)")
                            }
                            Text(entry.path)
                        }
                        .font(Typography.code)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .padding(.top, Space.md)
            .frame(height: expanded ? nil : 0, alignment: .top)
            .opacity(expanded ? 1 : 0)
            .clipped()
            .disabled(!expanded)
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
        }
        .smoothlyResizes(when: expanded)
    }
}

// `accepted` stays false until every project has checked the typed name.
struct SessionBranchField: View {
    private static let typingPause: Duration = .milliseconds(250)

    let placeholder: String
    @Binding var name: String
    let projects: [Project]
    @Binding var accepted: Bool

    @State private var problem: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LabeledField("Branch") {
            TextField(placeholder, text: $name).appTextField()
            if let problem {
                Text(problem)
                    .font(Typography.detail)
                    .foregroundStyle(Theme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .fadeIn, removal: .fold))
            }
        }
        .motion(Motion.reveal, value: problem)
        .task(id: [name.trimmed] + projects.map(\.path)) { await check(name.trimmed) }
    }

    private func check(_ branch: String) async {
        accepted = false
        guard !branch.isEmpty else {
            problem = nil
            accepted = true
            return
        }
        guard (try? await Task.sleep(for: Self.typingPause)) != nil else { return }
        var found: String?
        for project in projects {
            if let message = await GitBranches.nameProblem(branch, at: project.path) {
                found = projects.count > 1 ? "\(project.name): \(message)" : message
                break
            }
        }
        guard !Task.isCancelled else { return }
        problem = found
        accepted = found == nil
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

// A retried fetch got through. Shown for a moment, so the notice that goes with it is
// seen to leave for a reason rather than simply vanish.
private struct ReachedOriginRow: View {
    let report: GitFreshness.Report

    private var text: String {
        guard !report.isStale, let branch = report.defaultBranch else { return "Fetched origin." }
        return "Fetched origin. \(branch) is at its latest revision."
    }

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(Typography.body)
            Text(text)
                .font(Typography.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.addition)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.lg)
        .background(Theme.addition.opacity(0.08))
        .accessibilityElement(children: .combine)
        .onAppear { AccessibilityNotification.Announcement(text).post() }
    }
}
