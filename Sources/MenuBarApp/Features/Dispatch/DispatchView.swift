import SwiftUI

// A small HTTP client for the services a session is working on: the saved requests on
// the left, the one being edited and its answer on the right. Every configured environment
// shares one request list; the active one picks the credentials, the {{env}} value and the
// colour of the chrome, and the Send button names it, so where a send lands is read at
// the moment of sending.
struct DispatchView: View {
    @Environment(DispatchStore.self) private var store
    @Environment(DispatchAuthStore.self) private var auth
    @Environment(DispatchRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(MenuPresenter.self) private var menus
    @Environment(\.keyBindings) private var keyBindings
    @State private var query = ""
    @State private var searchClosedFolders: Set<UUID> = []
    @State private var showingLibrary = false
    @FocusState private var searchFocused: Bool

    @State private var showingEnvironments = false
    @State private var renamingFolderID: UUID?
    @State private var renamingRequestID: UUID?
    @State private var dropSlot: RequestDropSlot?
    @State private var rowHeights: [UUID: CGFloat] = [:]
    @State private var expanded = false
    // The sheet only learns its parent a moment after it opens, so start from the window
    // that is key while the sheet is being built. Without this the first frame uses a
    // fallback size and the sheet visibly jumps once the real size arrives.
    @State private var parentSize: CGSize?

    init(parentSize: CGSize? = NSApp.keyWindow?.contentLayoutRect.size) {
        _parentSize = State(initialValue: parentSize)
    }

    private var environment: ApiEnvironment { auth.active }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                if !compact || showingLibrary {
                    sidebar
                        .transition(.drawer(from: .leading, reduceMotion: reduceMotion))
                    Divider().overlay(Theme.hairline)
                }
                if !compact || !showingLibrary {
                    detail.motion(Motion.reveal, value: store.selectedID)
                }

            }
            SheetFooter(dismissTone: .outlined, dismiss: close) { footnote }
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .background(Theme.background)
        .background(ParentWindowSize(size: $parentSize))
        .sheet(isPresented: $showingEnvironments) {
            EnvironmentsView(previewRequest: store.selected).appOverlays()
        }
        .onDisappear { store.save() }
        .onChange(of: query) { _, _ in searchClosedFolders = [] }
        .motion(Motion.reveal, value: environment)
        .background {
            ZStack {
                Button("", action: focusSearch).appShortcut(.findRequest)
                Button("", action: focusSearch).keyboardShortcut("k", modifiers: .control)
            }
            .buttonStyle(.plain).opacity(0).accessibilityHidden(true)
        }
    }

    // Escape and Done put away whatever is on top first: a dialog, a menu, a send under
    // way, and only then the sheet.
    private func close() {
        if dialogs.current != nil { dialogs.dismiss() }
        else if menus.isOpen { menus.dismiss() }
        else if let id = store.selectedID, runner.isRunning(id, in: environment) { runner.cancel(id, in: environment) }
        else { dismiss() }
    }

    private var footnote: some View {
        HStack(spacing: Space.xl) {
            if let problem = store.saveError ?? store.loadError {
                Text(problem).foregroundStyle(Theme.warningText)
            } else {
                HStack(spacing: Space.sm) {
                    Image(systemName: "checkmark")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.addition)
                        .scaleEffect(store.hasPendingChanges ? 0.4 : 1)
                        .opacity(store.hasPendingChanges ? 0 : 1)
                        .accessibilityHidden(true)
                    Text(store.hasPendingChanges ? "Saving…" : "Saved on this Mac")
                        .contentTransition(.opacity)
                }
                .motion(Motion.pop, value: store.hasPendingChanges)
                if environment.isDangerous {
                    Text("Every send to \(environment.label) asks first.")
                        .font(Typography.caption.weight(.medium))
                        .foregroundStyle(Theme.warningText)
                        .transition(.fadeIn)
                } else if !compact {
                    HStack(spacing: Space.sm) {
                        Keycap("⌘↵")
                        Text("Send")
                        if let findKeys = keyBindings.keys(for: .findRequest) {
                            Keycap(findKeys.compactLabel).padding(.leading, Space.md)
                            Text("Find a request")
                        }
                    }
                    .transition(.fadeIn)
                }
            }
        }
        .font(Typography.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func focusSearch() {
        guard dialogs.current == nil, !showingEnvironments else { return }
        menus.dismiss()
        showingLibrary = true
        searchFocused = true
    }

    // A sheet wider than its window gets clipped rather than growing it, so both sizes
    // follow the window the sheet hangs off, leaving a margin so it still reads as a sheet.
    private var sheetSize: CGSize {
        let compact = DispatchMetrics.sheet
        guard let parentSize else { return CGSize(width: 940, height: 660) }
        let room = CGSize(width: parentSize.width - 48, height: parentSize.height - 36)
        if expanded { return room }
        return CGSize(width: max(480, min(compact.width, room.width)),
                      height: max(420, min(compact.height, room.height)))
    }

    private var compact: Bool { sheetSize.width < 900 }

    // One click per environment while they fit on the band. Past four, or in the narrow
    // layout, the track would crowd out the title, so the dropdown takes its place.
    private var tracksEnvironments: Bool { !compact && auth.environments.count <= 4 }

    private var header: some View {
        HStack(spacing: Space.md) {
            if compact {
                GlyphButton(icon: "sidebar.left", active: showingLibrary) { showingLibrary.toggle() }
                    .accessibilityLabel(showingLibrary ? "Show request" : "Show request library")
            }
            SheetTitle(name: "Dispatch", icon: "paperplane", tint: environment.accent,
                       font: Typography.display) {
                if tracksEnvironments {
                    Text("Send to").font(Typography.caption).foregroundStyle(.secondary)
                    EnvironmentPills(environments: auth.environments, selected: environment) {
                        auth.active = $0
                    }
                } else {
                    environmentMenu
                }
                GlyphButton(icon: "slider.horizontal.3") { showingEnvironments = true }
                    .accessibilityLabel("Environment settings")
                    .appTooltip("Environment properties and sign-in")
                GlyphButton(icon: expanded ? "arrow.down.right.and.arrow.up.left"
                                           : "arrow.up.left.and.arrow.down.right") { expanded.toggle() }
                    .appTooltip(expanded ? "Shrink" : "Expand to the window")
                    .accessibilityLabel(expanded ? "Shrink" : "Expand to the window")
            }
        }
        .padding(.horizontal, compact ? Space.lg : Space.pane)
        .headerBand(environment.isDangerous ? Theme.warningBackground : Theme.card)
    }

    private var environmentMenu: some View {
        HStack(spacing: Space.md) {
            Circle().fill(environment.brightAccent).frame(width: DispatchMetrics.dot, height: DispatchMetrics.dot)
            Text(environment.label + (environment.isDangerous ? " · Live" : ""))
                .font(Typography.label)
            MenuChevron(tint: environment.accent)
        }
        .foregroundStyle(environment.accent)
        .padding(.horizontal, Space.lg).frame(height: ControlHeight.md)
        .surface(environment.accent.opacity(0.07), cornerRadius: Radius.control,
                 border: environment.accent.opacity(0.25))
        .hoverLift()
        .appMenu {
            auth.environments.map { env in
                .item(env.label, checked: env == environment) { auth.active = env }
            } + [.separator, .item("Environment settings") { showingEnvironments = true }]
        }
        .accessibilityLabel("Send destination: \(environment.label)")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a request", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityLabel("Find a request by name, method or address")
                    if !query.isEmpty {
                        GlyphButton(icon: "xmark", side: ControlHeight.xs) { query = "" }
                            .accessibilityLabel("Clear search")
                    } else if let findKeys = keyBindings.keys(for: .findRequest) {
                        Text(findKeys.compactLabel).font(Typography.caps).foregroundStyle(.tertiary)
                    }
                }
                .font(Typography.detail)
                .padding(.horizontal, Space.md).frame(height: ControlHeight.lg)
                .surface(searchFocused ? Theme.card : Theme.field, cornerRadius: Radius.control,
                         border: searchFocused ? environment.accent : .clear)
                .motion(Motion.hover, value: searchFocused)
                GlyphButton(icon: "plus", side: ControlHeight.lg)
                    .appMenu {
                        [.item("New request", subtitle: "Starts in Default") { createRequest() },
                         .item("New folder", subtitle: "Groups related requests") {
                             renamingFolderID = store.addFolder().id
                         }]
                    }
                    .accessibilityLabel("New request or folder")
                    .appTooltip("New request or folder")
            }
            .padding(.horizontal, Space.lg).padding(.top, Space.lg).padding(.bottom, Space.md)

            ScrollView {
                VStack(spacing: Space.xs) {
                    ForEach(store.folders) { folder in
                        if query.trimmed.isEmpty || !store.visibleRequests(in: folder.id, matching: query).isEmpty {
                            folderSection(folder)
                        }
                    }
                    if !query.trimmed.isEmpty && store.folders.allSatisfy({ store.visibleRequests(in: $0.id, matching: query).isEmpty }) {
                        VStack(spacing: Space.md) {
                            Text("No requests match “\(query)”.").foregroundStyle(.secondary)
                            InlineLink(title: "Clear search") { query = "" }
                        }.font(Typography.detail).padding(.vertical, Space.xxl)
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.md)
            }

        }
        .frame(width: compact ? nil : DispatchMetrics.libraryWidth)
        .background(Theme.sidebar)
    }

    private func folderSection(_ folder: RequestFolder) -> some View {
        let searching = !query.trimmed.isEmpty
        let expanded = searching ? !searchClosedFolders.contains(folder.id) : store.isExpanded(folder.id)
        let requests = store.visibleRequests(in: folder.id, matching: query)
        return VStack(alignment: .leading, spacing: 0) {
            FolderRow(folder: folder,
                      expanded: expanded,
                      requestCount: requests.count,
                      isRenaming: renamingFolderID == folder.id,
                      accent: environment.accent,
                      onNewRequest: { createRequest(in: folder.id) },
                      onToggle: { toggleFolder(folder.id) },
                      onDropRequest: { store.move($0, to: folder.id) },
                      onRename: { name in
                          store.renameFolder(folder.id, to: name)
                          renamingFolderID = nil
                      },
                      onCancelRename: { renamingFolderID = nil })
                .appContextMenu {
                    folderContextMenu(for: folder)
                }

            if !requests.isEmpty {
                VStack(spacing: Space.xxs) {
                    ForEach(Array(requests.enumerated()), id: \.element.id) { index, request in
                        requestRow(request)
                            .opacity(expanded ? 1 : 0)
                            .offset(y: reduceMotion || expanded ? 0 : -3)
                            .animation(reduceMotion ? nil : Motion.reveal.delay(expanded ? Motion.stagger * Double(min(index, 4)) : 0), // design-rules: allow, each row needs its own delay
                                       value: expanded)
                    }
                }
                .frame(height: expanded ? nil : 0, alignment: .top)
                .opacity(expanded ? 1 : 0)
                .clipped()
                .disabled(!expanded)
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)
            }
        }
        .motion(Motion.control, value: expanded)
        .motion(Motion.control, value: requests.map(\.id))
    }

    private func toggleFolder(_ id: UUID) {
        if query.trimmed.isEmpty { store.toggleFolder(id) }
        else if !searchClosedFolders.insert(id).inserted { searchClosedFolders.remove(id) }
    }

    private func createRequest(in folder: UUID? = nil) {
        query = ""
        let request = store.add(to: folder)
        renamingRequestID = request.id
        showingLibrary = true
    }

    private func requestRow(_ request: SavedRequest) -> some View {
        RequestRow(request: request,
                   selected: request.id == store.selectedID,
                   answer: answer(for: request),
                   isRenaming: renamingRequestID == request.id,
                   accent: environment.accent,
                   onSelect: {
                       store.selectedID = request.id
                       showingLibrary = false
                   },
                   onRename: { name in
                       store.rename(request.id, to: name)
                       renamingRequestID = nil
                   },
                   onCancelRename: { renamingRequestID = nil })
            .contentShape(Rectangle())
            // Alongside the single tap rather than instead of it, so selecting a row
            // does not wait to see whether a second click is coming.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                renamingRequestID = request.id
            })
            .appContextMenu { requestContextMenu(for: request) }
            .draggable(request.id.uuidString)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                rowHeights[request.id] = $0
            }
            .onDrop(of: [.plainText], delegate: RequestDropDelegate(
                targetID: request.id,
                rowHeight: rowHeights[request.id] ?? 0,
                slot: $dropSlot,
                onDrop: { store.move($0, beside: request.id, after: $1) }))
            // A drag that is cancelled, or let go where nothing takes it, never tells the
            // row it left, so the line would stay. Hover never fires while a drag is under
            // way, so the first hover after one ends is a safe time to clear it.
            .onHover { _ in
                if dropSlot != nil { dropSlot = nil }
            }
            .overlay(alignment: dropSlot?.after == true ? .bottom : .top) {
                if dropSlot?.targetID == request.id {
                    // Drawn in the gap between rows, so the line sits where the
                    // request will land rather than over a neighbour.
                    Capsule()
                        .fill(environment.accent)
                        .frame(height: 2)
                        .offset(y: dropSlot?.after == true ? 3.5 : -3.5)
                        .allowsHitTesting(false)
                }
            }
    }

    // The last answer this request got in the environment on show. A send that was
    // called off got no answer, so it leaves no mark.
    private func answer(for request: SavedRequest) -> HTTPResult? {
        guard let result = runner.result(request.id, in: environment), !result.wasCancelled else { return nil }
        return result
    }

    private func folderContextMenu(for folder: RequestFolder) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("New request") { createRequest(in: folder.id) }
        ]
        guard !folder.isDefault else { return entries }
        entries.append(.item("Rename…") { renamingFolderID = folder.id })
        entries.append(.separator)
        entries.append(.item("Delete folder", kind: .destructive) {
            dialogs.show(deleteFolderDialog(for: folder, store: store))
        })
        return entries
    }

    private func requestContextMenu(for request: SavedRequest) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .item(request.isPinned ? "Unpin request" : "Pin to top of folder") { store.togglePin(request.id) },
            .item("Rename…") {
                store.selectedID = request.id
                renamingRequestID = request.id
            },
            .item("Duplicate") {
                if let copy = store.duplicate(request.id) {
                    auth.copyBasicPassword(from: request.id, to: copy)
                }
            },
            .separator
        ]
        entries.append(contentsOf: store.folders.map { folder in
            .item("Move to \(folder.name)", checked: request.folderID == folder.id) {
                store.move(request.id, to: folder.id)
            }
        })
        entries.append(.separator)
        entries.append(.item("Delete", kind: .destructive) {
            dialogs.show(deleteDialog(for: request, store: store, auth: auth))
        })
        return entries
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let request = store.selected {
            // Keyed on the request so switching in the sidebar starts the editor over
            // on the new one rather than keeping the last one's draft.
            RequestDetail(request: request, openEnvironments: { showingEnvironments = true }, close: close)
                .id(request.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(x: Space.md)),
                                        removal: .identity))
        } else {
            PaneMessage(icon: "paperplane", title: "Select a request or create a new one",
                        detail: "Saved requests are on the left. The plus beside the search adds one.")
        }
    }
}

