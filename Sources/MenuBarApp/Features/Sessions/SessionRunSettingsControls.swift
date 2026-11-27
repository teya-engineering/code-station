import SwiftUI

// The settings for the next turn are shared by Chat and Design. Both surfaces use this
// view so a choice has the same meaning and follows the same app default in either mode.
//
// Each control shows its own state rather than only its name: the agent by its tile, the
// model by name, the effort as a meter, and how much the agent asks before it acts as a
// shield coloured by how far it is trusted. Design adds how far the look is pushed, which
// means nothing to a Chat turn and so is only shown there.
//
// The agent, model and effort only change between turns, so a turn never runs on mixed
// settings. While one runs they are locked: a click opens a note on why and when they
// unlock, with a way to stop the turn or have the menu open once it ends.
struct SessionRunSettingsControls: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.keyBindings) private var keyBindings

    let sessionID: UUID
    var wraps = false
    var showsDesignAmbition = false
    // Only one composer on screen answers the keys that open these menus.
    var takesShortcuts = false

    enum Locked: Hashable { case agent, model, effort }

    @State private var opens: [Locked: Int] = [:]
    @State private var unlockWave = 0
    @State private var flashes: [Locked: Int] = [:]

    var body: some View {
        if let session = store.session(sessionID) {
            let agent = session.agent
            let locked = runner.state(sessionID).isBusy
            let layout = wraps ? AnyLayout(FlowRow(spacing: Space.md)) : AnyLayout(HStackLayout(spacing: Space.md))
            layout {
                agentControl(session, locked: locked)
                    .unlockWave(unlockWave, index: 0)
                modelControl(session, lastRan: session.usage?.model(for: agent), locked: locked)
                    .unlockWave(unlockWave, index: 1)
                if agent.choosesEffort {
                    effortControl(session, locked: locked)
                        .unlockWave(unlockWave, index: 2)
                }
                switch agent {
                case .claudeCode, .kiro: permissionsControl(agent: agent)
                case .codex: codexAccessControl(agent: agent)
                case .copilot: copilotAccessControl(agent: agent)
                }
                if showsDesignAmbition { ambitionControl }
            }
            .background { if takesShortcuts { shortcutKeys } }
            .task(id: agent) { await runner.catalog.discoverModels(for: agent) }
            .onChange(of: locked) { wasLocked, nowLocked in
                guard wasLocked, !nowLocked else { return }
                unlockWave += 1
            }
            .onChange(of: agent) { _, _ in
                flashes[.agent, default: 0] += 1
            }
        }
    }

    private var shortcutKeys: some View {
        ZStack {
            Button("") { opens[.agent, default: 0] += 1 }.appShortcut(.switchAgent)
            Button("") { opens[.model, default: 0] += 1 }.appShortcut(.changeModel)
            Button("") { opens[.effort, default: 0] += 1 }.appShortcut(.changeEffort)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var sessionSettings: SessionSettings {
        store.session(sessionID)?.settings ?? SessionSettings()
    }

    private func changeSettings(_ edit: (inout SessionSettings) -> Void) {
        var updated = sessionSettings
        edit(&updated)
        store.setSettings(updated, for: sessionID)
    }

    // MARK: - Agent

    // Design and diagnosis turns are written for the agent they started on, so only a
    // plain Chat session can move to another agent.
    private func canSwitchAgent(_ session: ChatSession) -> Bool {
        session.mode == .chat && !session.isDesignSession && !session.isTroubleshooting
    }

    @ViewBuilder private func agentControl(_ session: ChatSession, locked: Bool) -> some View {
        let agent = session.agent
        if canSwitchAgent(session) {
            AgentChip(agent: agent, locked: locked)
                .landingRings(flashes[.agent], colour: agent.tint, cornerRadius: ControlHeight.md, reach: 1.25)
                .appMenu(edge: .top, opens: opens[.agent] ?? 0) {
                    runner.state(sessionID).isBusy ? waitEntries() : agentEntries()
                }
                .appTooltip(locked ? lockedHelp("agent")
                                   : keyBindings.tooltip("Switch agent", for: .switchAgent))
                .accessibilityLabel("Agent: \(agent.title)\(agent.isBeta ? ", beta" : "")")
                .accessibilityHint(locked ? lockedHelp("agent") : "Opens the agents this session can continue in.")
        } else {
            AgentPill(agent: agent)
                .appTooltip(["This session always runs on \(agent.title).", agent.betaNote]
                    .compactMap { $0 }.joined(separator: " "))
                .accessibilityLabel("Agent: \(agent.title)\(agent.isBeta ? ", beta" : "")")
        }
    }

    private func agentEntries() -> [MenuEntry] {
        guard let session = store.session(sessionID) else { return [] }
        let agent = session.agent
        let used = session.agentsUsed
        let others = AgentKind.allCases.filter { $0 != agent && runner.catalog.isAvailable($0) }
        guard !others.isEmpty else {
            return [.note("No other agent is installed, so this session can only run on \(agent.title).")]
        }
        var entries: [MenuEntry] = [.heading("Continue this session in")]
        for other in others {
            let returning = used.contains(other)
            entries.append(.item(
                other.title, icon: other.symbol, iconTint: other.tint,
                badge: returning ? "BACK" : other.isBeta ? "BETA" : nil, badgeTint: other.tint,
                subtitle: AgentSwitch.blurb(for: other, returning: returning)) {
                    AgentSwitchDialog.open(other, in: sessionID, store: store, runner: runner,
                                           dialogs: dialogs)
                })
        }
        return entries
    }

    // MARK: - Waiting for the turn

    private func lockedHelp(_ word: String) -> String {
        "You can change the \(word) when this turn ends."
    }

    private func waitEntries() -> [MenuEntry] {
        guard let session = store.session(sessionID) else { return [] }
        return [
            .note("\(AgentSwitch.shortName(of: session.agent)) is still working."),
            .item("Stop the turn", kind: .destructive, icon: "stop.fill") {
                runner.stop(sessionID)
            },
        ]
    }

    // MARK: - Model

    private func modelControl(_ session: ChatSession, lastRan: String?, locked: Bool) -> some View {
        let agent = session.agent
        let model = runner.catalog.validModel(sessionSettings.model, for: agent)
        let choose = { (id: String?) in chooseModel(id, for: session) }
        let title = model.map { runner.catalog.modelTitle($0) }
            ?? lastRan.map { ModelChoice.shortName(of: $0) }
            ?? "Default"
        let help = "The model this session will use for its next turn."

        return ModelPill(title: title, locked: locked)
            .landingRings(flashes[.model], colour: Theme.brand, cornerRadius: ControlHeight.md, reach: 1.25)
            .appMenu(edge: .top, opens: opens[.model] ?? 0) {
                if runner.state(sessionID).isBusy { return waitEntries() }
                var entries: [MenuEntry] = [
                    .heading("\(agent.title) model"),
                    .item("Use \(agent.title) default", checked: model == nil) { choose(nil) },
                    .separator,
                ]
                entries += runner.catalog.modelOptions(for: agent).compactMap { option in
                    option.id.map { id in
                        MenuEntry.item(option.title, checked: model == id,
                                       subtitle: option.detail) { choose(id) }
                    }
                }
                entries.append(.note("Used from your next prompt. The conversation carries on as it is, though a different model may not reuse the cached context."))
                return entries
            }
            .appTooltip(locked ? lockedHelp("model")
                        : model == nil ? keyBindings.tooltip(help, for: .changeModel)
                        : keyBindings.tooltip("\(help) Overridden for this session.", for: .changeModel))
            .accessibilityLabel("Model: \(title)")
            .accessibilityHint(locked ? lockedHelp("model") : "")
    }

    private func chooseModel(_ model: String?, for session: ChatSession) {
        let current = runner.catalog.validModel(sessionSettings.model, for: session.agent)
        guard model != current, !runner.state(sessionID).isBusy else { return }
        setModel(model, for: session.agent)
        flashes[.model, default: 0] += 1
        let title = model.map { runner.catalog.modelTitle($0) } ?? "the \(session.agent.title) default"
        mark(.model, value: model.map { runner.catalog.modelTitle($0) } ?? "\(session.agent.title) default",
             text: "Model changed to \(title).")
    }

    private func setModel(_ model: String?, for agent: AgentKind) {
        changeSettings {
            $0.model = model
            if let effort = $0.effort,
               runner.catalog.validEffort(effort, for: agent, model: model) == nil {
                $0.effort = nil
            }
        }
    }

    // A change made between turns is marked where the next turn will start, so the
    // transcript says which settings each turn ran on. A session with nothing in it yet has
    // no turn to set the change against.
    private func mark(_ kind: SettingsMarker.Kind, value: String, text: String) {
        guard let session = store.session(sessionID),
              !store.transcript(of: sessionID).isEmpty else { return }
        var message = ChatMessage(role: .system, text: text)
        message.marker = SettingsMarker(kind: kind, agent: session.agent, value: value)
        store.append(message, to: sessionID)
    }

    // MARK: - Effort

    @ViewBuilder private func effortControl(_ session: ChatSession, locked: Bool) -> some View {
        let agent = session.agent
        let settings = sessionSettings
        let model = runner.catalog.validModel(settings.model, for: agent)
        let levels = runner.catalog.effortOptions(for: agent, model: model).compactMap(\.id)
        // An agent with no effort setting gets no control for one, rather than one that
        // can only ever say Default.
        if !levels.isEmpty {
            let override = runner.catalog.validEffort(settings.effort, for: agent, model: model)
            let appDefault = runner.catalog.validEffort(runner.catalog.defaults(for: agent).effort,
                                                        for: agent, model: model)
            let chosen = override ?? appDefault
            let title = chosen.map { runner.catalog.effortTitle($0, for: agent, model: model) } ?? "Default"
            let inheritedEffort = appDefault.map { runner.catalog.effortTitle($0, for: agent, model: model) }
                ?? "\(agent.title) settings"
            let help = "How long the model thinks before it answers. Inherit Code Station's default, or choose a level for this run."

            EffortPill(title: title, lit: EffortMeter.lit(for: chosen, among: levels), locked: locked)
                .landingRings(flashes[.effort], colour: Theme.brand, cornerRadius: ControlHeight.md, reach: 1.25)
                .appMenu(edge: .top, opens: opens[.effort] ?? 0) {
                    if runner.state(sessionID).isBusy { return waitEntries() }
                    var entries: [MenuEntry] = [
                        .heading("Effort"),
                        .item("Use Code Station default (\(inheritedEffort))",
                              meter: EffortMeter.lit(for: appDefault, among: levels),
                              checked: override == nil) {
                            chooseEffort(nil, agent: agent, model: model, appDefault: appDefault)
                        },
                        .separator,
                    ]
                    entries += levels.map { level in
                        MenuEntry.item(runner.catalog.effortTitle(level, for: agent, model: model),
                                       meter: EffortMeter.lit(for: level, among: levels),
                                       checked: override == level) {
                            chooseEffort(level, agent: agent, model: model, appDefault: appDefault)
                        }
                    }
                    entries.append(.note("Used from your next prompt."))
                    return entries
                }
                .appTooltip(locked ? lockedHelp("effort")
                            : keyBindings.tooltip(override != nil ? "\(help) Overridden for this session." : help,
                                                  for: .changeEffort))
                .accessibilityLabel("Effort: \(title)")
                .accessibilityHint(locked ? lockedHelp("effort") : "")
        }
    }

    private func chooseEffort(_ level: String?, agent: AgentKind, model: String?, appDefault: String?) {
        let override = runner.catalog.validEffort(sessionSettings.effort, for: agent, model: model)
        guard level != override, !runner.state(sessionID).isBusy else { return }
        let before = override ?? appDefault
        changeSettings { $0.effort = level }
        let after = level ?? appDefault
        guard before != after else { return }
        flashes[.effort, default: 0] += 1
        let title = after.map { runner.catalog.effortTitle($0, for: agent, model: model) } ?? "the default"
        mark(.effort, value: title, text: "Effort changed to \(title).")
    }

    // MARK: - Design ambition

    private var ambitionControl: some View {
        let override = sessionSettings.designAmbition
        let appDefault = appSettings.designAmbition
        let selected = override ?? appDefault
        let help = "How far the design pushes the look. Takes effect from the next turn."

        return AmbitionPill(ambition: selected)
            .appMenu(edge: .top) {
                var entries: [MenuEntry] = [
                    .item("Use Code Station default (\(appDefault.title))",
                          icon: "paintbrush.pointed", iconTint: appDefault.tint,
                          checked: override == nil) {
                        changeSettings { $0.designAmbition = nil }
                    },
                    .separator,
                ]
                entries += DesignAmbition.allCases.map { ambition in
                    MenuEntry.item(ambition.title, icon: "paintbrush.pointed",
                                   iconTint: ambition.tint,
                                   checked: override == ambition,
                                   subtitle: ambition.detail) {
                        changeSettings { $0.designAmbition = ambition }
                    }
                }
                return entries
            }
            .appTooltip(override != nil ? "\(help) Overridden for this session." : help)
            .accessibilityLabel("Design ambition: \(selected.title)")
    }

    // MARK: - Asks before

    private func permissionsControl(agent: AgentKind) -> some View {
        let settings = sessionSettings
        let defaults = runner.catalog.defaults(for: agent)
        let selected = (settings.permissionMode ?? defaults.permissionMode ?? .fallback)
        let appDefault = (defaults.permissionMode ?? .fallback)
        return shieldControl(
            tone: TrustTone(selected),
            title: selected.shortTitle,
            overridden: settings.permissionMode != nil,
            help: "How much the agent asks before it acts.",
            defaultEntry: (title: defaultTitle(appDefault.shortTitle), tone: TrustTone(appDefault)),
            options: PermissionMode.choices(for: agent).map {
                ShieldOption(id: $0, title: $0.shortTitle, detail: $0.title,
                             tone: TrustTone($0))
            },
            selection: Binding(get: { settings.permissionMode },
                               set: { mode in changeSettings { $0.permissionMode = mode } }))
    }

    private func codexAccessControl(agent: AgentKind) -> some View {
        let settings = sessionSettings
        let override = settings.codexSandboxMode
        let appDefault = (runner.catalog.defaults(for: agent).codexSandboxMode ?? .workspaceWrite)
        let selected = override ?? appDefault
        return shieldControl(
            tone: TrustTone(selected),
            title: selected.summary,
            overridden: override != nil,
            help: selected.detail,
            defaultEntry: (title: defaultTitle(appDefault.title), tone: TrustTone(appDefault)),
            options: CodexSandboxMode.allCases.map {
                ShieldOption(id: $0, title: $0.title,
                             detail: $0 == .fullAccess ? Self.unrestricted : nil,
                             tone: TrustTone($0))
            },
            selection: Binding(get: { override },
                               set: { value in changeSettings { $0.codexSandboxMode = value } }))
    }

    private func copilotAccessControl(agent: AgentKind) -> some View {
        let settings = sessionSettings
        let override = settings.copilotAccessMode
        let appDefault = (runner.catalog.defaults(for: agent).copilotAccessMode ?? .workspace)
        let selected = override ?? appDefault
        return shieldControl(
            tone: TrustTone(selected),
            title: selected.summary,
            overridden: override != nil,
            help: selected.detail,
            defaultEntry: (title: defaultTitle(appDefault.title), tone: TrustTone(appDefault)),
            options: CopilotAccessMode.allCases.map {
                ShieldOption(id: $0, title: $0.title,
                             detail: $0 == .fullAccess ? Self.unrestricted : nil,
                             tone: TrustTone($0))
            },
            selection: Binding(get: { override },
                               set: { value in changeSettings { $0.copilotAccessMode = value } }))
    }

    private static let unrestricted = "No file, service, or network restrictions."

    private struct ShieldOption<Choice: Hashable> {
        let id: Choice
        let title: String
        let detail: String?
        let tone: TrustTone
    }

    private func defaultTitle(_ resolved: String?) -> String {
        resolved.map { "Use the default (\($0))" } ?? "Use the default"
    }

    private func shieldControl<Choice: Hashable>(tone: TrustTone, title: String, overridden: Bool, help: String,
                               defaultEntry: (title: String, tone: TrustTone),
                               options: [ShieldOption<Choice>],
                               selection: Binding<Choice?>) -> some View {
        ShieldPill(tone: tone, title: title)
            .appMenu(edge: .top) {
                var entries: [MenuEntry] = [
                    .item(defaultEntry.title, icon: "shield", iconTint: defaultEntry.tone.ink,
                          checked: selection.wrappedValue == nil) {
                        selection.wrappedValue = nil
                    },
                    .separator,
                ]
                entries += options.map { option in
                    MenuEntry.item(option.title,
                                   kind: option.tone == .unrestricted ? .destructive : .plain,
                                   icon: "shield", iconTint: option.tone.ink,
                                   checked: selection.wrappedValue == option.id,
                                   subtitle: option.detail) {
                        selection.wrappedValue = option.id
                    }
                }
                return entries
            }
            .appTooltip(overridden ? "\(help) Overridden for this session." : help)
            .accessibilityLabel("Asks before: \(title)")
    }
}

// MARK: - Agent

// A session that cannot change its agent shows it on the same capsule as the controls
// beside it, but drawn as an outline, with no chevron and no answer to the pointer.
private struct AgentPill: View {
    let agent: AgentKind

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: agent.symbol)
                .font(Typography.label)
                .foregroundStyle(.secondary)
            Text(agent.title)
                .font(Typography.label)
                .foregroundStyle(.secondary)
            if agent.isBeta { BetaChip() }
        }
        .lineLimit(1)
        .padding(.horizontal, Space.md)
        .frame(height: ControlHeight.md)
        .overlay(Capsule().strokeBorder(Theme.border))
        .contentShape(Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
    }
}

