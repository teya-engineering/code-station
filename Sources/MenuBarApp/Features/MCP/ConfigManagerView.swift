import SwiftUI

// Configuring MCP servers is a setup job, not somewhere to sit and work, so it is a
// sheet over the window rather than a pane in it.
struct ConfigManagerView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(ProcessManager.self) private var processes
    @Environment(ClaudeCodeManager.self) private var claude
    @Environment(CodexCodeManager.self) private var codex
    @Environment(CopilotCodeManager.self) private var copilot
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Read once when the view opens, so the add button and its menu always agree on
    // which presets there are.
    @State private var presetGroups = SiteDefaults.current.mcpPresetGroups
    @State private var addingPresetGroup: SiteDefaults.MCP.PresetGroup?
    @State private var showingAddJSON = false
    @State private var grafanaExpanded = false
    @State private var expandedAgents: Set<AgentConfiguredServer.Source> = []
    // A server two agents hold has a row under each, so the pick names the agent too.
    @State private var selectedAgentConfigured: AgentConfiguredSelection?
    @State private var filter = ""
    @State private var note: String?
    @State private var noteIcon = "checkmark"
    @State private var notes = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if let persistenceError = store.loadError ?? store.saveError {
                WarningStrip(persistenceError) {
                    Button(store.loadError == nil ? "Retry" : "Reload") {
                        if store.loadError == nil {
                            store.flushPendingSave()
                        } else {
                            store.load()
                        }
                    }
                    .buttonStyle(.plain)
                    .hoverLift()
                    .underline()
                }
            }
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Theme.hairline)
                detail
                    .motion(Motion.reveal, value: selectedAgentConfigured)
                    .motion(Motion.reveal, value: store.selectedID)
            }
            .disabled(store.loadError != nil)
            SheetFooter { dismiss() }
        }
        .frame(width: 940, height: 640)
        .background(Theme.background)
        .overlay(alignment: .topTrailing) {
            ZStack {
                if let note {
                    HeaderNote(icon: noteIcon, text: note)
                        .padding(.top, Theme.headerHeight + 8).padding(.trailing, Space.xxl)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                }
            }
            .motion(Motion.reveal, value: note)
        }
        .sheet(item: $addingPresetGroup) { AddServerView(group: $0).appOverlays() }
        .sheet(isPresented: $showingAddJSON) { AddJSONServerView() }
        .onAppear { refreshIntegrations() }
        .onChange(of: filter) {
            if !filter.isBlank {
                grafanaExpanded = true
                expandedAgents = Set(AgentConfiguredServer.Source.allCases)
            }
        }
        .onChange(of: agentConfiguredServers.map(\.name)) {
            guard let selectedAgentConfigured,
                  !agentConfiguredServers.contains(where: {
                      $0.name == selectedAgentConfigured.name
                          && $0.registration(from: selectedAgentConfigured.source) != nil
                  }) else { return }
            self.selectedAgentConfigured = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.lg) {
            Button {
                store.load()
                refreshIntegrations()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .appTooltip("Reload from disk")

            HStack(spacing: Space.sm) {
                Text("MCP Servers")
                    .font(Typography.title)
                Image(systemName: "chevron.down")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .appMenu { configFileMenuEntries }

            Spacer()
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.lg)
        .background(Theme.card)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Servers").font(Typography.display)
                Text("\(processes.runningCount(among: store.servers.map(\.id))) of \(store.servers.count) Code Station servers running")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.lg)

            HStack(spacing: Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(Typography.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Filter servers", text: $filter)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .fieldSurface(cornerRadius: Radius.card)
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.lg)

            ScrollView {
                VStack(spacing: Space.xs) {
                    // Grafana needs one process per instance, so the rows cannot merge.
                    // Grouping them at least keeps it to a single control.
                    if !grafanaServers.isEmpty {
                        GrafanaGroupHeader(
                            running: processes.runningCount(among: grafanaServers.map(\.id)),
                            total: grafanaServers.count,
                            expanded: $grafanaExpanded,
                            toggleAll: toggleAllGrafana)
                        if grafanaExpanded || !filter.isBlank {
                            VStack(spacing: Space.xs) {
                                ForEach(grafanaServers) { row(for: $0) }
                            }
                            .transition(.fadeIn)
                        }
                    }
                    if !otherServers.isEmpty, store.servers.contains(where: \.isGrafana) {
                        HStack {
                            Text("OTHER")
                                .font(Typography.caption.weight(.semibold))
                                .kerning(0.6)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, Space.lg)
                        .padding(.top, Space.md)
                        .padding(.bottom, Space.xxs)
                    }
                    ForEach(otherServers) { row(for: $0) }
                    // Grouped by agent, so who owns a server is read before its name.
                    ForEach(AgentConfiguredServer.Source.allCases) { source in
                        let held = filteredAgentConfiguredServers.filter {
                            $0.registration(from: source) != nil
                        }
                        if !held.isEmpty {
                            AgentConfiguredGroupHeader(
                                source: source,
                                total: held.count,
                                needingLook: held.count {
                                    $0.registration(from: source)?.status.needsLook == true
                                },
                                expanded: expandedBinding(source))
                            if expandedAgents.contains(source) || !filter.isBlank {
                                VStack(spacing: Space.xs) {
                                    ForEach(held) { row(for: $0, from: source) }
                                }
                                .transition(.fadeIn)
                            }
                        }
                    }
                    if grafanaServers.isEmpty && otherServers.isEmpty
                        && filteredAgentConfiguredServers.isEmpty && !filter.isBlank {
                        Text("No servers match.")
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Space.lg)
                    }
                }
                .smoothlyResizes(when: grafanaExpanded)
                .smoothlyResizes(when: expandedAgents)
                .padding(.horizontal, Space.lg)
            }

            Spacer(minLength: 0)

            VStack(spacing: Space.md) {
                if claude.available {
                    syncButton(needing: claude.serversNeedingSync(store.servers).count,
                               busy: claude.bulkBusy, label: "Claude Code") {
                        claude.syncAll(store.servers)
                    }
                }
                if codex.available {
                    syncButton(needing: codex.serversNeedingSync(store.servers).count,
                               busy: codex.bulkBusy, label: "Codex") {
                        codex.syncAll(store.servers)
                    }
                }
                if copilot.available {
                    syncButton(needing: copilot.serversNeedingSync(store.servers).count,
                               busy: copilot.bulkBusy, label: "Copilot") {
                        copilot.syncAll(store.servers)
                    }
                }

                Text("+ Add server")
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.onFill)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.lg)
                    .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color.black.opacity(0.88)))
                    .addServerTrigger(addServerMenuEntries)

                HStack(spacing: Space.sm) {
                    Text("Config file")
                    Image(systemName: "chevron.down").font(Typography.micro)
                }
                .font(Typography.body.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.md)
                .surface(Theme.card, cornerRadius: Radius.card, border: Theme.hairline)
                .appMenu { configFileMenuEntries }

                Text(collapsedPath)
                    .font(Typography.data)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(Space.xl)
        }
        .frame(width: 292)
        .background(Theme.sidebar)
    }

    // Offered only while an agent has something to catch up on, so the sidebar stays
    // quiet once both are in step with the app's own list.
    @ViewBuilder private func syncButton(needing: Int, busy: Bool, label: String,
                                         action: @escaping () -> Void) -> some View {
        if needing > 0 {
            Button(action: action) {
                Text(busy ? "Syncing…" : "Sync \(needing) to \(label)")
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.md)
                    .surface(Theme.accent.opacity(0.10), cornerRadius: Radius.card,
                             border: Theme.accent.opacity(0.35))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.card))
            }
            .buttonStyle(.plain)
            .hoverLift()
            .disabled(busy)
        }
    }

    private var configFileMenuEntries: [MenuEntry] {
        [.item("Reload from disk") {
            store.load()
            refreshIntegrations()
         },
         .item("Reveal config in Finder") {
             NSWorkspace.shared.activateFileViewerSelecting([store.configURL])
             showNote("Revealed the config in Finder", icon: "folder")
         }]
    }

    // A second note keeps the line up rather than letting the first one's timer take it
    // down early.
    private func showNote(_ text: String, icon: String) {
        notes += 1
        let shown = notes
        noteIcon = icon
        note = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            if notes == shown { note = nil }
        }
    }

    private func matches(_ name: String) -> Bool {
        let term = filter.trimmed
        return term.isEmpty || name.localizedCaseInsensitiveContains(term)
    }

    private var grafanaServers: [Server] {
        store.servers.filter { $0.isGrafana && matches($0.name) }
    }

    private var otherServers: [Server] {
        store.servers.filter { !$0.isGrafana && matches($0.name) }
    }

    private var agentConfiguredServers: [AgentConfiguredServer] {
        AgentConfiguredServer.outsideCodeStation(
            managedServers: store.servers,
            claudeEntries: claude.entries,
            codexEntries: codex.entries,
            copilotEntries: copilot.entries,
            claudeHealth: claude.health,
            work: { source, name in
                switch source {
                case .claudeCode: claude.work(on: name)
                case .codex: codex.work(on: name)
                case .copilot: copilot.work(on: name)
                }
            })
    }

    private func expandedBinding(_ source: AgentConfiguredServer.Source) -> Binding<Bool> {
        Binding {
            expandedAgents.contains(source)
        } set: { expanded in
            if expanded { expandedAgents.insert(source) } else { expandedAgents.remove(source) }
        }
    }

    private var filteredAgentConfiguredServers: [AgentConfiguredServer] {
        agentConfiguredServers.filter { matches($0.name) }
    }

    private func row(for server: Server) -> some View {
        let selected = selectedAgentConfigured == nil && server.id == store.selectedID
        return Button {
            selectedAgentConfigured = nil
            store.selectedID = server.id
        } label: {
            ServerRow(server: server,
                      selected: selected,
                      running: processes.state(server.id).isActive,
                      claudeStatus: claude.registration(of: server.name)?.status)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.card)
        .motion(Motion.control, value: selected)
    }

    private func row(for server: AgentConfiguredServer,
                     from source: AgentConfiguredServer.Source) -> some View {
        let selection = AgentConfiguredSelection(name: server.name, source: source)
        let selected = selectedAgentConfigured == selection
        return Button {
            selectedAgentConfigured = selection
        } label: {
            AgentConfiguredServerRow(server: server, source: source, selected: selected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.card)
        .motion(Motion.control, value: selected)
    }

    private func toggleAllGrafana() {
        let ids = grafanaServers.map(\.id)
        if processes.runningCount(among: ids) == ids.count {
            processes.stopAll(ids)
        } else {
            processes.startAll(grafanaServers)
        }
    }

    private var collapsedPath: String { store.configURL.path.abbreviatedPath }

    private var addServerMenuEntries: [MenuEntry] {
        presetGroups.map { group in
            .item(group.addTitle) { addingPresetGroup = group }
        } + [
            .item("Add MCP server") { showingAddJSON = true }
        ]
    }

    private func refreshIntegrations() {
        claude.refresh()
        claude.checkHealth()
        codex.refresh(store.servers)
        copilot.refresh(store.servers)
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let selection = selectedAgentConfigured,
           let server = agentConfiguredServers.first(where: { $0.name == selection.name }) {
            AgentConfiguredServerDetailView(server: server, leading: selection.source)
                .id(server.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.fadeIn)
        } else if let server = store.selected {
            ServerDetailView(serverID: server.id)
                .id(server.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.fadeIn)
        } else {
            EmptyDetail(hasServers: !store.servers.isEmpty || !agentConfiguredServers.isEmpty,
                        addEntries: addServerMenuEntries)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.fadeIn)
        }
    }
}

