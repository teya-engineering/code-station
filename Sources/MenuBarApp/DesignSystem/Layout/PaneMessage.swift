import SwiftUI

// What a pane says when it has nothing to show: no changes, no file picked, a folder that
// is not there any more. Centred in whatever room it is given.
struct PaneMessage<Action: View>: View {
    let icon: String
    let title: String
    var detail: String
    var mono = false
    // An empty pane that names a way out should offer it here, so the sentence and the
    // button that carries it out are read in one place.
    @ViewBuilder let action: Action

    init(icon: String, title: String, detail: String, mono: Bool = false,
         @ViewBuilder action: () -> Action) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.mono = mono
        self.action = action()
    }

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(Typography.title)
            if !detail.isEmpty {
                Text(detail)
                    .font(mono ? Typography.data : Typography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
            action
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PaneMessage where Action == EmptyView {
    init(icon: String, title: String, detail: String, mono: Bool = false) {
        self.init(icon: icon, title: title, detail: detail, mono: mono) { EmptyView() }
    }
}