// The agent on its own tile and colour. Locked, the tile greys out and the words go quiet.
private struct AgentChip: View {
    let agent: AgentKind
    let locked: Bool

    var body: some View {
        BarPill {
            HStack(spacing: Space.sm) {
                ReviewAvatar(agent: agent, size: ControlHeight.xs - Space.xs, muted: locked)
                RollingText(agent.title, font: Typography.label)
                    .foregroundStyle(locked ? .secondary : .primary)
                if agent.isBeta { BetaChip() }
                LockChevron(locked: locked)
            }
        }
        .motion(Motion.reveal, value: locked)
    }
}

// MARK: - Design ambition

// Each level has its own colour, quiet to loud like the shield: Restrained stays plain,
// Balanced takes the house green, and All out turns violet, so a session set to go big
// shows it at a glance.
extension DesignAmbition {
    var tint: Color {
        switch self {
        case .restrained: Color(nsColor: .secondaryLabelColor)
        case .balanced: Theme.accent
        case .allOut: Theme.showcase
        }
    }

    var pillFill: Color {
        switch self {
        case .restrained: Theme.field
        case .balanced: Theme.accent.opacity(0.14)
        case .allOut: Theme.showcase.opacity(0.14)
        }
    }

    // The words on the pill. A plain pill keeps them in the body colour, since grey text
    // would read as a control that is switched off.
    var pillInk: Color {
        self == .restrained ? Color(nsColor: .labelColor) : tint
    }
}