private struct AgentConfiguredSelection: Equatable {
    let name: String
    let source: AgentConfiguredServer.Source
}

private struct AgentConfiguredGroupHeader: View {
    let source: AgentConfiguredServer.Source
    let total: Int
    let needingLook: Int
    @Binding var expanded: Bool

    private var lookPhrase: String {
        needingLook == 1 ? "1 needs a look" : "\(needingLook) need a look"
    }

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "chevron.right")
                    .font(Typography.micro)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .motion(Motion.reveal, value: expanded)
                Image(systemName: source.symbol)
                    .font(Typography.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text("FROM \(source.title.uppercased())")
                    .font(Typography.caption.weight(.semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Text("\(total)")
                    .font(Typography.data)
                    .foregroundStyle(.secondary)
                Spacer()
                if needingLook > 0 {
                    HStack(spacing: Space.xs) {
                        Circle().fill(Theme.attention).frame(width: 7, height: 7)
                        Text("\(needingLook)")
                            .font(Typography.data.weight(.semibold))
                            .foregroundStyle(Theme.attentionText)
                    }
                    .appTooltip(lookPhrase)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.control)
        .accessibilityLabel("From \(source.title), \(counted(total, "server"))"
            + (needingLook > 0 ? ", \(lookPhrase)" : ""))
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.md)
        .padding(.bottom, Space.xxs)
    }
}

