import SwiftUI

// Configuring MCP servers is a setup job, not somewhere to sit and work, so it is a
// sheet over the window rather than a pane in it.
struct ConfigManagerView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(ProcessManager.self) private var processes
    @Environment(ClaudeCodeManager.self) private var claude
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddGrafana = false
    @State private var showingAddJSON = false
    @State private var grafanaExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if let loadError = store.loadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(loadError).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Reload") { store.load() }
                        .buttonStyle(.plain)
                        .underline()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.55, green: 0.20, blue: 0.16))
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Color(red: 0.98, green: 0.90, blue: 0.88))
            }
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Theme.hairline)
                detail
            }
            SheetFooter { dismiss() }
        }
        .frame(width: 940, height: 640)
        .background(Theme.background)
        .sheet(isPresented: $showingAddGrafana) { AddServerView() }
        .sheet(isPresented: $showingAddJSON) { AddJSONServerView() }
        .onAppear { claude.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                store.load()
                claude.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Reload from disk")

            HStack(spacing: 6) {
                Text("MCP Servers")
                    .font(.system(size: 16, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .appMenu {
                [.item("Reload from disk") { store.load() },
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
                Text("\(processes.runningCount(among: store.servers.map(\.id))) of \(store.servers.count) running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

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
                            ForEach(grafanaServers) { row(for: $0) }
                        }
                    }
                    ForEach(otherServers) { row(for: $0) }
                }
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

                Text("+ Add server")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.88)))
                    .appMenu {
                        [.item("Add Grafana MCP server") { showingAddGrafana = true },
                         .item("Add MCP server") { showingAddJSON = true }]
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
                        claude.refresh()
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

    private var grafanaServers: [Server] { store.servers.filter(\.isGrafana) }
    private var otherServers: [Server] { store.servers.filter { !$0.isGrafana } }

    private func row(for server: Server) -> some View {
        ServerRow(server: server,
                  selected: server.id == store.selectedID,
                  running: processes.state(server.id).isActive)
            .contentShape(Rectangle())
            .onTapGesture { store.selectedID = server.id }
    }

    private func toggleAllGrafana() {
        let ids = grafanaServers.map(\.id)
        if processes.runningCount(among: ids) == ids.count {
            processes.stopAll(ids)
        } else {
            processes.startAll(grafanaServers)
        }
    }

    private var collapsedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return store.configURL.path.replacingOccurrences(of: home, with: "~")
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let server = store.selected {
            ServerDetailView(serverID: server.id)
                .id(server.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyDetail(hasServers: !store.servers.isEmpty) { showingAddGrafana = true }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            if !server.env.isEmpty {
                Text("\(server.env.count) env")
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

private struct EmptyDetail: View {
    let hasServers: Bool
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(hasServers ? "Select a server" : "No servers configured yet")
                .font(.serif(22))
            if !hasServers {
                Button(action: onAdd) {
                    Text("Add a Grafana server")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.88)))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
