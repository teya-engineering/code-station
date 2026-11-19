import AppKit
import Foundation
import SwiftUI

// Commands and prompts share one list in one order, and the first of them is on the split
// button beside the message box: a command runs, a prompt is inserted into the draft
// without starting a turn. The button only changes when the order does.
struct SessionRunButton: View {
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.keyBindings) private var keyBindings

    let session: ChatSession
    var availableWidth: CGFloat = 340
    let edit: (ShortcutEditorRequest) -> Void

    @State private var listOpen = false
    @State private var libraryOpen = false
    @State private var query = ""
    @State private var kind: ShortcutKind?
    @FocusState private var pickerFocused: Bool
    @FocusState private var focusedRow: String?
    // The card the arrow keys are on, counted from the top of the list.
    @State private var highlighted = 0
    @State private var buttonAnchor = FrameAnchor()
    @State private var listAnchor = FrameAnchor()
    @State private var listMonitor = CommandListMonitor()
    @State private var reorder = LiveReorder()
    @State private var contentHeight: CGFloat = 0
    // Counts each new shortcut landing on the button, to play the rings once for each.
    @State private var landings: Int?
    // Where the button and each card are in the window, so an inserted prompt can fly
    // from the place it was chosen.
    @State private var buttonFrame: CGRect = .zero
    @State private var cardFrames: [Shortcut.ID: CGRect] = [:]
    @Namespace private var filterTrack

    private var scope: ShortcutScope { .session(session.id) }

    static let rowGap = Space.md

    var body: some View {
        let entries = entries
        // While a row is in the air the button already shows what would be on top if it
        // were let go there, so the drag says what it will do before it is done.
        let top = reorder.isDragging
            ? reorder.preview(entries.map(\.id)).first.flatMap { id in entries.first { $0.id == id } }
            : entries.first
        HStack(spacing: 0) {
            if let top {
                splitButton(top, entries: entries)
            } else {
                Button(action: toggleList) {
                    Label("Shortcuts", systemImage: "bolt")
                        .font(Typography.label)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, Space.lg)
                        .frame(height: ControlHeight.md)
                        .cardSurface(cornerRadius: Radius.card)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverLift()
                .accessibilityValue(listOpen ? "Expanded" : "Collapsed")
            }
        }
        .background(FrameAnchorView(anchor: buttonAnchor))
        .overlay(alignment: .topTrailing) {
            // The guide sits on a stack that is always there. Set on the list inside the
            // `if`, SwiftUI drops it and the panel hangs down over the composer.
            ZStack {
                if listOpen {
                    list(entries).transition(.popover(reduceMotion: reduceMotion))
                }
            }
            .alignmentGuide(.top) { $0[.bottom] + 10 }
        }
        .background(keyShortcuts(top: entries.first))
        .motion(listOpen ? Motion.reveal : Motion.leave, value: listOpen)
        .onChange(of: listOpen) { _, open in
            open ? startListening() : listMonitor.stop()
        }
        .onChange(of: entries.first?.id) { old, new in
            if old != nil, new != nil { landings = (landings ?? 0) + 1 }
        }
        .onDisappear { listMonitor.stop() }
        .sheet(isPresented: $libraryOpen) { ShortcutsView().appOverlays() }
    }

    // MARK: - The button

    private func splitButton(_ top: Entry, entries: [Entry]) -> some View {
        let verb = Self.verb(for: top.shortcut, state: shortcuts.state(top.run))
        // Commands started from the list that are not on the button still need a way
        // back, so the list half counts them.
        let othersRunning = entries.count(where: { $0.id != top.id && shortcuts.state($0.run).isActive })
        return HStack(spacing: 0) {
            RunHalf(name: top.shortcut.name, kind: top.shortcut.kind, state: shortcuts.state(top.run)) {
                use(top, from: buttonFrame)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { buttonFrame = $0 }
            .appContextMenu { menu(for: top, entries: entries) }
            .appTooltip {
                Tooltip(title: shortcuts.state(top.run).isActive
                            ? "Show what \(top.shortcut.name) is printing"
                            : keyBindings.tooltip("\(verb) \(top.shortcut.name)", for: .runLastCommand),
                        subtitle: top.shortcut.text)
            }

            Rectangle()
                .fill(Theme.onFill.opacity(0.18))
                .frame(width: 1, height: ControlHeight.md)

            ListHalf(open: listOpen, running: othersRunning) { toggleList() }
                .appTooltip(keyBindings.tooltip("All shortcuts", for: .savedCommands))
        }
        .fixedSize()
        .landingRings(landings, colour: Theme.brand, cornerRadius: Radius.card, reach: 1.2)
    }

    static func verb(for shortcut: Shortcut, state: ShortcutStore.State) -> String {
        if shortcut.kind == .prompt { return "Ask" }
        return state.isActive ? "Output" : "Run"
    }

    // MARK: - The list

    private func list(_ entries: [Entry]) -> some View {
        let shown = shown(entries)
        let rows = rows(entries)
        let filtered = isFiltered
        return VStack(spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Text("Shortcuts").font(Typography.body.weight(.semibold))
                CountBadge(count: entries.count)
                Spacer()
                if !filtered && entries.count > 1 {
                    HStack(spacing: Space.xxs) {
                        Keycap("⌥")
                        Keycap("↑")
                        Keycap("↓")
                        Text("to sort").padding(.leading, Space.xxs)
                    }
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Option Up and Option Down sort the highlighted shortcut")
                    .transition(.fadeIn)
                }
                GlyphButton(icon: "xmark", side: ControlHeight.sm, tint: .secondary, action: closeList)
                    .accessibilityLabel("Close shortcuts")
            }
            .padding(.horizontal, Space.sm)
            .motion(Motion.reveal, value: filtered)
            HStack(spacing: Space.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a shortcut", text: $query)
                    .textFieldStyle(.plain)
                    .focused($pickerFocused)
                    .accessibilityLabel("Find a shortcut")
                if !query.isEmpty {
                    GlyphButton(icon: "xmark.circle.fill", side: ControlHeight.sm, tint: .secondary) { query = "" }
                        .accessibilityLabel("Clear shortcut search")
                }
            }
            .font(Typography.detail)
            .padding(.horizontal, Space.md)
            .frame(height: ControlHeight.lg)
            .fieldSurface(cornerRadius: Radius.control)
            .overlay(RoundedRectangle(cornerRadius: Radius.control)
                .stroke(pickerFocused ? Theme.accent : .clear, lineWidth: 2))
            HStack(spacing: Space.xxs) {
                filter("All", kind: nil, entries: entries)
                filter("Commands", kind: .command, entries: entries)
                filter("Prompts", kind: .prompt, entries: entries)
            }
            .padding(Space.xxs)
            .fieldSurface(cornerRadius: Radius.card)
            .motion(Motion.control, value: kind)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filter shortcuts by type")
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: Self.rowGap) {
                        if shown.isEmpty {
                            emptyMessage(entries)
                        } else {
                            cards(shown, entries: entries, rows: rows)
                        }
                        if !filtered, let last = saveLastCommand(entries) {
                            let index = rows.firstIndex { $0.id == Row.saveLast(last).id } ?? -1
                            CommandCard(kind: nil, icon: "square.and.arrow.down",
                                        name: "Save the agent's last command",
                                        detail: .command(last), tint: nil, dashed: true,
                                        highlighted: highlighted == index) { choose(.saveLast(last)) }
                                .padding(.horizontal, LeadSlot.inset)
                                .id(index)
                                .transition(.fadeIn)
                        }
                    }
                    .padding(.bottom, Space.xxs)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(360, max(contentHeight, 60)))
                .onChange(of: highlighted) { _, index in scroller.scrollTo(index) }
            }
            orderNote(entries)
            Divider().overlay(Theme.hairline)
            HStack {
                footerAction("New shortcut", icon: "plus", row: .new, rows: rows)
                Spacer(minLength: Space.md)
                footerAction("Manage shortcuts", row: .manage, rows: rows)
            }
        }
        .padding(Space.md)
        .frame(width: min(400, max(260, availableWidth)))
        .background {
            RoundedRectangle(cornerRadius: Radius.floating)
                .fill(Theme.sidebar)
                .overlay(RoundedRectangle(cornerRadius: Radius.floating).strokeBorder(Theme.settingsBorder))
                .elevation(.floating)
        }
        .background(FrameAnchorView(anchor: listAnchor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shortcuts")
        .motion(Motion.reveal, value: orderSource)
        .motion(Motion.control, value: shown.map(\.id))
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onChange(of: kind) { _, _ in highlighted = 0 }
        .onChange(of: focusedRow) { _, id in
            if let index = rows.firstIndex(where: { $0.id == id }) { highlighted = index }
        }
    }

    // The shortcuts in order. The first one sits in the slot marked as the button's, and
    // the rows can be dragged into a new order while nothing hides any of them.
    private func cards(_ shown: [Entry], entries: [Entry], rows: [Row]) -> some View {
        let ids = shown.map(\.id)
        let slotShown = shown.first?.id == entries.first?.id
        let sortable = !isFiltered
        return VStack(spacing: Self.rowGap) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                card(entry, index: index, count: entries.count, isTop: entry.id == entries.first?.id,
                     sortable: sortable, highlighted: highlighted == index)
                    .focused($focusedRow, equals: Row.shortcut(entry).id)
                    .liveReorder(entry.id, in: ids, spacing: Self.rowGap, enabled: sortable,
                                 cornerRadius: Radius.floating, state: $reorder) { id, position in
                        move(id, to: position, entries: entries)
                    }
                    .id(index)
            }
        }
        .padding(.horizontal, LeadSlot.inset)
        .padding(.top, slotShown ? LeadSlot.topRoom : 0)
        .background(alignment: .top) {
            if slotShown, let first = shown.first {
                LeadSlot(caption: "On the button",
                         keys: keyBindings.keys(for: .runLastCommand)?.compactLabel,
                         rowHeight: reorder.height(first.id))
                    .transition(.fadeIn)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shortcuts, in order")
    }

    private func card(_ entry: Entry, index: Int, count: Int, isTop: Bool,
                      sortable: Bool, highlighted: Bool) -> some View {
        let shortcut = entry.shortcut
        let detail: CommandCard.Detail = shortcut.kind == .prompt
            ? .plain(shortcut.text) : .outcome(summary(of: entry))
        let position = "Position \(index + 1) of \(count)" + (isTop ? ", on the button" : "")
        return CommandCard(kind: shortcut.kind,
                           icon: shortcut.kind == .prompt ? shortcut.icon ?? ShortcutKind.prompt.icon
                                                          : shortcut.glyph ?? "terminal",
                           name: shortcut.name, detail: detail, tint: entry.tint, dashed: false,
                           highlighted: highlighted,
                           verb: Self.verb(for: shortcut, state: shortcuts.state(entry.run)),
                           lead: isTop, grip: sortable ? .on : .dimmed,
                           position: position) { choose(.shortcut(entry)) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cardFrames[entry.id] = $0 }
            .appContextMenu { menu(for: entry, entries: entries) }
            .accessibilityAction(named: "Put on the button") { move(entry.id, to: 0, entries: entries) }
            .accessibilityAction(named: "Move up") { move(entry.id, by: -1, entries: entries) }
            .accessibilityAction(named: "Move down") { move(entry.id, by: 1, entries: entries) }
    }

    private func filter(_ title: String, kind choice: ShortcutKind?, entries: [Entry]) -> some View {
        let count = choice.map { choice in entries.count(where: { $0.shortcut.kind == choice }) } ?? entries.count
        return ChoicePill(title: title, selected: kind == choice, thumb: filterTrack,
                          fills: true, count: count) { kind = choice }
            .accessibilityLabel(title)
            .accessibilityValue("\(count)")
    }

    @ViewBuilder private func emptyMessage(_ entries: [Entry]) -> some View {
        VStack(spacing: Space.sm) {
            if entries.isEmpty {
                Text("No shortcuts saved. Add one below.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No shortcuts found").font(Typography.detail.weight(.semibold))
                let within = kind.map { " in \($0.title.lowercased())s" } ?? ""
                Text(query.isBlank ? "No \(kind?.title.lowercased() ?? "shortcut")s saved yet."
                                   : "Nothing is called “\(query.trimmed)”\(within).")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                InlineLink(title: query.isBlank ? "Show all" : "Clear search",
                           size: Typography.Size.caption, action: showAll)
            }
        }
        .font(Typography.caption)
        .frame(maxWidth: .infinity)
        .padding(Space.lg)
        .transition(.fadeIn)
    }

    private func showAll() {
        query = ""
        kind = nil
        pickerFocused = true
    }

    // MARK: - Sorting

    private enum OrderSource: Equatable {
        case standard
        case project
        case session
    }

    private var orderSource: OrderSource {
        if shortcuts.hasOwnOrder(scope) { return .session }
        if shortcuts.hasOwnOrder(.project(session.projectID)) { return .project }
        return .standard
    }

    private var isFiltered: Bool { !query.isBlank || kind != nil }

    // The line under the list says whose order this is and how to leave it. A drag sorts
    // this session only, and the way out is to hand the order to the project or go back
    // to the one above.
    @ViewBuilder private func orderNote(_ entries: [Entry]) -> some View {
        let source = orderSource
        let projectName = store.project(session.projectID)?.name ?? "the project"
        HStack(spacing: Space.sm) {
            if isFiltered {
                Image(systemName: "arrow.up.arrow.down").accessibilityHidden(true)
                Text("Sorting is off while the list is filtered.")
                    .lineLimit(1)
                Spacer(minLength: Space.sm)
                InlineLink(title: "Show all \(entries.count)", size: Typography.Size.caption, action: showAll)
            } else {
                switch source {
                case .standard:
                    Image(systemName: "arrow.up.arrow.down").accessibilityHidden(true)
                    Text("In the order set in Settings. Drag a card to sort this session.")
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                case .session:
                    Image(systemName: "arrow.up.arrow.down").accessibilityHidden(true)
                    Text("Sorted for this session").lineLimit(1)
                    Spacer(minLength: Space.sm)
                    InlineLink(title: "Use for \(projectName)", size: Typography.Size.caption) {
                        sort("Every session in \(projectName) now uses this order.") {
                            shortcuts.keepSessionOrder(session.id, for: session.projectID)
                        }
                    }
                    .appTooltip("Sort every session in \(projectName) this way")
                    resetLink(source, projectName: projectName)
                case .project:
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.dotOnText)
                        .accessibilityHidden(true)
                    Text("Sorted for every session in \(projectName)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Space.sm)
                    resetLink(source, projectName: projectName)
                }
            }
        }
        .font(Typography.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.sm)
        .id(isFiltered ? "filtered" : "\(source)")
        .transition(.fadeIn)
    }

    private func resetLink(_ source: OrderSource, projectName: String) -> some View {
        InlineLink(title: "Reset", size: Typography.Size.caption) {
            sort(nil) { shortcuts.resetOrder(for: source == .session ? scope : .project(session.projectID)) }
            if let top = entries.first { announce("Order reset. \(top.shortcut.name) is on the button.") }
        }
        .appTooltip(source == .session && shortcuts.hasOwnOrder(.project(session.projectID))
                    ? "Go back to the order of \(projectName)" : "Go back to the order in Settings")
    }

    @discardableResult
    private func sort(_ announcement: String?, _ change: () -> Bool) -> Bool {
        let changed = withAnimation(reduceMotion ? nil : Motion.control) { change() }
        if changed, let announcement { announce(announcement) }
        return changed
    }

    // Moves are made on the whole list, so they only happen while nothing is hidden.
    private func move(_ id: Shortcut.ID, to position: Int, entries: [Entry]) {
        guard !isFiltered, let entry = entries.first(where: { $0.id == id }) else { return }
        let ids = entries.map(\.id)
        let target = min(max(position, 0), ids.count - 1)
        guard ids.firstIndex(of: id) != target else { return }
        let message = "\(entry.shortcut.name) moved to position \(target + 1) of \(ids.count)."
            + (target == 0 ? " It is now on the button." : "")
        if sort(message, { shortcuts.move(id, to: target, in: ids, for: scope) }) {
            highlighted = target
        }
    }

    private func move(_ id: Shortcut.ID, by step: Int, entries: [Entry]) {
        guard let from = entries.firstIndex(where: { $0.id == id }) else { return }
        move(id, to: from + step, entries: entries)
    }

    private func announce(_ message: String) {
        guard let window = buttonAnchor.view?.window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func footerAction(_ title: String, icon: String? = nil, row: Row, rows: [Row]) -> some View {
        Button { choose(row) } label: {
            HStack(spacing: Space.xs) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(Typography.caption.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedRow, equals: row.id)
        .hoverFill(cornerRadius: Radius.inset)
        .overlay(RoundedRectangle(cornerRadius: Radius.inset)
            .stroke((rows.indices.contains(highlighted) && rows[highlighted].id == row.id) ? Theme.accent : .clear, lineWidth: 2))
    }

    private enum Row: Identifiable {
        case new
        case manage
        case saveLast(String)
        case shortcut(Entry)

        var id: String {
            switch self {
            case .new: "new"
            case .manage: "manage"
            case .saveLast: "save-last"
            case .shortcut(let entry): entry.id.uuidString
            }
        }
    }

    private func shown(_ entries: [Entry]) -> [Entry] {
        entries.filter { ShortcutStore.matches($0.shortcut, query: query, kind: kind) }
    }

    private func saveLastCommand(_ entries: [Entry]) -> String? {
        guard let last = SessionShortcuts.lastAgentCommand(in: session),
              !entries.contains(where: { $0.shortcut.kind == .command && $0.shortcut.text == last })
        else { return nil }
        return last
    }

    // Everything the arrow keys walk through, in the order it is drawn.
    private func rows(_ entries: [Entry]) -> [Row] {
        var rows = shown(entries).map(Row.shortcut)
        if !isFiltered, let last = saveLastCommand(entries) { rows.append(.saveLast(last)) }
        return rows + [.new, .manage]
    }

    private func summary(of command: Entry) -> CommandRunSummary {
        CommandRunSummary(state: shortcuts.state(command.run),
                          duration: shortcuts.duration(command.run),
                          started: shortcuts.hasStarted(command.run))
    }

    // MARK: - Opening and closing

    private func toggleList() {
        listOpen ? closeList() : openList()
    }

    private func openList() {
        highlighted = 0
        listOpen = true
        pickerFocused = true
    }

    private func closeList() {
        listOpen = false
    }

    // The arrow keys and Return belong to the list while it is open, even with the cursor
    // still in the prompt, and Escape closes it before it can stop the turn. Option with
    // an arrow moves the highlighted shortcut. A click anywhere else puts it away, the
    // way a menu goes.
    private func startListening() {
        listMonitor.start(
            anchor: buttonAnchor,
            regions: [buttonAnchor, listAnchor],
            key: { key in
                let entries = self.entries
                let rows = self.rows(entries)
                switch key {
                case .up:
                    highlighted = max(0, highlighted - 1)
                    focusedRow = rows[highlighted].id
                case .down:
                    highlighted = min(rows.count - 1, highlighted + 1)
                    focusedRow = rows[highlighted].id
                case .moveUp, .moveDown:
                    guard rows.indices.contains(highlighted),
                          case .shortcut(let entry) = rows[highlighted] else { return }
                    move(entry.id, by: key == .moveUp ? -1 : 1, entries: entries)
                case .choose:
                    guard rows.indices.contains(highlighted) else { return }
                    choose(rows[highlighted])
                case .close: closeList()
                }
            },
            outside: { closeList() })
    }

    private func choose(_ row: Row) {
        // A drag that ends over the row it started on must not also count as a click.
        guard !reorder.isDragging else { return }
        closeList()
        switch row {
        case .new: edit(blankRequest)
        case .manage: libraryOpen = true
        case .saveLast(let command):
            var request = blankRequest
            request.text = command
            request.kind = .command
            edit(request)
        case .shortcut(let entry): use(entry, from: cardFrames[entry.id] ?? buttonFrame)
        }
    }

    // MARK: - Keys

    // One key uses the shortcut on the button and another opens the list.
    private func keyShortcuts(top: Entry?) -> some View {
        ZStack {
            if let top {
                Button("") { use(top, from: buttonFrame) }
                    .appShortcut(.runLastCommand)
            }
            Button("") { toggleList() }
                .appShortcut(.savedCommands)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Using a shortcut

    // A prompt flies from where it was chosen and its text lands in the message box. The
    // message box announces it once the text is in.
    private func use(_ entry: Entry, from: CGRect) {
        switch entry.shortcut.kind {
        case .prompt:
            closeList()
            runner.composer.launch(entry.shortcut, in: session.id, from: from)
        case .command:
            activate(entry)
        }
    }

    // While a command runs, its button is the way back to what it is printing, not the
    // way to kill it. Stopping is the rarer of the two and stays in its menu and in the
    // drawer the output opens in.
    private func activate(_ command: Entry) {
        guard shortcuts.shortcut(command.id)?.kind == .command else { return }
        if !shortcuts.state(command.run).isActive {
            shortcuts.start(command.run)
        }
        shortcuts.showOutput(command.run, for: scope)
    }

    private func menu(for entry: Entry, entries: [Entry]) -> [MenuEntry] {
        let shortcut = entry.shortcut
        let index = entries.firstIndex { $0.id == entry.id } ?? 0
        let sortable = !isFiltered
        var items: [MenuEntry]
        if shortcut.kind == .prompt {
            items = [.item("Ask", icon: "bubble.left", action: {
                use(entry, from: cardFrames[entry.id] ?? buttonFrame)
            })]
        } else {
            let running = shortcuts.state(entry.run).isActive
            items = [
                running
                    ? .item("Stop", icon: "stop.fill", action: { shortcuts.stop(entry.run) })
                    : .item("Run", icon: "play.fill", action: { activate(entry) }),
                .item("Show output", icon: "terminal", action: {
                    closeList()
                    shortcuts.showOutput(entry.run, for: scope)
                })
            ]
        }
        items += [
            .separator,
            .item("Put on the button", icon: "capsule", disabled: index == 0 || !sortable, action: {
                move(entry.id, to: 0, entries: entries)
            }),
            .item("Move up", icon: "arrow.up", disabled: index == 0 || !sortable, action: {
                move(entry.id, by: -1, entries: entries)
            }),
            .item("Move down", icon: "arrow.down", disabled: index == entries.count - 1 || !sortable, action: {
                move(entry.id, by: 1, entries: entries)
            }),
            .separator,
            .item("Edit", action: {
                closeList()
                edit(ShortcutEditorRequest(shortcut: shortcut,
                                           projectID: entry.checkout.projectID,
                                           projectName: entry.projectName))
            })
        ]
        if !shortcut.availableInAllProjects {
            items.append(.item("Remove", kind: .destructive, action: { confirmRemove(entry) }))
        }
        return items
    }

    // The list goes away first, or its key monitor would take the Return and Escape
    // meant for the dialog.
    private func confirmRemove(_ entry: Entry) {
        closeList()
        let shortcut = entry.shortcut
        var rows = [Dialog.Impact.Row(title: "Saved \(shortcut.kind.rawValue)", detail: "Removed from this project.")]
        if shortcuts.isRunningAnywhere(shortcut.id) {
            rows.append(.init(title: "Running commands", detail: "Stopped right away."))
        }
        rows.append(.init(title: "Projects and conversations", detail: "Kept unchanged.", kept: true))
        dialogs.show(.impact("Remove \(shortcut.name)?",
                             subject: entry.projectName.map { .init(name: $0) },
                             rows: rows,
                             warning: "This shortcut cannot be restored after removal.",
                             action: "Remove shortcut") {
            shortcuts.remove(shortcut.id)
        })
    }

    private var blankRequest: ShortcutEditorRequest {
        ShortcutEditorRequest(projectID: session.projectID,
                              projectName: store.project(session.projectID)?.name,
                              text: runner.composer.draft(session.id).text,
                              kind: .prompt)
    }

    // MARK: - The shortcuts

    private struct Entry: Identifiable {
        let shortcut: Shortcut
        let checkout: SessionProject
        let projectName: String?
        let run: ShortcutRun
        let tint: Theme.ProjectTint?

        var id: Shortcut.ID { shortcut.id }
    }

    private var entries: [Entry] {
        let checkouts = store.checkoutProjects(for: session)
        let tinted = checkouts.count > 1
        return shortcuts.shortcuts(for: checkouts.map(\.projectID), session: session.id).compactMap { placement in
            guard let checkout = checkouts.first(where: { $0.projectID == placement.projectID })
            else { return nil }
            let project = store.project(checkout.projectID)
            let shortcut = placement.shortcut
            return Entry(
                shortcut: shortcut,
                checkout: checkout,
                projectName: project?.name,
                run: ShortcutRun(shortcut.id,
                                 in: shortcut.directory(projectPath: project?.path,
                                                        workspacePath: checkout.worktreePath)),
                tint: tinted ? Theme.projectTint(for: project?.name ?? "") : nil)
        }
    }
}


// MARK: - The two halves

private struct RunHalf: View {
    let name: String
    let kind: ShortcutKind
    let state: ShortcutStore.State
    let action: () -> Void

    @Environment(\.keyBindings) private var keyBindings
    @State private var hovering = false

    private var running: Bool { state.isActive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                ZStack {
                    if running {
                        RunSpinner().transition(.opacity)
                    } else {
                        Image(systemName: kind == .prompt ? "bubble.left" : "play.fill")
                            .font(Typography.micro.weight(.bold))
                            .id(kind)
                            .transition(.opacity)
                    }
                }
                .frame(width: 12, height: 12)
                RollingText(running ? name : "\(verb) \(name)",
                            font: Typography.body.weight(.semibold))
                if case .running(let since) = state {
                    TimelineView(.periodic(from: since, by: 0.1)) { context in
                        Text(CommandRunSummary.elapsed(context.date.timeIntervalSince(since)))
                            .font(Typography.detail)
                            .monospacedDigit()
                            .opacity(0.7)
                    }
                    .transition(.opacity)
                }
                if let keys = keyBindings.keys(for: .runLastCommand) {
                    KeyHint(keys.compactLabel, onFill: true)
                }
            }
            .foregroundStyle(Theme.onFill)
            .lineLimit(1)
            .padding(.leading, Space.lg)
            .padding(.trailing, Space.md)
            .frame(height: ControlHeight.md)
            .background(Theme.accentFill.brightness(hovering ? 0.06 : 0))
            .overlay(alignment: .bottom) {
                if running { RunSweep().transition(.opacity) }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: Radius.card, bottomLeadingRadius: Radius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.control, value: running)
        .motion(Motion.control, value: kind)
        .accessibilityLabel(running ? "Show the output of \(name)" : "\(verb) \(name)")
        .accessibilityHint("The first shortcut in the list is on this button.")
    }

    private var verb: String { kind == .prompt ? "Ask" : "Run" }
}

private struct ListHalf: View {
    let open: Bool
    // Commands running from the list that are not on the button.
    let running: Int
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: "bolt")
                    .font(Font.system(size: Typography.Size.micro))
                    .actOut("bolt", trigger: open ? 1 : 0)
                Text("Shortcuts")
                    .font(Typography.detail.weight(.medium))
                    .monospacedDigit()
                    .opacity(0.75)
                if running > 0 {
                    HStack(spacing: Space.xxs) {
                        Circle().fill(Theme.brand).frame(width: 6, height: 6)
                        Text(verbatim: "\(running)")
                            .font(Typography.micro)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(running)))
                    }
                    .transition(.opacity)
                }
                Chevron()
                    .stroke(Theme.onFill, style: StrokeStyle(lineWidth: 1.6, lineCap: .round,
                                                       lineJoin: .round))
                    .frame(width: 8, height: 4.5)
                    // Turned inside the label, never on the button: the button carries
                    // AppKit views that cannot be laid out under a rotation.
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .motion(Motion.control, value: open)
            }
            .foregroundStyle(Theme.onFill)
            .padding(.horizontal, Space.md)
            .frame(height: ControlHeight.md)
            .background(Theme.accentFill.brightness(hovering ? 0.06 : 0))
            .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: Radius.card, topTrailingRadius: Radius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.pop, value: running)
        .accessibilityLabel(running > 0 ? "All shortcuts, \(running) running" : "All shortcuts")
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}

