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
    @State private var copiedClaudeCommand = false
    @State private var copiedCodexCommand = false
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
            .onChange(of: server.env) {
                copiedClaudeCommand = false
                copiedCodexCommand = false
            }
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
                    Button {
                        processes.toggle(server)
                    } label: {
                        Label(state.isActive ? "Stop" : "Start",
                              systemImage: state.isActive ? "stop.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9)
                                .fill(state.isActive ? Theme.deletion : Theme.accentFill))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
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
                claudeCard(server)
                codexCard(server)
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

    private func claudeCard(_ server: Server) -> some View {
        let registered = claude.isRegistered(server.name)
        let outOfSync = claude.isOutOfSync(server)

        let tone: AgentCard.Tone
        let caption: String
        if !registered {
            tone = .notRegistered
            caption = "Not registered - Claude Code can't see this server yet."
        } else if outOfSync {
            tone = .outOfSync
            caption = "The token or URL here differs from the registered one."
        } else {
            tone = .inSync
            caption = "Registered as a user-scope MCP server."
        }

        var notes: [AgentCard.Note] = []
        if registered {
            notes.append(.init(text: "Restart your Claude Code session to load the change."))
        }
        if !claude.available {
            notes.append(.init(text: "Claude Code CLI not found on PATH.", tint: Theme.deletion))
        }
        if let error = claude.errors[server.name] {
            notes.append(.init(text: error, tint: Theme.deletion, mono: true))
        }

        return AgentCard(
            title: "Claude Code",
            tone: tone,
            caption: caption,
            busy: claude.isBusy(server.name),
            enabled: claude.available && !claude.isBusy(server.name),
            registered: registered,
            onToggle: { registered ? claude.remove(server.name) : claude.add(server) },
            onUpdate: { claude.reregister(server) },
            copied: copiedClaudeCommand,
            onCopy: {
                if let command = claude.addCommand(for: server) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedClaudeCommand = true
                }
            },
            notes: notes)
    }

    private func codexCard(_ server: Server) -> some View {
        let supported = codex.supports(server)
        let registered = codex.isRegistered(server.name)
        let outOfSync = codex.isOutOfSync(server)

        let tone: AgentCard.Tone
        let caption: String
        if !supported {
            tone = .unsupported
            caption = codexSupportCaption(server)
        } else if !registered {
            tone = .notRegistered
            caption = "Not registered - Codex can't see this server yet."
        } else if outOfSync {
            tone = .outOfSync
            caption = "The token or URL here differs from the registered one."
        } else {
            tone = .inSync
            caption = "Registered in Codex's MCP configuration."
        }

        var notes: [AgentCard.Note] = []
        if registered {
            notes.append(.init(text: "The next Codex turn loads the change."))
        }
        if !codex.available {
            notes.append(.init(text: "Codex CLI not found on PATH.", tint: Theme.deletion))
        }
        if let error = codex.errors[server.name] {
            notes.append(.init(text: error, tint: Theme.deletion, mono: true))
        }

        return AgentCard(
            title: "Codex",
            tone: tone,
            caption: caption,
            busy: codex.isBusy(server.name),
            enabled: supported && codex.available && !codex.isBusy(server.name),
            registered: registered,
            onToggle: { registered ? codex.remove(server.name) : codex.add(server) },
            onUpdate: { codex.reregister(server) },
            copied: copiedCodexCommand,
            onCopy: {
                if let command = codex.addCommand(for: server) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedCodexCommand = true
                }
            },
            notes: notes)
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
                connectionRow(label: server.isRemote ? "URL" : "COMMAND") {
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
                        connectionRow(label: variable.key.isEmpty ? "KEY" : variable.key) {
                            Text(variable.value)
                                .font(.mono(13))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if let endpoint = processes.endpoints[serverID] {
                    connectionRow(label: "SERVING AT") {
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
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
        }
    }

    private func connectionRow(label: String,
                               @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.mono(11, .semibold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 180, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
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

    // MARK: - Footer

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
                SecretBadge()
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

// One agent the server can be registered with. The two cards share a row, so each keeps
// to a compact pill-and-link layout instead of a full-width toolbar.
private struct AgentCard: View {
    enum Tone { case inSync, outOfSync, notRegistered, unsupported }

    struct Note: Identifiable {
        let id = UUID()
        let text: String
        var tint: Color? = nil
        var mono = false
    }

    let title: String
    let tone: Tone
    let caption: String
    let busy: Bool
    let enabled: Bool
    let registered: Bool
    let onToggle: () -> Void
    let onUpdate: () -> Void
    let copied: Bool
    let onCopy: () -> Void
    let notes: [Note]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) }
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
                        pill("Update", fill: Theme.secret, action: onUpdate)
                    }
                    pill(registered ? "Remove" : "Add",
                         fill: registered ? Theme.deletion : Theme.accentFill,
                         action: onToggle)
                    // Two cards share the row, so the label stays short and the tooltip
                    // carries the detail.
                    InlineLink(title: copied ? "Copied" : "Copy", size: 12.5,
                               action: onCopy)
                        .appTooltip("Copy the \(title) command for this server")
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
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private func pill(_ title: String, fill: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(fill))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
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

private struct SecretBadge: View {
    var body: some View {
        Text("SECRET")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.secret)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.secret.opacity(0.14)))
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
