import AppKit
import SwiftUI

struct ShortcutsView: View {
    @Environment(ShortcutStore.self) private var store
    @Environment(DialogPresenter.self) private var dialogs
    // Optional so the sheet can be shown without projects. The status band then counts
    // own orders without naming them.
    @Environment(ProjectStore.self) private var projects: ProjectStore?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ShortcutDraft?
    @State private var query = ""
    @State private var saveStatus = ""
    @State private var kind: ShortcutKind?
    @State private var showsWhy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var filterTrack

    // Order changes save at once; other edits preview in the list until cancelled.
    private var shortcuts: [Shortcut] { Self.previewing(draft?.value, in: store.macShortcuts) }
    private var matches: [Shortcut] {
        shortcuts.filter { ShortcutStore.matches($0, query: query, kind: kind) }
    }
    private var isFiltered: Bool { !query.isBlank || kind != nil }

    static func previewing(_ draft: Shortcut?, in shortcuts: [Shortcut]) -> [Shortcut] {
        guard let draft else { return shortcuts }
        return shortcuts.map { $0.id == draft.id ? draft : $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(1)
            statusBand
            if let error = store.loadError ?? store.saveError {
                WarningStrip(error, icon: "externaldrive.badge.exclamationmark")
            }
            HStack(spacing: 0) {
                library.frame(width: 300)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                editor
            }
            .frame(maxHeight: .infinity)
            if let draft { footer(draft) }
        }
        // A sheet with a flexible width opens at its narrowest over a small window, so the
        // width is fixed, as it is for Settings.
        .frame(width: 960)
        .frame(minHeight: 400, idealHeight: 780, maxHeight: 780)
        .background(Theme.background)
        .interactiveDismissDisabled(draft?.isDirty == true)
        .onAppear {
            if draft == nil {
                if let first = matches.first { select(first) }
                else { add() }
            }
        }
    }

    // The footer is the only way out, so the header carries no close button.
    private var header: some View {
        SheetTitle(name: "Shortcuts", icon: "command", count: store.libraryShortcuts().count) {
            WhyButton(label: "What shortcuts are", isOpen: $showsWhy) {
                Text("Commands and prompts you can use in every project.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Space.pane)
        .headerBand()
    }

    // What is on the button, what this order is for, and who keeps an order of their own.
    private var statusBand: some View {
        let top = store.macShortcuts.first
        let own = ownOrders
        return HStack(spacing: Space.md) {
            StatusCaps(text: "ON THE BUTTON")
            if let top {
                KindTile(kind: top.kind, icon: top.icon ?? top.kind.icon, side: ControlHeight.xs)
                RollingText(top.name, font: Typography.caption.weight(.semibold))
                    .lineLimit(1)
            } else {
                StatusValue(text: "Nothing yet")
            }
            StatusRule()
            StatusCaps(text: "THIS ORDER")
            StatusValue(text: "Used wherever no own order is set")
            StatusRule()
            StatusCaps(text: "OWN ORDER")
            StatusValue(text: own ?? "None")
                .contentTransition(.opacity)
            if own != nil {
                InlineLink(title: "Follow this order", size: Typography.Size.caption, action: confirmFollow)
                    .appTooltip("Clear every project and session order, so they all use this one")
                    .transition(.fadeIn)
            }
            Spacer(minLength: 0)
        }
        .motion(Motion.reveal, value: own)
        .accessibilityElement(children: .contain)
        .statusBand(padding: Space.pane)
    }

    // "code-station and 1 session", "3 projects", nil when nobody keeps their own order.
    private var ownOrders: String? {
        let projectIDs = Array(store.projectOrders.keys)
        let sessions = store.sessionOrders.count
        var parts: [String] = []
        if projectIDs.count == 1, let name = projects?.project(projectIDs[0])?.name {
            parts.append(name)
        } else if !projectIDs.isEmpty {
            parts.append(counted(projectIDs.count, "project"))
        }
        if sessions > 0 { parts.append(counted(sessions, "session")) }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    // Clearing every own order cannot be undone, so it is confirmed like a deletion.
    private func confirmFollow() {
        guard let own = ownOrders else { return }
        dialogs.show(.impact("Follow this order everywhere?",
                             rows: [.init(title: "Own orders", detail: "\(own). Cleared."),
                                    .init(title: "This order", detail: "Every project and session uses it.", kept: true),
                                    .init(title: "Shortcuts", detail: "Kept unchanged.", kept: true)],
                             warning: "Own orders cannot be restored after they are cleared.",
                             action: "Follow this order") {
            guard withAnimation(reduceMotion ? nil : Motion.control, { store.clearOwnOrders() }) else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "Every project and session now follows this order.",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        })
    }

    // Escape puts the explanation away before it closes the sheet.
    private func closeOrDismiss() {
        if showsWhy {
            showsWhy = false
        } else {
            guardChanges { dismiss() }
        }
    }

    private var library: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.md) {
                search
                HStack(spacing: Space.xxs) {
                    filter("All", kind: nil)
                    filter("Commands", kind: .command)
                    filter("Prompts", kind: .prompt)
                }
                .padding(Space.xxs)
                .fieldSurface(cornerRadius: Radius.card)
                .motion(Motion.control, value: kind)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Filter shortcuts by type")
                orderNote
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.sm)
            ShortcutLibraryList(shortcuts: matches, pending: draft?.isNew == true ? draft?.value : nil,
                                selectedID: draft?.value.id,
                                selectedIsDirty: draft?.isDirty == true,
                                isEmptyLibrary: shortcuts.isEmpty,
                                emptyDetail: emptyDetail,
                                leadID: shortcuts.first?.id,
                                sortable: !isFiltered,
                                total: shortcuts.count,
                                clearSearch: { query = ""; kind = nil },
                                select: { shortcut in guardChanges { select(shortcut) } },
                                move: { move($0, to: $1) })
            Rectangle().fill(Theme.hairline).frame(height: 1)
            NewItemButton(title: "New shortcut") { guardChanges { add() } }
                .padding(Space.lg)
        }
        .background(Theme.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved shortcuts")
    }

    private var search: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(Typography.label)
                .foregroundStyle(Theme.secondaryText)
            TextField("Find a shortcut", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .accessibilityLabel("Find a shortcut")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .transition(.fadeIn)
            }
        }
        .padding(.horizontal, Space.md)
        .frame(height: 32)
        .surface(Theme.card, cornerRadius: Radius.card)
        .motion(Motion.hover, value: query.isEmpty)
    }

