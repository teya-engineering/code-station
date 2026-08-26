import SwiftUI

struct AddServerView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let group: SiteDefaults.MCP.PresetGroup

    @State private var presetName: String
    @State private var environmentValues: [String: String] = [:]
    @State private var headerValues: [String: String] = [:]

    init(group: SiteDefaults.MCP.PresetGroup) {
        self.group = group
        _presetName = State(initialValue: group.presets.first?.name ?? "")
    }

    private var presets: [SiteDefaults.MCP.Preset] { group.presets }
    private var preset: SiteDefaults.MCP.Preset? {
        presets.first { $0.name == presetName }
    }
    private var exists: Bool {
        guard let preset else { return false }
        return store.servers.contains { $0.name == preset.name }
    }
    private var incomplete: Bool {
        guard let preset, preset.hasConnection else { return true }
        return requiredValues(in: preset.env).contains {
            environmentValues[$0.key]?.trimmed.isEmpty != false
        } || requiredValues(in: preset.headers).contains {
            headerValues[$0.key]?.trimmed.isEmpty != false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(group.addTitle).font(.serif(26, .semibold))

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "PRESET")
                ActionButton(title: preset?.label ?? "Choose a preset",
                             tone: .sunken,
                             disclosure: true,
                             fills: true)
                    .appMenu(matchWidth: true) {
                        presets.map { choice in
                            .item(choice.label,
                                  checked: choice.name == presetName,
                                  subtitle: choice.name,
                                  detail: ServerEnvironmentChoice.title(
                                    for: choice.environmentTag),
                                  action: { select(choice) })
                        }
                    }
            }

            if let preset {
                let environment = requiredValues(in: preset.env)
                let headers = requiredValues(in: preset.headers)
                if !environment.isEmpty || !headers.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "REQUIRED VALUES")
                        ForEach(environment) { value in
                            valueField(value,
                                       text: dictionaryBinding(value.key,
                                                               in: $environmentValues))
                        }
                        ForEach(headers) { value in
                            valueField(value,
                                       text: dictionaryBinding(value.key,
                                                               in: $headerValues))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "PREVIEW")
                    labeled("name", preset.name)
                    labeled("transport", preset.isRemote ? (preset.type ?? "http") : "stdio")
                    if let command = preset.command {
                        labeled("command", ([command] + (preset.args ?? [])).joined(separator: " "))
                    }
                    if let url = preset.url { labeled("url", url) }
                    labeled("environment",
                            ServerEnvironmentChoice.title(for: preset.environmentTag))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            }

            if exists {
                Label("A server with this name already exists. Adding will replace its configuration.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secret)
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
                    if let preset {
                        store.upsert(preset: preset,
                                     environmentValues: environmentValues,
                                     headerValues: headerValues)
                    }
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
        .frame(width: 500)
        .background(Theme.background)
    }

    private func requiredValues(in values: [SiteDefaults.MCP.Value]?)
        -> [SiteDefaults.MCP.Value] {
        (values ?? []).filter { $0.value.isEmpty }
    }

    private func select(_ preset: SiteDefaults.MCP.Preset) {
        presetName = preset.name
        environmentValues = [:]
        headerValues = [:]
    }

    @ViewBuilder private func valueField(_ value: SiteDefaults.MCP.Value,
                                         text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: value.key)
            if EnvVar(key: value.key, value: "").isSecret {
                SecureField(value.key, text: text)
                    .textFieldStyle(.plain)
                    .font(.mono(13))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            } else {
                TextField(value.key, text: text)
                    .textFieldStyle(.plain)
                    .font(.mono(13))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            }
        }
    }

    private func dictionaryBinding(_ key: String,
                                   in dictionary: Binding<[String: String]>) -> Binding<String> {
        Binding(get: { dictionary.wrappedValue[key] ?? "" },
                set: { dictionary.wrappedValue[key] = $0 })
    }

    private func labeled(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key)
                .font(.mono(12, .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value).font(.mono(12)).textSelection(.enabled)
        }
    }
}
