import SwiftUI
import CodeStationCore

// A server one or more agents own. Its connection details stay read only, but the
// status each agent reports, its on or off switch and its sign-in are offered here,
// through each agent's own commands, as far as that agent supports them.
struct AgentConfiguredServerDetailView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(ClaudeCodeManager.self) private var claude
    @Environment(CodexCodeManager.self) private var codex
    @Environment(CopilotCodeManager.self) private var copilot
    let server: AgentConfiguredServer
    // The agent whose sidebar row was picked, so its card comes first.
    let leading: AgentConfiguredServer.Source

    // Cards whose agent has been asked to change something, so they can say when the
    // change takes hold.
    @State private var changed: Set<AgentConfiguredServer.Source> = []
    @State private var copied: AgentConfiguredServer.Source?

    private typealias Registration = AgentConfiguredServer.Registration
    private typealias Source = AgentConfiguredServer.Source

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if server.hasDifferentConfigurations {
                        differenceCard
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SectionLabel("AGENT CONFIGURATIONS")
                            Spacer()
                            checkedLabel
                        }
                        ForEach(orderedRegistrations) { registrationCard($0) }
                    }
                    ownershipLine
                }
                .padding(28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var orderedRegistrations: [Registration] {
        server.registrations.filter { $0.source == leading }
            + server.registrations.filter { $0.source != leading }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.serif(24, .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Configured in \(owners)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let status = server.worstStatus {
                AgentStatusPill(status: status)
            }
            ActionButton(title: "Check again", tone: .outlined, size: 13,
                         icon: "arrow.clockwise", action: checkAgain)
                .disabled(isChecking)
                .appTooltip("Ask \(owners) how this server is doing")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private var owners: String {
        let titles = server.registrations.map(\.source.title)
        guard let last = titles.last else { return "an agent" }
        guard titles.count > 1 else { return last }
        return titles.dropLast().joined(separator: ", ") + " and " + last
    }

    private var isChecking: Bool {
        server.registrations.contains { $0.work == .checking }
    }

    @ViewBuilder private var checkedLabel: some View {
        if isChecking {
            Text("Checking…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else if let checkedAt {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text("Checked \(Self.checkedPhrase(since: checkedAt, now: context.date))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // The oldest reading among the server's agents, since that is how stale the page is.
    private var checkedAt: Date? {
        let dates = server.registrations.map { registration -> Date? in
            switch registration.source {
            case .claudeCode: claude.checkedAt
            case .codex: codex.checkedAt
            case .copilot: copilot.checkedAt
            }
        }
        guard !dates.contains(where: { $0 == nil }) else { return nil }
        return dates.compactMap { $0 }.min()
    }

    static func checkedPhrase(since date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded())
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds) seconds ago" }
        let minutes = Int((Double(seconds) / 60).rounded())
        return minutes == 1 ? "a minute ago" : "\(minutes) minutes ago"
    }

    private var differenceCard: some View {
        WarningStrip("The agents use different connection details for this server name.")
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Agent card

    private func registrationCard(_ registration: Registration) -> some View {
        let status = registration.status
        let source = registration.source
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                AgentMarkTile(source: source)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(source.title).font(.system(size: 14, weight: .semibold))
                        AgentStatusDot(status: status)
                        Text(status.word)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(status.tint)
                    }
                    .accessibilityElement(children: .combine)

                    Text(caption(registration))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    notes(registration)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                actions(registration)
                    .fixedSize()
            }
            .padding(16)

            Divider().overlay(Theme.hairline)

            connectionRows(registration)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12)
    }

    private func caption(_ registration: Registration) -> String {
        let title = registration.source.title
        switch registration.status {
        case .working(.checking): return "Asking \(title) how this server is doing."
        case .working(.signingIn):
            return "Finish signing in in your browser. This card updates when \(title) hears back."
        case .working(.turningOn), .working(.turningOff): return "Saving the change with \(title)."
        case .off: return "\(title) skips this server until it is turned back on."
        case .needsSignIn: return "\(title) can't use this server until you sign in."
        case .cantConnect:
            let what = registration.isRemote
                ? "Check that the URL below is right and that you are on the network it needs."
                : "Check that the command below runs on its own."
            return "\(title) could not reach this server. \(what)"
        case .connected: return "\(title) reached this server and can use its tools."
        case .on:
            return registration.signedIn
                ? "Signed in. \(title) loads this server when a session starts."
                : "\(title) loads this server when a session starts. It does not say whether the server answers."
        }
    }

    @ViewBuilder private func notes(_ registration: Registration) -> some View {
        let source = registration.source
        if copied == source, let command = signInCommand(registration) {
            Text("Copied: \(command)")
                .font(.mono(11))
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = work(for: source).errors[server.name] {
            Text(error)
                .font(.mono(11))
                .foregroundStyle(Theme.deletion)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if changed.contains(source), registration.work == nil {
            note(source.reloadNote)
        }
        if !source.canSwitch {
            note("Claude Code turns a server off per project. Use /mcp inside a session.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func actions(_ registration: Registration) -> some View {
        let source = registration.source
        HStack(spacing: 10) {
            if registration.work == .signingIn {
                ProgressView().controlSize(.small)
                InlineLink(title: "Cancel") { work(for: source).cancel(server.name) }
            } else if registration.work != nil {
                ProgressView().controlSize(.small)
            } else if registration.status == .needsSignIn, registration.offersSignIn {
                ActionButton(title: "Sign in", tone: .green, height: 28, size: 12) {
                    signIn(registration)
                }
            } else if registration.status == .cantConnect {
                ActionButton(title: "Check again", tone: .outlined, height: 28, size: 12,
                             action: checkAgain)
            }

            if source.canSwitch {
                Toggle(isOn: switchBinding(registration)) { EmptyView() }
                    .toggleStyle(.appSwitch)
                    .disabled(registration.work != nil)
                    .accessibilityLabel("Use \(server.name) in \(source.title)")
                    .appTooltip(registration.enabled
                                ? "Turn off in \(source.title)"
                                : "Turn on in \(source.title)")
            }

            if registration.offersSignIn {
                GlyphButton(icon: "ellipsis", side: 28)
                    .appMenu { menuEntries(registration) }
                    .accessibilityLabel("More for \(source.title)")
            }
        }
    }

    private func menuEntries(_ registration: Registration) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if registration.signedIn, registration.work == nil {
            entries.append(.item("Sign out") { signOut(registration) })
        }
        if let command = signInCommand(registration) {
            entries.append(.item("Copy sign-in command") { copy(command, for: registration.source) })
        }
        return entries
    }

    private func signInCommand(_ registration: Registration) -> String? {
        guard registration.offersSignIn else { return nil }
        return [registration.source.command, "mcp", "login", server.name]
            .map(\.shellQuoted).joined(separator: " ")
    }

    // MARK: - Connection

    private func connectionRows(_ registration: Registration) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            detailRow("TRANSPORT") {
                MonoChip(text: registration.transport, size: 13, bordered: true)
            }
            if let command = registration.command {
                detailRow("COMMAND") {
                    HStack(spacing: 8) {
                        MonoChip(text: command, size: 13, bordered: true)
                        if !registration.args.isEmpty {
                            Text(counted(registration.args.count, "argument"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let url = registration.url {
                detailRow("URL") {
                    Text(displayURL(url))
                        .font(.mono(12.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if !registration.env.isEmpty {
                detailRow("VARIABLES") {
                    hiddenValues(registration.env.keys.sorted())
                }
            }
            if !registration.headers.isEmpty {
                detailRow("HEADERS") {
                    hiddenValues(registration.headers.keys.sorted())
                }
            }
        }
    }

    private func detailRow(_ label: String,
                           @ViewBuilder content: () -> some View) -> some View {
        LabeledRow(label, content: content)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
    }

    private func hiddenValues(_ keys: [String]) -> some View {
        HStack(spacing: 8) {
            Text(keys.joined(separator: ", "))
                .font(.mono(12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("values hidden")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secret)
                .fixedSize()
        }
    }

    private func displayURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? value
    }

    // MARK: - Ownership

    private var ownershipLine: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
            Text(ownershipText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ownershipText: String {
        let many = server.registrations.count > 1
        var does: [String] = []
        if server.registrations.contains(where: \.source.canSwitch) { does.append("turns it on or off") }
        if server.registrations.contains(where: \.offersSignIn) { does.append("signs you in") }
        let commands = many ? "each agent's" : "\(owners)'s"
        let doing = does.isEmpty
            ? "Code Station shows it so you can see what your agents load."
            : "Code Station only \(does.joined(separator: " and ")), using \(commands) own commands."
        return "\(owners) \(many ? "own" : "owns") this server's connection details, so they can't be edited or removed here. \(doing)"
    }

    // MARK: - Actions

    private func work(for source: Source) -> AgentServerWork {
        switch source {
        case .claudeCode: claude.serverWork
        case .codex: codex.serverWork
        case .copilot: copilot.serverWork
        }
    }

    private func checkAgain() {
        for registration in server.registrations {
            switch registration.source {
            case .claudeCode: claude.checkHealth(of: server.name)
            case .codex: codex.refresh(store.servers)
            case .copilot: copilot.refresh(store.servers)
            }
        }
    }

    private func switchBinding(_ registration: Registration) -> Binding<Bool> {
        Binding {
            registration.enabled
        } set: { enabled in
            changed.insert(registration.source)
            switch registration.source {
            case .claudeCode: break
            case .codex: codex.setEnabled(enabled, for: server.name, servers: store.servers)
            case .copilot: copilot.setEnabled(enabled, for: server.name, servers: store.servers)
            }
        }
    }

    private func signIn(_ registration: Registration) {
        changed.insert(registration.source)
        switch registration.source {
        case .claudeCode: claude.signIn(server.name)
        case .codex: codex.signIn(server.name, servers: store.servers)
        case .copilot: break
        }
    }

    private func signOut(_ registration: Registration) {
        changed.insert(registration.source)
        switch registration.source {
        case .claudeCode: claude.signOut(server.name)
        case .codex: codex.signOut(server.name, servers: store.servers)
        case .copilot: break
        }
    }

    private func copy(_ command: String, for source: Source) {
        Pasteboard.copy(command)
        copied = source
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if copied == source { copied = nil }
        }
    }
}

// MARK: - Shared pieces

extension AgentConfiguredServer.Status {
    var tint: Color {
        switch self {
        case .connected, .on: Theme.accent
        case .needsSignIn: Theme.attentionText
        case .cantConnect: Theme.deletion
        case .off, .working: .secondary
        }
    }
}

// Filled once the agent has reached the server, a ring when it only loads it, and a
// breathing grey dot while work is in flight.
struct AgentStatusDot: View {
    let status: AgentConfiguredServer.Status
    var size: CGFloat = 8

    var body: some View {
        Group {
            switch status {
            case .connected: Circle().fill(Theme.dotOn)
            case .on: Circle().strokeBorder(Theme.dotOn, lineWidth: 2)
            case .needsSignIn: Circle().fill(Theme.attention)
            case .cantConnect: Circle().fill(Theme.deletion)
            case .off: Circle().fill(Theme.dotOff)
            case .working:
                BreathingCircle(colour: Theme.dotOff, fullOpacity: 0.35)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// The same shape as the run state pill on Code Station's own servers.
private struct AgentStatusPill: View {
    let status: AgentConfiguredServer.Status

    var body: some View {
        HStack(spacing: 6) {
            AgentStatusDot(status: status, size: 7)
            Text(status.word)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.04)))
        .accessibilityElement(children: .combine)
    }
}

private struct AgentMarkTile: View {
    let source: AgentConfiguredServer.Source

    var body: some View {
        Image(systemName: source.symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 34, height: 34)
            .surface(Theme.field, cornerRadius: 9)
            .accessibilityHidden(true)
    }
}