// Points up, towards where the list opens from a row this near the bottom of the window.
private struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
    }
}

// A ring turning while the command runs. With motion turned down it holds still, and the
// words beside it still say the command is running.
private struct RunSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RunSpinnerLayer(moving: !reduceMotion)
            .frame(width: 11, height: 11)
            .allowsHitTesting(false)
    }
}

private struct RunSpinnerLayer: NSViewRepresentable {
    let moving: Bool

    func makeNSView(context: Context) -> RunSpinnerView { RunSpinnerView() }

    func updateNSView(_ view: RunSpinnerView, context: Context) {
        view.update(moving: moving)
    }
}

final class RunSpinnerView: LoopLayerView {
    static let lap: CFTimeInterval = 0.8

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private(set) var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        track.fillColor = nil
        track.strokeColor = CGColor(gray: 1, alpha: 0.3)
        track.lineWidth = 1.8
        arc.fillColor = nil
        arc.strokeColor = .white
        arc.lineWidth = 1.8
        arc.lineCap = .round
        arc.strokeEnd = 0.28
        layer?.addSublayer(track)
        layer?.addSublayer(arc)
    }

    var loops: [String] { arc.animationKeys() ?? [] }

    func update(moving: Bool) {
        guard moving != self.moving else { return }
        self.moving = moving
        restartLoops()
    }

    override func layoutLayers() {
        let circle = CGPath(ellipseIn: bounds, transform: nil)
        track.frame = bounds
        track.path = circle
        arc.frame = bounds
        arc.path = circle
    }

    override func restartLoops() {
        arc.removeAnimation(forKey: "turn")
        guard moving else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = CGFloat.pi * 2
        turn.duration = Self.lap
        arc.add(LayerLoop.repeating(turn, period: Self.lap), forKey: "turn")
    }
}

