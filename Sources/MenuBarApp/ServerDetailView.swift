import SwiftUI

// The detail is ranked around what breaks: the credential first, then where the server
// is registered, then how it connects. Run controls sit in a fixed header so they stay
// at hand while the rest scrolls.
struct ServerDetailView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(ProcessManager.self) private var processes
    @Environment(ClaudeCodeManager.self) private var claude
    @Environment(CodexCodeManager.self) private var codex
    @Environment(DialogPresenter.self) private var dialogs
    let serverID: Server.ID

    @State private var showingRawJSON = false
    @State private var editingConnection = false

    private var server: Server? { store.servers.first { $0.id == serverID } }

    var body: some View {
        if let server {
            VStack(spacing: 0) {
                header(server)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        credentialSection(server)
                        registeredSection(server)
                        connectionSection(server)
                        outputSection
                        Divider().overlay(Theme.hairline)
                        footer(server)
                    }
                    .padding(28)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .sheet(isPresented: $showingRawJSON) { RawJSONView() }
        }
    }

    // MARK: - Header

    private func header(_ server: Server) -> some View {
        let state = processes.state(serverID)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.name)
                        .font(.serif(24, .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(server.transport)
                            .font(.mono(12))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Text(server.description)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        environmentPill(server)
                    }
                }
                Spacer(minLength: 12)
                // Remote servers are reached over a URL, so there is no local process
                // to run.
                if !server.isRemote {
                    StatePill(state: state)
                    ActionButton(title: state.isActive ? "Stop" : "Start",
                                 tone: state.isActive ? .danger : .green, size: 13,
                                 icon: state.isActive ? "stop.fill" : "play.fill") {
                        processes.toggle(server)
                    }
                }
                GlyphButton(icon: "ellipsis")
                    .appMenu {
                        [.item("View raw JSON") { showingRawJSON = true },
                         .item("Delete server", kind: .destructive) { confirmDelete(server) }]
                    }
            }
            if case let .failed(message) = state {
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    // Which diagnoses offer this server. It sits by the name because it decides where the
    // server turns up rather than how it connects, and it is one click from anywhere in
    // the page since the header does not scroll away.
    private func environmentPill(_ server: Server) -> some View {
        let title = ServerEnvironmentChoice.title(for: server.environmentTag)
        return HStack(spacing: 4) {
            Text(title).font(.mono(11))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.05)))
        .contentShape(Capsule())
        .appMenu {
            ServerEnvironmentChoice.menu(selected: server.environmentTag) { tag in
                store.setEnvironment(tag, for: serverID)
            }
        }
        .appTooltip("The environment a diagnosis offers this server for")
    }

    // MARK: - Credential

    private func secrets(_ server: Server) -> [EnvVar] {
        (server.isRemote ? server.headers : server.env).filter(\.isSecret)
    }

    @ViewBuilder private func credentialSection(_ server: Server) -> some View {
        let secrets = secrets(server)
        if !secrets.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(secrets.count == 1 ? "CREDENTIAL" : "CREDENTIALS")
                ForEach(secrets) { secret in
                    // Headers on a remote server are read-only here, like the rest of
                    // its connection details.
                    if server.isRemote {
                        CredentialCard(key: .constant(secret.key),
                                       value: .constant(secret.value),
                                       editable: false,
                                       onDelete: nil)
                    } else {
                        CredentialCard(key: store.keyBinding(secret.id, in: serverID),
                                       value: store.valueBinding(secret.id, in: serverID),
                                       editable: true,
                                       onDelete: { store.removeVar(secret.id, from: serverID) })
                    }
                }
            }
        }
    }

    // MARK: - Registered with

    private func registeredSection(_ server: Server) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("REGISTERED WITH")
                Spacer()
                if claudeNeedsSync(server) && codexNeedsSync(server) {
                    InlineLink(title: "Sync both", size: 13) {
                        syncBoth(server)
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                AgentCard(standing: claudeStanding(server))
                AgentCard(standing: codexStanding(server))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func claudeNeedsSync(_ server: Server) -> Bool {
        claude.available && (!claude.isRegistered(server.name) || claude.isOutOfSync(server))
    }

    private func codexNeedsSync(_ server: Server) -> Bool {
        codex.available && codex.supports(server)
            && (!codex.isRegistered(server.name) || codex.isOutOfSync(server))
    }

    private func syncBoth(_ server: Server) {
        claude.isRegistered(server.name) ? claude.reregister(server) : claude.add(server)
        codex.isRegistered(server.name) ? codex.reregister(server) : codex.add(server)
    }

    // The two managers answer the same questions but share no type, so each is read
    // into the one shape the card draws from.
    private func claudeStanding(_ server: Server) -> AgentStanding {
        AgentStanding(
            title: "Claude Code",
            available: claude.available,
            registered: claude.isRegistered(server.name),
            outOfSync: claude.isOutOfSync(server),
            busy: claude.isBusy(server.name),
            error: claude.errors[server.name],
            unsupported: nil,
            registeredCaption: "Registered as a user-scope MCP server.",
            reloadNote: "Restart your Claude Code session to load the change.",
            toggle: { claude.isRegistered(server.name) ? claude.remove(server.name) : claude.add(server) },
            update: { claude.reregister(server) },
            command: { claude.addCommand(for: server) })
    }

    private func codexStanding(_ server: Server) -> AgentStanding {
        AgentStanding(
            title: "Codex",
            available: codex.available,
            registered: codex.isRegistered(server.name),
            outOfSync: codex.isOutOfSync(server),
            busy: codex.isBusy(server.name),
            error: codex.errors[server.name],
            unsupported: codex.supports(server) ? nil : codexSupportCaption(server),
            registeredCaption: "Registered in Codex's MCP configuration.",
            reloadNote: "The next Codex turn loads the change.",
            toggle: { codex.isRegistered(server.name) ? codex.remove(server.name) : codex.add(server) },
            update: { codex.reregister(server) },
            command: { codex.addCommand(for: server) })
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

    // MARK: - Connection

    private func connectionSection(_ server: Server) -> some View {
        let plain = (server.isRemote ? server.headers : server.env).filter { !$0.isSecret }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("CONNECTION")
                Spacer()
                if !server.isRemote {
                    InlineLink(title: editingConnection ? "Done" : "Edit", size: 13) {
                        editingConnection.toggle()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                connectionRow(server.isRemote ? "URL" : "COMMAND") {
                    if let command = server.command {
                        HStack(spacing: 6) {
                            MonoChip(text: command, size: 13, bordered: true)
                            ForEach(server.args, id: \.self) { MonoChip(text: $0, size: 13, bordered: true) }
                        }
                    } else if let url = server.url {
                        Text(url)
                            .font(.mono(13))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                ForEach(plain) { variable in
                    if editingConnection && !server.isRemote {
                        editableVarRow(variable)
                    } else {
                        connectionRow(variable.key.isEmpty ? "KEY" : variable.key) {
                            Text(variable.value)
                                .font(.mono(13))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if let endpoint = processes.endpoint(for: serverID) {
                    connectionRow("SERVING AT") {
                        Text(endpoint)
                            .font(.mono(13))
                            .foregroundStyle(Theme.accent)
                            .textSelection(.enabled)
                    }
                }
                if editingConnection && !server.isRemote {
                    InlineLink(title: "+ Add variable", size: 12.5) {
                        store.addBlankVar(to: serverID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(cornerRadius: 12)
        }
    }

    private func connectionRow(_ label: String,
                               @ViewBuilder content: () -> some View) -> some View {
        LabeledRow(label, width: 180, content: content)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    private func editableVarRow(_ variable: EnvVar) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            TextField("KEY", text: store.keyBinding(variable.id, in: serverID))
                .textFieldStyle(.plain)
                .font(.mono(11, .semibold))
                .frame(width: 180, alignment: .leading)
            TextField("value", text: store.valueBinding(variable.id, in: serverID))
                .textFieldStyle(.plain)
                .font(.mono(13))
            Button {
                store.removeVar(variable.id, from: serverID)
            } label: {
                Image(systemName: "trash").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Output

    @ViewBuilder private var outputSection: some View {
        let log = processes.logs[serverID] ?? ""
        if !log.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("OUTPUT")
                    Spacer()
                    InlineLink(title: "Clear", size: 13) { processes.clearLog(serverID) }
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

    // MARK: - Footer

    private func confirmDelete(_ server: Server) {
        dialogs.show(.confirm("Delete \(server.name)?",
                              message: "This removes the server from the config file.",
                              action: "Delete server") { store.remove(serverID) })
    }

    private func footer(_ server: Server) -> some View {
        HStack(spacing: 20) {
            InlineLink(title: "View raw JSON", size: 13) { showingRawJSON = true }
            InlineLink(title: "Delete server", size: 13, tint: .red.opacity(0.85)) {
                confirmDelete(server)
            }
            Spacer()
            if let modified = store.lastModified {
                Text("Last modified \(modified.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Credential card

private struct CredentialCard: View {
    @Binding var key: String
    @Binding var value: String
    let editable: Bool
    let onDelete: (() -> Void)?

    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if editable {
                    TextField("KEY", text: $key)
                        .textFieldStyle(.plain)
                        .font(.mono(13.5, .semibold))
                        .fixedSize()
                } else {
                    Text(key).font(.mono(13.5, .semibold))
                }
                MonoChip(text: "SECRET", size: 10, tint: Theme.secret, mono: false)
                Spacer(minLength: 16)
                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().overlay(Theme.hairline)

            HStack(spacing: 12) {
                if revealed {
                    if editable {
                        TextField("value", text: $value)
                            .textFieldStyle(.plain)
                            .font(.mono(13))
                    } else {
                        Text(value)
                            .font(.mono(13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    InlineLink(title: "Hide", size: 12.5) { revealed = false }
                } else {
                    Text(String(repeating: "•", count: 18))
                        .font(.mono(13))
                        .foregroundStyle(.secondary)
                    InlineLink(title: "Reveal", size: 12.5) { revealed = true }
                }
                Spacer(minLength: 16)
                Text("Stored in the config file - treat it like a password.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Theme.secret.opacity(0.4), lineWidth: 1.2))
    }
}

// MARK: - Agent card

// What one agent says about this server, read from its manager.
private struct AgentStanding {
    let title: String
    let available: Bool
    let registered: Bool
    let outOfSync: Bool
    let busy: Bool
    let error: String?
    // Why the agent cannot take this server, or nil when it can.
    let unsupported: String?
    let registeredCaption: String
    // How a change reaches a running agent, since each picks it up differently.
    let reloadNote: String
    let toggle: () -> Void
    let update: () -> Void
    let command: () -> String?
}

// One agent the server can be registered with. The two cards share a row, so each keeps
// to a compact pill-and-link layout instead of a full-width toolbar.
private struct AgentCard: View {
    let standing: AgentStanding

    private enum Tone { case inSync, outOfSync, notRegistered, unsupported }

    private struct Note: Identifiable {
        let text: String
        var tint: Color? = nil
        var mono = false

        var id: String { text }
    }

    private var tone: Tone {
        if standing.unsupported != nil { return .unsupported }
        if !standing.registered { return .notRegistered }
        return standing.outOfSync ? .outOfSync : .inSync
    }

    private var caption: String {
        switch tone {
        case .unsupported: standing.unsupported ?? ""
        case .notRegistered: "Not registered - \(standing.title) can't see this server yet."
        case .outOfSync: "The token or URL here differs from the registered one."
        case .inSync: standing.registeredCaption
        }
    }

    private var enabled: Bool {
        tone != .unsupported && standing.available && !standing.busy
    }

    private var notes: [Note] {
        var notes: [Note] = []
        if standing.registered {
            notes.append(Note(text: standing.reloadNote))
        }
        if !standing.available {
            notes.append(Note(text: "\(standing.title) CLI not found on PATH.", tint: Theme.deletion))
        }
        if let error = standing.error {
            notes.append(Note(text: error, tint: Theme.deletion, mono: true))
        }
        return notes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(standing.title).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                if standing.busy { ProgressView().controlSize(.small) }
                Text(stateText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(stateTint)
            }

            Text(caption)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if tone != .unsupported {
                HStack(spacing: 10) {
                    if tone == .outOfSync {
                        ActionButton(title: "Update", tone: .attention, height: 28, size: 12,
                                     action: standing.update)
                    }
                    ActionButton(title: standing.registered ? "Remove" : "Add",
                                 tone: standing.registered ? .danger : .green,
                                 height: 28, size: 12, action: standing.toggle)
                    // Two cards share the row, so the label stays short and the tooltip
                    // carries the detail.
                    if let command = standing.command() {
                        CopyButton("Copy", size: 12.5) { command }
                            .appTooltip("Copy the \(standing.title) command for this server")
                    }
                    Spacer(minLength: 0)
                }
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
            }

            ForEach(notes) { note in
                Text(note.text)
                    .font(note.mono ? .mono(11) : .system(size: 11.5))
                    .foregroundStyle(note.tint ?? Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface(cornerRadius: 12)
    }

    private var dot: Color {
        switch tone {
        case .inSync: Theme.dotOn
        case .outOfSync: Theme.attention
        case .notRegistered, .unsupported: Theme.dotOff
        }
    }

    private var stateText: String {
        switch tone {
        case .inSync: "in sync"
        case .outOfSync: "out of sync"
        case .notRegistered: "not registered"
        case .unsupported: "unsupported"
        }
    }

    private var stateTint: Color {
        switch tone {
        case .inSync: Theme.accent
        case .outOfSync: Theme.attentionText
        case .notRegistered, .unsupported: .secondary
        }
    }
}

// MARK: - Small pieces

private struct StatePill: View {
    let state: RunState

    private var label: String {
        switch state {
        case .stopped: "stopped"
        case .running: "running"
        case .failed: "failed"
        }
    }

    private var color: Color {
        switch state {
        case .stopped: Theme.dotOff
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
