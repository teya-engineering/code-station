import AppKit
import SwiftUI

struct ShortcutsView: View {
    @Environment(ShortcutStore.self) private var store
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ShortcutDraft?
    @State private var query = ""
    @State private var saveStatus = ""
    @State private var kind: ShortcutKind?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var filterTrack

    // Favorites save independently; other edits preview in the list until cancelled.
    private var shortcuts: [Shortcut] { Self.previewing(draft?.value, in: store.macShortcuts) }
    private var matches: [Shortcut] {
        Self.previewing(draft?.value, in: store.libraryShortcuts()).filter {
            (kind == nil || $0.kind == kind)
                && (query.isBlank || ($0.name + " " + $0.text).localizedStandardContains(query.trimmed))
        }
    }

    static func previewing(_ draft: Shortcut?, in shortcuts: [Shortcut]) -> [Shortcut] {
        guard let draft else { return shortcuts }
        return shortcuts.map { shortcut in
            guard shortcut.id == draft.id else { return shortcut }
            var previewed = draft
            previewed.favorite = shortcut.favorite
            return previewed
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Shortcuts").font(Typography.title)
            Text("Commands and prompts you can use in every project.")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Space.xxl)
        .headerBand()
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
                Label(shortcuts.contains(where: \.favorite) ? "Starred shortcuts stay at the top."
                      : "Star a shortcut to keep it at the top.", systemImage: "star")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.xxs)
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.sm)
            ShortcutLibraryList(shortcuts: matches, pending: draft?.isNew == true ? draft?.value : nil,
                                selectedID: draft?.value.id,
                                selectedIsDirty: draft?.isDirty == true,
                                isEmptyLibrary: shortcuts.isEmpty,
                                emptyDetail: emptyDetail,
                                clearSearch: { query = ""; kind = nil },
                                select: { shortcut in guardChanges { select(shortcut) } },
                                favorite: { shortcut in
                                    if store.toggleFavorite(shortcut.id) {
                                        let message = "\(shortcut.name) \(shortcut.favorite ? "removed from" : "added to") favorites"
                                        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                                    }
                                })
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
                    dismiss: { guardChanges { dismiss() } }) {
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
    let clearSearch: () -> Void
    let select: (Shortcut) -> Void
    let favorite: (Shortcut) -> Void
    @FocusState private var focusedStar: Shortcut.ID?
    @State private var movingID: Shortcut.ID?

    static let rowHeight: CGFloat = 52

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: Space.xxs) {
                    if pending == nil && shortcuts.isEmpty {
                        emptyMessage
                    }
                    if let pending {
                        ShortcutLibraryRow(shortcut: pending, selected: pending.id == selectedID, dirty: true,
                                           select: {}, starFocus: $focusedStar, favorite: nil)
                            .id(pending.id)
                            .transition(.fadeIn)
                    }
                    ForEach(shortcuts) { shortcut in
                        let selected = shortcut.id == selectedID
                        ShortcutLibraryRow(shortcut: shortcut, selected: selected,
                                           dirty: selected && selectedIsDirty,
                                           select: { select(shortcut) }, starFocus: $focusedStar) {
                            movingID = shortcut.id
                            focusedStar = shortcut.id
                            withAnimation(reduceMotion ? nil : Motion.control) {
                                favorite(shortcut)
                            }
                            Task { @MainActor in
                                await Task.yield()
                                scroller.scrollTo(shortcut.id)
                            }
                        }
                        .id(shortcut.id)
                        .zIndex(movingID == shortcut.id ? 1 : 0)
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.top, Space.xxs)
                .padding(.bottom, Space.md)
            }
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
    let select: () -> Void
    var starFocus: FocusState<Shortcut.ID?>.Binding
    let favorite: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var starHovering = false
    @State private var starClicks = 0

    private var title: String { shortcut.name.isBlank ? "New shortcut" : shortcut.name }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: Space.md) {
                    Image(systemName: shortcut.icon ?? shortcut.kind.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28, height: 28)
                        .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.control))
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
                            .padding(.trailing, favorite == nil ? 4 : 0)
                            .transition(popTransition)
                            .accessibilityLabel("Unsaved changes")
                    }
                }
                .padding(.leading, Space.md)
                .padding(.trailing, favorite == nil ? 10 : 4)
                .frame(height: ShortcutLibraryList.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(shortcut.kind.rawValue), available in all projects")
            .accessibilityValue(shortcut.text)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let favorite {
                Button {
                    starClicks += 1
                    favorite()
                } label: {
                    Image(systemName: shortcut.favorite ? "star.fill" : "star")
                        .font(Typography.body)
                        .foregroundStyle(shortcut.favorite ? Theme.secret : Color.secondary)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .actOut("star", trigger: starClicks)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverLift(starHovering, amount: Motion.smallLift)
                .onPointerHover { starHovering = $0 }
                .focused(starFocus, equals: shortcut.id)
                .overlay(RoundedRectangle(cornerRadius: Radius.control)
                    .stroke(starFocus.wrappedValue == shortcut.id ? Theme.accent : .clear, lineWidth: 2))
                .padding(.trailing, Space.xs)
                .accessibilityLabel(shortcut.favorite ? "Remove \(shortcut.name) from favorites" : "Add \(shortcut.name) to favorites")
                .accessibilityValue(shortcut.favorite ? "Favorite" : "Not favorite")
                .accessibilityAddTraits(shortcut.favorite ? .isSelected : [])
            }
        }
        .background {
            if selected {
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.settingsBorder))
            }
        }
        .hoverFill(cornerRadius: Radius.control)
        .motion(Motion.control, value: selected)
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