// The same question whether the delete starts from the sidebar or from the editor.
@MainActor
func deleteDialog(for request: SavedRequest, store: DispatchStore,
                          auth: DispatchAuthStore) -> Dialog {
    Dialog.impact("Delete \"\(request.name.isEmpty ? "Untitled" : request.name)\"?",
                  rows: [.init(title: "Request",
                               detail: "The address, headers, body and sign-in set up on it are deleted."),
                         .init(title: "Other requests and environment sign-ins", detail: "Kept in every environment.", kept: true)],
                  warning: "The request cannot be restored.",
                  action: "Delete request") {
        store.remove(request.id)
        auth.forgetBasicPassword(for: request.id)
    }
}

@MainActor
private func deleteFolderDialog(for folder: RequestFolder, store: DispatchStore) -> Dialog {
    let count = store.requestCount(in: folder.id)
    var rows = [Dialog.Impact.Row(title: count == 0 ? "Empty folder" : "Folder", detail: "Deleted for good.")]
    if count > 0 {
        rows.append(.init(title: "\(counted(count, "request")) \(count == 1 ? "stays" : "stay")",
                          detail: "Moved to Default.", kept: true))
    }
    return Dialog.impact("Delete \"\(folder.name)\"?", rows: rows, action: "Delete folder") {
        store.removeFolder(folder.id)
    }
}

