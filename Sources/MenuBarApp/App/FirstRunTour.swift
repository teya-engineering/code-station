import SwiftUI

struct FirstRunTour: View {
    private struct Feature {
        let label: String
        let title: String
        let detail: String
    }

    private static let features = [
        Feature(label: "Parallel work", title: "Run work in parallel",
                detail: "Give each session its own Git worktree and branch, or work directly in the project folder."),
        Feature(label: "Conversation", title: "Keep the whole conversation",
                detail: "Follow replies, tool activity, permissions, token use and background work in one timeline."),
        Feature(label: "Changes", title: "Review every change",
                detail: "Browse project files and inspect the full diff without leaving the session."),
        Feature(label: "Tools", title: "Use the tools around the work",
                detail: "Open terminals, manage Git, inspect Docker, send API requests and connect MCP servers.")
    ]

    let closeTitle: String
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.textScale) private var textScale
    @State private var selected = 2
    @FocusState private var focused: Int?

    static func dialog(closeTitle: String, onClose: @escaping () -> Void = {}) -> Dialog {
        Dialog(title: "See how Code Station works",
               message: "A session brings the conversation, files, Git changes, and tools into one place. Each agent uses its own CLI and account.",
               content: AnyView(FirstRunTour(closeTitle: closeTitle)),
               actions: [], onCancel: onClose, width: 620)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text(Self.features[selected].title)
                        .font(.serif(21 * max(1, textScale)))
                        .accessibilityAddTraits(.isHeader)
                    Text(Self.features[selected].detail)
                        .font(.system(size: 12 * max(1, textScale)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    preview
                        .accessibilityLabel("Example session")
                }
                // A plain fade under Reduce Motion as well, since nothing here moves.
                .id(selected)
                .transition(.fadeIn.animation(Motion.reveal))
            }
            .frame(idealHeight: 280, maxHeight: 320)
            HStack(spacing: Space.sm) {
                ForEach(Self.features.indices, id: \.self) { index in
                    ChoicePill(title: Self.features[index].label, selected: selected == index) {
                        select(index)
                    }
                    .focused($focused, equals: index)
                    .accessibilityAddTraits(selected == index ? [.isSelected] : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Feature examples")
            ActionButton(title: closeTitle, tone: .green, height: ControlHeight.xl, fills: true) { dialogs.dismiss() }
                .focused($focused, equals: 4)
        }
        .padding(.top, Space.md)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { focused = selected }
        .onKeyPress(.escape) {
            dialogs.dismiss()
            return .handled
        }
        .onKeyPress(keys: [.tab]) { press in
            focused = ((focused ?? selected) + (press.modifiers.contains(.shift) ? 4 : 1)) % 5
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end]) { press in
            guard focused != 4 else { return .ignored }
            switch press.key {
            case .home: select(0)
            case .end: select(3)
            case .leftArrow, .upArrow: select((selected + 3) % 4)
            default: select((selected + 1) % 4)
            }
            return .handled
        }
    }

    private func select(_ index: Int) {
        selected = index
        focused = index
        AccessibilityNotification.Announcement(Self.features[index].title).post()
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Acorn API").fontWeight(.semibold)
                Spacer()
                Text(selected == 0 ? "2 sessions" : selected == 3 ? "Terminal" : "Filter deliveries")
                    .foregroundStyle(.secondary)
            }
            .font(Typography.caption).padding(Space.lg)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if selected == 0 {
                sessionRow("Filter deliveries", branch: "delivery-filter", status: "Running")
                sessionRow("Refresh checkout tokens", branch: "checkout-tokens", status: "Ready")
            } else if selected == 3 {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("$ ./mvnw test").foregroundStyle(Theme.terminalText)
                    Text("Tests run: 12, Failures: 0\nBUILD SUCCESS").foregroundStyle(Theme.terminalText)
                }
                .font(Typography.code).padding(Space.xl)
                .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
                .background(Theme.terminal)
            } else {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Add a delivery window filter.\nKeep the existing date range.")
                        .font(Typography.detail).padding(Space.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surface(Theme.userMessage, cornerRadius: Radius.card, border: Theme.userMessageRing)
                    Text(selected == 1
                         ? "I'll check the current filters and add the delivery window alongside them."
                         : "The delivery filter is ready.")
                        .font(Typography.detail)
                    Text(selected == 1 ? "Read DeliveryController.java" : "Updated the query and covered it with tests.")
                        .font(Typography.caption).foregroundStyle(.secondary)
                }
                .padding(Space.lg)
                if selected == 2 {
                    Text("+ deliveryWindow: selectedWindow\n+ preserveDateRange: true")
                        .font(Typography.data).foregroundStyle(Theme.addition)
                        .padding(Space.md).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.addition.opacity(0.06))
                }
            }
        }
        .cardSurface(cornerRadius: Radius.card)
        .accessibilityElement(children: .combine)
    }

    private func sessionRow(_ title: String, branch: String, status: String) -> some View {
        HStack(spacing: Space.lg) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(Typography.detail)
                Text("worktree / \(branch)").font(Font.mono(Typography.Size.micro)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status).font(Font.system(size: Typography.Size.micro)).foregroundStyle(Theme.accent)
        }
        .padding(Space.xl)
    }
}
