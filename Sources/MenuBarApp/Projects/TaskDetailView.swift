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
                VStack(alignment: .leading, spacing: 12) {
                    promptCard(task)
                    runBar(task)
                }
                runList(task, runs: runs)
            }
            .padding(24)
        }
    }

    private func promptCard(_ task: Project) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionRule(title: "PROMPT") { EmptyView() }

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

    // MARK: - Run bar

    // Where a run starts from: the choices every run of this task begins with, and the
    // button itself. A choice left unset follows the app default, so each menu names
    // what that default currently resolves to.
    private func runBar(_ task: Project) -> some View {
        HStack(spacing: 14) {
            SessionBotPicker(avatars: appSettings.agentAvatars,
                             selectedName: botBinding(task), size: 26)
            agentMenu(task)
            modelMenu(task)
            effortMenu(task)
            if runAgent(task) == .claudeCode {
                permissionsMenu(task)
            } else {
                codexAccessMenu(task)
            }
            Spacer(minLength: 12)
            ActionButton(title: "Run task", tone: .green, icon: "play.fill") {
                run(task)
            }
            .disabled(!runReady(task))
            .opacity(runReady(task) ? 1 : 0.45)
            .appTooltip(runBusy(task)
                ? "A run is still working in this folder."
                : "Start a fresh session with the saved prompt")
        }
        .padding(.horizontal, 4)
    }

    private func botBinding(_ task: Project) -> Binding<String> {
        Binding(get: { spec(task).agentAvatarName ?? appSettings.defaultAgentAvatarName },
                set: { name in changeSpec(task) { $0.agentAvatarName = name } })
    }

    // The agent a run of this task starts on. Changing it swaps the menus beside it to
    // that agent's choices; an override saved for the other agent reads as unset until
    // the task is switched back.
    private func runAgent(_ task: Project) -> AgentKind {
        spec(task).agent ?? runner.agent
    }

    private func agentMenu(_ task: Project) -> some View {
        let override = spec(task).agent
        return choiceMenu((override ?? runner.agent).title,
                          overridden: override != nil,
                          help: "The coding agent each run starts on.",
                          defaultTitle: defaultTitle(runner.agent.title),
                          options: AgentKind.allCases.map { (id: $0.rawValue, title: $0.title) },
                          selection: Binding(get: { override?.rawValue },
                                             set: { value in
                                                 changeSpec(task) {
                                                     $0.agent = value.flatMap(AgentKind.init(rawValue:))
                                                 }
                                             }))
    }

    private func modelMenu(_ task: Project) -> some View {
        let agent = runAgent(task)
        let override = ModelChoice.valid(spec(task).model, for: agent)
        let appDefault = ModelChoice.valid(runner.defaults(for: agent).model, for: agent)
        return choiceMenu(override.map { ModelChoice.title(of: $0) } ?? "Default model",
                          overridden: override != nil,
                          help: "The model each run starts on.",
                          defaultTitle: defaultTitle(appDefault.map { ModelChoice.title(of: $0) }),
                          options: ModelChoice.options(for: agent).compactMap { choice in
                              choice.id.map { (id: $0, title: choice.title) }
                          },
                          selection: Binding(get: { override },
                                             set: { id in changeSpec(task) { $0.model = id } }))
    }

    private func effortMenu(_ task: Project) -> some View {
        let agent = runAgent(task)
        let override = EffortChoice.valid(spec(task).effort, for: agent)
        let appDefault = EffortChoice.valid(runner.defaults(for: agent).effort, for: agent)
        let chosen = override ?? appDefault
        return choiceMenu(chosen.map { "\(EffortChoice.summary(of: $0, agent: agent)) effort" }
                              ?? "Default effort",
                          overridden: override != nil,
                          help: "How long the model thinks before it answers.",
                          defaultTitle: defaultTitle(appDefault.map {
                              EffortChoice.summary(of: $0, agent: agent)
                          }),
                          options: EffortChoice.all(for: agent).compactMap { choice in
                              choice.id.map { (id: $0, title: choice.title) }
                          },
                          selection: Binding(get: { override },
                                             set: { id in changeSpec(task) { $0.effort = id } }))
    }

    private func permissionsMenu(_ task: Project) -> some View {
        let agent = runAgent(task)
        let override = spec(task).permissionMode
        let defaults = runner.defaults(for: agent)
        return choiceMenu(PermissionMode.shortTitle(of: override ?? defaults.permissionMode),
                          overridden: override != nil,
                          help: "How much the agent asks before it acts.",
                          defaultTitle: defaultTitle(PermissionMode.shortTitle(of: defaults.permissionMode)),
                          options: PermissionMode.all.map { (id: $0.mode, title: $0.title) },
                          selection: Binding(get: { override },
                                             set: { mode in
                                                 changeSpec(task) { $0.permissionMode = mode }
                                             }))
    }

    private func codexAccessMenu(_ task: Project) -> some View {
        let agent = runAgent(task)
        let override = CodexSandboxMode.valid(spec(task).codexSandboxMode)
        let appDefault = CodexSandboxMode.resolved(runner.defaults(for: agent).codexSandboxMode)
        let selected = override ?? appDefault
        return choiceMenu(selected.summary,
                          overridden: override != nil,
                          help: selected.detail,
                          defaultTitle: defaultTitle(appDefault.title),
                          options: CodexSandboxMode.allCases.map { (id: $0.rawValue, title: $0.title) },
                          warning: selected == .fullAccess,
                          warningOption: CodexSandboxMode.fullAccess.rawValue,
                          selection: Binding(get: { override?.rawValue },
                                             set: { value in
                                                 changeSpec(task) { $0.codexSandboxMode = value }
                                             }))
    }

    // The first row of every menu, naming what following the default currently means.
    private func defaultTitle(_ resolved: String?) -> String {
        resolved.map { "Use the default (\($0))" } ?? "Use the default"
    }

    private func choiceMenu(_ label: String, overridden: Bool, help: String,
                            defaultTitle: String,
                            options: [(id: String, title: String)],
                            warning: Bool = false,
                            warningOption: String? = nil,
                            selection: Binding<String?>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: overridden ? .semibold : .regular))
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
        }
        .foregroundStyle(warning ? Theme.deletion
                                 : overridden ? Theme.accent : Color.secondary)
        .fixedSize()
        .appMenu {
            var entries: [MenuEntry] = [
                .item(defaultTitle, checked: selection.wrappedValue == nil) {
                    selection.wrappedValue = nil
                },
                .separator,
            ]
            entries += options.map { option in
                MenuEntry.item(option.title,
                               kind: option.id == warningOption ? .destructive : .plain,
                               checked: selection.wrappedValue == option.id,
                               subtitle: option.id == warningOption
                                   ? "No file, service, or network restrictions."
                                   : nil) {
                    selection.wrappedValue = option.id
                }
            }
            return entries
        }
        .appTooltip(overridden ? "\(help) Overridden for this task." : help)
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
        changeSpec(task) { $0.prompt = prompt }
    }

    private func spec(_ task: Project) -> TaskSpec {
        store.project(task.id)?.task ?? TaskSpec(prompt: prompt)
    }

    // Edits keep everything else in the spec: the prompt and each run choice are saved
    // through the same record.
    private func changeSpec(_ task: Project, _ edit: (inout TaskSpec) -> Void) {
        var updated = spec(task)
        edit(&updated)
        store.setTaskSpec(updated, for: task.id)
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