// The brand yellow sweeping along the bottom edge of a running command. With motion
// turned down it is a still line instead.
private struct RunSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Rectangle().fill(Theme.brand)
            } else {
                RunSweepLayer()
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

private struct RunSweepLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> RunSweepView { RunSweepView() }

    func updateNSView(_ view: RunSweepView, context: Context) {
        view.update(colour: Theme.brand.resolve(in: context.environment).cgColor)
    }
}

final class RunSweepView: LoopLayerView {
    static let lap: CFTimeInterval = 1.1
    static let barShare: CGFloat = 0.35

    private let bar = CALayer()
    private var sweptWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        layer?.addSublayer(bar)
    }

    var loops: [String] { bar.animationKeys() ?? [] }

    func update(colour: CGColor) {
        LayerLoop.still { bar.backgroundColor = colour }
    }

    // The bar starts just off the left edge and the sweep carries it just past the right,
    // so how far it travels depends on the width, and a new width needs a new sweep.
    override func layoutLayers() {
        let width = bounds.width * Self.barShare
        bar.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
        guard bounds.width != sweptWidth else { return }
        sweptWidth = bounds.width
        restartLoops()
    }

    override func restartLoops() {
        bar.removeAnimation(forKey: "sweep")
        guard sweptWidth > 0 else { return }
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = 0
        sweep.toValue = sweptWidth * (1 + Self.barShare)
        sweep.duration = Self.lap
        // Quick out of the gate, then a long gentle finish.
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
        bar.add(LayerLoop.repeating(sweep, period: Self.lap), forKey: "sweep")
    }
}

