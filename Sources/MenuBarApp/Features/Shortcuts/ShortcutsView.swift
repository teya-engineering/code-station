import AppKit
import SwiftUI
import CodeStationCore

struct ShortcutsView: View {
    @Environment(ShortcutStore.self) private var store
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ShortcutDraft?
    @State private var query = ""
    @State private var saveStatus = ""

    // The list and the header show the open draft's pick before it is saved, so they
    // never disagree with the editor beside them. Cancel puts the saved value back.
    private var shortcuts: [Shortcut] { Self.previewing(draft?.value, in: store.macShortcuts) }
    private var matches: [Shortcut] { Self.previewing(draft?.value, in: store.libraryShortcuts(query: query)) }

    static func previewing(_ draft: Shortcut?, in shortcuts: [Shortcut]) -> [Shortcut] {
        guard let draft else { return shortcuts }
        return shortcuts.map { shortcut in
            guard shortcut.id == draft.id else { return shortcut }
            var previewed = shortcut
            previewed.availableInAllProjects = draft.availableInAllProjects
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
                library.frame(width: 340)
                Divider().overlay(Theme.hairline)
                editor
            }
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

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shortcuts").font(.serif(32, .semibold))
                    .lineLimit(1)
                    .fixedSize()
                Text("\(shortcuts.count) saved on this Mac · \(shortcuts.count(where: \.availableInAllProjects)) in all projects")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            ActionButton(title: "Add shortcut", tone: .green, height: 38, size: 12, icon: "plus") {
                guardChanges { add() }
            }
            .accessibilityLabel("Add shortcut")
            GlyphButton(icon: "xmark", side: 32, tint: .secondary) {
                guardChanges { dismiss() }
            }
            .accessibilityLabel("Close shortcuts")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
    }