private struct FolderRow: View {
    let folder: RequestFolder
    let expanded: Bool
    let requestCount: Int
    let isRenaming: Bool
    let accent: Color
    let onNewRequest: () -> Void
    let onToggle: () -> Void
    let onDropRequest: (UUID) -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var draftName = ""
    @State private var hovering = false
    @State private var isDropTarget = false
    @FocusState private var nameFocused: Bool
    @FocusState private var rowFocused: Bool

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)

            if isRenaming {
                TextField("Folder name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(Typography.body.weight(.semibold))
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                    .fieldSurface(cornerRadius: Radius.inset)
                    .focused($nameFocused)
                    .onSubmit { onRename(draftName) }
                    .onExitCommand(perform: onCancelRename)
            } else {
                Text(folder.name)
                    .font(Typography.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Group {
                if hovering && !isRenaming {
                    Button(action: onNewRequest) {
                        Text("+ Request")
                            .font(Typography.micro)
                            .foregroundStyle(accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Capsule().fill(accent.opacity(0.12)))
                            .contentShape(Rectangle())
                            .hoverLift()
                    }
                    .buttonStyle(.plain)
                    .appTooltip("New request in \(folder.name)")
                    .transition(.fadeIn)
                } else {
                    Text("\(requestCount)")
                        .font(Font.mono(Typography.Size.micro))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.fadeIn)
                }
            }
            .frame(width: 62, height: 20)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, isRenaming ? 5 : 8)
        .background(RoundedRectangle(cornerRadius: Radius.control)
            .fill(isDropTarget ? accent.opacity(0.12) : (hovering ? Theme.field : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: Radius.control)
            .stroke(isDropTarget ? accent.opacity(0.65) : (hovering ? accent.opacity(0.18) : .clear),
                    lineWidth: isDropTarget ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { onToggle() } }
        .focusable(!isRenaming).focused($rowFocused).focusEffectDisabled()
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(rowFocused ? accent : .clear, lineWidth: 2))
        .onKeyPress(keys: [.space, .return]) { _ in onToggle(); return .handled }
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityLabel("\(folder.name), \(requestCount) requests")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
        .motion(Motion.control, value: expanded)
        .motion(Motion.hover, value: hovering)
        .onPointerHover { hovering = $0 }
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let requestID = UUID(uuidString: value) else {
                return false
            }
            onDropRequest(requestID)
            return true
        } isTargeted: {
            isDropTarget = $0
        }
        .onAppear { prepareRename() }
        .onChange(of: isRenaming) { _, _ in prepareRename() }
    }

    private func prepareRename() {
        guard isRenaming else { return }
        draftName = folder.name
        nameFocused = true
    }
}