// MARK: - A card

private struct CommandCard: View {
    enum Detail {
        case plain(String)
        case command(String)
        case outcome(CommandRunSummary)
    }

    enum Grip { case none, on, dimmed }

    // A command or a prompt wears its kind's tile; nil draws the plain glyph of a row
    // that is not a saved shortcut.
    let kind: ShortcutKind?
    let icon: String
    let name: String
    let detail: Detail
    let tint: Theme.ProjectTint?
    let dashed: Bool
    let highlighted: Bool
    var verb: String? = nil
    // The first shortcut, the one on the button, carries a rail on its leading edge.
    var lead = false
    var grip: Grip = .none
    var position: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                if grip != .none {
                    Image(systemName: "line.3.horizontal")
                        .font(Typography.micro)
                        .foregroundStyle(grip == .on && hovering ? AnyShapeStyle(Theme.accent)
                                                                  : AnyShapeStyle(.tertiary))
                        .opacity(grip == .dimmed ? 0.4 : 1)
                        .accessibilityHidden(true)
                }
                tile
                    .overlay(alignment: .topTrailing) {
                        if let tint { ProjectDot(tint: tint, size: 6).padding(Space.xxs) }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(Typography.body.weight(.semibold))
                    detailLine
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let verb {
                    Text(verb)
                        .font(Font.system(size: Typography.Size.micro, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, Space.xxs)
                        .cardSurface(cornerRadius: Radius.tag)
                        .fixedSize()
                }
            }
            .padding(.leading, grip == .none ? Space.md : Space.sm)
            .padding(.trailing, Space.lg)
            .padding(.vertical, Space.md)
            .background(fill)
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
            .overlay(RoundedRectangle(cornerRadius: Radius.floating)
                .strokeBorder(stroke,
                              style: StrokeStyle(lineWidth: highlighted ? 1.5 : 1,
                                                 dash: dashed && !highlighted ? [4, 3] : [])))
            // Only a hairline: the tray under the cards does the lifting.
            .elevation(dashed ? .none : .raised)
            .contentShape(RoundedRectangle(cornerRadius: Radius.floating))
        }
        .buttonStyle(.plain)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.control, value: lead)
        .accessibilityLabel(verb.map { "\($0) \(name)" } ?? name)
        .accessibilityValue([accessibilityDetail, position].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    @ViewBuilder private var tile: some View {
        if let kind {
            KindTile(kind: kind, icon: icon, side: ControlHeight.lg)
        } else {
            Image(systemName: icon)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: ControlHeight.lg, height: ControlHeight.lg)
        }
    }

    // Every fill is solid. `field` is see-through, so it is only ever laid over a card,
    // never used on its own. A dashed row stays clear until touched, because the tray
    // under it is already opaque.
    private var fill: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.floating)
        return ZStack {
            shape.fill(dashed && !hovering && !highlighted ? Color.clear : Theme.card)
            if hovering && !dashed {
                shape.fill(Theme.field.opacity(0.6))
            }
        }
    }

    private var stroke: Color {
        if highlighted { return Theme.accent }
        return dashed ? Self.dashedBorder : Theme.border
    }

    // Strong enough for the dashes to read on the tray's sidebar fill.
    private static let dashedBorder = Theme.adaptive(
        light: NSColor(srgbRed: 0.46, green: 0.42, blue: 0.34, alpha: 0.28),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))

    @ViewBuilder private var detailLine: some View {
        switch detail {
        case .plain(let text):
            Text(text)
                .font(Typography.detail)
                .foregroundStyle(.secondary)
        case .command(let text):
            Text(text)
                .font(Typography.data)
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
        case .outcome(let summary):
            // The state is in the glyph and the words as well as the colour, so it reads
            // the same to someone who cannot tell the colours apart.
            HStack(spacing: Space.xs) {
                if let glyph = summary.glyph {
                    Image(systemName: glyph)
                        .font(.system(size: 8.5, weight: .bold))
                }
                RollingText(summary.text, font: Typography.detail)
            }
            .foregroundStyle(colour(of: summary.outcome))
        }
    }

    private func colour(of outcome: CommandRunSummary.Outcome) -> Color {
        switch outcome {
        case .passed: Theme.addition
        case .failed: Theme.deletion
        case .running: Theme.dotOnText
        case .never, .stopped: .secondary
        }
    }

    private var accessibilityDetail: String {
        switch detail {
        case .plain(let text): text
        case .command(let text): text
        case .outcome(let summary): summary.text
        }
    }
}