private struct GrafanaGroupHeader: View {
    let running: Int
    let total: Int
    @Binding var expanded: Bool
    let toggleAll: () -> Void

    private var allRunning: Bool { running == total }

    var body: some View {
        HStack(spacing: Space.md) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: "chevron.right")
                        .font(Typography.micro)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .motion(Motion.reveal, value: expanded)
                    Image(systemName: "chart.xyaxis.line")
                        .font(Typography.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("GRAFANA")
                        .font(Typography.caption.weight(.semibold))
                        .kerning(0.6)
                        .foregroundStyle(.secondary)
                    Text("\(running)/\(total)")
                        .font(Typography.data)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverFill(cornerRadius: Radius.control)

            Spacer()

            Button(action: toggleAll) {
                Text(allRunning ? "Stop all" : "Start all")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(allRunning ? Color.secondary : Theme.accent)
                    .contentTransition(.interpolate)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.xxs)
                    .background(Capsule().fill(Theme.field))
                    .motion(Motion.reveal, value: allRunning)
            }
            .buttonStyle(.plain)
            .hoverLift()
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.xxs)
    }
}

private struct ServerRow: View {
    let server: Server
    let selected: Bool
    let running: Bool
    let claudeStatus: AgentConfiguredServer.Status?

    var body: some View {
        HStack(spacing: Space.md) {
            // A remote server has no process here, so the only state worth a dot is
            // whether Claude Code can reach it.
            if server.isRemote, let claudeStatus {
                AgentStatusDot(status: claudeStatus)
            } else {
                Circle()
                    .fill(running ? Theme.dotOn : Theme.dotOff)
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(Typography.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(server.transport).font(Typography.data).foregroundStyle(.secondary)
            }
            Spacer()
            if let claudeStatus, claudeStatus.needsLook {
                Text(claudeStatus.word)
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(claudeStatus.tint)
                    .lineLimit(1)
                    .fixedSize()
                    .appTooltip("What Claude Code says about this server")
            }
            if let environment = server.deployEnvironment {
                Text(environment)
                    .font(Typography.data)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.xxs)
                    .background(Capsule().fill(Theme.field))
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(selected ? Theme.field : .clear))
    }
}

private struct AgentConfiguredServerRow: View {
    let server: AgentConfiguredServer
    let source: AgentConfiguredServer.Source
    let selected: Bool

