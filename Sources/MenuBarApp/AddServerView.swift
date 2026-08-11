import SwiftUI

struct AddServerView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var scope: String = SiteDefaults.current.grafanaPresets.first?.scope ?? ""
    @State private var env: String = SiteDefaults.current.grafanaPresets.first?.environment ?? ""
    @State private var token = ""

    private var presets: [SiteDefaults.Grafana.Preset] { SiteDefaults.current.grafanaPresets }

    // One pill per scope, in the order the site file lists them, and only the
    // environments that scope actually has an instance in.
    private var scopes: [String] {
        presets.map(\.scope).reduce(into: []) { unique, scope in
            if !unique.contains(scope) { unique.append(scope) }
        }
    }

    private var environments: [String] {
        presets.filter { $0.scope == scope }.map(\.environment)
    }

    private var preset: SiteDefaults.Grafana.Preset? {
        presets.first { $0.scope == scope && $0.environment == env }
    }

    private var name: String { preset?.name ?? "" }
    private var url: String { preset?.url ?? "" }
    private var exists: Bool { store.servers.contains { $0.name == name } }

    private var incomplete: Bool {
        preset == nil || token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Add Grafana server").font(.serif(26, .semibold))

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "SCOPE")
                HStack(spacing: 4) {
                    ForEach(scopes, id: \.self) { choice in
                        ChoicePill(title: choice, selected: scope == choice) {
                            scope = choice
                            // The environments differ per scope, so the one picked before
                            // may not exist under the new scope.
                            if !environments.contains(env) { env = environments.first ?? "" }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "ENVIRONMENT")
                HStack(spacing: 4) {
                    ForEach(environments, id: \.self) { choice in
                        ChoicePill(title: choice, selected: env == choice) { env = choice }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "SERVICE ACCOUNT TOKEN")
                SecureField("glsa_xxxxxxxxxxxxxxxx", text: $token)
                    .textFieldStyle(.plain)
                    .font(.mono(13))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "PREVIEW")
                labeled("name", name)
                labeled("url", url)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))

            if exists {
                Label("This scope-env already exists. Adding will replace its token and URL.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.secret)
            }

            HStack(spacing: 10) {
                Spacer()
                Button { dismiss() } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button {
                    if let preset { store.upsertGrafana(preset: preset, token: token) }
                    dismiss()
                } label: {
                    Text(exists ? "Replace" : "Add")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentFill))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(incomplete)
                .opacity(incomplete ? 0.4 : 1)
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(Theme.background)
    }

    private func labeled(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key).font(.mono(12, .semibold)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            Text(value).font(.mono(12)).textSelection(.enabled)
        }
    }
}
