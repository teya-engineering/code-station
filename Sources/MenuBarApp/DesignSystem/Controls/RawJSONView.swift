import SwiftUI

struct RawJSONView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text("config.json")
                    .font(Typography.display)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    Text(store.rawJSON)
                        .font(Typography.code)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.lg)
                }
                .fieldSurface(cornerRadius: Radius.card)
            }
            .padding(Space.xxxl)

            SheetFooter { dismiss() } leading: {
                CopyButton("Copy", size: Typography.Size.detail) { store.rawJSON }
            }
        }
        .frame(width: 620, height: 520)
        .background(Theme.background)
    }
}
