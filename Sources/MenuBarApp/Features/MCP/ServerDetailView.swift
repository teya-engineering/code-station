import SwiftUI

// The detail is ranked around what breaks: the credential first, then where the server
// is registered, then how it connects. Run controls sit in a fixed header so they stay
// at hand while the rest scrolls.
struct ServerDetailView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(ProcessManager.self) private var processes
    @Environment(ClaudeCodeManager.self) private var claude
    @Environment(CodexCodeManager.self) private var codex
    @Environment(CopilotCodeManager.self) private var copilot
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
                    VStack(alignment: .leading, spacing: Space.xxxl) {
                        credentialSection(server)
                        registeredSection(server)
                        connectionSection(server)
                        outputSection
                        Divider().overlay(Theme.hairline)
                        footer(server)
                    }
                    .padding(Space.xxxl)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .sheet(isPresented: $showingRawJSON) { RawJSONView() }
            .onAppear { claude.checkHealthIfIdle(of: server.name) }
        }
    }

    // MARK: - Header

    private func header(_ server: Server) -> some View {
        let state = processes.state(serverID)
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(server.name)
                        .font(Typography.display)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: Space.md) {
                        Text(server.transport)
                            .font(Typography.code)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(Typography.detail)
                            .foregroundStyle(.tertiary)
                        Text(server.description)
                            .font(Typography.body)
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
                                 tone: state.isActive ? .danger : .green, size: Typography.Size.body,
                                 icon: state.isActive ? "stop.fill" : "play.fill") {
                        processes.toggle(server)
                    }
                    .contentTransition(.interpolate)
                    .motion(Motion.reveal, value: state.isActive)
                }
                GlyphButton(icon: "ellipsis")
                    .appMenu {
                        [.item("View raw JSON") { showingRawJSON = true },
                         .item("Delete server", kind: .destructive) { confirmDelete(server) }]
                    }
            }
            if case let .failed(message) = state {
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Space.xxxl)
        .padding(.vertical, Space.lg)
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
        return HStack(spacing: Space.xs) {
            Text(title).font(Typography.data)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xxs)
        .background(Capsule().fill(Theme.field))
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
            VStack(alignment: .leading, spacing: Space.lg) {
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
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                SectionLabel("REGISTERED WITH")
                Spacer()
                if [claudeNeedsSync(server), codexNeedsSync(server), copilotNeedsSync(server)]
                    .filter({ $0 }).count > 1 {
                    InlineLink(title: "Sync all", size: Typography.Size.body) {
                        syncAll(server)
                    }
                }
            }
            // Stacked rather than side by side: three cards in a row leave each too
            // narrow for its buttons, which then push the whole sheet wider than it is.
            VStack(spacing: Space.md) {
                AgentCard(standing: claudeStanding(server))
                AgentCard(standing: codexStanding(server))
                AgentCard(standing: copilotStanding(server))
            }
        }
    }

    private func claudeNeedsSync(_ server: Server) -> Bool {
        claude.available && (!claude.isRegistered(server.name) || claude.isOutOfSync(server))
    }

    private func codexNeedsSync(_ server: Server) -> Bool {
        codex.available && codex.supports(server)
            && (!codex.isRegistered(server.name) || codex.isOutOfSync(server))
    }

    private func copilotNeedsSync(_ server: Server) -> Bool {
        copilot.available && copilot.supports(server)
            && (!copilot.isRegistered(server.name) || copilot.isOutOfSync(server))
    }

    private func syncAll(_ server: Server) {
        if claudeNeedsSync(server) {
            claude.isRegistered(server.name) ? claude.reregister(server) : claude.add(server)
        }
        if codexNeedsSync(server) {
            codex.isRegistered(server.name) ? codex.reregister(server) : codex.add(server)
        }
        if copilotNeedsSync(server) {
            copilot.isRegistered(server.name) ? copilot.reregister(server) : copilot.add(server)
        }
    }

    // The managers answer the same questions but share no type, so each is read into
    // the one shape the card draws from.
    private func claudeStanding(_ server: Server) -> AgentStanding {
        AgentStanding(
            title: "Claude Code",
            available: claude.available,
            registered: claude.isRegistered(server.name),
            outOfSync: claude.isOutOfSync(server),
            busy: claude.isBusy(server.name),
            error: claude.errors[server.name] ?? claude.serverWork.errors[server.name],
            unsupported: nil,
            registeredCaption: "Registered as a user-scope MCP server.",
            reloadNote: "Restart your Claude Code session to load the change.",
            toggle: { claude.isRegistered(server.name) ? claude.remove(server.name) : claude.add(server) },
            update: { claude.reregister(server) },
            command: { claude.addCommand(for: server) },
            reach: claude.registration(of: server.name),
            signIn: { claude.signIn(server.name) },
            cancelSignIn: { claude.serverWork.cancel(server.name) },
            checkAgain: { claude.checkHealth(of: server.name) })
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

    private func copilotStanding(_ server: Server) -> AgentStanding {
        AgentStanding(
            title: "Copilot",
            available: copilot.available,
            registered: copilot.isRegistered(server.name),
            outOfSync: copilot.isOutOfSync(server),
            busy: copilot.isBusy(server.name),
            error: copilot.errors[server.name],
            unsupported: copilot.supports(server) ? nil : copilotSupportCaption(server),
            registeredCaption: "Registered in Copilot's user MCP configuration.",
            reloadNote: "The next Copilot turn loads the change.",
            toggle: { copilot.isRegistered(server.name) ? copilot.remove(server.name) : copilot.add(server) },
            update: { copilot.reregister(server) },
            command: { copilot.addCommand(for: server) })
    }

    private func copilotSupportCaption(_ server: Server) -> String {
        if server.isRemote, !["http", "sse"].contains(server.transport) {
            return "Copilot supports streamable HTTP and SSE, not \(server.transport.uppercased())."
        }
        return "A command or URL is needed before Copilot can register this server."
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
        return VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                SectionLabel("CONNECTION")
                Spacer()
                if !server.isRemote {
                    InlineLink(title: editingConnection ? "Done" : "Edit", size: Typography.Size.body) {
                        editingConnection.toggle()
                    }
                }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                connectionRow(server.isRemote ? "URL" : "COMMAND") {
                    if let command = server.command {
                        HStack(spacing: Space.sm) {
                            MonoChip(text: command, size: Typography.Size.body, bordered: true)
                            ForEach(server.args, id: \.self) { MonoChip(text: $0, size: Typography.Size.body, bordered: true) }
                        }
                    } else if let url = server.url {
                        Text(url)
                            .font(Font.mono(Typography.Size.body))
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
                                .font(Font.mono(Typography.Size.body))
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
                            .font(Font.mono(Typography.Size.body))
                            .foregroundStyle(Theme.accent)
                            .textSelection(.enabled)
                    }
                }
                if editingConnection && !server.isRemote {
                    InlineLink(title: "+ Add variable", size: Typography.Size.body) {
                        store.addBlankVar(to: serverID)
                    }
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.md)
                }
            }
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(cornerRadius: Radius.floating)
        }
    }

    private func connectionRow(_ label: String,
                               @ViewBuilder content: () -> some View) -> some View {
        LabeledRow(label, width: 180, content: content)
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.md)
    }

    private func editableVarRow(_ variable: EnvVar) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xl) {
            TextField("KEY", text: store.keyBinding(variable.id, in: serverID))
                .textFieldStyle(.plain)
                .font(Typography.data.weight(.semibold))
                .frame(width: 180, alignment: .leading)
            TextField("value", text: store.valueBinding(variable.id, in: serverID))
                .textFieldStyle(.plain)
                .font(Font.mono(Typography.Size.body))
            Button {
                store.removeVar(variable.id, from: serverID)
            } label: {
                Image(systemName: "trash").font(Typography.detail)
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
    }

    // MARK: - Output

    @ViewBuilder private var outputSection: some View {
        let log = processes.logs[serverID] ?? ""
        if !log.isEmpty {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack {
                    SectionLabel("OUTPUT")
                    Spacer()
                    InlineLink(title: "Clear", size: Typography.Size.body) { processes.clearLog(serverID) }
                }
                ScrollView {
                    Text(log)
                        .font(Typography.data)
                        .foregroundStyle(Theme.terminalText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.lg)
                }
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: Radius.floating).fill(Theme.terminal))
            }
        }
    }

    // MARK: - Footer

    private func confirmDelete(_ server: Server) {
        dialogs.show(.impact("Delete \(server.name)?",
                             rows: [.init(title: "Server entry",
                                          detail: "Removed from \(store.configURL.path.abbreviatedPath).")],
                             action: "Delete server") { store.remove(serverID) })
    }

    private func footer(_ server: Server) -> some View {
        HStack(spacing: Space.xxl) {
            InlineLink(title: "View raw JSON", size: Typography.Size.body) { showingRawJSON = true }
            InlineLink(title: "Delete server", size: Typography.Size.body, tint: .red.opacity(0.85)) {
                confirmDelete(server)
            }
            Spacer()
            if let modified = store.lastModified {
                Text("Last modified \(modified.formatted(.relative(presentation: .named)))")
                    .font(Typography.detail).foregroundStyle(.secondary)
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
            HStack(spacing: Space.md) {
                if editable {
                    TextField("KEY", text: $key)
                        .textFieldStyle(.plain)
                        .font(Font.mono(Typography.Size.body, .semibold))
                        .fixedSize()
                } else {
                    Text(key).font(Font.mono(Typography.Size.body, .semibold))
                }
                MonoChip(text: "SECRET", size: Typography.Size.micro, tint: Theme.secret, mono: false)
                Spacer(minLength: 16)
                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash").font(Typography.detail)
                    }
                    .buttonStyle(.plain)
                    .hoverLift(amount: Motion.smallLift)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.lg)

            Divider().overlay(Theme.hairline)

            HStack(spacing: Space.lg) {
                if revealed {
                    if editable {
                        TextField("value", text: $value)
                            .textFieldStyle(.plain)
                            .font(Font.mono(Typography.Size.body))
                    } else {
                        Text(value)
                            .font(Font.mono(Typography.Size.body))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    InlineLink(title: "Hide", size: Typography.Size.body) { revealed = false }
                } else {
                    Text(String(repeating: "•", count: 18))
                        .font(Font.mono(Typography.Size.body))
                        .foregroundStyle(.secondary)
                    InlineLink(title: "Reveal", size: Typography.Size.body) { revealed = true }
                }
                Spacer(minLength: 16)
                Text("Stored in the config file - treat it like a password.")
                    .font(Typography.detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.lg)
        }
        .background(RoundedRectangle(cornerRadius: Radius.floating).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.floating)
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
    // What the agent last said about reaching the server. Only Claude Code checks, so
    // the others leave it out and show the config match alone.
    var reach: AgentConfiguredServer.Registration? = nil
    var signIn: () -> Void = {}
    var cancelSignIn: () -> Void = {}
    var checkAgain: () -> Void = {}
}

// One agent the server can be registered with.
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

    // A matching config is not enough when the agent cannot reach the server, so once
    // the entry is in sync the card speaks for what the agent last saw. A plain "on"
    // says nothing new, so the card stays on "in sync".
    private var reachStatus: AgentConfiguredServer.Status? {
        guard tone == .inSync, let status = standing.reach?.status, status != .on else { return nil }
        return status
    }

    private var caption: String {
        switch tone {
        case .unsupported: standing.unsupported ?? ""
        case .notRegistered: "Not registered - \(standing.title) can't see this server yet."
        case .outOfSync: "The token or URL here differs from the registered one."
        case .inSync: reachCaption ?? standing.registeredCaption
        }
    }

    private var reachCaption: String? {
        switch reachStatus {
        case .needsSignIn: "\(standing.title) can't use this server until you sign in."
        case .cantConnect: "\(standing.title) could not reach this server. Check the connection below."
        case .working(.signingIn):
            "Finish signing in in your browser. This card updates when \(standing.title) hears back."
        default: nil
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
        HStack(alignment: .top, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.md) {
                    if let reachStatus {
                        AgentStatusDot(status: reachStatus)
                    } else {
                        Circle().fill(dot).frame(width: 8, height: 8)
                    }
                    Text(standing.title).font(Typography.body.weight(.semibold))
                    Text(reachStatus?.word ?? stateText)
                        .font(Typography.label)
                        .foregroundStyle(reachStatus?.tint ?? stateTint)
                    if standing.busy { LoopSpinner(size: 14) }
                }

                Text(caption)
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(notes) { note in
                    Text(note.text)
                        .font(note.mono ? Typography.data : Typography.detail)
                        .foregroundStyle(note.tint ?? Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if tone != .unsupported {
                HStack(spacing: Space.md) {
                    reachAction
                    if let command = standing.command() {
                        CopyButton("Copy", size: Typography.Size.body) { command }
                            .appTooltip("Copy the \(standing.title) command for this server")
                    }
                    if tone == .outOfSync {
                        ActionButton(title: "Update", tone: .attention, height: ControlHeight.md, size: Typography.Size.detail,
                                     action: standing.update)
                    }
                    ActionButton(title: standing.registered ? "Remove" : "Add",
                                 tone: standing.registered ? .danger : .green,
                                 height: ControlHeight.md, size: Typography.Size.detail, action: standing.toggle)
                }
                .fixedSize()
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Radius.floating)
    }

    @ViewBuilder private var reachAction: some View {
        switch reachStatus {
        case .working(.signingIn):
            InlineLink(title: "Cancel", action: standing.cancelSignIn)
        case .needsSignIn where standing.reach?.offersSignIn == true:
            ActionButton(title: "Sign in", tone: .green, height: ControlHeight.md, size: Typography.Size.detail,
                         action: standing.signIn)
        case .cantConnect:
            ActionButton(title: "Check again", tone: .outlined, height: ControlHeight.md, size: Typography.Size.detail,
                         action: standing.checkAgain)
        default:
            EmptyView()
        }
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
        HStack(spacing: Space.sm) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(Typography.body.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
        .background(Capsule().fill(Theme.sunken))
    }
}
