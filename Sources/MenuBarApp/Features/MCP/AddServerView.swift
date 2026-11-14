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
            VStack(alignment: .leading, spacing: Space.xxl) {
                Text(group.addTitle).font(Typography.display)

                VStack(alignment: .leading, spacing: Space.md) {
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
                        VStack(alignment: .leading, spacing: Space.lg) {
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

                    VStack(alignment: .leading, spacing: Space.sm) {
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
                    .padding(Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fieldSurface(cornerRadius: Radius.card)
                }

                if exists {
                    Label("A server with this name already exists. Adding will replace its configuration.",
                          systemImage: "exclamationmark.triangle")
                        .font(Typography.detail)
                        .foregroundStyle(Theme.secret)
                }
            }
            .padding(Space.xxxl)

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
        VStack(alignment: .leading, spacing: Space.md) {
            SectionLabel(value.key)
            Group {
                if EnvVar.isSecretKey(value.key) {
                    SecureField(value.key, text: text)
                } else {
                    TextField(value.key, text: text)
                }
            }
            // Set before the field chrome, so the mono face wins over the chrome's own.
            .font(Font.mono(Typography.Size.body))
            .appTextField(cornerRadius: Radius.card)
        }
    }

    private func dictionaryBinding(_ key: String,
                                   in dictionary: Binding<[String: String]>) -> Binding<String> {
        Binding(get: { dictionary.wrappedValue[key] ?? "" },
                set: { dictionary.wrappedValue[key] = $0 })
    }

    private func labeled(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Text(key)
                .font(Typography.code.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value).font(Typography.code).textSelection(.enabled)
        }
    }
}
