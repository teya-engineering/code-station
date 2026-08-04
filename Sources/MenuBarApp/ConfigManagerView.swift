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
    @State private var showingAddChoice = false

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

            Menu {
                Button("Reload from disk") { store.load() }
                Button("Reveal config in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.configURL])
                }
            } label: {
                HStack(spacing: 6) {
                    Text("MCP Servers")
                        .font(.system(size: 16, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.88)))
                // Escape leaves the sheet, the way any other dialog behaves.
                .keyboardShortcut(.cancelAction)
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
                    ForEach(store.servers) { server in
                        ServerRow(server: server,
                                  selected: server.id == store.selectedID,
                                  running: processes.state(server.id).isActive)
                            .contentShape(Rectangle())
                            .onTapGesture { store.selectedID = server.id }
                    }
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

                Button {
                    showingAddChoice = true
                } label: {
                    Text("+ Add server")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.88)))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingAddChoice, arrowEdge: .top) {
                    VStack(spacing: 2) {
                        AddChoiceButton(title: "Add Grafana MCP server") {
                            showingAddChoice = false; showingAddGrafana = true
                        }
                        AddChoiceButton(title: "Add MCP server") {
                            showingAddChoice = false; showingAddJSON = true
                        }
                    }
                    .padding(6)
                    .frame(width: 240)
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

private struct AddChoiceButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.black.opacity(0.06) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
                Button("Add a Grafana server", action: onAdd)
            }
        }
    }
}