private struct RequestDropSlot: Equatable {
    let targetID: UUID
    let after: Bool
}

// Dropping on the top half of a row puts the request before it, the bottom half after.
private struct RequestDropDelegate: DropDelegate {
    let targetID: UUID
    let rowHeight: CGFloat
    @Binding var slot: RequestDropSlot?
    let onDrop: (UUID, Bool) -> Void

    private func after(_ info: DropInfo) -> Bool {
        info.location.y > rowHeight / 2
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        slot = RequestDropSlot(targetID: targetID, after: after(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = RequestDropSlot(targetID: targetID, after: after(info))
        if slot != next { slot = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if slot?.targetID == targetID { slot = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let placeAfter = after(info)
        slot = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadTransferable(type: String.self) { result in
            guard case .success(let value) = result,
                  let requestID = UUID(uuidString: value) else { return }
            Task { @MainActor in onDrop(requestID, placeAfter) }
        }
        return true
    }
}

private struct RequestRow: View {
    let request: SavedRequest
    let selected: Bool
    // The last answer in the environment on show, as a dot in its status colour.
    let answer: HTTPResult?
    let isRenaming: Bool
    let accent: Color
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @State private var draftName = ""
    @State private var cancelled = false
    @FocusState private var nameFocused: Bool
    @FocusState private var rowFocused: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            MethodTag(method: request.method)
            if isRenaming {
                TextField("Request name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(Typography.body.weight(.semibold))
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                    .fieldSurface(cornerRadius: Radius.inset)
                    .focused($nameFocused)
                    .onSubmit { onRename(draftName) }
                    .onExitCommand {
                        cancelled = true
                        onCancelRename()
                    }
            } else {
                Text(request.name.isEmpty ? "Untitled" : request.name)
                    .font(Typography.detail.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if request.isPinned {
                Image(systemName: "star.fill").font(Font.system(size: Typography.Size.micro)).foregroundStyle(accent)
                    .accessibilityLabel("Pinned")
            }
            Circle()
                .fill(answer?.tint ?? .clear)
                .frame(width: DispatchMetrics.dot, height: DispatchMetrics.dot)
                .scaleEffect(answer == nil ? 0.4 : 1)
                .opacity(answer == nil ? 0 : 1)
                .motion(Motion.pop, value: answer == nil)
                .accessibilityHidden(true)
        }
        // Lines the method up with the folder icon above: the folder row's padding,
        // chevron and gap add up to this step.
        .padding(.leading, Space.xxxl)
        .padding(.trailing, Space.md)
        .padding(.vertical, isRenaming ? 4 : 8)
        .surface(selected ? accent.opacity(0.10) : (hovering ? Theme.field : .clear), cornerRadius: Radius.control,
                 border: .clear)
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(accent).frame(width: 3, height: 17).accessibilityHidden(true) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { onSelect() } }
        .focusable(isEnabled && !isRenaming).focused($rowFocused).focusEffectDisabled()
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(rowFocused ? accent : .clear, lineWidth: 2))
        .onKeyPress(keys: [.space, .return]) { _ in
            guard isEnabled else { return .ignored }
            onSelect()
            return .handled
        }
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityValue(answer.map { "Last answer: \($0.statusText)" } ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { onSelect() }
        .motion(Motion.control, value: selected)
        .motion(Motion.hover, value: hovering)
        .onPointerHover { hovering = $0 }
        .onAppear { prepareRename() }
        .onChange(of: isRenaming) { _, _ in prepareRename() }
        // Clicking away keeps the new name, the way Finder does. Escape is the only
        // way to throw it away.
        .onChange(of: nameFocused) { _, focused in
            guard !focused, isRenaming, !cancelled else { return }
            onRename(draftName)
        }
    }

    private func prepareRename() {
        guard isRenaming else { return }
        draftName = request.name
        cancelled = false
        nameFocused = true
    }
}

private struct MethodTag: View {
    let method: HTTPMethod

    var body: some View {
        Text(method.rawValue)
            .font(Typography.caps)
            .foregroundStyle(method.tint)
            .frame(width: 34, alignment: .leading)
    }
}

