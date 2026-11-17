import SwiftUI

// What an action that has already happened changed, said after the fact. It is the
// impact card turned around: the same corner, padding, rows and footer band, with a
// deck on top that shows the group the thing joined and the thing landing in it.
extension Dialog {
    struct Receipt {
        struct Member {
            let name: String
            let tint: Theme.ProjectTint
        }

        struct Row {
            let title: String
            let detail: String
            // A plus mark for what the action brought in. The rest are ticks for what
            // stays as it was.
            var added = false
        }

        // The one real decision the action leaves to the person, asked inline so it
        // can be changed without another trip.
        struct Choice {
            struct Option {
                let title: String
                let hint: String
            }

            let label: String
            let options: [Option]
            let selected: Int
            // Set when the choice cannot be made, and said in place of the hint.
            var offReason: String?
            let choose: (Int) -> Void
        }

        let subject: Impact.Subject
        let members: [Member]
        let added: Member
        let message: AttributedString
        let rows: [Row]
        var choice: Choice?
    }

    // A receipt closes the way it was going to end anyway: Escape, Return and a click
    // outside all run `onClose`, since the action is already done and cannot be lost.
    // The actions are listed left to right; the last is the main one.
    static func receipt(_ title: String, receipt: Receipt, actions: [Action],
                        onClose: @escaping () -> Void) -> Dialog {
        var dialog = Dialog(title: title, message: String(receipt.message.characters),
                            actions: actions, onCancel: onClose)
        dialog.width = 500
        dialog.receipt = receipt
        return dialog
    }
}

struct ReceiptDialogCard: View {
    let dialog: Dialog
    let maxHeight: CGFloat

    private enum Focus: Hashable {
        case action(UUID)
        case option(Int)
    }

    @Environment(DialogPresenter.self) private var presenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Focus?
    @State private var choice = 0
    @State private var counted = false
    @State private var landed: Int?
    @Namespace private var choiceTrack

    // A deck shows at most four members ahead of the new one. Past that it shows three
    // and a tile that counts the rest, so the line never runs off the card.
    private static let deckLimit = 4
    private static let memberWidth: CGFloat = 76
    private static let memberTile: CGFloat = 40
    private static let memberStagger = 0.045

    private var receipt: Dialog.Receipt { dialog.receipt! }

    private var shownMembers: [Dialog.Receipt.Member] {
        receipt.members.count > Self.deckLimit ? Array(receipt.members.prefix(3)) : receipt.members
    }

    private var hiddenCount: Int { receipt.members.count - shownMembers.count }

    // The deck is dealt in from the left, the line under it draws, and the new member
    // drops in last. The rows follow the impact card's pace below it.
    private var lineStart: Double {
        0.06 + Double(shownMembers.count + (hiddenCount > 0 ? 1 : 0)) * Self.memberStagger + 0.03
    }
    private var landStart: Double { lineStart + 0.15 }

    private func rowStart(_ index: Int) -> Double { 0.18 + Double(index) * 0.07 }

