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
                promptCard(task)
                runList(task, runs: runs)
            }
            .padding(24)
        }
    }

    private func promptCard(_ task: Project) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionRule(title: "PROMPT") { EmptyView() }

            TaskPromptEditor(prompt: $prompt, minHeight: 110)

            Divider().overlay(Theme.hairline)

            runBar(task)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private func runList(_ task: Project, runs: [ChatSession]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionRule(title: "RUNS") { EmptyView() }

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

    // Where a run starts from, at the foot of the prompt it will send. Only the agent
    // stays on show, because it decides what the other choices mean; those live behind
    // one Options menu, and a choice only earns a spot in the row when it strays from
    // the app default or needs a warning kept visible.
    private func runBar(_ task: Project) -> some View {
        let choices = runChoices(task)
        return HStack(spacing: 14) {
            SessionBotPicker(avatars: appSettings.agentAvatars,
                             selectedName: botBinding(task), size: 26)
            choiceMenu(agentChoice(task))
            ForEach(choices.filter { $0.overridden || $0.warning },
                    id: \.badge) { choice in
                choiceMenu(choice)
            }
            optionsMenu(choices)
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
    }

    private func botBinding(_ task: Project) -> Binding<String> {
        Binding(get: { spec(task).agentAvatarName ?? appSettings.defaultAgentAvatarName },
                set: { name in changeSpec(task) { $0.agentAvatarName = name } })
    }

    // The agent a run of this task starts on. Changing it swaps the choices beside it
    // to that agent's; an override saved for the other agent reads as unset until the
    // task is switched back.
    private func runAgent(_ task: Project) -> AgentKind {
        spec(task).agent ?? runner.agent
    }

    // MARK: - Run choices

    // One choice a run starts with: its current state, the rows its menu offers, and
    // where a pick lands.
    private struct RunChoice {
        let badge: String
        let label: String
        let overridden: Bool
        let help: String
        let defaultTitle: String
        let options: [(id: String, title: String)]
        var warning = false
        var warningOption: String? = nil
        let selection: Binding<String?>
    }

    private func runChoices(_ task: Project) -> [RunChoice] {
        [modelChoice(task),
         effortChoice(task),
         runAgent(task) == .claudeCode ? permissionsChoice(task) : codexAccessChoice(task)]
    }

    private func agentChoice(_ task: Project) -> RunChoice {
        let override = spec(task).agent
        return RunChoice(
            badge: "AGENT",
            label: (override ?? runner.agent).title,
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

    private func modelChoice(_ task: Project) -> RunChoice {
        let agent = runAgent(task)
        let override = ModelChoice.valid(spec(task).model, for: agent)
        let appDefault = ModelChoice.valid(runner.defaults(for: agent).model, for: agent)
        return RunChoice(
            badge: "MODEL",
            label: override.map { ModelChoice.title(of: $0) } ?? "Default model",
            overridden: override != nil,
            help: "The model each run starts on.",
            defaultTitle: defaultTitle(appDefault.map { ModelChoice.title(of: $0) }),
            options: ModelChoice.options(for: agent).compactMap { choice in
                choice.id.map { (id: $0, title: choice.title) }
            },
            selection: Binding(get: { override },
                               set: { id in changeSpec(task) { $0.model = id } }))
    }

    private func effortChoice(_ task: Project) -> RunChoice {
        let agent = runAgent(task)
        let override = EffortChoice.valid(spec(task).effort, for: agent)
        let appDefault = EffortChoice.valid(runner.defaults(for: agent).effort, for: agent)
        let chosen = override ?? appDefault
        return RunChoice(
            badge: "EFFORT",
            label: chosen.map { "\(EffortChoice.summary(of: $0, agent: agent)) effort" }
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

    private func permissionsChoice(_ task: Project) -> RunChoice {
        let agent = runAgent(task)
        let override = spec(task).permissionMode
        let defaults = runner.defaults(for: agent)
        return RunChoice(
            badge: "ASKS",
            label: PermissionMode.shortTitle(of: override ?? defaults.permissionMode),
            overridden: override != nil,
            help: "How much the agent asks before it acts.",
            defaultTitle: defaultTitle(PermissionMode.shortTitle(of: defaults.permissionMode)),
            options: PermissionMode.all.map { (id: $0.mode, title: $0.title) },
            selection: Binding(get: { override },
                               set: { mode in
                                   changeSpec(task) { $0.permissionMode = mode }
                               }))
    }

    private func codexAccessChoice(_ task: Project) -> RunChoice {
        let agent = runAgent(task)
        let override = CodexSandboxMode.valid(spec(task).codexSandboxMode)
        let appDefault = CodexSandboxMode.resolved(runner.defaults(for: agent).codexSandboxMode)
        let selected = override ?? appDefault
        return RunChoice(
            badge: "ACCESS",
            label: selected.summary,
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

    private func choiceMenu(_ choice: RunChoice) -> some View {
        HStack(spacing: 4) {
            Text(choice.label)
                .font(.system(size: 11, weight: choice.overridden ? .semibold : .regular))
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
        }
        .foregroundStyle(choice.warning ? Theme.deletion
                                        : choice.overridden ? Theme.accent : Color.secondary)
        .fixedSize()
        .appMenu { menuEntries(choice, badged: false) }
        .appTooltip(choice.overridden ? "\(choice.help) Overridden for this task." : choice.help)
    }

    // Every remaining choice in one place, each group's rows wearing a chip that names
    // the group.
    private func optionsMenu(_ choices: [RunChoice]) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 9, weight: .semibold))
            Text("Options")
                .font(.system(size: 11))
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .appMenu {
            choices.enumerated().flatMap { index, choice -> [MenuEntry] in
                (index == 0 ? [] : [.separator]) + menuEntries(choice, badged: true)
            }
        }
        .appTooltip("The model, effort, and access choices each run starts with.")
    }

    // The rows of one choice: the default first, naming what it resolves to, then each
    // option. A standalone menu separates the default from the options; the combined
    // menu keeps each group in one block and separates the groups instead.
    private func menuEntries(_ choice: RunChoice, badged: Bool) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .item(choice.defaultTitle,
                  checked: choice.selection.wrappedValue == nil,
                  badge: badged ? choice.badge : nil) {
                choice.selection.wrappedValue = nil
            }
        ]
        if !badged { entries.append(.separator) }
        entries += choice.options.map { option in
            MenuEntry.item(option.title,
                           kind: option.id == choice.warningOption ? .destructive : .plain,
                           checked: choice.selection.wrappedValue == option.id,
                           badge: badged ? choice.badge : nil,
                           subtitle: option.id == choice.warningOption
                               ? "No file, service, or network restrictions."
                               : nil) {
                choice.selection.wrappedValue = option.id
            }
        }
        return entries
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
