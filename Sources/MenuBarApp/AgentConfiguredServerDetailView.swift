import SwiftUI

struct AgentConfiguredServerDetailView: View {
    let server: AgentConfiguredServer

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ownershipCard
                    if server.hasDifferentConfigurations {
                        differenceCard
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "AGENT CONFIGURATIONS")
                        ForEach(server.registrations) { registrationCard($0) }
                    }
                }
                .padding(28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.serif(24, .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sourceSummary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text("read only")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.05)))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private var sourceSummary: String {
        let titles = server.registrations.map(\.source.title)
        if titles.count == 2 { return "Configured in \(titles[0]) and \(titles[1])" }
        return "Configured in \(titles.first ?? "an agent")"
    }

    private var ownershipCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Configured outside Code Station")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("Code Station shows this server for visibility. It does not start, edit, sync or remove configurations owned by an agent.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.24)))
    }

    private var differenceCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.warningText)
                .padding(.top, 1)
            Text("Claude Code and Codex use different connection details for this server name.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.warningBackground))
    }

    private func registrationCard(_ registration: AgentConfiguredServer.Registration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(registration.enabled ? Theme.dotOn : Theme.dotOff)
                    .frame(width: 8, height: 8)
                Text(registration.source.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(registration.enabled ? "configured" : "disabled")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(registration.enabled ? Theme.accent : Color.secondary)
            }
            .padding(16)

            Divider().overlay(Theme.hairline)

            VStack(alignment: .leading, spacing: 2) {
                detailRow(label: "TRANSPORT") {
                    Chip(text: registration.transport)
                }
                if let command = registration.command {
                    detailRow(label: "COMMAND") {
                        HStack(spacing: 8) {
                            Chip(text: command)
                            if !registration.args.isEmpty {
                                Text("\(registration.args.count) argument\(registration.args.count == 1 ? "" : "s")")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if let url = registration.url {
                    detailRow(label: "URL") {
                        Text(displayURL(url))
                            .font(.mono(12.5))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if !registration.env.isEmpty {
                    detailRow(label: "VARIABLES") {
                        hiddenValues(registration.env.keys.sorted())
                    }
                }
                if !registration.headers.isEmpty {
                    detailRow(label: "HEADERS") {
                        hiddenValues(registration.headers.keys.sorted())
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private func detailRow(label: String,
                           @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.mono(11, .semibold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
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
}
