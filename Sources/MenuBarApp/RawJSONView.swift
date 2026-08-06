import SwiftUI

struct RawJSONView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("config.json")
                    .font(.serif(22, .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    Text(store.rawJSON)
                        .font(.mono(12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            }
            .padding(24)

            SheetFooter { dismiss() } leading: {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.rawJSON, forType: .string)
                    copied = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: 620, height: 520)
        .background(Theme.background)
    }
}