    // Says what the order is for, or why it cannot be changed right now.
    private var orderNote: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "arrow.up.arrow.down").accessibilityHidden(true)
            Text(isFiltered ? "Sorting is off while the list is filtered."
                            : "Drag to sort. The top one is on the button.")
                .lineLimit(1)
            Spacer(minLength: Space.xs)
            if isFiltered {
                InlineLink(title: "Show all", size: Typography.Size.caption) { query = ""; kind = nil }
            }
        }
        .font(Typography.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.xxs)
        .id(isFiltered)
        .transition(.fadeIn)
        .motion(Motion.reveal, value: isFiltered)
    }

    // Order changes save at once, apart from the editor's draft.
    private func move(_ id: Shortcut.ID, to position: Int) {
        guard !isFiltered, let shortcut = store.shortcut(id) else { return }
        let count = store.macShortcuts.count
        let target = min(max(position, 0), count - 1)
        let moved = withAnimation(reduceMotion ? nil : Motion.control) {
            store.moveInLibrary(id, to: target)
        }
        guard moved else { return }
        let message = "\(shortcut.name) moved to position \(target + 1) of \(count)."
            + (target == 0 ? " It is now on the button." : "")
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func filter(_ title: String, kind choice: ShortcutKind?) -> some View {
        let count = choice.map { choice in shortcuts.count(where: { $0.kind == choice }) } ?? shortcuts.count
        return ChoicePill(title: title, selected: kind == choice, thumb: filterTrack,
                          fills: true, count: count) { kind = choice }
            .accessibilityLabel(title)
            .accessibilityValue("\(count)")
    }

    private var emptyDetail: String {
        let scope = kind.map { " in \($0.title.lowercased())s" } ?? ""
        return query.isBlank ? "Nothing here\(scope)." : "Nothing is called “\(query.trimmed)”\(scope)."
    }

    // The old editor goes at once and only the new one moves in, so two heavy panes are
    // never drawn over each other.
    private var paneTransition: AnyTransition {
        let insertion: AnyTransition = reduceMotion
            ? .opacity.animation(Motion.reveal)
            : .opacity.combined(with: .offset(y: HeaderMotion.popoverLift)).animation(Motion.reveal)
        return .asymmetric(insertion: insertion, removal: .identity)
    }

    @ViewBuilder private var editor: some View {
        ZStack {
            if let draft {
                ScrollView {
                    if !draft.isNew, let index = store.macShortcuts.firstIndex(where: { $0.id == draft.value.id }) {
                        ShortcutPlaceCard(shortcut: draft.value, top: store.macShortcuts.first,
                                          index: index, count: store.macShortcuts.count) {
                            move(draft.value.id, to: $0)
                        }
                        .padding(.horizontal, Space.xxxl)
                        .padding(.top, Space.xxl)
                    }
                    ShortcutEditorForm(draft: draft, locked: store.isRunningAnywhere(draft.value.id),
                                       remove: draft.isNew ? nil : { remove(draft) }) {
                        ShortcutCommandOutput(shortcut: store.shortcut(draft.value.id),
                                              canRun: !draft.isDirty && !draft.isNew,
                                              isNew: draft.isNew)
                    }
                    .padding(.horizontal, Space.xxxl)
                    .padding(.top, Space.xxl)
                    .padding(.bottom, Space.xxxl)
                }
                .id(draft.value.id)
                .transition(paneTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(_ draft: ShortcutDraft) -> some View {
        SheetFooter(primary: SheetAction(title: draft.isNew ? "Add shortcut" : "Save shortcut",
                                         enabled: draft.canSave && !store.isRunningAnywhere(draft.value.id),
                                         shortcut: KeyboardShortcut("s"), hint: "⌘S",
                                         action: { _ = save() }),
                    dismiss: closeOrDismiss) {
            ZStack(alignment: .leading) {
                if draft.isDirty {
                    HStack(spacing: Space.sm) {
                        Circle().fill(Theme.attention).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text("Unsaved changes")
                        InlineLink(title: draft.isNew ? "Discard" : "Revert", size: Typography.Size.detail) { revert(draft) }
                            .padding(.leading, Space.xs)
                    }
                    .transition(noteTransition)
                } else if !saveStatus.isEmpty {
                    Label(saveStatus, systemImage: "checkmark")
                        .foregroundStyle(Theme.dotOnText)
                        .transition(noteTransition)
                }
            }
            .font(Typography.detail)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .motion(Motion.pop, value: draft.isDirty)
            .motion(Motion.pop, value: saveStatus)
        }
    }

    // A mark landing grows from just over half its size, never from nothing, and goes
    // on the quicker leaving curve.
    private var noteTransition: AnyTransition {
        .asymmetric(insertion: reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: HeaderMotion.seed, anchor: .leading)),
                    removal: .opacity.animation(Motion.leave))
    }

    private func revert(_ draft: ShortcutDraft) {
        if draft.isNew {
            if let first = matches.first { select(first) } else { draft.reset() }
        } else {
            draft.reset()
            saveStatus = ""
        }
    }

    private func select(_ shortcut: Shortcut) {
        draft = ShortcutDraft(request: ShortcutEditorRequest(shortcut: shortcut))
        saveStatus = ""
    }

    private func add() {
        draft = ShortcutDraft(request: ShortcutEditorRequest(kind: kind ?? .prompt))
        saveStatus = ""
    }

    @discardableResult private func save() -> Bool {
        guard let draft, draft.canSave, store.saveShortcut(draft.shortcut),
              let saved = store.shortcut(draft.value.id) else { return false }
        draft.accept(saved)
        saveStatus = "Saved"
        return true
    }

    private func guardChanges(_ action: @escaping () -> Void) {
        guard let draft, draft.isDirty else { action(); return }
        dialogs.show(shortcutUnsavedDialog(draft: draft, save: {
            if save() { action() }
        }, discard: action))
    }

    private func remove(_ draft: ShortcutDraft) {
        guard let shortcut = store.shortcut(draft.value.id) else { return }
        var rows = [Dialog.Impact.Row(title: "Saved \(shortcut.kind.rawValue)",
                                     detail: "Removed from all projects.")]
        if store.isRunningAnywhere(shortcut.id) {
            rows.append(.init(title: "Running commands", detail: "Stopped right away."))
        }
        rows.append(.init(title: "Projects and conversations", detail: "Kept unchanged.", kept: true))
        dialogs.show(.impact("Remove \(shortcut.name)?", rows: rows,
                             warning: "This shortcut cannot be restored after removal.", action: "Remove shortcut") {
            store.remove(shortcut.id)
            if let first = matches.first { select(first) }
            else { add() }
        })
    }
}

struct ShortcutLibraryList: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let shortcuts: [Shortcut]
    // A new shortcut that is not saved yet. It sits on top so its name can be
    // seen changing while it is typed.
    let pending: Shortcut?
    let selectedID: Shortcut.ID?
    let selectedIsDirty: Bool
    let isEmptyLibrary: Bool
    let emptyDetail: String
    // The first shortcut of the whole list, the one on the button.
    let leadID: Shortcut.ID?
    // Rows only move while the whole list is showing, since a filtered list would have
    // to guess where the hidden rows go.
    let sortable: Bool
    let total: Int
    let clearSearch: () -> Void
    let select: (Shortcut) -> Void
    // Puts a shortcut at a position in the whole list.
    let move: (Shortcut.ID, Int) -> Void
    @State private var reorder = LiveReorder()

    static let rowHeight: CGFloat = 52
    static let rowGap = Space.xxs

    var body: some View {
        let ids = shortcuts.map(\.id)
        let slotShown = shortcuts.first?.id == leadID && leadID != nil
        ScrollView {
            VStack(spacing: Self.rowGap) {
                if pending == nil && shortcuts.isEmpty {
                    emptyMessage
                }
                VStack(spacing: Self.rowGap) {
                    ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                        let selected = shortcut.id == selectedID
                        ShortcutLibraryRow(shortcut: shortcut, selected: selected,
                                           dirty: selected && selectedIsDirty,
                                           lead: shortcut.id == leadID,
                                           grip: sortable,
                                           position: sortable ? "Position \(index + 1) of \(total)" : nil,
                                           select: { if !reorder.isDragging { select(shortcut) } })
                            .liveReorder(shortcut.id, in: ids, spacing: Self.rowGap, enabled: sortable,
                                         cornerRadius: Radius.control, state: $reorder) { id, position in
                                move(id, position)
                            }
                            .accessibilityAction(named: "Put on the button") { move(shortcut.id, 0) }
                            .accessibilityAction(named: "Move up") { move(shortcut.id, index - 1) }
                            .accessibilityAction(named: "Move down") { move(shortcut.id, index + 1) }
                            .id(shortcut.id)
                    }
                }
                .padding(.horizontal, LeadSlot.inset)
                .padding(.top, slotShown ? LeadSlot.topRoom : 0)
                .background(alignment: .top) {
                    if slotShown, let first = shortcuts.first {
                        LeadSlot(caption: "On the button", rowHeight: reorder.height(first.id))
                            .transition(.fadeIn)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Shortcuts, in order")
                // A new shortcut joins at the bottom of the order, so adding one never
                // takes the button.
                if let pending {
                    ShortcutLibraryRow(shortcut: pending, selected: pending.id == selectedID, dirty: true,
                                       lead: false, grip: false, position: nil, select: {})
                        .padding(.horizontal, LeadSlot.inset)
                        .id(pending.id)
                        .transition(.fadeIn)
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.top, Space.xxs)
            .padding(.bottom, Space.md)
        }
    }

    private var emptyMessage: some View {
        VStack(spacing: Space.md) {
            VStack(spacing: Space.xs) {
                Text(isEmptyLibrary ? "No shortcuts yet" : "No shortcuts found")
                    .font(Typography.body.weight(.semibold))
                Text(isEmptyLibrary ? "Save a command you run often, or a prompt you keep retyping."
                     : emptyDetail)
                    .font(Typography.detail)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !isEmptyLibrary {
                InlineLink(title: "Clear search", action: clearSearch)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.xxxl)
        .transition(.fadeIn)
    }
}

struct ShortcutLibraryRow: View {
    let shortcut: Shortcut
    let selected: Bool
    let dirty: Bool
    let lead: Bool
    let grip: Bool
    let position: String?
    let select: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var title: String { shortcut.name.isBlank ? "New shortcut" : shortcut.name }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "line.3.horizontal")
                        .font(Typography.micro)
                        .foregroundStyle(hovering ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                        .opacity(grip ? 1 : 0.3)
                        .accessibilityHidden(true)
                    KindTile(kind: shortcut.kind, icon: shortcut.icon ?? shortcut.kind.icon)
                        .padding(.trailing, Space.xxs)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(title)
                            .font(Typography.body.weight(shortcut.name.isBlank ? .medium : .semibold))
                            .foregroundStyle(shortcut.name.isBlank ? Theme.secondaryText : Color.primary)
                        Text(subtitle)
                            .font(shortcut.kind == .command ? Typography.data : Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if dirty {
                        Circle()
                            .fill(Theme.attention)
                            .frame(width: 6, height: 6)
                            .transition(popTransition)
                            .accessibilityLabel("Unsaved changes")
                    }
                }
                .padding(.leading, Space.sm)
                .padding(.trailing, Space.lg)
                .frame(height: ShortcutLibraryList.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(shortcut.kind.rawValue), available in all projects")
            .accessibilityValue([shortcut.text, position, lead ? "on the button" : nil]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .background {
            if selected || lead {
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: Radius.control)
                        .stroke(selected ? Theme.settingsBorder : Theme.border))
            }
        }
        .overlay(alignment: .leading) {
            if lead {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: SubjectRail.width)
                    .padding(.vertical, Space.lg)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .hoverFill(cornerRadius: Radius.control)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.control, value: selected)
        .motion(Motion.control, value: lead)
        .motion(Motion.pop, value: dirty)
    }

    private var subtitle: String {
        let text = shortcut.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !text.isEmpty { return text }
        return shortcut.kind == .command ? "No command yet" : "No prompt yet"
    }

    // A mark landing grows from just over half its size, never from nothing, and goes
    // on the quicker leaving curve.
    private var popTransition: AnyTransition {
        .asymmetric(insertion: reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: HeaderMotion.seed)),
                    removal: .opacity.animation(Motion.leave))
    }
}

// Where a shortcut sits in the order every session starts with, and the ways to move it
// without dragging. The first place is the one on the split button, so the card shows a
// copy of that button. Pointing at "Put on the button" shows it with this shortcut on it
// before anything moves.
struct ShortcutPlaceCard: View {
    let shortcut: Shortcut
    let top: Shortcut?
    let index: Int
    let count: Int
    let move: (Int) -> Void

    @State private var previewing = false

    private var onButton: Shortcut? { previewing || index == 0 ? shortcut : top }

    var body: some View {
        HStack(alignment: .center, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Place in the order").font(Typography.label)
                if let onButton { ButtonCopy(shortcut: onButton) }
                Text(index == 0 ? "This shortcut is on the button in every session"
                     : previewing ? "The button, if you put this one on it" : "The button in every session")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .motion(Motion.control, value: onButton?.id)
            Spacer(minLength: Space.md)
            VStack(alignment: .trailing, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    (Text(Self.ordinal(index + 1)).fontWeight(.semibold) + Text(" of \(count)"))
                        .font(Typography.detail)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(index)))
                        .motion(Motion.pop, value: index)
                    GlyphButton(icon: "arrow.up", side: ControlHeight.sm) { move(index - 1) }
                        .disabled(index == 0)
                        .appTooltip("Move up")
                        .accessibilityLabel("Move up")
                    GlyphButton(icon: "arrow.down", side: ControlHeight.sm) { move(index + 1) }
                        .disabled(index >= count - 1)
                        .appTooltip("Move down")
                        .accessibilityLabel("Move down")
                }
                ZStack(alignment: .trailing) {
                    if index == 0 {
                        Label("On the button", systemImage: "checkmark")
                            .font(Typography.detail.weight(.semibold))
                            .foregroundStyle(Theme.dotOnText)
                            .frame(height: ControlHeight.sm)
                            .transition(.fadeIn)
                    } else {
                        ActionButton(title: "Put on the button", tone: .outlined, height: ControlHeight.sm,
                                     size: Typography.Size.detail, icon: "capsule") {
                            previewing = false
                            move(0)
                        }
                        .onPointerHover { previewing = $0 }
                        .transition(.fadeIn)
                    }
                }
                .motion(Motion.reveal, value: index == 0)
            }
        }
        .padding(Space.lg)
        .cardSurface(cornerRadius: Radius.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Place in the order")
        .accessibilityValue("Position \(index + 1) of \(count)" + (index == 0 ? ", on the button" : ""))
    }

    static func ordinal(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    // A still copy of the split button as every session draws it.
    private struct ButtonCopy: View {
        let shortcut: Shortcut

        var body: some View {
            let verb = shortcut.kind == .prompt ? "Ask" : "Run"
            HStack(spacing: 0) {
                HStack(spacing: Space.sm) {
                    Image(systemName: shortcut.kind == .prompt ? "bubble.left" : "play.fill")
                        .font(Typography.micro.weight(.bold))
                    RollingText("\(verb) \(shortcut.name.isBlank ? "New shortcut" : shortcut.name)",
                                font: Typography.detail.weight(.semibold))
                }
                .padding(.leading, Space.md)
                .padding(.trailing, Space.sm)
                Rectangle().fill(Theme.onFill.opacity(0.18)).frame(width: 1)
                HStack(spacing: Space.xs) {
                    Image(systemName: "bolt")
                    Text("Shortcuts").opacity(0.75)
                }
                .font(Typography.caption.weight(.medium))
                .padding(.horizontal, Space.sm)
            }
            .foregroundStyle(Theme.onFill)
            .lineLimit(1)
            .frame(height: ControlHeight.sm)
            .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: Radius.control))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("The button shows \(verb) \(shortcut.name)")
        }
    }
}

