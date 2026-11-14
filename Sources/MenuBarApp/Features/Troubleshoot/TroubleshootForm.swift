import SwiftUI

// The parts a diagnosis is written on: the skills to load, the problem with its evidence,
// and whether the MCP servers it needs are ready.

// MARK: - Skills

@MainActor
enum TroubleshootSkills {
    static func host(for agent: AgentKind) -> SkillHost {
        switch agent {
        case .claudeCode: .claude
        case .codex: .codex
        case .copilot: .copilot
        }
    }

    static func available(_ manager: SkillsManager,
                          for agent: AgentKind) -> [SkillMarketplace.Plugin] {
        var names = Set<String>()
        return manager.plugins.filter {
            manager.installation(of: $0, on: host(for: agent))?.enabled == true
                && names.insert($0.name).inserted
        }
    }

    // A skill picked for one agent stays picked while the other is selected, so switching
    // agents and back keeps the choice. Only what this agent can load is sent to it.
    static func chosen(_ manager: SkillsManager, for agent: AgentKind,
                       selected: Set<String>) -> [String] {
        available(manager, for: agent).map(\.name).filter { selected.contains($0) }
    }

    // The menu that picks skills, one checked row per skill the agent has installed. A
    // long list gets a filter field.
    static func menu(_ manager: SkillsManager, for agent: AgentKind,
                     selected: Binding<Set<String>>,
                     manage: @escaping () -> Void) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        let items = available(manager, for: agent).map { plugin in
            MenuItem(label: plugin.name,
                     checked: selected.wrappedValue.contains(plugin.name),
                     subtitle: plugin.description,
                     handler: {
                         if selected.wrappedValue.contains(plugin.name) {
                             selected.wrappedValue.remove(plugin.name)
                         } else {
                             selected.wrappedValue.insert(plugin.name)
                         }
                     })
        }
        if items.count > 6 {
            entries.append(.searchable(items,
                                       prompt: "Filter skills by name",
                                       noResults: "No skill matches this filter."))
        } else {
            entries.append(contentsOf: items.map { MenuEntry.item($0) })
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.item("Manage skills…", icon: "sparkles", action: manage))
        return entries
    }
}

// MARK: - Problem and evidence

// What is failing, in the person's own words, with whatever they can already show for it
// docked underneath. Files arrive by drag, by paste or from the file chooser, and the
// three land in the same place. Under the words, the details the agent will start from
// are read back as they are typed, so a pasted id is seen to land. A screen that wants
// its controls on the card's bottom edge hands them in as the footer.
struct TroubleshootProblemEditor: View {
    @Environment(Dictation.self) private var dictation: Dictation?
    @Environment(MenuPresenter.self) private var menus: MenuPresenter?
    @Environment(\.isEnabled) private var isEnabled

    @Binding var problem: String
    @Binding var attachments: [Attachment]
    @Binding var focused: Bool
    var isBrief = false
    var dictationID: UUID? = nil
    var dictationDraft: Binding<SessionComposerStore.Draft>? = nil
    var roots: [String] = []
    var vocabulary: [String] = []
    // The projects the diagnosis covers, so a brief that names one shows it recognised.
    var projects: [String] = []
    var footer: AnyView? = nil

    @State private var dropTargeted = false
    @State private var fieldLink = ComposerFieldLink()
    @State private var dictateShortcut = WindowKeyMonitor([.command, .shift], "d")
    @State private var dictationKeys = DictationKeys()

    private var listening: Bool {
        dictationID.map { dictation?.isListening($0) == true } ?? false
    }

