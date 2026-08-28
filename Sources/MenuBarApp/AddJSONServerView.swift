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
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Paste") {
                    if let clip = NSPasteboard.general.string(forType: .string) { text = clip }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
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
                    do {
                        try store.importJSON(text, environment: environment)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                } label: {
                    Text("Add")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentFill))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            }
        }
        .padding(28)
        .frame(width: 540)
        .background(Theme.background)
    }
}