// The body is always the terminal colour, so the card does not flip between light and
// dark as a command starts and stops.
private struct ShortcutCommandOutput: View {
    @Environment(ShortcutStore.self) private var store
    let shortcut: Shortcut?
    let canRun: Bool
    let isNew: Bool

    private var run: ShortcutRun? {
        shortcut.map { ShortcutRun($0.id, in: $0.directory(projectPath: nil)) }
    }
    private var state: ShortcutStore.State? { run.map(store.state) }
    private var active: Bool { state?.isActive ?? false }
    private var log: String { run.map(store.log) ?? "" }

    private var status: (text: String, colour: Color) {
        switch state {
        case nil, .stopped: ("Not run yet", Color.secondary.opacity(0.6))
        case .running: ("Running", Theme.dotOn)
        case .finished: ("Finished", Theme.dotOn)
        case .failed: ("Failed", Theme.deletion)
        }
    }

    // While Run is off, the empty terminal says why.
    private var emptyMessage: String {
        guard canRun, run != nil else {
            return isNew ? "Save the shortcut to try it here." : "Save your changes to run it here."
        }
        switch state {
        case nil, .stopped: return "Runs from your home folder on this Mac.\nOutput shows here."
        case .running: return "Waiting for output…"
        case .finished: return "Finished without output."
        case .failed(let message, _, _): return message
        }
    }

