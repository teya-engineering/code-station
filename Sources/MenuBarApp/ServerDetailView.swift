import SwiftUI

struct ServerDetailView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(ProcessManager.self) private var processes
    @Environment(ClaudeCodeManager.self) private var claude
    let serverID: Server.ID

    @State private var showingRawJSON = false
    @State private var confirmingDelete = false
    @State private var copiedCommand = false

    private var server: Server? { store.servers.first { $0.id == serverID } }

    var body: some View {
        if let server {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    titleRow(server)
                    claudeCodeSection(server)
                    commandSection(server)
                    varsSection(server)
                    outputSection
                    Divider().overlay(Theme.hairline)
                    footer
                }
                .padding(32)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheet(isPresented: $showingRawJSON) { RawJSONView() }
            .alert("Delete \(server.name)?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) { store.remove(serverID) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the server from the config file.")
            }
        }
    }

    private func titleRow(_ server: Server) -> some View {
        let state = processes.state(serverID)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(server.name).font(.serif(30, .semibold))
                Spacer()
                // Remote servers are reached over a URL, so there is no local process to run.
                if !server.isRemote {
                    HStack(spacing: 12) {
                        StatePill(state: state)
                        Button {
                            processes.toggle(server)
                        } label: {
                            Label(state.isActive ? "Stop" : "Start",
                                  systemImage: state.isActive ? "stop.fill" : "play.fill")
                                .frame(width: 64)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(state.isActive ? Color(red: 0.75, green: 0.28, blue: 0.24) : Theme.accent)
                    }
                    .padding(.top, 8)
                }
            }
            Text(server.description)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            if let endpoint = processes.endpoints[serverID] {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12))
                    Text("Serving at")
                    Text(endpoint).font(.mono(13)).textSelection(.enabled)
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
            }
            if case let .failed(message) = state {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.75, green: 0.28, blue: 0.24))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var outputSection: some View {
        let log = processes.logs[serverID] ?? ""
        if !log.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(text: "OUTPUT")
                    Spacer()
                    Button("Clear") { processes.clearLog(serverID) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                ScrollView {
                    Text(log)
                        .font(.mono(11))
                        .foregroundStyle(Color(white: 0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12)))
            }
        }
    }

    private func claudeCodeSection(_ server: Server) -> some View {
        let registered = claude.isRegistered(server.name)
        let outOfSync = claude.isOutOfSync(server)
        let busy = claude.isBusy(server.name)
        let amber = Color(red: 0.72, green: 0.52, blue: 0.20)
        let red = Color(red: 0.75, green: 0.28, blue: 0.24)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: !registered ? "seal" : (outOfSync ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"))
                    .font(.system(size: 16))
                    .foregroundStyle(!registered ? Color.secondary : (outOfSync ? amber : Theme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code").font(.system(size: 15, weight: .semibold))
                    Text(!registered ? "Not registered - Claude Code can't see this server yet."
                         : (outOfSync ? "Registered, but the token or URL here differs from Claude Code."
                            : "Registered as a user-scope MCP server."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small).padding(.trailing, 4) }
                if outOfSync {
                    Button("Update") { claude.reregister(server) }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(amber)
                        .disabled(!claude.available || busy)
                }
                Button {
                    registered ? claude.remove(server.name) : claude.add(server)
                } label: {
                    Text(registered ? "Remove from Claude Code" : "Add to Claude Code")
                        .frame(minWidth: registered ? 100 : 140)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(registered ? red : Theme.accent)
                .disabled(!claude.available || busy)
            }

            if registered {
                Label("Restart your Claude Code session to load the change.", systemImage: "arrow.clockwise")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !claude.available {
                Text("Claude Code CLI not found on PATH.")
                    .font(.system(size: 12)).foregroundStyle(Color(red: 0.75, green: 0.28, blue: 0.24))
            }
            if let error = claude.errors[server.name] {
                Text(error)
                    .font(.mono(11)).foregroundStyle(Color(red: 0.75, green: 0.28, blue: 0.24))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                if let command = claude.addCommand(for: server) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedCommand = true
                }
            } label: {
                Text(copiedCommand ? "Copied" : "Copy claude mcp add command")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
        .onChange(of: server.env) { copiedCommand = false }
    }

    private func commandSection(_ server: Server) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: server.isRemote ? "URL" : "COMMAND")
            HStack(spacing: 8) {
                if let command = server.command {
                    Chip(text: command)
                    ForEach(server.args, id: \.self) { Chip(text: $0) }
                } else if let url = server.url {
                    Chip(text: url)
                }
                Spacer()
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
        }
    }

    // Remote servers show their headers (read-only); stdio servers show editable env.
    @ViewBuilder private func varsSection(_ server: Server) -> some View {
        if server.isRemote {
            if !server.headers.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "HEADERS")
                    VStack(spacing: 8) {
                        ForEach(server.headers) { header in
                            ReadOnlyVarRow(key: header.key, value: header.value, isSecret: header.isSecret)
                        }
                    }
                }
            }
        } else {
            envSection(server)
        }
    }

    private func envSection(_ server: Server) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "ENVIRONMENT VARIABLES")
                Spacer()
                Button {
                    store.addBlankVar(to: serverID)
                } label: {
                    Text("+ Add variable")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            if server.env.isEmpty {
                Text("No variables.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(server.env) { v in
                        EnvRow(
                            serverID: serverID,
                            envID: v.id,
                            isSecret: v.isSecret,
                            keyBinding: store.keyBinding(v.id, in: serverID),
                            valueBinding: store.valueBinding(v.id, in: serverID),
                            onDelete: { store.removeVar(v.id, from: serverID) }
                        )
                    }
                }
            }

            if server.isGrafana {
                Text("The service account token is stored in this config file. Treat the file like a password.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 20) {
            Button("View raw JSON") { showingRawJSON = true }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
            Button("Delete server") { confirmingDelete = true }
                .buttonStyle(.plain).foregroundStyle(.red.opacity(0.85))
            Spacer()
            if let modified = store.lastModified {
                Text("Last modified \(modified.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13, weight: .medium))
    }
}

private struct ReadOnlyVarRow: View {
    let key: String
    let value: String
    let isSecret: Bool
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 12) {
            Text(key).font(.mono(13, .semibold)).lineLimit(1)
            if isSecret {
                Text("SECRET")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.secret)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.secret.opacity(0.14)))
            }
            Spacer(minLength: 16)
            if isSecret && !revealed {
                Text(String(repeating: "•", count: 18)).font(.mono(13)).foregroundStyle(.secondary)
                Button("Reveal") { revealed = true }.controlSize(.small)
            } else {
                Text(value).font(.mono(13)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if isSecret { Button("Hide") { revealed = false }.controlSize(.small) }
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}

private struct StatePill: View {
    let state: RunState

    private var label: String {
        switch state {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .failed: return "failed"
        }
    }

    private var color: Color {
        switch state {
        case .stopped: return Theme.dotOff
        case .starting: return Theme.secret
        case .running: return Theme.dotOn
        case .failed: return Color(red: 0.75, green: 0.28, blue: 0.24)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.04)))
    }
}

private struct EnvRow: View {
    let serverID: Server.ID
    let envID: EnvVar.ID
    let isSecret: Bool
    @Binding var keyBinding: String
    @Binding var valueBinding: String
    let onDelete: () -> Void

    @State private var revealed = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            TextField("KEY", text: $keyBinding)
                .textFieldStyle(.plain)
                .font(.mono(13, .semibold))
                .lineLimit(1)
                .fixedSize()

            if isSecret {
                Text("SECRET")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.secret)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.secret.opacity(0.14)))
            }

            Spacer(minLength: 16)

            if isSecret && !revealed {
                Text(String(repeating: "•", count: 18))
                    .font(.mono(13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Reveal") { revealed = true }
                    .controlSize(.small)
            } else {
                TextField("value", text: $valueBinding)
                    .textFieldStyle(.plain)
                    .font(.mono(13))
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                if isSecret {
                    Button("Hide") { revealed = false }
                        .controlSize(.small)
                }
            }

            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .frame(height: 24)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}
