import SwiftUI

// Configuring MCP servers is a setup job, not somewhere to sit and work, so it is a
// sheet over the window rather than a pane in it.
struct ConfigManagerView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(ProcessManager.self) private var processes
    @Environment(ClaudeCodeManager.self) private var claude
    @Environment(CodexCodeManager.self) private var codex
    @Environment(\.dismiss) private var dismiss
    @State private var addingPresetGroup: SiteDefaults.MCP.PresetGroup?
    @State private var showingAddJSON = false
    @State private var grafanaExpanded = true
    @State private var agentConfiguredExpanded = false
    @State private var selectedAgentConfiguredName: String?
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if let persistenceError = store.loadError ?? store.saveError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(persistenceError).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(store.loadError == nil ? "Retry" : "Reload") {
                        if store.loadError == nil {
                            store.flushPendingSave()
                        } else {
                            store.load()
                        }
                    }
                        .buttonStyle(.plain)
                        .underline()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.warningText)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Theme.warningBackground)
            }
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Theme.hairline)
                detail
            }
            .disabled(store.loadError != nil)
            SheetFooter { dismiss() }
        }
        .frame(width: 940, height: 640)
        .background(Theme.background)
        .sheet(item: $addingPresetGroup) { AddServerView(group: $0).appOverlays() }
        .sheet(isPresented: $showingAddJSON) { AddJSONServerView() }
        .onAppear { refreshIntegrations() }
        .onChange(of: filter) {
            if !trimmedFilter.isEmpty { agentConfiguredExpanded = true }
        }
        .onChange(of: agentConfiguredServers.map(\.name)) {
            guard let selectedAgentConfiguredName,
                  !agentConfiguredServers.contains(where: {
                      $0.name == selectedAgentConfiguredName
                  }) else { return }
            self.selectedAgentConfiguredName = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                store.load()
                refreshIntegrations()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .appTooltip("Reload from disk")

            HStack(spacing: 6) {
                Text("MCP Servers")
                    .font(.system(size: 16, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .appMenu {
                [.item("Reload from disk") {
                    store.load()
                    refreshIntegrations()
                 },
                 .item("Reveal config in Finder") {
                     NSWorkspace.shared.activateFileViewerSelecting([store.configURL])
                 }]
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.card)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Servers").font(.serif(22, .semibold))
                Text("\(processes.runningCount(among: store.servers.map(\.id))) of \(store.servers.count) Code Station servers running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Filter servers", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 4) {
                    // Grafana needs one process per instance, so the rows cannot merge.
                    // Grouping them at least keeps it to a single control.
                    if !grafanaServers.isEmpty {
                        GrafanaGroupHeader(
                            running: processes.runningCount(among: grafanaServers.map(\.id)),
                            total: grafanaServers.count,
                            expanded: $grafanaExpanded,
                            toggleAll: toggleAllGrafana)
                        if grafanaExpanded {
                            VStack(spacing: 4) {
                                ForEach(grafanaServers) { row(for: $0) }
                            }
                            .transition(.fadeIn)
                        }
                    }
                    if !otherServers.isEmpty, store.servers.contains(where: \.isGrafana) {
                        HStack {
                            Text("OTHER")
                                .font(.system(size: 11, weight: .semibold))
                                .kerning(0.6)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                    }
                    ForEach(otherServers) { row(for: $0) }
                    if !filteredAgentConfiguredServers.isEmpty {
                        AgentConfiguredGroupHeader(
                            total: filteredAgentConfiguredServers.count,
                            expanded: $agentConfiguredExpanded)
                        if agentConfiguredExpanded || !trimmedFilter.isEmpty {
                            VStack(spacing: 4) {
                                ForEach(filteredAgentConfiguredServers) { row(for: $0) }
                            }
                            .transition(.fadeIn)
                        }
                    }
                    if grafanaServers.isEmpty && otherServers.isEmpty
                        && filteredAgentConfiguredServers.isEmpty && !trimmedFilter.isEmpty {
                        Text("No servers match.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                .smoothlyResizes(when: grafanaExpanded)
                .padding(.horizontal, 12)
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                let needing = claude.serversNeedingSync(store.servers)
                if claude.available, !needing.isEmpty {
                    Button {
                        claude.syncAll(store.servers)
                    } label: {
                        Text(claude.bulkBusy ? "Syncing…" : "Sync \(needing.count) to Claude Code")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.10)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .disabled(claude.bulkBusy)
                }

                let codexNeeding = codex.serversNeedingSync(store.servers)
                if codex.available, !codexNeeding.isEmpty {
                    Button {
                        codex.syncAll(store.servers)
                    } label: {
                        Text(codex.bulkBusy ? "Syncing…" : "Sync \(codexNeeding.count) to Codex")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.10)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .disabled(codex.bulkBusy)
                }

                Text("+ Add server")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.88)))
                    .appMenu {
                        addServerMenuEntries
                    }

                HStack(spacing: 6) {
                    Text("Config file")
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
                .appMenu {
                    [.item("Reload from disk") {
                        store.load()
                        refreshIntegrations()
                     },
                     .item("Reveal config in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.configURL])
                     }]
                }

                Text(collapsedPath)
                    .font(.mono(11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(16)
        }
        .frame(width: 292)
        .background(Theme.sidebar)
    }

    private var trimmedFilter: String {
        filter.trimmingCharacters(in: .whitespaces)
    }

    private func matches(_ name: String) -> Bool {
        trimmedFilter.isEmpty || name.localizedCaseInsensitiveContains(trimmedFilter)
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
            codexEntries: codex.entries)
    }

    private var filteredAgentConfiguredServers: [AgentConfiguredServer] {
        agentConfiguredServers.filter { matches($0.name) }
    }

    private func row(for server: Server) -> some View {
        ServerRow(server: server,
                  selected: selectedAgentConfiguredName == nil && server.id == store.selectedID,
                  running: processes.state(server.id).isActive)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedAgentConfiguredName = nil
                store.selectedID = server.id
            }
    }

    private func row(for server: AgentConfiguredServer) -> some View {
        AgentConfiguredServerRow(
            server: server,
            selected: selectedAgentConfiguredName == server.id)
            .contentShape(Rectangle())
            .onTapGesture { selectedAgentConfiguredName = server.id }
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
        SiteDefaults.current.mcpPresetGroups.map { group in
            .item(group.addTitle) { addingPresetGroup = group }
        } + [
            .item("Add MCP server") { showingAddJSON = true }
        ]
    }

    private func refreshIntegrations() {
        claude.refresh()
        codex.refresh(store.servers)
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let name = selectedAgentConfiguredName,
           let server = agentConfiguredServers.first(where: { $0.name == name }) {
            AgentConfiguredServerDetailView(server: server)
                .id(server.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let server = store.selected {
            ServerDetailView(serverID: server.id)
                .id(server.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyDetail(hasServers: !store.servers.isEmpty || !agentConfiguredServers.isEmpty,
                        addMenu: { addServerMenuEntries })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AgentConfiguredGroupHeader: View {
    let total: Int
    @Binding var expanded: Bool

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("CONFIGURED ELSEWHERE")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Text("\(total)")
                    .font(.mono(11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

private struct GrafanaGroupHeader: View {
    let running: Int
    let total: Int
    @Binding var expanded: Bool
    let toggleAll: () -> Void

    private var allRunning: Bool { running == total }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("GRAFANA")
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(.secondary)
                    Text("\(running)/\(total)")
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: toggleAll) {
                Text(allRunning ? "Stop all" : "Start all")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(allRunning ? Color.secondary : Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.05)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

private struct ServerRow: View {
    let server: Server
    let selected: Bool
    let running: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(running ? Theme.dotOn : Theme.dotOff)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(server.transport).font(.mono(11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let environment = server.deployEnvironment {
                Text(environment)
                    .font(.mono(11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.05)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.black.opacity(0.06) : .clear))
    }
}

private struct AgentConfiguredServerRow: View {
    let server: AgentConfiguredServer
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    ForEach(server.registrations) { registration in
                        Text(registration.enabled
                             ? registration.source.shortTitle
                             : "\(registration.source.shortTitle) off")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.05)))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(selected ? Color.black.opacity(0.06) : .clear))
    }
}

private struct EmptyDetail: View {
    let hasServers: Bool
    let addMenu: () -> [MenuEntry]

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(hasServers ? "Select a server" : "No servers configured yet")
                .font(.serif(22))
            if !hasServers {
                Text("Add an MCP server")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.88)))
                    .appMenu { addMenu() }
            }
        }
    }
}