    var body: some View {
        VStack(spacing: 0) {
            MenuContentScrollView(maxHeight: max(0, maxHeight - 76)) {
                VStack(spacing: 0) {
                    deck
                    VStack(alignment: .leading, spacing: 0) {
                        Text(dialog.title)
                            .font(.serif(26, .regular))
                            .accessibilityAddTraits(.isHeader)
                            .arrives(after: 0.09, rising: 4)
                        Text(receipt.message)
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                            .padding(.top, Space.md)
                            .arrives(after: 0.13, rising: 4)
                        rows.padding(.top, Space.lg)
                        if let option = receipt.choice {
                            choiceRow(option)
                                .padding(.top, Space.xl)
                                .arrives(after: rowStart(receipt.rows.count) + 0.06, rising: 4)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, Space.xxxl)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .floatingCard(cornerRadius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(dialog.title)
        .accessibilityValue(dialog.message ?? "")
        .onKeyPress(keys: [.tab]) { press in
            let order = focusOrder
            guard !order.isEmpty else { return .handled }
            let index = focus.flatMap { order.firstIndex(of: $0) } ?? (order.count - 1)
            let step = press.modifiers.contains(.shift) ? -1 : 1
            focus = order[(index + step + order.count) % order.count]
            return .handled
        }
        .onExitCommand { presenter.dismiss() }
        .onAppear {
            choice = receipt.choice?.selected ?? 0
            if let main = dialog.actions.last { focus = .action(main.id) }
        }
        .task { await land() }
        .onDisappear { presenter.restoreFocus() }
    }

    // Tab walks the choice and then the footer, and wraps, so focus never leaves the card.
    private var focusOrder: [Focus] {
        var order: [Focus] = []
        if let option = receipt.choice, option.offReason == nil {
            order += option.options.indices.map(Focus.option)
        }
        return order + dialog.actions.filter { $0.isEnabled() }.map { .action($0.id) }
    }

    private func land() async {
        guard !reduceMotion else {
            counted = true
            return
        }
        try? await Task.sleep(for: .seconds(landStart))
        landed = 1
        try? await Task.sleep(for: .seconds(0.12))
        counted = true
    }

    // MARK: - Deck

    private var deck: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: Space.md) {
                ProjectTileView(name: receipt.subject.name, tint: Theme.workspaceTint, side: 22,
                                stacked: receipt.subject.kind == .workspace)
                    .accessibilityHidden(true)
                Text(receipt.subject.name)
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text("\(receipt.members.count + (counted ? 1 : 0))")
                        .font(.mono(Typography.Size.caption, .semibold))
                        .contentTransition(.numericText())
                        .motion(Motion.pop, value: counted)
                    Text("projects")
                        .font(.mono(Typography.Size.caption))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .arrives(after: 0.05, rising: 4)

            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(shownMembers.enumerated()), id: \.offset) { index, member in
                    memberView(member)
                        .arrives(after: 0.06 + Double(index + 1) * Self.memberStagger, sliding: 6)
                }
                if hiddenCount > 0 {
                    moreView
                        .arrives(after: 0.06 + Double(shownMembers.count + 1) * Self.memberStagger, sliding: 6)
                }
                newMemberView
            }
            .background(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.workspaceTint.colour.opacity(0.45))
                    .frame(height: 1.5)
                    .padding(.horizontal, Self.memberWidth / 2)
                    .offset(y: Self.memberTile / 2 - 0.75)
                    .draws(after: lineStart)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, Space.xxl)
        .padding(.bottom, 18)
        .background(Theme.sunken)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func memberView(_ member: Dialog.Receipt.Member) -> some View {
        VStack(spacing: 7) {
            ProjectTileView(name: member.name, tint: member.tint, side: Self.memberTile)
                .background { backing(Self.memberTile * 0.27) }
            memberName(member.name, isNew: false)
        }
        .frame(width: Self.memberWidth)
    }

    private var moreView: some View {
        VStack(spacing: 7) {
            Text("+\(hiddenCount)")
                .font(.mono(Self.memberTile * 0.36, .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.memberTile, height: Self.memberTile)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: Self.memberTile * 0.27))
                .overlay(RoundedRectangle(cornerRadius: Self.memberTile * 0.27).stroke(Theme.border))
            memberName("\(hiddenCount) more", isNew: false)
        }
        .frame(width: Self.memberWidth)
    }

    private var newMemberView: some View {
        let radius = Self.memberTile * 0.27
        return VStack(spacing: 7) {
            ProjectTileView(name: receipt.added.name, tint: receipt.added.tint, side: Self.memberTile)
                .background { backing(radius) }
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .stroke(receipt.added.tint.colour.opacity(0.75), lineWidth: 1.5))
                .landingRings(landed, colour: receipt.added.tint.colour, cornerRadius: radius, reach: 1.9)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "plus")
                        .font(.system(size: Typography.Size.micro, weight: .bold))
                        .foregroundStyle(Theme.onFill)
                        .frame(width: 17, height: 17)
                        .background(Theme.accentFill, in: Circle())
                        .background(Theme.card, in: Circle().inset(by: -2))
                        .offset(x: 8, y: -6)
                        .arrives(after: landStart + 0.2, growing: 0.5, animation: Motion.pop)
                }
                .arrives(after: landStart, rising: -26, growing: 0.7, animation: Motion.pop)
            memberName(receipt.added.name, isNew: true)
                .arrives(after: landStart + 0.08, rising: 4)
        }
        .frame(width: Self.memberWidth)
    }

    // Tile fills are see-through, so each tile sits on the deck's own colour and the
    // line threading them stops at their edges instead of showing through.
    private func backing(_ radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: radius).fill(Theme.sunken))
    }

    private func memberName(_ name: String, isNew: Bool) -> some View {
        Text(name)
            .font(.mono(Typography.Size.micro, isNew ? .semibold : .regular))
            .foregroundStyle(isNew ? Color.primary : Color.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Rows

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(receipt.rows.enumerated()), id: \.offset) { index, row in
                let start = rowStart(index)
                Rectangle().fill(Theme.border).frame(height: 1)
                    .draws(after: start)
                HStack(alignment: .top, spacing: Space.lg) {
                    Image(systemName: row.added ? "plus" : "checkmark")
                        .font(.system(size: Typography.Size.detail, weight: .semibold))
                        .foregroundStyle(row.added ? Theme.addition : Theme.accent)
                        .frame(width: ControlHeight.sm, height: ControlHeight.sm)
                        .background((row.added ? Theme.addition.opacity(0.14) : Theme.accent.opacity(0.10)),
                                    in: Circle())
                        .accessibilityHidden(true)
                        .arrives(after: start + 0.04, growing: 0.5, animation: Motion.pop)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(row.title).font(Typography.body.weight(.medium))
                        Text(row.detail)
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                    }
                    .arrives(after: start + 0.06, sliding: 6)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Space.lg)
                .accessibilityElement(children: .combine)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
                .draws(after: rowStart(receipt.rows.count))
        }
    }

    // MARK: - Choice

    private func choiceRow(_ option: Dialog.Receipt.Choice) -> some View {
        let enabled = option.offReason == nil
        let hint = option.offReason ?? option.options[min(choice, option.options.count - 1)].hint
        return HStack(spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(option.label.uppercased())
                    .font(Typography.caps)
                    .kerning(1.2)
                    .foregroundStyle(.secondary)
                Text(hint)
                    .font(Typography.detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(hint)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .motion(Motion.reveal, value: hint)

            HStack(spacing: Space.xxs) {
                ForEach(Array(option.options.enumerated()), id: \.offset) { index, item in
                    ChoicePill(title: item.title, selected: choice == index, enabled: enabled,
                               thumb: choiceTrack) {
                        guard choice != index else { return }
                        choice = index
                        option.choose(index)
                    }
                    .focused($focus, equals: .option(index))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control)
                        .stroke(focus == .option(index) ? Theme.accent : .clear, lineWidth: 2))
                }
            }
            .padding(Space.xxs)
            .background(Theme.field, in: Capsule())
            .motion(Motion.control, value: choice)
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(option.label)
            .accessibilityHint(option.offReason ?? "")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Space.md) {
            Spacer(minLength: 0)
            ForEach(dialog.actions) { action in
                ActionButton(title: action.label,
                             tone: action.kind == .primary ? .dark : action.kind == .destructive ? .danger : .sunken,
                             height: ControlHeight.xl, size: Typography.Size.body, icon: action.icon,
                             keyboardShortcut: action.kind == .primary ? .defaultAction : nil) {
                    presenter.run(action)
                }
                .disabled(!action.isEnabled())
                .focused($focus, equals: .action(action.id))
                .overlay(RoundedRectangle(cornerRadius: Radius.card)
                    .stroke(focus == .action(action.id) ? Theme.accent : .clear, lineWidth: 2)
                    .padding(-3))
            }
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.xl)
        .background(Theme.field)
        .arrives(after: 0.06)
    }
}
