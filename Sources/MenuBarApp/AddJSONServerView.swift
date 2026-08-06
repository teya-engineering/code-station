import SwiftUI

struct AddJSONServerView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
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

            SectionLabel(text: "JSON")
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

            HStack {
                Button("Paste") {
                    if let clip = NSPasteboard.general.string(forType: .string) { text = clip }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    do {
                        try store.importJSON(text)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 540)
        .background(Theme.background)
    }
}