    private var registration: AgentConfiguredServer.Registration? {
        server.registration(from: source)
    }

    private var subtitle: String {
        let others = server.registrations.filter { $0.source != source }.map(\.source.title)
        let transport = registration?.transport ?? ""
        guard !others.isEmpty else { return transport }
        return "\(transport), also in \(others.joined(separator: " and "))"
    }

    var body: some View {
        let status = registration?.status ?? .on
        HStack(spacing: Space.md) {
            AgentStatusDot(status: status)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(Typography.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(Typography.data)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if status.showsWordInSidebar {
                Text(status.word)
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(status.tint)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.card)
            .fill(selected ? Theme.field : .clear))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(server.name), \(subtitle), \(status.word)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct EmptyDetail: View {
    let hasServers: Bool
    let addEntries: [MenuEntry]

    var body: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(hasServers ? "Select a server" : "No servers configured yet")
                .font(Typography.display)
            if !hasServers {
                Text("Add an MCP server")
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.onFill)
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.md)
                    .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color.black.opacity(0.88)))
                    .addServerTrigger(addEntries)
            }
        }
    }
}

private extension View {
    // A menu with a single row would only ask the user to pick the only choice there is,
    // so the click runs that row instead.
    @ViewBuilder
    func addServerTrigger(_ entries: [MenuEntry]) -> some View {
        if entries.count == 1, case .item(let item) = entries[0], let handler = item.handler {
            Button(action: handler) {
                contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverLift()
        } else {
            hoverLift().appMenu { entries }
        }
    }
}