private struct AmbitionPill: View {
    let ambition: DesignAmbition

    // The level as it was before this change, so the word rolls up as the ambition rises
    // and down as it falls.
    @State private var previous: DesignAmbition?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BarPill(fill: ambition.pillFill) {
            HStack(spacing: Space.sm) {
                Image(systemName: "paintbrush.pointed")
                    .font(Typography.label)
                    .foregroundStyle(ambition.tint)
                    // On the glyph rather than the pill, for the same reason as the shield.
                    .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? nil : ambition) { glyph, scale in
                        glyph.scaleEffect(scale)
                    } keyframes: { _ in
                        SpringKeyframe(1.25, duration: 0.15)
                        SpringKeyframe(1.0, duration: 0.23, spring: .bouncy)
                    }
                RollingText(ambition.title, rising: rank(ambition) >= rank(previous ?? ambition),
                            font: Typography.label)
                    .foregroundStyle(ambition.pillInk)
                MenuChevron(size: 8, tint: ambition == .restrained ? .secondary : ambition.tint.opacity(0.7))
            }
        }
        .motion(Motion.pop, value: ambition)
        .onChange(of: ambition, initial: true) { _, now in previous = now }
    }

    private func rank(_ ambition: DesignAmbition) -> Int {
        DesignAmbition.allCases.firstIndex(of: ambition) ?? 0
    }
}

// Says on the right of the composer bar why the agent, model and effort cannot be changed
// while a turn runs, and when they can. Between turns it names the key for switching.
struct RunSettingsLockHint: View {
    let agent: AgentKind
    let locked: Bool
    var canSwitch = true

    @Environment(\.keyBindings) private var keyBindings

    var body: some View {
        Group {
            if locked {
                Label("Unlocks when \(AgentSwitch.shortName(of: agent)) finishes", systemImage: "lock")
                    .id("locked")
            } else if canSwitch, let keys = keyBindings.keys(for: .switchAgent) {
                HStack(spacing: Space.xs) {
                    Keycap(keys.compactLabel)
                    Text("switch agent")
                }
                .id("unlocked")
            }
        }
        .font(Typography.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        // The hint is the first thing to give way when the bar is short of room.
        .layoutPriority(-1)
        .transition(.opacity.combined(with: .offset(y: Space.xs)))
        .motion(Motion.reveal, value: locked)
        .accessibilityElement(children: .combine)
    }
}
