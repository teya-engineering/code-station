import SwiftUI

// The Second opinion tab: what an ask starts from. Each block matches a part of the ask
// card, so what is set here is what the card opens with, and Tune still changes one ask.
struct SecondOpinionSettingsView: View {
    @Binding var defaults: SecondOpinionDefaults

    @Environment(SessionRunner.self) private var runner
    @Environment(ClaudeCodeManager.self) private var claude
    @Environment(ConfigStore.self) private var configs
    @Environment(\.settingsNote) private var settingsNote
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The subject names in Look for share one column, so their chips line up.
    private static let subjectWidth: CGFloat = 180
    // The subject whose last ticked chip was clicked, which says why it stays on.
    @State private var keptFocus: SecondOpinionStop.Kind?
    // A seat arriving plays the reveal; one put away leaves on the faster curve.
    @State private var seatMotion = Motion.reveal

    private var installed: [AgentKind] {
        runner.catalog.availableAgents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            reviewers.id(SettingsSearchTarget.secondOpinionReviewers.id)
            lookFor.id(SettingsSearchTarget.secondOpinionFocus.id)
            reading.id(SettingsSearchTarget.secondOpinionReading.id)
            access.id(SettingsSearchTarget.secondOpinionAccess.id)
        }
        .onAppear {
            claude.refresh()
            seatInstalledAgents()
        }
        // A reset empties the lineup, and the rows to tick come straight back.
        .onChange(of: defaults.seats.isEmpty) { seatInstalledAgents() }
        .task { for agent in installed { await runner.discoverModels(for: agent) } }
    }

    // Every installed agent gets a row to tick, unticked until the person picks it. A
    // lineup with nobody ticked asks the same way an empty one does.
    private func seatInstalledAgents() {
        for agent in installed where !defaults.seats.contains(where: { $0.reviewer.agent == agent })
            && defaults.seats.count < SecondOpinion.Reviewer.maxSeats {
            defaults.seats.append(.init(reviewer: SecondOpinion.Reviewer(agent: agent), on: false))
        }
    }

    // MARK: Usual reviewers

    private var reviewers: some View {
        ChoiceBlock("USUAL REVIEWERS", note: "The ask opens with these seats ticked. Change them for one ask under Tune.") {
            SettingsCard {
                if defaults.seats.isEmpty {
                    Text(SecondOpinionLineup.installHint(author: runner.agent))
                        .font(Typography.detail).foregroundStyle(.secondary)
                        .padding(Space.lg)
                }
                ForEach(Array(defaults.seats.enumerated()), id: \.offset) { index, seat in
                    if index > 0 { SettingsRowDivider() }
                    seatRow(seat, at: index)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .fadeIn, removal: .fold))
                }
                SettingsRowDivider()
                addSeatRow
            }
            .motion(seatMotion, value: defaults.seats.count)
        }
    }

    private func seatRow(_ seat: SecondOpinionDefaults.Seat, at index: Int) -> some View {
        let agent = seat.reviewer.agent
        let extra = defaults.isExtraSeat(at: index)
        return HStack(spacing: Space.lg) {
            Toggle(isOn: Binding(get: { seat.on }, set: { on in
                guard defaults.seats.indices.contains(index) else { return }
                defaults.seats[index].on = on
                settingsNote(on ? "\(agent.title) asked by default" : "\(agent.title) left out by default",
                             on ? "checkmark" : "minus")
            })) {
                HStack(spacing: Space.md) {
                    ReviewAvatar(agent: agent, size: ControlHeight.sm)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(agent.title).font(Typography.body.weight(.semibold))
                        Text(extra ? "Second seat" : Self.maker(of: seat.reviewer))
                            .font(Typography.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.appCheckbox)
            .accessibilityLabel("Ask \(agent.title)\(extra ? " on a second model" : "") by default")
            Spacer(minLength: 0)
            Group {
                modelMenu(seat.reviewer, at: index)
                effortMenu(seat.reviewer, at: index)
            }
            .disabled(!seat.on)
            .opacity(seat.on ? 1 : 0.45)
            .motion(Motion.control, value: seat.on)
            if extra {
                GlyphButton(icon: "xmark", side: ControlHeight.sm) {
                    seatMotion = Motion.leave
                    _ = defaults.seats.remove(at: index)
                    settingsNote("Removed the \(agent.title) seat", "minus")
                }
                .appTooltip("Remove this seat")
                .accessibilityLabel("Remove this \(agent.title) seat")
            } else {
                Color.clear.frame(width: ControlHeight.sm, height: ControlHeight.sm)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    static func maker(of reviewer: SecondOpinion.Reviewer) -> String {
        switch reviewer.agent {
        case .claudeCode: "Anthropic"
        case .codex: "OpenAI"
        case .copilot: reviewer.model == nil ? "Copilot picks the model" : "Several makers"
        }
    }

    private var addSeatRow: some View {
        HStack(spacing: Space.md) {
            AddSeatLabel()
                .appMenu {
                    installed.map { agent in
                        MenuEntry.item(agent.title, subtitle: "Starts on a model no seat of it uses yet") {
                            seatMotion = Motion.reveal
                            defaults.addSeat(agent, models: runner.modelOptions(for: agent).map(\.id), effort: nil)
                            settingsNote("Added a \(agent.title) seat", "plus")
                        }
                    }
                }
                .disabled(defaults.seats.count >= SecondOpinion.Reviewer.maxSeats || installed.isEmpty)
                .appTooltip(defaults.seats.count >= SecondOpinion.Reviewer.maxSeats
                            ? "Up to \(SecondOpinion.Reviewer.maxSeats) seats" : "Ask one agent on two models")
            Spacer(minLength: 0)
            Text("\(defaults.seats.count(where: \.on)) of \(defaults.seats.count) asked")
                .font(Typography.caption).foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .motion(Motion.pop, value: defaults.seats.count(where: \.on))
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    private func modelMenu(_ seat: SecondOpinion.Reviewer, at index: Int) -> some View {
        let title = seat.model.map { runner.modelTitle($0) } ?? "Default"
        return SeatPill { Text(title) }
            .appMenu {
                runner.modelOptions(for: seat.agent).map { option in
                    MenuEntry.item(option.title, checked: seat.model == option.id, subtitle: option.detail) {
                        guard defaults.seats.indices.contains(index) else { return }
                        defaults.seats[index].reviewer.model = option.id
                        defaults.seats[index].reviewer.effort = runner.validEffort(seat.effort, for: seat.agent,
                                                                                   model: option.id)
                    }
                }
            }
            .appTooltip("The model \(seat.agent.title) reviews on")
            .accessibilityLabel("\(seat.agent.title) model: \(title)")
    }

    private func effortMenu(_ seat: SecondOpinion.Reviewer, at index: Int) -> some View {
        let levels = runner.effortOptions(for: seat.agent, model: seat.model).compactMap(\.id)
        let title = seat.effort.map { runner.effortTitle($0, for: seat.agent, model: seat.model) } ?? "Default"
        func pick(_ effort: String?) {
            guard defaults.seats.indices.contains(index) else { return }
            defaults.seats[index].reviewer.effort = effort
        }
        return SeatPill {
            EffortMeter(lit: EffortMeter.lit(for: seat.effort, among: levels), height: 11)
            Text(title)
        }
        .appMenu {
            [MenuEntry.item("Default", meter: 0, checked: seat.effort == nil,
                            subtitle: "Whatever \(seat.agent.title) is set to use",
                            detail: "about \(SecondOpinion.minutes(for: nil)) min") { pick(nil) },
             .separator] + levels.map { level in
                MenuEntry.item(runner.effortTitle(level, for: seat.agent, model: seat.model),
                               meter: EffortMeter.lit(for: level, among: levels),
                               checked: seat.effort == level,
                               detail: "about \(SecondOpinion.minutes(for: level)) min") { pick(level) }
            }
        }
        .appTooltip("How long it thinks. More effort uses more of your plan.")
        .accessibilityLabel("\(seat.agent.title) effort: \(title)")
    }

    // MARK: Look for

    private var lookFor: some View {
        ChoiceBlock("LOOK FOR", note: "What starts ticked on each kind of ask. Pick at least one.") {
            SettingsCard {
                focusRow(.chat, title: "Answers and plans", detail: "From under an answer or a plan") {
                    ForEach(ChatSecondOpinion.Focus.allCases, id: \.self) { item in
                        ToggleChip(item.title, isOn: focusBinding(item, in: \.chatFocus, kind: .chat))
                    }
                }
                SettingsRowDivider()
                focusRow(.changes, title: "Code changes", detail: "From Changes or a file") {
                    ForEach(SecondOpinion.Focus.allCases, id: \.self) { item in
                        ToggleChip(item.title, isOn: focusBinding(item, in: \.changesFocus, kind: .changes))
                    }
                }
                SettingsRowDivider()
                focusRow(.design, title: "Designs", detail: "From a design canvas") {
                    ForEach(DesignSecondOpinion.Focus.allCases, id: \.self) { item in
                        ToggleChip(item.title, isOn: focusBinding(item, in: \.designFocus, kind: .design))
                    }
                }
            }
        }
    }

    private func focusRow(_ kind: SecondOpinionStop.Kind, title: String, detail: String,
                          @ViewBuilder chips: () -> some View) -> some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(Typography.body.weight(.semibold))
                Text(detail).font(Typography.detail).foregroundStyle(.secondary)
            }
            .frame(width: Self.subjectWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.sm) {
                FlowRow(spacing: Space.sm) { chips() }
                if keptFocus == kind {
                    Text("Keep at least one, or the ask has nothing to look for.")
                        .font(Typography.caption).foregroundStyle(Theme.attentionText)
                        .transition(reduceMotion ? .opacity : .fadeIn)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .motion(Motion.reveal, value: keptFocus)
        }
        .padding(Space.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func focusBinding<Item: Hashable>(_ item: Item, in path: WritableKeyPath<SecondOpinionDefaults, Set<Item>>,
                                              kind: SecondOpinionStop.Kind) -> Binding<Bool> {
        Binding(get: { defaults[keyPath: path].contains(item) }, set: { _ in
            guard let next = SecondOpinionDefaults.toggled(item, in: defaults[keyPath: path]) else {
                keptFocus = kind
                return
            }
            keptFocus = nil
            defaults[keyPath: path] = next
        })
    }

    // MARK: They read

    private var reading: some View {
        ChoiceBlock("THEY READ") {
            SettingsCard {
                SettingsToggleRow(
                    "Project files, for answers and plans",
                    detail: "They can open the files an answer talks about to check it. Code changes always read the changes and the project's files.",
                    isOn: $defaults.chatReading.files)
                    .padding(Space.lg)
                SettingsRowDivider()
                SettingsToggleRow(
                    "This conversation, for answers and plans",
                    detail: "Gives them the whole session. It also makes them think like the agent that wrote it, so they catch less.",
                    isOn: $defaults.chatReading.conversation, warns: true)
                    .padding(Space.lg)
                SettingsRowDivider()
                SettingsToggleRow(
                    "HTML, handoff and theme, for designs",
                    detail: "Every screen is always sent as a picture, light and dark. This adds the files behind it.",
                    isOn: $defaults.designReading.source)
                    .padding(Space.lg)
                SettingsRowDivider()
                SettingsToggleRow(
                    "The design conversation",
                    detail: "Shows them how the design was asked for. Like the session, it pulls them toward the author's view.",
                    isOn: $defaults.designReading.conversation, warns: true)
                    .padding(Space.lg)
            }
        }
    }

    // MARK: Access

    private var access: some View {
        ChoiceBlock("ACCESS") {
            SettingsCard {
                HStack(alignment: .top, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("Read files, never change them").font(Typography.body.weight(.semibold))
                        Text("Reviewers can open any file in the project. They cannot edit, run commands that write, or reach the session's agent until you send what they said.")
                            .font(Typography.detail).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Label("Always", systemImage: "lock.fill")
                        .font(Typography.caption).foregroundStyle(.secondary)
                }
                .padding(Space.lg)
                .accessibilityElement(children: .combine)
                SettingsRowDivider()
                VStack(alignment: .leading, spacing: Space.md) {
                    SettingsToggleRow(
                        "Use your MCP servers",
                        detail: "Reviewers get the same MCP servers your sessions use, so they can check what the work assumes against logs, dashboards or docs. Off, they only see the files and what you send.",
                        isOn: Binding(get: { defaults.usesServers }, set: { on in
                            defaults.usesServers = on
                            settingsNote(on ? "Reviewers will use your MCP servers"
                                            : "Reviewers run without MCP servers", on ? "server.rack" : "checkmark")
                        }),
                        warns: true)
                    if defaults.usesServers {
                        serverDetails.transition(reduceMotion ? .opacity : .fold)
                    }
                }
                .padding(Space.lg)
                .motion(defaults.usesServers ? Motion.reveal : Motion.leave, value: defaults.usesServers)
            }
        }
    }

    // The servers a reviewer would get, as the agents last reported them. One that
    // needs signing in cannot answer a reviewer, so it is shown dimmed.
    private var servers: [(name: String, ready: Bool)] {
        let names = Set(configs.servers.filter { !$0.disabled }.map(\.name)).union(claude.entries.keys)
        return names.sorted().map { ($0, claude.health[$0] != .needsSignIn) }
    }

    private var serverDetails: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if servers.isEmpty {
                Text("You have no MCP servers yet. Add them under Tools, MCP servers.")
                    .font(Typography.caption).foregroundStyle(.secondary)
            } else {
                FlowRow(spacing: Space.sm) {
                    ForEach(servers, id: \.name) { server in
                        HStack(spacing: Space.xs) {
                            Circle().fill(server.ready ? Theme.dotOn : Theme.dotOff)
                                .frame(width: Space.sm, height: Space.sm)
                            Text(server.name).font(Typography.data)
                        }
                        .padding(.horizontal, Space.sm)
                        .frame(height: ControlHeight.xs)
                        .background(Capsule().fill(Theme.sunken))
                        .opacity(server.ready ? 1 : 0.55)
                        .appTooltip(server.ready ? "Reviewers can use it" : "Needs signing in. Reviewers skip it.")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(server.name + (server.ready ? "" : ", needs signing in, skipped"))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Servers reviewers would get")
            }
            HStack(alignment: .top, spacing: Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Reviewers only run the tools a server marks read-only. That mark is the server's own word, so keep this on only for servers you trust to set it right.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .warningCard()
            .accessibilityElement(children: .combine)
        }
    }
}

// The words of an InlineLink for a control that opens a menu. The menu supplies the
// button, so this draws only the label and answers the pointer.
private struct AddSeatLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "plus").font(Typography.caption.weight(.semibold))
            Text("Add a seat on another model").font(Typography.label)
        }
        .foregroundStyle(isEnabled ? Theme.accent : Color.secondary)
        .opacity(hovering ? 0.75 : 1)
        .fixedSize()
        .contentShape(Rectangle())
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
    }
}
