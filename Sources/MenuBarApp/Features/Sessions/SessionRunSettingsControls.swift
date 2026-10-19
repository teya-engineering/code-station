import SwiftUI
import CodeStationCore

// The settings for the next turn are shared by Chat and Design. Both surfaces use this
// view so a choice has the same meaning and follows the same app default in either mode.
//
// Each control shows its own state rather than only its name: the model by name, the
// effort as a meter, and how much the agent asks before it acts as a shield coloured by
// how far it is trusted. Design adds how far the look is pushed, which means nothing to a
// Chat turn and so is only shown there.
struct SessionRunSettingsControls: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings

    let sessionID: UUID
    var wraps = false
    var showsDesignAmbition = false

    var body: some View {
        if let session = store.session(sessionID) {
            let agent = session.agent
            let layout = wraps ? AnyLayout(FlowRow(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                AgentPill(agent: agent)
                    .appTooltip("This session always runs on \(agent.title).")
                    .accessibilityLabel("Agent: \(agent.title)")
                modelControl(session, lastRan: session.usage?.model(for: agent))
                effortControl(agent: agent)
                switch agent {
                case .claudeCode: permissionsControl(agent: agent)
                case .codex: codexAccessControl(agent: agent)
                case .copilot: copilotAccessControl(agent: agent)
                }
                if showsDesignAmbition { ambitionControl }
            }
            .task(id: agent) { await runner.discoverModels(for: agent) }
        }
    }

    private var sessionSettings: SessionSettings {
        store.session(sessionID)?.settings ?? SessionSettings()
    }

    private func changeSettings(_ edit: (inout SessionSettings) -> Void) {
        var updated = sessionSettings
        edit(&updated)
        store.setSettings(updated, for: sessionID)
    }

    // MARK: - Model

    private func modelControl(_ session: ChatSession, lastRan: String?) -> some View {
        let agent = session.agent
        let model = runner.validModel(sessionSettings.model, for: agent)
        let choose = { (id: String?) in chooseModel(id, for: session, lastRan: lastRan) }
        let title = model.map { runner.modelTitle($0) }
            ?? lastRan.map { ModelChoice.shortName(of: $0) }
            ?? "Default"
        let help = "The model this session will use for its next turn."

        return ModelPill(title: title)
            .appMenu(edge: .top) {
                var entries: [MenuEntry] = [
                    .item("Use \(agent.title) default", checked: model == nil) { choose(nil) },
                    .separator,
                ]
                entries += runner.modelOptions(for: agent).compactMap { option in
                    option.id.map { id in
                        MenuEntry.item(option.title, checked: model == id,
                                       subtitle: option.detail) { choose(id) }
                    }
                }
                return entries
            }
            .appTooltip(model == nil ? help : "\(help) Overridden for this session.")
            .accessibilityLabel("Model: \(title)")
    }

    private func chooseModel(_ model: String?, for session: ChatSession, lastRan: String?) {
        let current = runner.validModel(sessionSettings.model, for: session.agent)
        guard model != current else { return }
        guard session.hasAgentConversation else {
            setModel(model, for: session.agent)
            return
        }

        let currentTitle = current.map { runner.modelTitle($0) }
            ?? lastRan.map { ModelChoice.shortName(of: $0) }
            ?? "the \(session.agent.title) default"
        let nextTitle = model.map { runner.modelTitle($0) }
            ?? "the \(session.agent.title) default"
        dialogs.show(.confirm(
            "Change from \(currentTitle) to \(nextTitle)?",
            message: "The next turn will resume this conversation using \(nextTitle). "
                + "The conversation and files stay in place. If this selects a different "
                + "model, cached context may not carry over, so processing the existing "
                + "context can use more input tokens.",
            action: "Change model", kind: .primary) {
                setModel(model, for: session.agent)
            })
    }

    private func setModel(_ model: String?, for agent: AgentKind) {
        changeSettings {
            $0.model = model
            if let effort = $0.effort,
               runner.validEffort(effort, for: agent, model: model) == nil {
                $0.effort = nil
            }
        }
    }

    // MARK: - Effort

    private func effortControl(agent: AgentKind) -> some View {
        let settings = sessionSettings
        let model = runner.validModel(settings.model, for: agent)
        let override = runner.validEffort(settings.effort, for: agent, model: model)
        let appDefault = runner.validEffort(runner.defaults(for: agent).effort,
                                            for: agent, model: model)
        let chosen = override ?? appDefault
        let levels = runner.effortOptions(for: agent, model: model).compactMap(\.id)
        let title = chosen.map { runner.effortTitle($0, for: agent, model: model) } ?? "Default"
        let inheritedEffort = appDefault.map { runner.effortTitle($0, for: agent, model: model) }
            ?? "\(agent.title) settings"
        let help = "How long the model thinks before it answers. Inherit Code Station's default, or choose a level for this run."

        return EffortPill(title: title, lit: EffortMeter.lit(for: chosen, among: levels))
            .appMenu(edge: .top) {
                var entries: [MenuEntry] = [
                    .item("Use Code Station default (\(inheritedEffort))",
                          meter: EffortMeter.lit(for: appDefault, among: levels),
                          checked: override == nil) {
                        changeSettings { $0.effort = nil }
                    },
                    .separator,
                ]
                entries += levels.map { level in
                    MenuEntry.item(runner.effortTitle(level, for: agent, model: model),
                                   meter: EffortMeter.lit(for: level, among: levels),
                                   checked: override == level) {
                        changeSettings { $0.effort = level }
                    }
                }
                return entries
            }
            .appTooltip(override != nil ? "\(help) Overridden for this session." : help)
            .accessibilityLabel("Effort: \(title)")
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
        let defaults = runner.defaults(for: agent)
        let selected = (settings.permissionMode ?? defaults.permissionMode ?? .fallback)
        let appDefault = (defaults.permissionMode ?? .fallback)
        return shieldControl(
            tone: TrustTone(selected),
            title: selected.shortTitle,
            overridden: settings.permissionMode != nil,
            help: "How much the agent asks before it acts.",
            defaultEntry: (title: defaultTitle(appDefault.shortTitle), tone: TrustTone(appDefault)),
            options: PermissionMode.allCases.map {
                ShieldOption(id: $0, title: $0.shortTitle, detail: $0.title,
                             tone: TrustTone($0))
            },
            selection: Binding(get: { settings.permissionMode },
                               set: { mode in changeSettings { $0.permissionMode = mode } }))
    }

    private func codexAccessControl(agent: AgentKind) -> some View {
        let settings = sessionSettings
        let override = settings.codexSandboxMode
        let appDefault = (runner.defaults(for: agent).codexSandboxMode ?? .workspaceWrite)
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
        let appDefault = (runner.defaults(for: agent).copilotAccessMode ?? .workspace)
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

// The agent is fixed for the life of a session, so it sits on the same capsule as the
// controls beside it but drawn as an outline, with no chevron and no answer to the pointer.
private struct AgentPill: View {
    let agent: AgentKind

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: agent.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(agent.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay(Capsule().strokeBorder(Theme.border))
        .contentShape(Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
    }
}

// MARK: - Model

private struct ModelPill: View {
    let title: String

    var body: some View {
        BarPill {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                RollingText(title, font: .system(size: 12, weight: .semibold))
                MenuChevron(size: 8)
            }
        }
    }
}

// MARK: - Effort

// Four bars, lit from the left as the level rises. Each bar changes on its own beat, in
// the direction the level moved, so the meter visibly fills up or drains down.
struct EffortMeter: View {
    let lit: Int
    var height: CGFloat = 14

    @State private var previous: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let bars = 4

    // How many bars a level lights. No choice lights none; the lowest level lights one
    // and the highest all four, with whatever lies between spread evenly across them, so
    // an agent with five levels and one with three both read on the same scale.
    static func lit(for level: String?, among levels: [String]) -> Int {
        guard let level, let index = levels.firstIndex(of: level) else { return 0 }
        guard levels.count > 1 else { return bars }
        let share = Double(index) / Double(levels.count - 1)
        return 1 + Int((share * Double(bars - 1)).rounded())
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: height * 0.18) {
            ForEach(0..<Self.bars, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(bar < lit ? Theme.accent : Theme.settingsBorder)
                    .frame(width: height * 0.28, height: barHeight(bar))
                    .animation(reduceMotion ? nil : Motion.pop.delay(delay(of: bar)), value: lit)
            }
        }
        .frame(height: height, alignment: .bottom)
        .onChange(of: lit, initial: true) { _, now in previous = now }
        .accessibilityHidden(true)
    }

    // The bars climb from a quarter of the meter's height to all of it.
    private func barHeight(_ bar: Int) -> CGFloat {
        let share = CGFloat(bar + 1) / CGFloat(Self.bars)
        return height * (0.25 + 0.75 * share)
    }

    private func delay(of bar: Int) -> Double {
        let from = previous ?? lit
        let step = lit > from ? bar - from : from - 1 - bar
        return Double(max(0, step)) * 0.04
    }
}

private struct EffortPill: View {
    let title: String
    let lit: Int

    // The level as it was before this change, read while the change is being drawn so
    // the word knows which way to roll.
    @State private var previous: Int?

    var body: some View {
        BarPill {
            HStack(spacing: 7) {
                EffortMeter(lit: lit)
                RollingText(title, rising: lit >= (previous ?? lit),
                            font: .system(size: 12, weight: .semibold))
                MenuChevron(size: 8)
            }
        }
        .onChange(of: lit, initial: true) { _, now in previous = now }
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
            HStack(spacing: 6) {
                Image(systemName: "paintbrush.pointed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ambition.tint)
                    // On the glyph rather than the pill, for the same reason as the shield.
                    .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? nil : ambition) { glyph, scale in
                        glyph.scaleEffect(scale)
                    } keyframes: { _ in
                        SpringKeyframe(1.25, duration: 0.15)
                        SpringKeyframe(1.0, duration: 0.23, spring: .bouncy)
                    }
                RollingText(ambition.title, rising: rank(ambition) >= rank(previous ?? ambition),
                            font: .system(size: 12, weight: .semibold))
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

// MARK: - Asks before

// How far the agent is trusted to act without asking, as the colour of its shield. Green
// asks before everything, plain only asks about risky steps, amber lets edits through,
// and blue changes nothing at all. Red is kept for access with no limits whatever.
enum TrustTone: Equatable {
    case asksEverything
    case risky
    case allowsEdits
    case plans
    case unrestricted

    init(_ mode: PermissionMode) {
        self = switch mode {
        case .manual: .asksEverything
        case .auto: .risky
        case .acceptEdits: .allowsEdits
        case .plan: .plans
        }
    }

    init(_ mode: CodexSandboxMode) {
        self = switch mode {
        case .workspaceWrite: .risky
        case .approveForMe: .allowsEdits
        case .fullAccess: .unrestricted
        }
    }

    init(_ mode: CopilotAccessMode) {
        self = switch mode {
        case .workspace: .allowsEdits
        case .fullAccess: .unrestricted
        }
    }

    var ink: Color {
        switch self {
        case .asksEverything: Theme.addition
        case .risky: .primary
        case .allowsEdits: Theme.attentionText
        case .plans: Theme.plan
        // The red read as words, which has to carry on its own tint in dark mode.
        case .unrestricted: Theme.warningText
        }
    }

    var fill: Color {
        switch self {
        case .asksEverything: Theme.addition.opacity(0.14)
        case .risky: Theme.field
        case .allowsEdits: Theme.attention.opacity(0.18)
        case .plans: Theme.plan.opacity(0.14)
        case .unrestricted: Theme.deletion.opacity(0.14)
        }
    }
}

private struct ShieldPill: View {
    let tone: TrustTone
    let title: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BarPill(fill: tone.fill) {
            HStack(spacing: 6) {
                Image(systemName: "shield")
                    .font(.system(size: 12, weight: .semibold))
                    // The swell is on the glyph inside the label: the pill around it hosts
                    // AppKit views that cannot be laid out under a transform.
                    .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? nil : tone) { glyph, scale in
                        glyph.scaleEffect(scale)
                    } keyframes: { _ in
                        SpringKeyframe(1.25, duration: 0.15)
                        SpringKeyframe(1.0, duration: 0.23, spring: .bouncy)
                    }
                RollingText(title, font: .system(size: 12, weight: .semibold))
                MenuChevron(size: 8, tint: tone.ink.opacity(0.7))
            }
            .foregroundStyle(tone.ink)
        }
        .motion(Motion.pop, value: tone)
    }
}

// MARK: - Shared pieces

// The rounded pill every menu control on the bar is drawn on, so they share one height
// and one way of answering the pointer.
struct BarPill<Content: View>: View {
    var fill: Color = Theme.field
    @ViewBuilder let content: Content

    @State private var hovering = false
    @Environment(\.menuIsOpen) private var open

    init(fill: Color = Theme.field, @ViewBuilder content: () -> Content) {
        self.fill = fill
        self.content = content()
    }

    var body: some View {
        content
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Capsule().fill(fill))
            .overlay(Capsule().fill(Color.primary.opacity(hovering || open ? 0.05 : 0)))
            .contentShape(Capsule())
            .fixedSize()
            .hoverLift(hovering)
            .onHover { hovering = $0 }
            .motion(Motion.hover, value: hovering)
    }
}

// A word that changes rolls: the old one goes up and out, the new one comes in from
// below, and the width follows. A level that falls rolls the other way.
struct RollingText: View {
    let text: String
    var rising = true
    let font: Font

    init(_ text: String, rising: Bool = true, font: Font) {
        self.text = text
        self.rising = rising
        self.font = font
    }

    var body: some View {
        ZStack {
            Text(text)
                .font(font)
                .fixedSize()
                .id(text)
                .transition(.asymmetric(
                    insertion: .move(edge: rising ? .bottom : .top).combined(with: .opacity),
                    removal: .move(edge: rising ? .top : .bottom).combined(with: .opacity)))
        }
        .clipped()
        .motion(Motion.control, value: text)
    }
}