    private var library: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a shortcut", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Find a shortcut")
                    if !query.isEmpty {
                        GlyphButton(icon: "xmark.circle.fill", side: 32, tint: .secondary) { query = "" }
                            .accessibilityLabel("Clear search")
                    }
                }
                .font(.system(size: 12))
                .padding(.leading, 11)
                .padding(.trailing, 5)
                .frame(height: 37)
                .fieldSurface(cornerRadius: 8)
                Label(shortcuts.contains(where: \.favorite) ? "Favorites first" : "Star shortcuts to keep them first",
                      systemImage: "star")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            ShortcutLibraryList(shortcuts: matches, pending: draft?.isNew == true ? draft?.value : nil,
                                selectedID: draft?.value.id,
                                isEmptyLibrary: shortcuts.isEmpty,
                                select: { shortcut in guardChanges { select(shortcut) } },
                                favorite: { shortcut in
                                    if store.toggleFavorite(shortcut.id) {
                                        let message = "\(shortcut.name) \(shortcut.favorite ? "removed from" : "added to") favorites"
                                        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                                    }
                                })
        }
        .background(Theme.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved shortcuts")
    }

    @ViewBuilder private var editor: some View {
        if let draft {
            VStack(spacing: 0) {
                ScrollView {
                    ShortcutEditorForm(draft: draft, locked: store.isRunningAnywhere(draft.value.id),
                                       showsCommandOutput: true) {
                        ShortcutCommandOutput(shortcut: store.shortcut(draft.value.id),
                                              canRun: !draft.isDirty && !draft.isNew,
                                              availableInAllProjects: draft.value.availableInAllProjects)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 25)
                }
                .id(draft.value.id)
                footer(draft)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func footer(_ draft: ShortcutDraft) -> some View {
        SheetFooter(primary: SheetAction(title: draft.isNew ? "Add shortcut" : "Save shortcut",
                                         enabled: draft.canSave && !store.isRunningAnywhere(draft.value.id),
                                         shortcut: KeyboardShortcut("s"), action: { _ = save() }),
                    dismissTone: .outlined, primaryLast: true,
                    dismiss: {
                        if draft.isNew, let first = matches.first { select(first) }
                        else { draft.reset(); saveStatus = "" }
                    }) {
            if !draft.isNew {
                Button { remove(draft) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("Remove shortcut")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove shortcut")
            }
            Text(draft.isDirty ? "Unsaved changes" : saveStatus)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func select(_ shortcut: Shortcut) {
        draft = ShortcutDraft(request: ShortcutEditorRequest(shortcut: shortcut))
        saveStatus = ""
    }

    private func add() {
        draft = ShortcutDraft(request: ShortcutEditorRequest(name: "New Shortcut"))
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
        var rows = [Dialog.Impact.Row(title: "Saved command",
                                     detail: shortcut.availableInAllProjects
                                     ? "Removed from all projects." : "Removed from this Mac.")]
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
    let isEmptyLibrary: Bool
    let select: (Shortcut) -> Void
    let favorite: (Shortcut) -> Void
    @FocusState private var focusedStar: Shortcut.ID?
    @State private var movingID: Shortcut.ID?
    @State private var visibleRect = CGRect.zero

    static let rowHeight: CGFloat = 76
    static let rowStride: CGFloat = 80

    private var rows: [Shortcut] { (pending.map { [$0] } ?? []) + shortcuts }

    private var below: [Shortcut] {
        rows.enumerated().filter {
            CGFloat($0.offset) * Self.rowStride + Self.rowHeight > visibleRect.maxY + 2
        }.map(\.element)
    }

    var body: some View {
        ScrollViewReader { scroller in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 4) {
                        if rows.isEmpty {
                            PaneMessage(icon: isEmptyLibrary ? "bolt.slash" : "magnifyingglass",
                                        title: isEmptyLibrary ? "No shortcuts saved" : "No shortcuts found",
                                        detail: isEmptyLibrary ? "Add a command to get started."
                                        : "Try another name or clear the search.")
                                .frame(minHeight: 100)
                        }
                        if let pending {
                            ShortcutLibraryRow(shortcut: pending, selected: pending.id == selectedID,
                                               select: {}, starFocus: $focusedStar, favorite: nil)
                                .id(pending.id)
                        }
                        ForEach(shortcuts) { shortcut in
                            ShortcutLibraryRow(shortcut: shortcut, selected: shortcut.id == selectedID,
                                               select: { select(shortcut) }, starFocus: $focusedStar) {
                                movingID = shortcut.id
                                focusedStar = shortcut.id
                                withAnimation(reduceMotion ? nil : .timingCurve(0.2, 0.75, 0.25, 1, duration: 0.34)) {
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
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.visible)
                .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
                    visibleRect = rect
                }
                .overlay(alignment: .trailing) {
                    GeometryReader { geometry in
                        let contentHeight = CGFloat(rows.count) * Self.rowStride + 8
                        if visibleRect.height > 0, contentHeight > visibleRect.height {
                            let trackHeight = max(0, geometry.size.height - 8)
                            let thumbHeight = min(trackHeight, max(20, trackHeight * visibleRect.height / contentHeight))
                            let progress = min(1, max(0, visibleRect.minY / (contentHeight - visibleRect.height)))
                            Capsule().fill(Theme.accent.opacity(0.08))
                                .overlay(alignment: .top) {
                                    Capsule().fill(Theme.accent.opacity(0.4))
                                        .frame(height: thumbHeight)
                                        .offset(y: (trackHeight - thumbHeight) * progress)
                                }
                                .frame(width: 4, height: trackHeight)
                                .padding(.vertical, 4)
                        }
                    }
                    .frame(width: 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                Divider().overlay(Theme.hairline)
                Group {
                    if let first = below.first {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                scroller.scrollTo(first.id, anchor: .top)
                            }
                        } label: {
                            Label("\(below.count) more shortcut\(below.count == 1 ? "" : "s") below",
                                  systemImage: "arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .surface(Theme.accent.opacity(0.07), cornerRadius: 7, border: Theme.accent.opacity(0.25))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label(rows.isEmpty ? "No matching shortcuts"
                              : visibleRect.minY > 2 ? "End of list · \(rows.count) shortcuts"
                              : "All \(rows.count) shortcuts visible", systemImage: "checkmark")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }
}

struct ShortcutLibraryRow: View {
    let shortcut: Shortcut
    let selected: Bool
    let select: () -> Void
    var starFocus: FocusState<Shortcut.ID?>.Binding
    let favorite: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: select) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: shortcut.icon ?? "terminal")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? .white : Theme.accent)
                        .frame(width: 28, height: 28)
                        .background(selected ? Theme.accentFill : Theme.accent.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shortcut.name.isBlank ? "New Shortcut" : shortcut.name)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.trailing, 26)
                        Text(shortcut.text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                            .font(.mono(10.5))
                            .foregroundStyle(.secondary)
                        Label(shortcut.availableInAllProjects ? "All projects" : "Shortcuts window",
                              systemImage: shortcut.availableInAllProjects ? "globe" : "macwindow")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(height: ShortcutLibraryList.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let favorite {
                Button(action: favorite) {
                    Image(systemName: shortcut.favorite ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundStyle(shortcut.favorite ? Theme.secret : Color.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused(starFocus, equals: shortcut.id)
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(starFocus.wrappedValue == shortcut.id ? Theme.accent : .clear, lineWidth: 2))
                .padding(.trailing, 5)
                .padding(.top, 3)
                .accessibilityLabel(shortcut.favorite ? "Remove \(shortcut.name) from favorites" : "Add \(shortcut.name) to favorites")
                .accessibilityValue(shortcut.favorite ? "Favorite" : "Not favorite")
                .accessibilityAddTraits(shortcut.favorite ? .isSelected : [])
            }
        }
        .surface(selected ? Theme.accent.opacity(0.07) : Theme.sidebar, cornerRadius: 8,
                 border: selected ? Theme.accent.opacity(0.4) : .clear)
    }
}

private struct ShortcutCommandOutput: View {
    @Environment(ShortcutStore.self) private var store
    let shortcut: Shortcut?
    let canRun: Bool
    let availableInAllProjects: Bool

    private var runLine: String {
        guard canRun else { return "Save your changes before running this command." }
        return availableInAllProjects
            ? "Runs with zsh from ~ here, or from the project folder that runs it."
            : "Runs with zsh from ~ on this Mac."
    }

    private var run: ShortcutRun? {
        shortcut.map { ShortcutRun($0.id, in: $0.directory(projectPath: nil)) }
    }
    private var active: Bool { run.map { store.state($0).isActive } ?? false }
    private var log: String { run.map(store.log) ?? "" }
    private var status: String {
        guard let run else { return "Not running" }
        switch store.state(run) {
        case .stopped: return "Not running"
        case .running: return "Running"
        case .finished: return "Finished"
        case .failed: return "Failed"
        }
    }
    private var output: String {
        if !log.isEmpty { return log }
        guard let run else { return "Save this shortcut before running it." }
        switch store.state(run) {
        case .stopped: return "Run this command to see its output here."
        case .running: return "Waiting for output…"
        case .finished: return "Finished without output."
        case .failed(let message, _, _): return message
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(runLine)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                ActionButton(title: active ? "Stop command" : "Run command",
                             tone: active ? .danger : .dark, height: 33, size: 12,
                             icon: active ? "stop.fill" : "play.fill") {
                    guard let run else { return }
                    if active { store.stop(run) } else { store.start(run) }
                }
                .disabled(!active && (!canRun || run == nil))
            }
            VStack(spacing: 0) {
                HStack {
                    Text("Output").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
                    if !log.isEmpty {
                        Button("Clear") { if let run { store.clearLog(run) } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11)).foregroundStyle(Theme.accent)
                            .frame(minHeight: 32)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 45)
                ScrollViewReader { scroller in
                    Group {
                        if log.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "terminal").font(.system(size: 22))
                                Text(output).font(.system(size: 12))
                                    .textSelection(.enabled)
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(14)
                        } else {
                            ScrollView {
                                Text(output)
                                    .font(.mono(11))
                                    .foregroundStyle(Theme.terminalText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                Color.clear.frame(height: 1).id("output-bottom")
                            }
                        }
                    }
                    .frame(height: 120)
                    .background(log.isEmpty ? Theme.card : Theme.terminal)
                    .onChange(of: log) { _, _ in scroller.scrollTo("output-bottom", anchor: .bottom) }
                }
            }
            .cardSurface(cornerRadius: 10)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
