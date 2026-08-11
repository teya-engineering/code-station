import AppKit
import SwiftUI

// One task: the prompt it runs and every run it has had. A run is an ordinary session
// in the task's folder, so opening one takes over the pane the same way any session
// does.
struct TaskDetailView: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings
    @Environment(TerminalStore.self) private var terminals

    private enum Tab: Hashable { case task, explorer }

    @State private var tab: Tab = .task
    @State private var prompt = ""
    @State private var promptLoaded = false
    @State private var terminalFocused = false

    private var terminalScope: TerminalScope { .project(projectID) }

    var body: some View {
        if let task = store.project(projectID) {
            VStack(spacing: 0) {
                header(task)
                if store.isMissing(task) { missingFolder(task) }
                content(task)
                if terminals.isOpen(terminalScope) {
                    TerminalDrawer(scope: terminalScope,
                                   directory: task.path,
                                   focusTerminal: $terminalFocused)
                }
            }
            .background(Theme.background)
            .onChange(of: prompt) { _, _ in savePrompt(task) }
            .task {
                guard !promptLoaded else { return }
                prompt = task.task?.prompt ?? ""
                promptLoaded = true
            }
        } else {
            PaneMessage(icon: "bolt.badge.questionmark",
                        title: "This task is gone",
                        detail: "Choose another task or project from the sidebar.")
        }
    }

    // MARK: - Header

    private func header(_ task: Project) -> some View {
        HStack(spacing: 12) {
            ProjectTileView(name: task.name,
                            tint: Theme.projectTint(for: task.name),
                            dashed: true)
            Text(task.name)
                .font(.serif(20, .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 12)

            HStack(spacing: 12) {
                HeaderTabToggle(selection: $tab,
                                options: [("Task", .task),
                                          ("Explorer", .explorer)])
                TerminalToggle(isOpen: terminals.isOpen(terminalScope)) {
                    toggleTerminal(directory: task.path)
                }
                .disabled(store.isMissing(task))
                .opacity(store.isMissing(task) ? 0.4 : 1)

                ActionButton(title: "Run task", tone: .green, size: 12,
                             icon: "play.fill") {
                    run(task)
                }
                .disabled(!runReady(task))
                .opacity(runReady(task) ? 1 : 0.45)
                .appTooltip(runBusy(task)
                    ? "A run is still working in this folder."
                    : "Start a fresh session with the saved prompt")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 24)
        .headerBand()
    }

    @ViewBuilder private func content(_ task: Project) -> some View {
        switch tab {
        case .task:
            details(task)
        case .explorer:
            ExplorerView(root: task.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Task tab

    private func details(_ task: Project) -> some View {
        let runs = store.standaloneSessions(for: task.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                promptCard(task)
                runList(task, runs: runs)
                FooterStrip(title: "Runs as", detail: runDefaults) { EmptyView() }
            }
            .padding(24)
        }
    }

    private func promptCard(_ task: Project) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionRule(title: "PROMPT") {
                InlineLink(title: "Reveal folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([task.url])
                }
            }

            TaskPromptEditor(prompt: $prompt, minHeight: 110)

            Text("Run it as often as you like. Every run starts a fresh session with this prompt.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private func runList(_ task: Project, runs: [ChatSession]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionRule(title: "RUNS · \(runs.count)") {
                if !runs.isEmpty {
                    Text(runs.map { SessionTone($0.id, store: store, runner: runner) }.tally)
                        .font(.mono(10))
                        .kerning(0.6)
                        .foregroundStyle(.tertiary)
                }
            }

            if runs.isEmpty {
                emptyRuns(task)
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(runs) { session in
                        SessionRow(session: session,
                                   tone: SessionTone(session.id, store: store, runner: runner),
                                   branch: nil,
                                   activity: SessionActivity.line(for: session, store: store,
                                                                  runner: runner),
                                   detail: .location(task.collapsedPath),
                                   onOpen: { store.selectSession(session.id) },
                                   menu: { runMenu(session, task: task) })
                    }
                }
            }
        }
    }

    private func emptyRuns(_ task: Project) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not run yet")
                .font(.system(size: 14, weight: .semibold))
            Text("Running the task starts a session in its folder and sends the prompt for you.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            ActionButton(title: "Run task", tone: .green, icon: "play.fill") {
                run(task)
            }
            .disabled(!runReady(task))
            .opacity(runReady(task) ? 1 : 0.45)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func runMenu(_ session: ChatSession, task: Project) -> [MenuEntry] {
        [
            .item("Open run") { store.selectSession(session.id) },
            .item("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([task.url])
            },
            .separator,
            .item("Delete run", kind: .destructive) { confirmRemove(session) }
        ]
    }

    // What a run starts with, read from the same defaults the run itself would use.
    private var runDefaults: String {
        let agent = runner.agent
        let settings = runner.defaults(for: agent)
        var parts = [agent.title]
        if let model = ModelChoice.valid(settings.model, for: agent) {
            parts.append(ModelChoice.title(of: model))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Reading and changing the task

    // Two runs in the same folder would edit the same files under each other, so the
    // button waits for the previous run to finish.
    private func runBusy(_ task: Project) -> Bool {
        store.standaloneSessions(for: task.id).contains { runner.state($0.id).isBusy }
    }

    private func runReady(_ task: Project) -> Bool {
        !store.isMissing(task) && !runBusy(task)
    }

    private func savePrompt(_ task: Project) {
        guard promptLoaded else { return }
        store.setTaskSpec(TaskSpec(prompt: prompt), for: task.id)
    }

    private func run(_ task: Project) {
        guard runReady(task) else { return }
        // The prompt on screen is the one the user expects to run, saved or not yet.
        savePrompt(task)
        guard let current = store.project(task.id) else { return }
        if case .failure(let failure) = TaskRun.run(
            current, store: store, runner: runner,
            agentAvatarName: appSettings.defaultAgentAvatarName) {
            dialogs.show(Dialog(
                title: "Could not run the task",
                message: failure.message,
                actions: [.init(label: "OK", kind: .cancel)]))
        }
    }

    private func confirmRemove(_ session: ChatSession) {
        dialogs.show(Dialog(
            title: "Delete \"\(session.title)\"?",
            message: "Its conversation history is removed from the app. Files it wrote in the task folder stay.",
            actions: [
                .init(label: "Delete run", kind: .destructive) {
                    Task {
                        if case .failure(let failure) = await SessionLifecycle.remove(
                            session, from: store, runner: runner) {
                            dialogs.show(Dialog(title: failure.title, message: failure.message,
                                                actions: [.init(label: "OK", kind: .cancel)]))
                        }
                    }
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    // MARK: - Terminal

    private func toggleTerminal(directory: String) {
        let opening = !terminals.isOpen(terminalScope)
        terminals.setOpen(opening, for: terminalScope, directory: directory)
        terminalFocused = opening
    }

    private func missingFolder(_ task: Project) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Folder not found at \(task.collapsedPath). The task cannot run until it is back.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ChatColor.warningText)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(ChatColor.warningBackground)
    }
}
