import SwiftUI

struct AddServerView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var scope: Scope = .platform
    @State private var env: DeployEnv = .dev
    @State private var token = ""

    private var name: String { Grafana.name(scope, env) }
    private var url: String { Grafana.url(scope, env) }
    private var exists: Bool { store.servers.contains { $0.name == name } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Add Grafana server").font(.serif(26, .semibold))

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "SCOPE")
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "ENVIRONMENT")
                Picker("", selection: $env) {
                    ForEach(DeployEnv.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "SERVICE ACCOUNT TOKEN")
                SecureField("glsa_xxxxxxxxxxxxxxxx", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .font(.mono(13))
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

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(exists ? "Replace" : "Add") {
                    store.upsertGrafana(scope: scope, env: env, token: token)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
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