// A key a shortcut is pressed with, drawn as a small cap.
private struct KeyHint: View {
    let keys: String
    var onFill = false

    init(_ keys: String, onFill: Bool = false) {
        self.keys = keys
        self.onFill = onFill
    }

    var body: some View {
        Text(keys)
            .font(Typography.caption.weight(.medium))
            .foregroundStyle(onFill ? AnyShapeStyle(Theme.onFill) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Space.xs)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: Radius.inset)
                .fill(onFill ? Theme.onFill.opacity(0.16) : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: Radius.inset)
                .stroke(onFill ? Color.clear : Theme.border))
            .accessibilityHidden(true)
    }
}

// MARK: - How a run went

// One command's last run, in the words its card shows: "Passed 12 min ago in 38s",
// "Failed just now in 4.2s", "Never run".
struct CommandRunSummary: Equatable {
    enum Outcome { case never, running, passed, failed, stopped }

    let state: ShortcutStore.State
    let duration: TimeInterval?
    let started: Bool
    var now = Date()

    var outcome: Outcome {
        switch state {
        case .running: .running
        case .finished: .passed
        case .failed: .failed
        case .stopped: started ? .stopped : .never
        }
    }

    var text: String {
        switch state {
        case .running: return "Running now"
        case .stopped: return started ? "Stopped" : "Never run"
        case .finished(let at): return sentence("Passed", at: at)
        case .failed(_, _, let at): return sentence("Failed", at: at)
        }
    }

