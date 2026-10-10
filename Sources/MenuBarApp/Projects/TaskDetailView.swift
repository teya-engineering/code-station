import AppKit
import SwiftUI

// One task: the prompt it runs and every run it has had. A run is an ordinary session
// in the task's folder, so opening one takes over the pane the same way any session
// does.
struct TaskDetailView: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings
    @Environment(TerminalStore.self) private var terminals
    @Environment(WorkingTreeWatch.self) private var workingTrees

    private enum Tab: Hashable { case task, explorer }

    @State private var tab: Tab = .task
    @State private var prompt = ""
    @State private var promptLoaded = false
    @State private var promptFocused = false
    @State private var terminalFocused = false
    @State private var askingTask: Project?
    @State private var runFilter: TaskRunHistory.Filter = .all
    @State private var paneWidth: CGFloat = 1_000

    private var terminalScope: TerminalScope { .project(projectID) }

    var body: some View {
        if let task = store.project(projectID) {
            VStack(spacing: 0) {
                header(task)
                statusStrip(task)
                if store.isMissing(task) { missingFolder(task) }
                content(task)
                if terminals.isOpen(terminalScope) {
                    TerminalDrawer(scope: terminalScope,
                                   directory: task.path,
                                   focusTerminal: $terminalFocused)
                }
            }
            .background(Theme.background)
            .taskRunSheet($askingTask) { asking, values, note in
                startRun(asking, values: values, note: note)
            }
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

    // The name and the views, and nothing about the runs: how the last one went reads on
    // the strip under this one, the way a session's state does. Running stays at the foot
    // of the prompt, because what a run sends is the prompt on screen and the choices
    // beside the button, not something the header can speak for.
    private func header(_ task: Project) -> some View {
        HStack(spacing: 12) {
            Button { store.changeSidebarAvatar(forProject: task.id) } label: {
                SidebarIdentityTile(
                    avatar: task.sidebarAvatar,
                    name: task.name,
                    tint: Theme.projectTint(for: task.name),
                    dashed: true)
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .accessibilityLabel("Change \(task.name) icon")
            .appTooltip("Change icon")
            Text(task.name)
                .font(.serif(17, .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .appTooltip(task.collapsedPath)

            Spacer(minLength: 12)

            HStack(spacing: 12) {
                HeaderTabToggle(selection: $tab,
                                options: [("Task", .task),
                                          ("Explorer", .explorer)])
                TerminalToggle(isOpen: terminals.isOpen(terminalScope),
                               directory: task.path) {
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

    // MARK: - Status strip

    // A task is a prompt that has been run before, so its state is how the last run went
    // and what it was given: the same line a session wears, reading about the newest run
    // instead of about itself. What was filled in last time is the readable part of "what
    // did this do", which is why it takes the end of the row.
    private func statusStrip(_ task: Project) -> some View {
        let runs = store.standaloneSessions(for: task.id)
        let latest = runs.max { $0.lastActivity < $1.lastActivity }
        let inputs = TaskTemplate.inputs(in: spec(task))
        return HStack(spacing: 14) {
            if let latest {
                lastRun(latest)
            } else {
                StatusCaps(text: "NEVER RUN")
            }

            StatusRule()

            HStack(spacing: 7) {
                StatusCaps(text: counted(runs.count, "run").uppercased())
                if !inputs.isEmpty {
                    StatusDot()
                    StatusCaps(text: counted(inputs.count, "input").uppercased())
                }
            }

            if let schedule = spec(task).schedule, schedule.isActive,
               let next = schedule.nextRunAt {
                StatusRule()
                StatusValue(text: "Next run \(RelativeTime.stamp(next))", tint: Theme.accent)
                    .fixedSize()
            }

            Spacer(minLength: 12)

            if let latest {
                let given = TaskTemplate.summary(of: latest.taskValues ?? [:], inputs: inputs)
                if !given.isEmpty { StatusValue(text: given) }
            }
            InlineLink(title: "Reveal in Finder", size: 11.5) {
                NSWorkspace.shared.activateFileViewerSelecting([task.url])
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .statusBand(padding: 24)
    }

    private func lastRun(_ session: ChatSession) -> some View {
        let tone = SessionTone(session.id, store: store, runner: runner)
        return Button { store.selectSession(session.id) } label: {
            HStack(spacing: 7) {
                StateLight(tone: tone, size: 6)
                StatusCaps(text: tone.word, tint: tone.colour)
                StatusDot()
                StatusValue(text: RelativeTime.short(session.lastActivity))
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
        .appTooltip("Open the latest run")
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

    // The prompt is the page; the schedule and the inputs are settings beside it. Below
    // about 900 points the settings drop under the prompt rather than squeezing it, and
    // stay above the runs, since they shape the next run while the runs are history. One
    // layout that only moves its parts keeps the editor itself in place, so the cursor
    // survives a window being resized across the line.
    private static let stackBelow: CGFloat = 900

    private func details(_ task: Project) -> some View {
        let runs = store.standaloneSessions(for: task.id)
        let inputs = TaskTemplate.inputs(in: spec(task))
        return ScrollView {
            TaskDetailLayout(wide: paneWidth >= Self.stackBelow) {
                promptCard(task, inputs: inputs)

                VStack(alignment: .leading, spacing: 22) {
                    TaskScheduleCard(task: task, schedule: spec(task).schedule) { schedule in
                        changeSpec(task) { $0.schedule = schedule }
                    }
                    TaskInputsCard(inputs: inputs) { input in
                        changeSpec(task) { spec in
                            spec.inputs = TaskTemplate.saving(input, in: spec)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                runList(task, runs: runs, inputs: inputs)
            }
            .padding(24)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
    }

    private func promptCard(_ task: Project, inputs: [TaskInput]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Prompt")
                .font(.serif(15, .semibold))
                .padding(.horizontal, 18)
                .padding(.top, 16)

            TaskPromptEditor(text: $prompt,
                             placeholder: "What should the agent do on every run?",
                             minHeight: 96,
                             onFocusChange: { promptFocused = $0 })
                .padding(.horizontal, 18)
                .padding(.top, 10)

            // How to make a hole only matters while writing, but the holes a run will ask
            // for stay in view, since they change what pressing Run does.
            if promptFocused || !inputs.isEmpty {
                holeHint(inputs)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .transition(.opacity)
            }

            Divider().overlay(Theme.hairline)
                .padding(.top, 16)

            runBar(task)
                .padding(.leading, 18)
                .padding(.trailing, 14)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12)
        .animation(Motion.reveal, value: promptFocused)
    }

    // What each run will ask for, read off the prompt as it is typed. With nothing to
    // ask, it says how to make a hole instead.
    private func holeHint(_ inputs: [TaskInput]) -> some View {
        let text: Text
        if inputs.isEmpty {
            text = Text("Type \(holeName("{{ticket}}")) anywhere and each run asks for a ticket before it starts.")
        } else {
            var names = holeName(inputs[0].name)
            for input in inputs.dropFirst() {
                names = Text("\(names), \(holeName(input.name))")
            }
            text = Text("Each run asks for \(names) before it starts.")
        }
        return text
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func holeName(_ name: String) -> Text {
        Text(verbatim: name).font(.mono(11.5)).foregroundStyle(Theme.accent)
    }

    // MARK: - Runs

    private func runList(_ task: Project, runs: [ChatSession], inputs: [TaskInput]) -> some View {
        let shown = TaskRunHistory.filtered(runs, by: runFilter) { failure(of: $0) != nil }
        let days = TaskRunHistory.days(of: shown)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Runs")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(runs.count)")
                    .font(.mono(11))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 12)
                if !runs.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(TaskRunHistory.Filter.allCases, id: \.self) { filter in
                            ChoicePill(title: filter.title, selected: runFilter == filter) {
                                runFilter = filter
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Filter runs")
                }
            }

            Group {
                if shown.isEmpty {
                    emptyRuns(hasRuns: !runs.isEmpty)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days) { day in
                            dayHeader(day.title, first: day.id == days.first?.id)
                            ForEach(Array(day.runs.enumerated()), id: \.element.id) { index, session in
                                if index > 0 {
                                    Divider().overlay(Theme.hairline)
                                }
                                runRow(session, task: task, inputs: inputs)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .cardSurface(cornerRadius: 12)
        }
    }

    private func dayHeader(_ title: String, first: Bool) -> some View {
        VStack(spacing: 0) {
            if !first { Divider().overlay(Theme.hairline) }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 9)
                .padding(.bottom, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.sunken)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func runRow(_ session: ChatSession, task: Project, inputs: [TaskInput]) -> some View {
        let tone = SessionTone(session.id, store: store, runner: runner)
        let live = tone == .running || tone == .waiting
        return TaskRunRow(
            session: session,
            tone: tone,
            failure: failure(of: session).map { "Stopped: \($0)" },
            activity: live ? SessionActivity.line(for: session, store: store, runner: runner) : "",
            given: TaskTemplate.summary(of: session.taskValues ?? [:], inputs: inputs),
            onOpen: { store.selectSession(session.id) },
            menu: { runMenu(session, task: task) })
    }

    // Why a run stopped, read from how its turn ended. Only the runner knows this, so a
    // run that failed before the app was last opened reads as finished.
    private func failure(of session: ChatSession) -> String? {
        let live = LiveConversation.id(of: session.id, store: store, runner: runner)
        if case .failed(let message) = runner.state(live) {
            let line = message.split(whereSeparator: \.isNewline).first.map(String.init)
            return line?.trimmed.nilIfBlank ?? "the run ended with an error"
        }
        return nil
    }

    private func emptyRuns(hasRuns: Bool) -> some View {
        let (title, detail): (String, String) = switch (hasRuns, runFilter) {
        case (false, _), (true, .all):
            ("Not run yet",
             "Run task starts a fresh session in this folder and sends the prompt for you.")
        case (true, .scheduled):
            ("No scheduled runs", "Set a schedule and the runs it starts show up here.")
        case (true, .failed):
            ("No failed runs", "Every run so far finished.")
        }
        return VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
    }

    private func runMenu(_ session: ChatSession, task: Project) -> [MenuEntry] {
        [
            .item("Open run") { store.selectSession(session.id) },
            .item(session.isPinned ? "Unpin" : "Pin",
                  icon: session.isPinned ? "pin.slash" : "pin") {
                store.setPinned(!session.isPinned, forSession: session.id)
            },
            SessionUnread.menuEntry(for: session.id, store: store),
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
    // one Options menu, and a choice only earns a spot in the row when it needs a
    // warning kept visible.
    private func runBar(_ task: Project) -> some View {
        let choices = runChoices(task)
        return HStack(spacing: 14) {
            SessionBotPicker(avatars: appSettings.agentAvatars,
                             selectedName: botBinding(task), size: 26)
            choiceMenu(agentChoice(task))
            ForEach(choices.filter(\.warning), id: \.badge) { choice in
                choiceMenu(choice)
            }
            optionsMenu(choices)
            Spacer(minLength: 12)
            if runBusy(task) {
                Text("Waiting for the current run to finish")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            ActionButton(title: "Run task", tone: .green, icon: "play.fill") {
                run(task)
            }
            .disabled(!runReady(task))
            .appTooltip(runBusy(task)
                ? "A run is still working in this folder."
                : TaskRun.needsInput(task)
                    ? "Ask for what this run needs, then start a fresh session"
                    : "Start a fresh session with the saved prompt")
        }
        .task(id: runAgent(task)) { await runner.discoverModels(for: runAgent(task)) }
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
        let access = switch runAgent(task) {
        case .claudeCode: permissionsChoice(task)
        case .codex: codexAccessChoice(task)
        case .copilot: copilotAccessChoice(task)
        }
        return [modelChoice(task), effortChoice(task), access]
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
        let override = runner.validModel(spec(task).model, for: agent)
        let appDefault = runner.validModel(runner.defaults(for: agent).model, for: agent)
        return RunChoice(
            badge: "MODEL",
            label: override.map { runner.modelTitle($0) } ?? "Default model",
            overridden: override != nil,
            help: "The model each run starts on.",
            defaultTitle: defaultTitle(appDefault.map { runner.modelTitle($0) }),
            options: runner.modelOptions(for: agent).compactMap { choice in
                choice.id.map { (id: $0, title: choice.title) }
            },
            selection: Binding(get: { override },
                               set: { id in
                                   changeSpec(task) {
                                       $0.model = id
                                       if let effort = $0.effort,
                                          runner.validEffort(effort, for: agent,
                                                             model: id ?? appDefault) == nil {
                                           $0.effort = nil
                                       }
                                   }
                               }))
    }

    private func effortChoice(_ task: Project) -> RunChoice {
        let agent = runAgent(task)
        let model = runner.validModel(spec(task).model, for: agent)
            ?? runner.validModel(runner.defaults(for: agent).model, for: agent)
        let override = runner.validEffort(spec(task).effort, for: agent, model: model)
        let appDefault = runner.validEffort(runner.defaults(for: agent).effort,
                                            for: agent, model: model)
        let chosen = override ?? appDefault
        let inheritedEffort = appDefault.map { runner.effortTitle($0, for: agent, model: model) }
            ?? "\(agent.title) settings"
        return RunChoice(
            badge: "EFFORT",
            label: chosen.map { "\(runner.effortTitle($0, for: agent, model: model)) effort" }
                ?? "\(agent.title) default effort",
            overridden: override != nil,
            help: "How long the model thinks before it answers. Inherit Code Station's default, or choose a level for this run.",
            defaultTitle: "Use Code Station default (\(inheritedEffort))",
            options: runner.effortOptions(for: agent, model: model).compactMap { choice in
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
            label: PermissionMode(stored: override ?? defaults.permissionMode).shortTitle,
            overridden: override != nil,
            help: "How much the agent asks before it acts.",
            defaultTitle: defaultTitle(PermissionMode(stored: defaults.permissionMode).shortTitle),
            options: PermissionMode.allCases.map { (id: $0.rawValue, title: $0.title) },
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

    private func copilotAccessChoice(_ task: Project) -> RunChoice {
        let agent = runAgent(task)
        let override = CopilotAccessMode.valid(spec(task).copilotAccessMode)
        let appDefault = CopilotAccessMode.resolved(runner.defaults(for: agent).copilotAccessMode)
        let selected = override ?? appDefault
        return RunChoice(
            badge: "ACCESS",
            label: selected.summary,
            overridden: override != nil,
            help: selected.detail,
            defaultTitle: defaultTitle(appDefault.title),
            options: CopilotAccessMode.allCases.map { (id: $0.rawValue, title: $0.title) },
            warning: selected == .fullAccess,
            warningOption: CopilotAccessMode.fullAccess.rawValue,
            selection: Binding(get: { override?.rawValue },
                               set: { value in
                                   changeSpec(task) { $0.copilotAccessMode = value }
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
    // the group. The control takes the accent when any choice inside strays from the
    // app default, so an override stays visible without a pill of its own.
    private func optionsMenu(_ choices: [RunChoice]) -> some View {
        let overridden = choices.contains(where: \.overridden)
        return HStack(spacing: 4) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 9, weight: .semibold))
            Text(optionsLabel(choices))
                .font(.system(size: 11, weight: overridden ? .semibold : .regular))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
        }
        .foregroundStyle(overridden ? Theme.accent : Color.secondary)
        .fixedSize()
        .appMenu {
            choices.enumerated().flatMap { index, choice -> [MenuEntry] in
                (index == 0 ? [] : [.separator]) + menuEntries(choice, badged: true)
            }
        }
        .appTooltip(overridden
            ? "The model, effort, and access choices each run starts with. Some are overridden for this task."
            : "The model, effort, and access choices each run starts with.")
    }

    // The current choices in words: "Default model, high effort". A warning choice
    // already has its own control in the row, so it is not said twice.
    private func optionsLabel(_ choices: [RunChoice]) -> String {
        choices.enumerated().compactMap { index, choice -> String? in
            if index >= 2, choice.warning || !choice.overridden { return nil }
            return index == 0 ? choice.label : choice.label.lowercased()
        }
        .joined(separator: ", ")
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
        runFilter = .all
        if TaskRun.needsInput(current) {
            askingTask = current
        } else {
            startRun(current, values: [:], note: "")
        }
    }

    private func startRun(_ task: Project, values: [String: String], note: String) {
        if case .failure(let failure) = TaskRun.run(
            task, values: values, note: note, store: store, runner: runner,
            agentAvatarName: appSettings.defaultAgentAvatarName) {
            dialogs.show(.notice("Could not run the task", message: failure.message))
        }
    }

    private func confirmRemove(_ session: ChatSession) {
        SessionRemoval.confirm(session, in: store, runner: runner,
                               workingTrees: workingTrees, dialogs: dialogs)
    }

    // MARK: - Terminal

    private func toggleTerminal(directory: String) {
        let opening = !terminals.isOpen(terminalScope)
        terminals.setOpen(opening, for: terminalScope, directory: directory)
        terminalFocused = opening
    }

    // A task's folder belongs to the app, so a missing one is unlikely to come back: the
    // banner names the way out rather than leaving a dead task in the list, and the
    // sentence offers the button rather than the button arriving unannounced.
    private func missingFolder(_ task: Project) -> some View {
        WarningStrip("Folder not found at \(task.collapsedPath). The task cannot run without it. Delete the task to clear it out.") {
            ActionButton(title: "Delete task", tone: .outlined, height: 28, size: 11.5) {
                ProjectRemoval.confirm(task, in: store, runner: runner, shortcuts: shortcuts,
                                       dialogs: dialogs)
            }
            .fixedSize()
        }
    }
}

// Lays out the prompt, the settings and the runs, in that order. Wide, the settings sit in
// a column on the right beside the prompt and the runs. Narrow, all three stack, with the
// settings between the prompt and the runs.
private struct TaskDetailLayout: Layout {
    let wide: Bool
    var sideWidth: CGFloat = 312
    var spacing: CGFloat = 22

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = self.frames(width: proposal.width ?? 800, subviews: subviews)
        let size = frames.reduce(CGRect.zero) { $0.union($1) }
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 3 else { return [] }
        let prompt = subviews[0], side = subviews[1], runs = subviews[2]
        func height(of view: LayoutSubview, at width: CGFloat) -> CGFloat {
            view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }

        if wide {
            let mainWidth = max(width - sideWidth - spacing, 0)
            let promptHeight = height(of: prompt, at: mainWidth)
            return [
                CGRect(x: 0, y: 0, width: mainWidth, height: promptHeight),
                CGRect(x: mainWidth + spacing, y: 0, width: sideWidth,
                       height: height(of: side, at: sideWidth)),
                CGRect(x: 0, y: promptHeight + spacing, width: mainWidth,
                       height: height(of: runs, at: mainWidth)),
            ]
        }

        var y: CGFloat = 0
        return [prompt, side, runs].map { view in
            let frame = CGRect(x: 0, y: y, width: width, height: height(of: view, at: width))
            y = frame.maxY + spacing
            return frame
        }
    }
}
