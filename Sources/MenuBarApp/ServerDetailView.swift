import SwiftUI

struct ServerDetailView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(ProcessManager.self) private var processes
    @Environment(ClaudeCodeManager.self) private var claude
    @Environment(CodexCodeManager.self) private var codex
    let serverID: Server.ID

    @Environment(DialogPresenter.self) private var dialogs

    @State private var showingRawJSON = false
    @State private var copiedClaudeCommand = false
    @State private var copiedCodexCommand = false

    private var server: Server? { store.servers.first { $0.id == serverID } }

    var body: some View {
        if let server {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    titleRow(server)
                    claudeCodeSection(server)
                    codexSection(server)
                    commandSection(server)
                    varsSection(server)
                    outputSection
                    Divider().overlay(Theme.hairline)
                    footer(server)
                }
                .padding(32)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheet(isPresented: $showingRawJSON) { RawJSONView() }
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
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 64)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 9)
                                    .fill(state.isActive ? Theme.deletion : Theme.accentFill))
                                .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
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
                    .foregroundStyle(Theme.deletion)
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

        let icon: String
        let tint: Color
        let caption: String
        if !registered {
            icon = "seal"
            tint = .secondary
            caption = "Not registered - Claude Code can't see this server yet."
        } else if outOfSync {
            icon = "exclamationmark.triangle.fill"
            tint = Theme.secret
            caption = "Registered, but the token or URL here differs from Claude Code."
        } else {
            icon = "checkmark.seal.fill"
            tint = Theme.accent
            caption = "Registered as a user-scope MCP server."
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code").font(.system(size: 15, weight: .semibold))
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small).padding(.trailing, 4) }
                if outOfSync {
                    Button { claude.reregister(server) } label: {
                        Text("Update")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.secret))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .disabled(!claude.available || busy)
                    .opacity(!claude.available || busy ? 0.4 : 1)
                }
                Button {
                    registered ? claude.remove(server.name) : claude.add(server)
                } label: {
                    Text(registered ? "Remove from Claude Code" : "Add to Claude Code")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: registered ? 100 : 140)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(registered ? Theme.deletion : Theme.accentFill))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(!claude.available || busy)
                .opacity(!claude.available || busy ? 0.4 : 1)
            }

            if registered {
                Label("Restart your Claude Code session to load the change.", systemImage: "arrow.clockwise")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !claude.available {
                Text("Claude Code CLI not found on PATH.")
                    .font(.system(size: 12)).foregroundStyle(Theme.deletion)
            }
            if let error = claude.errors[server.name] {
                Text(error)
                    .font(.mono(11)).foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                if let command = claude.addCommand(for: server) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedClaudeCommand = true
                }
            } label: {
                Text(copiedClaudeCommand ? "Copied" : "Copy claude mcp add command")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
        .onChange(of: server.env) { copiedClaudeCommand = false }
    }

    private func codexSection(_ server: Server) -> some View {
        let supported = codex.supports(server)
        let registered = codex.isRegistered(server.name)
        let outOfSync = codex.isOutOfSync(server)
        let busy = codex.isBusy(server.name)

        let icon: String
        let tint: Color
        let caption: String
        if !supported {
            icon = "exclamationmark.triangle.fill"
            tint = Theme.secret
            caption = codexSupportCaption(server)
        } else if !registered {
            icon = "seal"
            tint = .secondary
            caption = "Not registered - Codex can't see this server yet."
        } else if outOfSync {
            icon = "exclamationmark.triangle.fill"
            tint = Theme.secret
            caption = "Registered, but the token or URL here differs from Codex."
        } else {
            icon = "checkmark.seal.fill"
            tint = Theme.accent
            caption = "Registered in Codex's MCP configuration."
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex").font(.system(size: 15, weight: .semibold))
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small).padding(.trailing, 4) }
                if outOfSync {
                    Button { codex.reregister(server) } label: {
                        Text("Update")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.secret))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .disabled(!codex.available || busy)
                    .opacity(!codex.available || busy ? 0.4 : 1)
                }
                Button {
                    registered ? codex.remove(server.name) : codex.add(server)
                } label: {
                    Text(registered ? "Remove from Codex" : "Add to Codex")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: registered ? 100 : 140)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(registered ? Theme.deletion : Theme.accentFill))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(!supported || !codex.available || busy)
                .opacity(!supported || !codex.available || busy ? 0.4 : 1)
            }

            if registered {
                Label("The next Codex turn loads the change.", systemImage: "arrow.clockwise")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !codex.available {
                Text("Codex CLI not found on PATH.")
                    .font(.system(size: 12)).foregroundStyle(Theme.deletion)
            }
            if let error = codex.errors[server.name] {
                Text(error)
                    .font(.mono(11)).foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if supported {
                Button {
                    if let command = codex.addCommand(for: server) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copiedCodexCommand = true
                    }
                } label: {
                    Text(copiedCodexCommand ? "Copied" : "Copy codex mcp add command")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
        .onChange(of: server.env) { copiedCodexCommand = false }
    }

    private func codexSupportCaption(_ server: Server) -> String {
        if server.isRemote, server.transport != "http" {
            return "Codex supports streamable HTTP, not \(server.transport.uppercased())."
        }
        if server.isRemote, server.headers.contains(where: { !$0.key.isEmpty }) {
            return "Codex can't register remote servers with custom HTTP headers."
        }
        return "A command or URL is needed before Codex can register this server."
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
                            isSecret: v.isSecret,
                            key: store.keyBinding(v.id, in: serverID),
                            value: store.valueBinding(v.id, in: serverID),
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

    private func confirmDelete(_ server: Server) {
        dialogs.show(Dialog(
            title: "Delete \(server.name)?",
            message: "This removes the server from the config file.",
            actions: [
                .init(label: "Delete server", kind: .destructive) { store.remove(serverID) },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    private func footer(_ server: Server) -> some View {
        HStack(spacing: 20) {
            Button("View raw JSON") { showingRawJSON = true }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
            Button("Delete server") { confirmDelete(server) }
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

private struct SecretBadge: View {
    var body: some View {
        Text("SECRET")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.secret)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.secret.opacity(0.14)))
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
            if isSecret { SecretBadge() }
            Spacer(minLength: 16)
            if isSecret && !revealed {
                Text(String(repeating: "•", count: 18)).font(.mono(13)).foregroundStyle(.secondary)
                Button("Reveal") { revealed = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            } else {
                Text(value).font(.mono(13)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if isSecret {
                    Button("Hide") { revealed = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
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
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .failed: "failed"
        }
    }

    private var color: Color {
        switch state {
        case .stopped: Theme.dotOff
        case .starting: Theme.secret
        case .running: Theme.dotOn
        case .failed: Theme.deletion
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
    let isSecret: Bool
    @Binding var key: String
    @Binding var value: String
    let onDelete: () -> Void

    @State private var revealed = false

    var body: some View {
        HStack(spacing: 12) {
            TextField("KEY", text: $key)
                .textFieldStyle(.plain)
                .font(.mono(13, .semibold))
                .lineLimit(1)
                .fixedSize()

            if isSecret { SecretBadge() }

            Spacer(minLength: 16)

            if isSecret && !revealed {
                Text(String(repeating: "•", count: 18))
                    .font(.mono(13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Reveal") { revealed = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            } else {
                TextField("value", text: $value)
                    .textFieldStyle(.plain)
                    .font(.mono(13))
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
                if isSecret {
                    Button("Hide") { revealed = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
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