    var glyph: String? {
        switch outcome {
        case .passed: "checkmark"
        case .failed: "xmark"
        case .running: "circle.fill"
        case .stopped: "stop.fill"
        case .never: nil
        }
    }

    private func sentence(_ verb: String, at: Date) -> String {
        let when = Self.ago(now.timeIntervalSince(at))
        guard let duration else { return "\(verb) \(when)" }
        return "\(verb) \(when) in \(Self.length(duration))"
    }

    // "just now", "12 min ago", "3 h ago", "2 d ago".
    static func ago(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }

    // "4.2s", "38s", "1m 12s", "1h 5m": tenths only while they still matter.
    static func length(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return "\(Int(seconds))s" }
        let whole = Int(seconds)
        if whole < 3_600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3_600)h \(whole % 3_600 / 60)m"
    }

    // The clock on a running button: "4.2s" for the first minute, then "1:12".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds)
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

// MARK: - Keys and clicks while the list is open

// Catches the keys the open list answers, and the click that lands anywhere else. A
// local monitor sees them before the prompt field does, which is what lets the arrows
// move through the list while the cursor is still in the prompt.
@MainActor
final class CommandListMonitor {
    enum Key { case up, down, moveUp, moveDown, choose, close }

    private var token: Any?

    func start(anchor: FrameAnchor, regions: [FrameAnchor],
               key: @escaping (Key) -> Void, outside: @escaping () -> Void) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let window = anchor.view?.window, event.window === window else { return false }
                if event.type == .leftMouseDown {
                    guard let content = window.contentView else { return false }
                    if !Self.lands(event.locationInWindow, in: content, on: regions.compactMap { $0.frame() }) {
                        outside()
                    }
                    return false
                }
                guard WindowKeyMonitor.routes(to: window, frontmost: NSApp.keyWindow),
                      let pressed = Self.key(for: event.keyCode, modifiers: event.modifierFlags)
                else { return false }
                key(pressed)
                return true
            }
            return consumed ? nil : event
        }
    }

    // A window point counts from the bottom. Converting it into the content view first
    // lets fromTop flip it only when that view is not already flipped, which the SwiftUI
    // hosting view is.
    static func lands(_ windowPoint: CGPoint, in content: NSView, on regions: [CGRect]) -> Bool {
        let point = FrameAnchor.fromTop(content.convert(windowPoint, from: nil), in: content)
        return regions.contains { $0.contains(point) }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    // Option with an arrow sorts. Any other held key leaves the press to the window, so
    // Command-Up and the rest keep their usual meaning.
    static func key(for code: UInt16, modifiers: NSEvent.ModifierFlags) -> Key? {
        let held = modifiers.intersection([.command, .option, .control])
        if held == .option {
            switch code {
            case 126: return .moveUp
            case 125: return .moveDown
            default: return nil
            }
        }
        guard held.isEmpty else { return nil }
        switch code {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .choose
        case 53: return .close
        default: return nil
        }
    }
}

