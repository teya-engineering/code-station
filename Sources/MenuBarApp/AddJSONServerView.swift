import SwiftUI

struct AddJSONServerView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var environment = ""
    @State private var error: String?

    private static let placeholder = """
    {
      "filesystem": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path"],
        "env": {}
      }
    }
    """

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Add MCP server").font(.serif(26, .semibold))
                Text("Paste a server as JSON. Accepts a full \"mcpServers\" block or a bare \"name\": { … } map, for stdio or remote (url) servers.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("ENVIRONMENT")
                    ServerEnvironmentPills(tag: $environment)
                    Text("Which diagnoses offer these servers. JSON that names its own \"environment\" keeps it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SectionLabel("JSON")
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(Self.placeholder)
                            .font(.mono(12))
                            .foregroundStyle(.tertiary)
                            .padding(10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(.mono(12))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                }
                .frame(height: 260)
                .fieldSurface(cornerRadius: 10)

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.deletion)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)

            SheetFooter(primary: SheetAction(title: "Add", enabled: !text.isBlank,
                                             shortcut: .defaultAction, action: add),
                        dismiss: { dismiss() }) {
                InlineLink(title: "Paste", size: 13) {
                    if let clip = NSPasteboard.general.string(forType: .string) { text = clip }
                }
            }
        }
        .frame(width: 540)
        .background(Theme.background)
    }

    private func add() {
        do {
            try store.importJSON(text, environment: environment)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
