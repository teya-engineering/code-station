import AppKit
import SwiftUI

// The product home gives the logo a stable destination and explains why the surrounding
// tools belong together. Its main action stays useful after the first project is added.
struct HomeView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings

    @State private var choosingSessionKind: Project?

    private let highlights = [
        HomeHighlight(
            icon: "arrow.triangle.branch",
            title: "Work in parallel",
            detail: "Give each session an isolated Git worktree, or let it work directly in the project folder."),
        HomeHighlight(
            icon: "doc.text.magnifyingglass",
            title: "See everything that changed",
            detail: "Follow the conversation, tool activity, files, diffs, token use and terminal without losing context."),
        HomeHighlight(
            icon: "person.2.fill",
            title: "Use the right agent",
            detail: "Start each session with Codex or Claude Code and choose its model, reasoning and access settings."),
        HomeHighlight(
            icon: "wrench.and.screwdriver.fill",
            title: "Stay in flow",
            detail: "Answer permissions, manage Git, inspect Docker, send API requests and use MCP tools inside Conductor.")
    ]

    private let columns = [
        GridItem(.flexible(minimum: 250), spacing: 14),
        GridItem(.flexible(minimum: 250), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero

                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "WHY CONDUCTOR")
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(highlights) { highlight in
                                highlightCard(highlight)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "ALSO BUILT IN")
                        builtInTools
                    }
                }
                .padding(28)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background(Theme.background)
        .sheet(item: $choosingSessionKind) { project in
            NewSessionView(project: project) { choice in
                startSession(choice, in: project)
            }
            .appOverlays()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Home")
                .font(.serif(22))
            Text("What Teya Conductor brings together")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 22) {
            if let logo = AppArt.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Run the work. See the whole change.")
                    .font(.serif(30))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Use Codex and Claude Code across local projects while keeping conversations, files, Git and terminals together.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 650, alignment: .leading)

                HStack(spacing: 10) {
                    primaryAction
                    if !store.projects.isEmpty {
                        actionButton("Add a project", icon: "folder.badge.plus",
                                     primary: false, action: addProject)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var primaryAction: some View {
        if let session = latestSession {
            actionButton("Continue latest session", icon: "arrow.right", primary: true) {
                store.selectSession(session.id)
            }
        } else if store.projects.count == 1, let project = store.projects.first {
            actionButton("Start a session", icon: "plus", primary: true) {
                requestNewSession(in: project)
            }
        } else if !store.projects.isEmpty {
            actionLabel("Start a session", icon: "chevron.down", primary: true)
                .appMenu(matchWidth: true) {
                    store.projects.map { project in
                        .item(project.name, subtitle: project.collapsedPath) {
                            requestNewSession(in: project)
                        }
                    }
                }
                .accessibilityLabel("Start a session")
        } else {
            actionButton("Add a project", icon: "folder.badge.plus",
                         primary: true, action: addProject)
        }
    }

    private func actionButton(_ title: String, icon: String, primary: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionLabel(title, icon: icon, primary: primary)
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, icon: String, primary: Bool) -> some View {
        HStack(spacing: 7) {
            Text(title)
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(primary ? Color.white : Theme.accent)
        .padding(.horizontal, 15)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(primary ? Theme.accent : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(primary ? Color.clear : Theme.border))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .subtleButtonGlow()
    }

    private func highlightCard(_ highlight: HomeHighlight) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: highlight.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.accent.opacity(0.09)))

            VStack(alignment: .leading, spacing: 5) {
                Text(highlight.title)
                    .font(.serif(17))
                Text(highlight.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private var builtInTools: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { toolChips }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    toolChip("Multi-project workspaces")
                    toolChip("MCP servers")
                    toolChip("Skills")
                }
                HStack(spacing: 8) {
                    toolChip("Docker")
                    toolChip("API requests")
                    toolChip("Shortcuts")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    @ViewBuilder private var toolChips: some View {
        toolChip("Multi-project workspaces")
        toolChip("MCP servers")
        toolChip("Skills")
        toolChip("Docker")
        toolChip("API requests")
        toolChip("Shortcuts")
    }

    private func toolChip(_ title: String) -> some View {
        HStack(spacing: 6) {
            SectionDot(size: 5)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
    }

    private var latestSession: ChatSession? {
        store.sidebarSessions.max { left, right in
            if left.lastActivity != right.lastActivity {
                return left.lastActivity < right.lastActivity
            }
            return left.createdAt < right.createdAt
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Pick the folder a coding agent should work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let added = store.addProject(at: url)
        if let id = added?.id ?? store.selectedProjectID {
            store.selectProject(id)
        }
    }

    private func requestNewSession(in project: Project) {
        guard !store.isMissing(project) else { return }
        guard FileManager.default.fileExists(atPath: project.path + "/.git") else {
            startSession(.folder(agent: runner.agent,
                                 agentAvatarName: appSettings.defaultAgentAvatarName),
                         in: project)
            return
        }
        choosingSessionKind = project
    }

    private func startSession(_ choice: NewSessionChoice, in project: Project) {
        switch choice {
        case .worktree(let sessionID, let base, let agent, let agentAvatarName):
            Task {
                switch await SessionLifecycle.createWorktreeSession(
                    in: project, id: sessionID, base: base,
                    agentAvatarName: agentAvatarName, store: store) {
                case .success:
                    runner.agent = agent
                case .failure(let failure):
                    show(failure)
                }
            }
        case .folder(let agent, let agentAvatarName):
            switch store.insertSession(in: project.id, agentAvatarName: agentAvatarName) {
            case .success:
                runner.agent = agent
            case .failure(let failure):
                show(SessionLifecycle.Failure(
                    title: "Could not create the session", message: failure.message))
            }
        }
    }

    private func show(_ failure: SessionLifecycle.Failure) {
        dialogs.show(Dialog(title: failure.title, message: failure.message,
                            actions: [.init(label: "OK", kind: .cancel)]))
    }
}

private struct HomeHighlight: Identifiable {
    let icon: String
    let title: String
    let detail: String

    var id: String { title }
}
