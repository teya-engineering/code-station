import AppKit
import SwiftUI

struct DesignImplementationDialog: View {
    @Bindable var draft: DesignImplementationDraft
    let implement: (DesignImplementationSettings) -> Void
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(MenuPresenter.self) private var menus
    @State private var keys = WindowKeyHandler(handlesTyping: true)
    @State private var dialogID: UUID?
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case change, agent, model, effort, permissions, reset, guidance, implement, cancel
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            form.fixedSize(horizontal: false, vertical: true)
            ScrollView { form }
        }
        .background(Theme.card)
        .background(WindowKeyAnchor(handler: keys))
        .onAppear {
            dialogID = dialogs.current?.id
            focus = .implement
            keys.start { handleKey($0) }
        }
        .onDisappear {
            keys.stop()
            dialogs.restoreFocus()
        }
        .onChange(of: draft.failure) { _, failure in
            if let failure {
                focus = .implement
                announce("\(failure.title). \(failure.message)")
            }
        }
        .onChange(of: draft.effortAdjustment) { _, note in
            if let note { announce(note) }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            VStack(alignment: .leading, spacing: Space.md) {
                SheetTitle("Implement this Design?", icon: "hammer")
                Text("The design and handoff notes are included.")
                    .font(Typography.body).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Space.xl) {
                summary
                if draft.isExpanded && draft.hasAgents {
                    editor
                        .transition(.fold)
                }
            }
            .motion(draft.isExpanded ? Motion.reveal : Motion.leave, value: draft.isExpanded)
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    SectionLabel("ADDITIONAL CONTEXT", style: .field)
                    Spacer(minLength: 0)
                    Text("Optional").font(Typography.caption).foregroundStyle(.secondary)
                }
                AppTextEditor(text: $draft.text,
                              placeholder: "For example: use the second checkout option and keep the current navigation.",
                              minHeight: FormMetrics.guidanceHeight)
                    .frame(height: FormMetrics.guidanceHeight)
                    .focused($focus, equals: .guidance)
                    .accessibilityLabel("Additional implementation context, optional")
                    .disabled(draft.isStarting)
                Label("Your design conversation stays in the Design tab.", systemImage: "link")
                    .font(Typography.caption).foregroundStyle(.secondary)
                    .padding(.top, Space.xs)
            }
            if let failure = draft.failure {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(failure.title).font(Typography.label)
                    Text(failure.message).font(Typography.detail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .warningCard()
                .accessibilityElement(children: .combine)
                .transition(.fadeIn)
            }
            VStack(spacing: Space.md) {
                ActionButton(title: draft.isStarting ? "Starting implementation…" : "Implement with \(draft.agent.title)",
                             tone: .dark, height: ControlHeight.xl, size: Typography.Size.body,
                             icon: draft.isStarting ? "hourglass" : nil, fills: true) {
                    start()
                }
                .disabled(!draft.canStart)
                .focused($focus, equals: .implement)
                .overlay(FocusRingStroke(focused: focus == .implement))
                ActionButton(title: "Cancel", tone: .sunken, height: ControlHeight.xl,
                             size: Typography.Size.body, fills: true) { dialogs.dismiss() }
                    .disabled(draft.isStarting)
                    .focused($focus, equals: .cancel)
                    .overlay(FocusRingStroke(focused: focus == .cancel))
            }
        }
        .padding(Space.pane)
        .motion(Motion.reveal, value: draft.failure)
        .motion(Motion.control, value: draft.isStarting)
    }

    private var summary: some View {
        HStack(spacing: Space.lg) {
            Image(systemName: draft.agent.symbol)
                .font(Typography.body).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(draft.summaryTitle).font(Typography.label)
                Text(draft.summaryDetail).font(Typography.detail).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.interpolate)
            ActionButton(title: draft.isExpanded ? "Done" : "Change", tone: .outlined,
                         height: ControlHeight.md) {
                menus.dismiss()
                draft.isExpanded.toggle()
                focus = .change
                announce(draft.isExpanded ? "Agent, model, effort and permissions are available to change." : draft.summaryDetail)
            }
            .disabled(draft.isStarting || !draft.hasAgents)
            .focused($focus, equals: .change)
            .overlay(FocusRingStroke(focused: focus == .change))
            .accessibilityLabel(draft.isExpanded ? "Done changing implementation settings" : "Change implementation settings")
            .accessibilityValue(draft.isExpanded ? "Expanded" : "Collapsed")
        }
        .padding(Space.card)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Radius.control))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            FormPair {
                LabeledField("Agent") {
                    CodingAgentPicker(agent: draft.agent, fills: true, entries: agentEntries)
                        .focused($focus, equals: .agent)
                }
                LabeledField("Model") {
                    OptionMenu(value: draft.modelTitle, height: ControlHeight.xl) { modelEntries }
                        .focused($focus, equals: .model)
                        .accessibilityLabel("Model: \(draft.modelTitle)")
                }
            }
            FormPair {
                LabeledField("Effort") {
                    EffortPill(title: draft.effortTitle,
                               lit: EffortMeter.lit(for: draft.effort, among: draft.effortLevels), form: true)
                        .appMenu(matchWidth: true, showsFocusRing: true) { effortEntries }
                        .focused($focus, equals: .effort)
                        .accessibilityLabel("Effort: \(draft.effortTitle)")
                }
                LabeledField("Permissions") {
                    ShieldPill(tone: permissionTone, title: draft.permissionTitle, form: true)
                        .appMenu(matchWidth: true, showsFocusRing: true) { permissionEntries }
                        .focused($focus, equals: .permissions)
                        .accessibilityLabel("Permissions: \(draft.permissionTitle)")
                        .accessibilityHint(draft.permissionDetail)
                }
            }
            Text(draft.permissionDetail)
                .font(Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = draft.effortAdjustment {
                Text(note).font(Typography.caption).foregroundStyle(Theme.attentionText)
                    .transition(.fadeIn)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.md) { settingsNote; reset }
                VStack(alignment: .leading, spacing: Space.md) { settingsNote; reset }
            }
        }
        .disabled(draft.isStarting)
        .task(id: draft.agent) {
            await draft.catalog.discoverModels(for: draft.agent)
            draft.validateEffort()
        }
        .onChange(of: draft.catalog.discoveredModels) { _, _ in draft.validateEffort() }
    }

    private var settingsNote: some View {
        Text("Changes apply only to implementation.")
            .font(Typography.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var reset: some View {
        if !draft.isInherited {
            InlineLink(title: "Use design settings") {
                menus.dismiss()
                draft.reset()
                focus = .change
                announce("Restored the design settings. \(draft.summaryDetail)")
            }
            .focused($focus, equals: .reset)
            .overlay(FocusRingStroke(focused: focus == .reset))
        }
    }

    private var agentEntries: [MenuEntry] {
        AgentKind.allCases.map { agent in
            .item(agent.title, icon: agent.symbol, checked: draft.agent == agent,
                  subtitle: draft.catalog.isAvailable(agent) ? agent.vendor : "Not installed",
                  disabled: !draft.catalog.isAvailable(agent)) {
                draft.chooseAgent(agent)
            }
        }
    }

    private var modelEntries: [MenuEntry] {
        [.item("Use Code Station default", checked: draft.usesDefaultModel,
               subtitle: draft.catalog.modelTitle(draft.catalog.validModel(draft.catalog.defaults(for: draft.agent).model, for: draft.agent))) {
            draft.chooseModel(nil, useDefault: true)
        }, .separator] + draft.catalog.modelOptions(for: draft.agent).map { option in
            .item(option.title, checked: !draft.usesDefaultModel && draft.model == option.id,
                  subtitle: option.detail) { draft.chooseModel(option.id) }
        }
    }

    private var effortEntries: [MenuEntry] {
        [.item("Use Code Station default", meter: EffortMeter.lit(for: draft.defaultEffort, among: draft.effortLevels),
               checked: draft.settings.effort == nil,
               subtitle: draft.catalog.effortTitle(draft.defaultEffort, for: draft.agent, model: draft.model)) {
            draft.edit { $0.effort = nil }
        }, .separator] + draft.effortLevels.map { level in
            .item(draft.catalog.effortTitle(level, for: draft.agent, model: draft.model),
                  meter: EffortMeter.lit(for: level, among: draft.effortLevels), checked: draft.settings.effort == level) {
                draft.edit { $0.effort = level }
            }
        }
    }

    private var permissionTone: TrustTone {
        switch draft.agent {
        case .claudeCode, .kiro: TrustTone(draft.permission)
        case .codex: TrustTone(draft.codexAccess)
        case .copilot: TrustTone(draft.copilotAccess)
        }
    }

    private var permissionEntries: [MenuEntry] {
        let defaults = draft.catalog.defaults(for: draft.agent)
        switch draft.agent {
        case .claudeCode, .kiro:
            let agent = draft.agent
            return permissions(defaultTitle: (defaults.permissionMode ?? .fallback).shortTitle,
                               selected: draft.settings.permissionMode, choices: PermissionMode.choices(for: agent),
                               title: { $0.shortTitle }, detail: { $0.detail(for: agent) }, tone: { TrustTone($0) }) { mode in
                draft.edit { $0.permissionMode = mode }
            }
        case .codex:
            return permissions(defaultTitle: (defaults.codexSandboxMode ?? .workspaceWrite).title,
                               selected: draft.settings.codexSandboxMode, choices: CodexSandboxMode.allCases,
                               title: { $0.title }, detail: { $0.detail }, tone: { TrustTone($0) }) { mode in
                draft.edit { $0.codexSandboxMode = mode }
            }
        case .copilot:
            return permissions(defaultTitle: (defaults.copilotAccessMode ?? .workspace).title,
                               selected: draft.settings.copilotAccessMode, choices: CopilotAccessMode.allCases,
                               title: { $0.title }, detail: { $0.detail }, tone: { TrustTone($0) }) { mode in
                draft.edit { $0.copilotAccessMode = mode }
            }
        }
    }

    private func permissions<Choice: Equatable>(defaultTitle: String, selected: Choice?, choices: [Choice],
                                                title: (Choice) -> String, detail: (Choice) -> String,
                                                tone: (Choice) -> TrustTone,
                                                choose: @escaping (Choice?) -> Void) -> [MenuEntry] {
        [.item("Use Code Station default", checked: selected == nil, subtitle: defaultTitle) { choose(nil) },
         .separator] + choices.map { choice in
            .item(title(choice), kind: tone(choice) == .unrestricted ? .destructive : .plain,
                  icon: "shield", iconTint: tone(choice).ink,
                  checked: selected == choice, subtitle: detail(choice)) { choose(choice) }
        }
    }

    private func start() {
        menus.dismiss()
        guard let settings = draft.start() else { return }
        implement(settings)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard dialogs.current?.id == dialogID else { return false }
        if event.keyCode == 53 {
            if menus.isOpen { menus.dismiss() } else { dialogs.dismiss() }
            return true
        }
        guard !menus.isOpen else { return false }
        if event.keyCode == 48 {
            guard !draft.isStarting else { return true }
            var fields: [Field] = draft.hasAgents ? [.change] : []
            if draft.isExpanded && draft.hasAgents {
                fields += [.agent, .model, .effort, .permissions]
                if !draft.isInherited { fields.append(.reset) }
            }
            fields.append(.guidance)
            if draft.canStart { fields.append(.implement) }
            fields.append(.cancel)
            let index = focus.flatMap { fields.firstIndex(of: $0) } ?? 0
            let step = event.modifierFlags.contains(.shift) ? fields.count - 1 : 1
            focus = fields[(index + step) % fields.count]
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.command) || focus == .implement {
                start()
                return true
            }
        }
        return false
    }

    private func announce(_ message: String) {
        guard let window = keys.anchor?.window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