// MARK: - Output

// Where a chip's run went, docked under the content the way the terminal is. It is a
// captured log rather than a shell: the point of a shortcut is that it reports how it
// ended, which a live terminal cannot be asked.
struct ShortcutOutputDrawer: View {
    @Environment(ShortcutStore.self) private var shortcuts

    let run: ShortcutRun
    let onClose: () -> Void

    private static let bottom = "shortcut-drawer-bottom"

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            strip
            Divider().overlay(Theme.hairline)
            ScrollViewReader { scroller in
                ScrollView {
                    Text(text)
                        .font(Typography.data)
                        .foregroundStyle(log.isEmpty ? AnyShapeStyle(.secondary)
                                                     : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.lg)
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .onChange(of: log) { _, _ in
                    scroller.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            .frame(height: 240)
        }
        .background(Theme.card)
        .interruptOnStopKey(isEnabled: shortcuts.state(run).isActive) {
            shortcuts.stop(run)
        }
    }

    private var strip: some View {
        HStack(spacing: Space.md) {
            Text("OUTPUT")
                .font(Typography.data.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            if let name = shortcuts.shortcut(run.shortcutID)?.name {
                Text(name)
                    .font(Typography.label)
                    .lineLimit(1)
            }
            Text(status)
                .font(Typography.data)
                .foregroundStyle(statusColour)
                .lineLimit(1)

            Spacer(minLength: 12)

            // Kept in the row whether or not anything is running, so the way to stop a
            // command is always in the same place. The chip that opens this panel no
            // longer stops anything, and a control that comes and goes is one the reader
            // has to find again every time they need it.
            let running = shortcuts.state(run).isActive
            stripButton("Stop", tint: Theme.deletion, enabled: running) {
                shortcuts.stop(run)
            }
            .appTooltip(running ? "Stop this command (^C)" : "Nothing is running")

            if !log.isEmpty {
                stripButton("Clear", tint: Theme.accent) { shortcuts.clearLog(run) }
            }

            // Named for what it does, since the row beside it stops the command and the
            // two must not read as the same thing: this only puts the panel away, and
            // whatever is running carries on.
            stripButton("Close output", tint: Theme.deletion, action: onClose)
                .appTooltip("Hide this panel. Anything running keeps running.")
                .accessibilityLabel("Hide the output")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(Theme.card)
    }

    private func stripButton(_ title: String, tint: Color, enabled: Bool = true,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xs)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.field))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .hoverLift()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private var log: String { shortcuts.log(run) }

    private var text: String {
        if !log.isEmpty { return log }
        switch shortcuts.state(run) {
        case .stopped: return "Run this shortcut to see its output."
        case .running: return "Waiting for output…"
        case .finished: return "Finished without output."
        case .failed(let message, _, _): return message
        }
    }

    private var status: String {
        switch shortcuts.state(run) {
        case .stopped: "not running"
        case .running(let since): "running · \(RelativeTime.duration(since: since))"
        case .finished: "exit 0"
        case .failed(_, let code, _): code.map { "exit \($0)" } ?? "failed"
        }
    }

    private var statusColour: Color {
        switch shortcuts.state(run) {
        case .failed: Theme.deletion
        case .finished: Theme.addition
        default: .secondary
        }
    }
}

// The stroke that ends a running command, wherever the reader's hands happen to be.
// The pane prints a command the way a shell does, so ^C is what anyone watching it
// reaches for, and there is no text field in it to type that into. A monitor is what
// catches it: the drawer never holds the keyboard, since the composer beside it does.
private struct InterruptCatcher: ViewModifier {
    let isEnabled: Bool
    let interrupt: () -> Void

