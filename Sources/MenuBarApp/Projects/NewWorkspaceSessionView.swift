import SwiftUI

// Chooses how each repository in a workspace is opened for one session. Every workspace
// member starts attached, while extra projects can be added to this session alone.
struct NewWorkspaceSessionView: View {
    let workspace: ProjectWorkspace
    let onCreate: (WorkspaceSessionChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var appSettings

    @State private var sessionID = UUID()
    @State private var projectIDs: [UUID]
    @State private var worktrees: Set<UUID>
    @State private var selectedAgent: AgentKind?
    @State private var selectedAvatarName = AgentAvatarSelection.nonBotName

    init(workspace: ProjectWorkspace, onCreate: @escaping (WorkspaceSessionChoice) -> Void) {
        self.workspace = workspace
        self.onCreate = onCreate
        _projectIDs = State(initialValue: workspace.projectIDs)
        _worktrees = State(initialValue: Set(workspace.worktreeProjectIDs))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New session in \(workspace.name)")
                    .font(.serif(21, .semibold))
                Text("The lead project is the agent's working directory. Attached projects are available to the same conversation.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(projectIDs, id: \.self) { id in
                        if let project = store.project(id) {
                            projectCard(project, lead: id == workspace.leadProjectID)
                        }
                    }

                    if !attachableProjects.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("Attach a project")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(attachableProjects.map(\.name).joined(separator: " · "))
                                .font(.mono(11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Rectangle())
                        .appMenu { attachMenu }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(maxHeight: 470)

            footer
        }
        .frame(width: 680)
        .background(Theme.background)
        .onAppear { selectedAvatarName = appSettings.defaultAgentAvatarName }
    }

    private func projectCard(_ project: Project, lead: Bool) -> some View {
        let supportsWorktree = isGitRepository(project)
        let usesWorktree = supportsWorktree && worktrees.contains(project.id)
        let checkout = GitWorktree.plan(projectName: project.name, projectID: project.id,
                                        sessionID: sessionID)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(projectColour(project.id))
                    .frame(width: 10, height: 10)
                Text(project.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(lead ? "LEAD" : "ATTACHED")
                    .font(.mono(9.5, .semibold))
                    .kerning(0.5)
                    .foregroundStyle(lead ? Theme.accent : projectColour(project.id))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill((lead ? Theme.accent : projectColour(project.id)).opacity(0.1)))
                Spacer(minLength: 8)
                Text(project.collapsedPath)
                    .font(.mono(11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !lead {
                    Button { detach(project.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .appTooltip("Detach from this session")
                }
            }

            HStack(spacing: 8) {
                modeButton("Worktree", selected: usesWorktree,
                           enabled: supportsWorktree, tint: projectColour(project.id)) {
                    worktrees.insert(project.id)
                }
                modeButton("Project folder", selected: !usesWorktree,
                           enabled: true, tint: projectColour(project.id)) {
                    worktrees.remove(project.id)
                }
                Spacer(minLength: 8)
                Text(usesWorktree ? checkout.path.abbreviatedPath : project.collapsedPath)
                    .font(.mono(11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !supportsWorktree {
                Text("This folder is not a Git repository, so the session uses it directly.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(lead ? Theme.accent : Theme.border, lineWidth: lead ? 1.5 : 1))
    }

    private func modeButton(_ title: String, selected: Bool, enabled: Bool,
                            tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(selected ? AnyShapeStyle(Color.white)
                                           : AnyShapeStyle(enabled ? Color.primary : Color.secondary))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? tint : Theme.background))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.clear : Theme.border))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(alignment: .top, spacing: 12) {
                Text("Deleting the session removes all of its worktrees together.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button { dismiss() } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                SessionBotPicker(avatars: appSettings.agentAvatars,
                                 selectedName: $selectedAvatarName)

                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 0) {
                        Button(action: create) {
                            Text("Create session")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 18)
                                .frame(height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)
                        .disabled(projectIDs.count < 2)

                        Rectangle()
                            .fill(.white.opacity(0.35))
                            .frame(width: 1, height: 16)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                            .appMenu { agentMenu }
                            .accessibilityLabel("Choose coding agent")
                    }
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .opacity(projectIDs.count >= 2 ? 1 : 0.45)

                    Text(selectedAgent.map { "Will use \($0.title)" }
                         ?? "Uses default: \(runner.agent.title)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.card)
        }
    }

    private var attachableProjects: [Project] {
        store.projects.filter { !projectIDs.contains($0.id) }
    }

    private var attachMenu: [MenuEntry] {
        attachableProjects.map { project in
            .item(project.name, subtitle: project.collapsedPath) {
                projectIDs.append(project.id)
                if isGitRepository(project) { worktrees.insert(project.id) }
            }
        }
    }

    private var agentMenu: [MenuEntry] {
        AgentKind.allCases.map { agent in
            .item(agent.title, checked: selectedAgent == agent) { selectedAgent = agent }
        }
    }

    private func detach(_ id: UUID) {
        projectIDs.removeAll { $0 == id }
        worktrees.remove(id)
    }

    private func create() {
        let choices = projectIDs.map { id in
            let useWorktree = store.project(id).map {
                worktrees.contains(id) && isGitRepository($0)
            } ?? false
            return WorkspaceProjectChoice(projectID: id, useWorktree: useWorktree)
        }
        onCreate(WorkspaceSessionChoice(sessionID: sessionID, projects: choices,
                                        agent: selectedAgent ?? runner.agent,
                                        agentAvatarName: selectedAvatarName))
        dismiss()
    }

    private func isGitRepository(_ project: Project) -> Bool {
        FileManager.default.fileExists(atPath: project.path + "/.git")
    }

    private func projectColour(_ id: UUID) -> Color {
        let colours = [Theme.accent, Theme.secret, Theme.attention, Theme.addition]
        let value = id.uuidString.utf8.reduce(0) { ($0 + Int($1)) % colours.count }
        return colours[value]
    }
}

struct WorkspaceSessionChoice: Equatable {
    var sessionID: UUID
    var projects: [WorkspaceProjectChoice]
    var agent: AgentKind
    var agentAvatarName: String? = nil
}

struct WorkspaceProjectChoice: Equatable {
    var projectID: UUID
    var useWorktree: Bool
}
