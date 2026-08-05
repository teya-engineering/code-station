import SwiftUI

// Where a new session will do its work. This is the one choice made before a session
// exists and it cannot be changed afterwards, so it is a screen rather than a dialog:
// both options say what they mean for the working tree, and each shows the branch and
// folder it would actually use.
struct NewSessionView: View {
    let project: Project
    let onCreate: (NewSessionChoice) -> Void

    @Environment(\.dismiss) private var dismiss

    // Picked up front so the branch and folder shown here are the ones the session is
    // created with, rather than a guess at what they will look like.
    @State private var sessionID = UUID()
    @State private var useWorktree = true

    private var planned: GitWorktree.Created {
        GitWorktree.plan(projectName: project.name, sessionID: sessionID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                OptionCard(
                    title: "Use a git worktree",
                    badge: "Runs in parallel",
                    badgeTint: Theme.accent,
                    detail: "An isolated checkout on its own branch, so several sessions of this project can run at once.",
                    branch: planned.branch,
                    path: planned.path.abbreviatedPath,
                    selected: useWorktree) { useWorktree = true }

                OptionCard(
                    title: "Work in the project folder",
                    badge: "One at a time",
                    badgeTint: Theme.secret,
                    detail: "Edits your working tree directly. Sessions that share a folder cannot run together.",
                    branch: GitHead.branch(at: project.path),
                    path: project.collapsedPath,
                    selected: !useWorktree) { useWorktree = false }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            footer
        }
        .frame(width: 560)
        .background(Theme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New session in \(project.name)")
                .font(.serif(19))
                .lineLimit(2)
            Text("\(project.name) is a git repository, so this session can have a checkout of its own.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 10) {
                Text(useWorktree
                     ? "A worktree is removed when its session is deleted."
                     : "Changes land straight in your working tree.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    .keyboardShortcut(.cancelAction)
                Button("Create session") { create() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.card)
        }
    }

    private func create() {
        onCreate(useWorktree ? .worktree(sessionID) : .folder)
        dismiss()
    }
}

// What the sheet came back with. The worktree case carries the id the session must be
// created with, since the branch and folder shown were named after it.
enum NewSessionChoice: Equatable {
    case worktree(UUID)
    case folder
}

// One of the two ways to run, as a card the whole of which is the target. The line at the
// bottom is the point of the card: it is what turns "an isolated checkout" into a branch
// and a folder the user can recognise.
private struct OptionCard: View {
    let title: String
    let badge: String
    let badgeTint: Color
    let detail: String
    let branch: String?
    let path: String
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(badge.uppercased())
                        .font(.mono(9.5, .semibold))
                        .kerning(0.6)
                        .foregroundStyle(badgeTint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(badgeTint.opacity(0.12)))
                    Spacer(minLength: 0)
                }
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.mono(11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("·")
                            .font(.mono(11.5))
                            .foregroundStyle(.tertiary)
                    }
                    Text(path)
                        .font(.mono(11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