    @State private var monitor = WindowKeyMonitor(AppCommand.stopCommand.info.keys)

    func body(content: Content) -> some View {
        content
            .background(WindowAnchor(monitor: monitor).keyMonitor(monitor, follows: .stopCommand))
            .onChange(of: isEnabled, initial: true) { _, enabled in
                guard enabled else { return monitor.stop() }
                monitor.start {
                    interrupt()
                    return true
                }
            }
            .onDisappear { monitor.stop() }
    }
}

extension View {
    func interruptOnStopKey(isEnabled: Bool,
                             interrupt: @escaping () -> Void) -> some View {
        modifier(InterruptCatcher(isEnabled: isEnabled, interrupt: interrupt))
    }
}

// MARK: - Promoting what the agent ran

enum SessionShortcuts {
    // The last shell command the agent ran in this session, for the menu entry that
    // turns it into a saved shortcut. Only single-line commands are offered: a saved
    // command names one thing, and a heredoc pasted into one is not that.
    static func lastAgentCommand(in session: ChatSession) -> String? {
        for message in session.messages.reversed() where message.role == .assistant {
            for tool in message.tools.reversed() where tool.name == "Bash" {
                guard let command = ToolPresentation.shellCommand(in: tool.input)?.trimmed,
                      !command.isEmpty, !command.contains("\n") else { continue }
                return command
            }
        }
        return nil
    }
}
