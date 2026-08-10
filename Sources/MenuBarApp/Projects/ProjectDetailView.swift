import AppKit
import SwiftUI

// The project keeps its folder, conversations and folder-level tools together without
// opening a conversation until the user asks.
struct ProjectDetailView: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings
    @Environment(WorkingTreeWatch.self) private var workingTrees
    @Environment(TerminalStore.self) private var terminals

    private enum Tab: Hashable { case sessions, changes, explorer }

    @State private var tab: Tab = .sessions
    @State private var choosingSessionKind: Project?
    @State private var terminalFocused = false

    private var terminalScope: TerminalScope { .project(projectID) }

    var body: some View {
        if let project = store.project(projectID) {
            VStack(spacing: 0) {
                header(project)
                if store.isMissing(project) { missingFolder(project) }
                content(project)
                if terminals.isOpen(terminalScope) {
                    TerminalDrawer(scope: terminalScope,
                                   directory: project.path,
                                   focusTerminal: $terminalFocused)
                }
            }
            .background(Theme.background)
            .background(terminalShortcut(project))
            .sheet(item: $choosingSessionKind) { project in
                NewSessionView(project: project) { choice in
                    startSession(choice, in: project)
                }
                .appOverlays()
            }
        } else {
            PaneMessage(icon: "folder.badge.questionmark",
                        title: "This project is gone",
                        detail: "Choose another project from the sidebar.")
        }
    }

    private func header(_ project: Project) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.serif(22))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("Project overview")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            ViewThatFits(in: .horizontal) {
                headerControls(project, compactActions: false)
                headerControls(project, compactActions: true)
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private func headerControls(_ project: Project, compactActions: Bool) -> some View {
        HStack(spacing: compactActions ? 10 : 12) {
            HeaderTabToggle(selection: $tab,
                            options: [("Sessions", .sessions),
                                      ("Changes", .changes),
                                      ("Explorer", .explorer)])

            TerminalToggle(isOpen: terminals.isOpen(terminalScope)) {
                toggleTerminal(directory: project.path)
            }
            .disabled(store.isMissing(project))
            .opacity(store.isMissing(project) ? 0.4 : 1)

            revealButton(project, compact: compactActions)
            newSessionButton(project, compact: compactActions)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func revealButton(_ project: Project, compact: Bool) -> some View {
        Button { reveal(project) } label: {
            Group {
                if compact {
                    Image(systemName: "folder")
                        .frame(width: 32, height: 32)
                } else {
                    Label("Reveal in Finder", systemImage: "folder")
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Reveal in Finder")
    }

    private func newSessionButton(_ project: Project, compact: Bool) -> some View {
        Button { requestNewSession(in: project) } label: {
            Group {
                if compact {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 32)
                } else {
                    Label("New session", systemImage: "plus")
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(store.isMissing(project))
        .help("New session")
    }

    @ViewBuilder private func content(_ project: Project) -> some View {
        switch tab {
        case .sessions:
            sessions(project)
        case .changes:
            ChangesView(root: project.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .explorer:
            ExplorerView(root: project.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func terminalShortcut(_ project: Project) -> some View {
        Button("") {
            if !terminals.isOpen(terminalScope) {
                terminals.setOpen(true, for: terminalScope, directory: project.path)
                terminalFocused = true
            } else {
                terminalFocused.toggle()
            }
        }
        .keyboardShortcut("`", modifiers: .control)
        .opacity(0)
        .disabled(store.isMissing(project))
    }

    private func toggleTerminal(directory: String) {
        let opening = !terminals.isOpen(terminalScope)
        terminals.setOpen(opening, for: terminalScope, directory: directory)
        terminalFocused = opening
    }

    private func missingFolder(_ project: Project) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Folder not found at \(project.collapsedPath). Move it back or remove the project before starting a session.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ChatColor.warningText)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(ChatColor.warningBackground)
    }

    private func sessions(_ project: Project) -> some View {
        let available = store.standaloneSessions(for: project.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                folder(project)

                HStack(alignment: .firstTextBaseline) {
                    Text("Sessions")
                        .font(.serif(18))
                    Text("\(available.count)")
                        .font(.mono(11, .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(Color.black.opacity(0.05)))
                    Spacer()
                }

                if available.isEmpty {
                    emptySessions(project)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(available) { session in
                            ProjectSessionRow(session: session,
                                              isBusy: runner.state(session.id).isBusy,
                                              onOpen: { store.selectSession(session.id) },
                                              onDelete: { confirmRemove(session) })
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func folder(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("PROJECT FOLDER")
                .font(.mono(10, .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
            Text(project.path)
                .font(.mono(13))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border))
    }

    private func emptySessions(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No sessions yet")
                .font(.system(size: 14, weight: .semibold))
            Text("Start a session when you are ready to work in this project.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button { requestNewSession(in: project) } label: {
                Text("Start a new session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(store.isMissing(project))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.black.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    // A git repository gets the folder-or-worktree choice; a plain folder can start
    // directly because there is no checkout choice to make.
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
            createWorktreeSession(in: project, id: sessionID, base: base, agent: agent,
                                  agentAvatarName: agentAvatarName)
        case .folder(let agent, let agentAvatarName):
            switch store.insertSession(in: project.id, agentAvatarName: agentAvatarName) {
            case .success:
                runner.agent = agent
            case .failure(let failure):
                dialogs.show(Dialog(
                    title: "Could not create the session",
                    message: failure.message,
                    actions: [.init(label: "OK", kind: .cancel)]))
            }
        }
    }

    private func createWorktreeSession(in project: Project, id sessionID: UUID, base: String?,
                                       agent: AgentKind, agentAvatarName: String?) {
        Task {
            switch await SessionLifecycle.createWorktreeSession(
                in: project, id: sessionID, base: base,
                agentAvatarName: agentAvatarName, store: store) {
            case .success:
                runner.agent = agent
            case .failure(let failure):
                dialogs.show(Dialog(
                    title: failure.title,
                    message: failure.message,
                    actions: [.init(label: "OK", kind: .cancel)]))
            }
        }
    }

    private func confirmRemove(_ session: ChatSession) {
        let worktree = session.worktreePath
        dialogs.show(Dialog(
            title: "Delete \"\(session.title)\"?",
            message: worktree.map { path in
                let changes = workingTrees.isDirty(path)
                    ? "Its worktree at \(path.abbreviatedPath) has uncommitted changes, and they are lost with it."
                    : "Its worktree at \(path.abbreviatedPath) goes with it, along with anything uncommitted there."
                return changes + " The branch is kept if it has unmerged commits."
            } ?? "Its conversation history is removed from the app.",
            actions: [
                .init(label: worktree == nil ? "Delete session" : "Delete session and worktree",
                      kind: .destructive) {
                    Task {
                        if case .failure(let failure) = await SessionLifecycle.remove(
                            session, from: store, runner: runner) {
                            dialogs.show(Dialog(
                                title: failure.title,
                                message: failure.message,
                                actions: [.init(label: "OK", kind: .cancel)]))
                        }
                    }
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    private func reveal(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
    }
}

// Sessions are deliberately a short summary here. Opening one is the point where its
// full transcript, files and terminal take over the detail pane.
private struct ProjectSessionRow: View {
    let session: ChatSession
    let isBusy: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 14) {
                    Circle()
                        .fill(isBusy ? Theme.dotOn : Theme.dotOff)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: 7) {
                            StatusPill(text: isBusy ? "Running" : "Idle", running: isBusy)
                            if let branch = session.worktreeBranch {
                                Label(branch, systemImage: "arrow.triangle.branch")
                                    .labelStyle(.titleAndIcon)
                                    .font(.mono(10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text("Project folder")
                                    .font(.mono(10.5))
                                    .foregroundStyle(.secondary)
                            }
                            Text("Last active \(session.lastActivity.formatted(date: .abbreviated, time: .shortened))")
                                .font(.mono(10.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 56)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border))
                .contentShape(RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.deletion)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .appTooltip("Delete session")
            .padding(.trailing, 14)
        }
    }
}
