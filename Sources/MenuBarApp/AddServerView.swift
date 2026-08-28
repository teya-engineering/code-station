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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                Text(group.addTitle).font(.serif(26, .semibold))

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("PRESET")
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
                            SectionLabel("REQUIRED VALUES")
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
                        SectionLabel("PREVIEW")
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
                    .fieldSurface(cornerRadius: 10)
                }

                if exists {
                    Label("A server with this name already exists. Adding will replace its configuration.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secret)
                }
            }
            .padding(28)

            SheetFooter(primary: SheetAction(title: exists ? "Replace" : "Add",
                                             enabled: !incomplete,
                                             shortcut: .defaultAction, action: add),
                        dismiss: { dismiss() })
        }
        .frame(width: 500)
        .background(Theme.background)
    }

    private func add() {
        if let preset {
            store.upsert(preset: preset,
                         environmentValues: environmentValues,
                         headerValues: headerValues)
        }
        dismiss()
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

    private func valueField(_ value: SiteDefaults.MCP.Value,
                            text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(value.key)
            Group {
                if EnvVar.isSecretKey(value.key) {
                    SecureField(value.key, text: text)
                } else {
                    TextField(value.key, text: text)
                }
            }
            // Set before the field chrome, so the mono face wins over the chrome's own.
            .font(.mono(13))
            .appTextField(cornerRadius: 9)
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
