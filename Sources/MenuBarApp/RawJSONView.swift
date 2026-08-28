import SwiftUI

struct RawJSONView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

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
                .fieldSurface(cornerRadius: 10)
            }
            .padding(24)

            SheetFooter { dismiss() } leading: {
                CopyButton("Copy", size: 12) { store.rawJSON }
            }
        }
        .frame(width: 620, height: 520)
        .background(Theme.background)
    }
}