    private var feedback: DictationFeedback? {
        guard let dictation, let dictationID, let dictationDraft else { return nil }
        return DictationFeedback(dictation: dictation, sessionID: dictationID,
                                 draft: dictationDraft, notice: dictation.notice(for: dictationID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            feedback
            editor
        }
        .background {
            if feedback != nil {
                WindowAnchor(monitor: dictateShortcut)
                DictationKeysAnchor(keys: dictationKeys)
            }
        }
        .onChange(of: isEnabled, initial: true) {
            guard feedback != nil else { return }
            dictateShortcut.start {
                guard isEnabled else { return false }
                toggleDictation()
                return true
            }
        }
        .onChange(of: listening, initial: true) { _, live in
            guard let dictation, live else {
                dictationKeys.stop()
                return
            }
            dictationKeys.start(stop: { dictation.stop() }, throwAway: { dictation.throwAway() })
        }
        .onDisappear {
            dictateShortcut.stop()
            dictationKeys.stop()
            if let dictationID { dictation?.leave(dictationID) }
        }
        .onChange(of: problem) { _, text in
            if let dictationID { dictation?.draftEdited(dictationID, text: text) }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextArea(text: $problem,
                         isFocused: $focused,
                         isEnabled: isEnabled,
                         font: .systemFont(ofSize: 13),
                         onSubmit: {},
                         onOversizedPaste: { text in
                             if let attachment = Attachments.fromPastedText(text) { attach([attachment]) }
                         },
                         onRecallUp: nil, onRecallDown: nil,
                         highlightsKeyword: false,
                         onSuggestionKey: nil, onCommandKey: nil,
                         onDropFiles: { attach(Attachments.fromDrop($0)) },
                         onFileDragTargeted: { dropTargeted = $0 },
                         readOnly: listening,
                         marks: marks,
                         onMarkClick: showWordMenu,
                         link: fieldLink,
                         submitsOnReturn: false,
                         accessibilityLabel: "Problem description",
                         animatesKeyword: false,
                         onHeightChange: { _ in })
                    .padding(.horizontal, Space.xs)
                    .padding(Space.md)
                    .frame(height: isBrief ? 174 : 120)
                if problem.isEmpty {
                    Text("Describe what is failing, what you expected, and anything you already checked. Paste a traceId or a Grafana trace link and the agent starts from that trace.")
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.xl)
                        .padding(.vertical, Space.md)
                        .allowsHitTesting(false)
                }
            }

            recognisedRow

            Divider().overlay(Theme.hairline)

            HStack(spacing: Space.md) {
                if attachments.isEmpty {
                    Image(systemName: "arrow.down.doc")
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(dropTargeted ? "Drop files here" : "Drag or paste files here, or add them from Finder")
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.sm) {
                            ForEach(attachments) { attachment in
                                AttachmentChip(url: attachment.url) {
                                    attachments.removeAll { $0.id == attachment.id }
                                }
                                .transition(.fold)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
                Spacer(minLength: 8)
                if let dictation, let dictationID, dictationDraft != nil {
                    DictationMicButton(live: listening,
                                       preparing: dictation.isPreparing(dictationID),
                                       blocked: dictation.notice(for: dictationID).isMicrophoneBlocked,
                                       level: dictation.level,
                                       startedAt: dictation.startedAt,
                                       download: dictation.notice(for: dictationID).downloadFraction,
                                       action: toggleDictation)
                }
                Button(action: chooseFiles) {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "paperclip")
                        Text(isBrief ? "Add evidence" : "Add files")
                    }
                    .font(Typography.label)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .fieldSurface(cornerRadius: Radius.control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverLift()
            }
            .motion(Motion.reveal, value: attachments.map(\.id))
            .padding(Space.md)

            if let footer {
                Divider().overlay(Theme.hairline)
                footer
                    .background(UnevenRoundedRectangle(bottomLeadingRadius: Radius.floating,
                                                       bottomTrailingRadius: Radius.floating)
                        .fill(Theme.sunken))
            }
        }
        .background(RoundedRectangle(cornerRadius: Radius.floating).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.floating)
            .stroke(listening ? Theme.listenEdge : dropTargeted || focused ? Theme.accent : Theme.border,
                    lineWidth: dropTargeted ? 2 : 1))
        .dropDestination(for: URL.self) { urls, _ in
            attach(Attachments.fromDrop(urls))
            return true
        } isTargeted: { dropTargeted = $0 }
        // Only while the description has the cursor: a screen that also holds a plain
        // text field would otherwise steal a path pasted into it as a file.
        .pasteAttachments(enabled: focused) { attach($0) }
        .onChange(of: attachments) { old, new in
            guard let window = NSApp?.keyWindow else { return }
            let added = new.filter { item in !old.contains { $0.id == item.id } }
            let removed = old.filter { item in !new.contains { $0.id == item.id } }
            let message = [
                added.isEmpty ? nil : "Evidence added: " + added.map { $0.url.lastPathComponent }.joined(separator: ", "),
                removed.isEmpty ? nil : "Evidence removed: " + removed.map { $0.url.lastPathComponent }.joined(separator: ", ")
            ].compactMap { $0 }.joined(separator: ". ")
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: message,
                                            .priority: NSAccessibilityPriorityLevel.low.rawValue])
        }
    }

    // What the agent will start from, as chips, or a hint at what would show here. Read
    // off the text on every keystroke, so a pasted trace id lands as a chip at once.
    private var recognisedRow: some View {
        let details = TroubleshootRecognised.details(in: problem, projects: projects)
        return HStack(spacing: Space.sm) {
            if details.isEmpty {
                Text("Paste a trace id, a Grafana link or a time and it shows up here.")
                    .font(Typography.detail)
                    .foregroundStyle(.tertiary)
            } else {
                Text("The agent starts from")
                    .font(Typography.detail)
                    .foregroundStyle(.tertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.sm) {
                        ForEach(details) { detail in
                            HStack(spacing: Space.xs) {
                                Image(systemName: detail.icon)
                                    .font(.system(size: 9.5, weight: .semibold))
                                Text(detail.label)
                                    .font(Typography.label)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, Space.md)
                            .frame(height: 22)
                            .surface(Theme.accent.opacity(0.09), cornerRadius: Radius.control,
                                     border: Theme.accent.opacity(0.22))
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 24)
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.md)
        .motion(Motion.reveal, value: details)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(details.isEmpty
                            ? "No trace id, link or time recognised yet"
                            : "The agent starts from " + details.map(\.label).joined(separator: ", "))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var marks: ComposerMarks {
        guard let dictation, let dictationID else { return ComposerMarks() }
        return listening
            ? ComposerMarks(tentative: dictation.tentative)
            : ComposerMarks(unsure: dictation.review(dictationID)?.unsure.map(\.range) ?? [])
    }

    private func toggleDictation() {
        guard isEnabled, let dictation, let dictationID, let dictationDraft else { return }
        let link = fieldLink
        dictation.toggle(DictationRequest(
            sessionID: dictationID, draft: dictationDraft,
            caret: link.caret ?? (problem as NSString).length,
            roots: roots, vocabulary: vocabulary,
            placeCaret: { location in
                focused = true
                link.placeCaret(location)
            }))
    }

    private func showWordMenu(_ index: Int, at frame: CGRect) {
        guard let dictationID, let words = dictation?.review(dictationID)?.unsure,
              words.indices.contains(index), let feedback else { return }
        menus?.show(feedback.wordMenu(words[index]),
                    at: CGPoint(x: frame.minX, y: frame.minY - 4),
                    verticalAttachment: .control(edge: .top, oppositeY: frame.maxY + 4))
    }

    private func chooseFiles() {
        let urls = FilePicker.chooseFiles(prompt: "Attach",
                                          message: "Choose files that help explain the problem.")
        attach(urls.map(Attachment.init(url:)))
    }

    private func attach(_ found: [Attachment]) {
        for item in found where !attachments.contains(where: { $0.url == item.url }) {
            attachments.append(item)
        }
        focused = true
    }
}

// MARK: - MCP servers

enum TroubleshootMCPState: Equatable {
    case ready
    case checking
    case unavailable(TroubleshootMCPConfiguration)

    // Whether the servers the diagnosis promises are really registered with the agent it
    // will run on. Until the check has been asked for it counts as still running, so a
    // start cannot slip through the gap before the first answer.
    static func resolve(enabled: Bool, servers: [Server], hasStartedCheck: Bool,
                        isRefreshing: Bool, registeredNames: Set<String>,
                        disabledNames: Set<String>) -> Self {
        guard enabled, !servers.isEmpty else { return .ready }
        guard hasStartedCheck, !isRefreshing else { return .checking }

        let configuration = TroubleshootMCPConfiguration(
            requiredNames: servers.map(\.name),
            registeredNames: registeredNames,
            disabledNames: disabledNames)
        return configuration.isAvailable ? .ready : .unavailable(configuration)
    }

    // The same question asked of a live agent. Codex and Copilot can have a server
    // registered but switched off, and both read their registry in the background.
    @MainActor
    static func resolve(agent: AgentKind, enabled: Bool, servers: [Server],
                        hasStartedCheck: Bool,
                        claude: ClaudeCodeManager, codex: CodexCodeManager,
                        copilot: CopilotCodeManager) -> Self {
        switch agent {
        case .claudeCode:
            resolve(enabled: enabled, servers: servers, hasStartedCheck: hasStartedCheck,
                    isRefreshing: false,
                    registeredNames: Set(claude.entries.keys), disabledNames: [])
        case .copilot:
            resolve(enabled: enabled, servers: servers, hasStartedCheck: hasStartedCheck,
                    isRefreshing: copilot.isRefreshing,
                    registeredNames: Set(copilot.entries.keys),
                    disabledNames: Set(copilot.entries.compactMap {
                        $0.value.enabled ? nil : $0.key
                    }))
        case .codex:
            resolve(enabled: enabled, servers: servers, hasStartedCheck: hasStartedCheck,
                    isRefreshing: codex.isRefreshing,
                    registeredNames: Set(codex.entries.keys),
                    disabledNames: Set(codex.entries.compactMap {
                        $0.value.enabled ? nil : $0.key
                    }))
        }
    }

    func configurationLabel(for name: String) -> String {
        switch self {
        case .checking: return "Checking"
        case .ready: return "Configured"
        case .unavailable(let configuration):
            if configuration.missing.contains(name) { return "Not configured" }
            if configuration.disabled.contains(name) { return "Disabled" }
            return "Configured"
        }
    }

    func message(for agent: AgentKind) -> String? {
        guard case .unavailable(let configuration) = self else { return nil }
        var messages: [String] = []
        if !configuration.missing.isEmpty {
            messages.append("Not configured for \(agent.title): \(configuration.missing.joined(separator: ", ")).")
        }
        if !configuration.disabled.isEmpty {
            messages.append("Disabled in \(agent.title): \(configuration.disabled.joined(separator: ", ")).")
        }
        messages.append("Sync the listed servers in MCP Servers before diagnosing.")
        return messages.joined(separator: " ")
    }
}