    private var failed: Bool { state?.isFailure == true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                Text("Output").font(Typography.label)
                HStack(spacing: Space.sm) {
                    Breathing(active: active) {
                        Circle().fill(status.colour).frame(width: 6, height: 6)
                    }
                    Text(status.text)
                        .font(Typography.caption)
                        .foregroundStyle(failed ? Theme.deletion : Color.secondary)
                        .contentTransition(.opacity)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status: \(status.text)")
                .motion(Motion.reveal, value: status.text)
                Spacer(minLength: 0)
                if !log.isEmpty && !active {
                    InlineLink(title: "Clear", size: Typography.Size.detail) { if let run { store.clearLog(run) } }
                        .frame(minHeight: 26)
                        .transition(.fadeIn)
                }
                ActionButton(title: active ? "Stop" : "Run here",
                             tone: active ? .dangerOutlined : .outlined, height: ControlHeight.sm, size: Typography.Size.detail,
                             icon: active ? "stop.fill" : "play.fill") {
                    guard let run else { return }
                    if active { store.stop(run) } else { store.start(run) }
                }
                .disabled(!active && (!canRun || run == nil))
                .accessibilityLabel(active ? "Stop command" : "Run command here")
                .accessibilityHint(!active && !canRun ? emptyMessage : "")
            }
            .padding(.leading, Space.lg)
            .padding(.trailing, Space.md)
            .frame(height: 40)
            .motion(Motion.control, value: active)
            ScrollViewReader { scroller in
                Group {
                    if log.isEmpty {
                        Text(emptyMessage)
                            .font(Typography.detail)
                            .foregroundStyle(failed ? Theme.terminalFailure : Theme.terminalDim)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .contentTransition(.opacity)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(Space.lg)
                            .motion(Motion.reveal, value: emptyMessage)
                    } else {
                        ScrollView {
                            Text(log)
                                .font(Typography.data)
                                .foregroundStyle(Theme.terminalText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Space.lg)
                                .padding(.vertical, Space.lg)
                            Color.clear.frame(height: 1).id("output-bottom")
                        }
                    }
                }
                .frame(height: 132)
                .background(Theme.terminal)
                .onChange(of: log) { _, _ in scroller.scrollTo("output-bottom", anchor: .bottom) }
            }
        }
        .cardSurface(cornerRadius: Radius.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }
}
