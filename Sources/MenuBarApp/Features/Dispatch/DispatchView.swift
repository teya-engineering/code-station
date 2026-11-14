import SwiftUI

// A small HTTP client for the services a session is working on: the saved requests on
// the left, the one being edited and its answer on the right. Every configured environment
// shares one request list; the active one picks the credentials, the {{env}} value and the
// colour of the chrome, so where a send lands is legible at a glance.
struct DispatchView: View {
    @Environment(DispatchStore.self) private var store
    @Environment(DispatchAuthStore.self) private var auth
    @Environment(DispatchRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(MenuPresenter.self) private var menus
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
            Rectangle().fill(environment.brightAccent).frame(height: 5)
            header
            Divider().overlay(Theme.hairline)
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
            SheetFooter(dismiss: {
                if dialogs.current != nil { dialogs.dismiss() }
                else if menus.isOpen { menus.dismiss() }
                else if let id = store.selectedID, runner.isRunning(id, in: environment) { runner.cancel(id, in: environment) }
                else { dismiss() }
            }) {
                Text(store.saveError ?? store.loadError
                     ?? (store.hasPendingChanges ? "Saving changes…" : environment.isDangerous
                         ? "Changes saved · Live sends always ask for confirmation."
                         : "Changes saved locally · ⌘↵ Send · ⌘K Find a request"))
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
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
                Button("", action: focusSearch).keyboardShortcut("k", modifiers: .command)
                Button("", action: focusSearch).keyboardShortcut("k", modifiers: .control)
            }
            .buttonStyle(.plain).opacity(0).accessibilityHidden(true)
        }
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
        let compact = CGSize(width: 1020, height: 720)
        guard let parentSize else { return CGSize(width: 940, height: 660) }
        let room = CGSize(width: parentSize.width - 48, height: parentSize.height - 36)
        if expanded { return room }
        return CGSize(width: max(480, min(compact.width, room.width)),
                      height: max(420, min(compact.height, room.height)))
    }

    private var compact: Bool { sheetSize.width < 900 }

    private var header: some View {
        HStack(spacing: Space.md) {
            if compact {
                GlyphButton(icon: "sidebar.left", active: showingLibrary) { showingLibrary.toggle() }
                    .accessibilityLabel(showingLibrary ? "Show request" : "Show request library")
            }
            Image(systemName: "paperplane")
                .foregroundStyle(environment.accent)
                .frame(width: 29, height: 29)
                .background(environment.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.control))
            Text("Dispatch").font(Typography.display)
            Spacer(minLength: 0)
            tokenStatus
            HStack(spacing: Space.md) {
                Circle().fill(environment.brightAccent).frame(width: 6, height: 6)
                Text(environment.label + (environment.isDangerous ? " · Live" : ""))
                    .font(Typography.label)
                MenuChevron(tint: environment.accent)
            }
            .foregroundStyle(environment.accent)
            .padding(.horizontal, Space.lg).frame(height: ControlHeight.lg)
            .surface(environment.accent.opacity(0.07), cornerRadius: Radius.control,
                     border: environment.accent.opacity(0.25))
            .hoverLift()
            .appMenu {
                auth.environments.map { env in
                    .item(env.label, checked: env == environment) { auth.active = env }
                } + [.separator, .item("Environment settings") { showingEnvironments = true }]
            }
            .accessibilityLabel("Send destination: \(environment.label)")
            GlyphButton(icon: "slider.horizontal.3", tint: environment.accent) {
                showingEnvironments = true
            }
            .accessibilityLabel("Environment settings")
            .appTooltip("Environment properties and authentication")
            GlyphButton(icon: expanded ? "arrow.down.right.and.arrow.up.left"
                                       : "arrow.up.left.and.arrow.down.right",
                        side: ControlHeight.sm, tint: environment.accent) { expanded.toggle() }
                .appTooltip(expanded ? "Shrink" : "Expand to the window")
                .accessibilityLabel(expanded ? "Shrink" : "Expand")
        }
        .padding(.horizontal, compact ? 12 : 20)
        .padding(.vertical, Space.md)
        .background(environment.isDangerous ? Theme.deletion.opacity(0.10) : Theme.card)
    }

    private var tokenStatus: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let authenticated = auth.isAuthenticated(for: environment)
            let busy = auth.busy.contains(environment) || auth.awaitingPaste.contains(environment)
            let status = busy ? "Signing in…" : auth.failures[environment] != nil ? "Sign-in failed"
                : authenticated ? "Token ready" : "Token needed"
            HStack(spacing: Space.sm) {
                Image(systemName: authenticated ? "checkmark.shield" : "shield")
                if !compact {
                    Text(status)
                    if authenticated, let token = auth.tokens[environment] {
                        Text("· \(token.remainingText)").font(Font.mono(Typography.Size.micro))
                    }
                }
            }
            .font(Typography.caption)
            .foregroundStyle(authenticated ? environment.accent : .secondary)
            .padding(Space.sm)
            .contentShape(Rectangle())
            .hoverLift()
            .appMenu {
                if busy {
                    [.item("Cancel authentication") { auth.cancelAuthentication(environment) }]
                } else {
                    [.item(auth.config(for: environment).missing.isEmpty ? "Re-authenticate" : "Set up credentials") {
                        if auth.config(for: environment).missing.isEmpty {
                            auth.authenticate(environment)
                            if auth.config(for: environment).grant.usesBrowser && !auth.config(for: environment).usesLoopback {
                                showingEnvironments = true
                            }
                        } else { showingEnvironments = true }
                    }, .item("Authentication settings") { showingEnvironments = true }]
                }
            }
            .accessibilityLabel("\(environment.label) authentication: \(status)")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Requests").font(Typography.body.weight(.semibold))
                Text("\(store.requests.count)").font(Font.mono(Typography.Size.micro)).foregroundStyle(.secondary)
                Spacer()
                GlyphButton(icon: "plus", side: ControlHeight.sm) { createRequest() }
                    .accessibilityLabel("New request")
            }
            .padding(.horizontal, Space.xl).padding(.top, Space.xl).padding(.bottom, Space.lg)

            HStack(spacing: Space.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a request", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Find a request by name, method or URL")
                if !query.isEmpty {
                    GlyphButton(icon: "xmark", side: ControlHeight.xs) { query = "" }
                        .accessibilityLabel("Clear search")
                } else { Text("⌘K").foregroundStyle(.secondary) }
            }
            .font(Typography.caption)
            .padding(Space.md).fieldSurface(cornerRadius: Radius.control)
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(searchFocused ? environment.accent : .clear, lineWidth: 2))
            .padding(.horizontal, Space.lg).padding(.bottom, Space.lg)

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

            VStack(spacing: Space.md) {
                newMenu

                Text("Shared across environments.\nCredentials stay separate.")
                    .font(Typography.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Space.xl)
        }
        .frame(width: compact ? nil : 238)
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
                            .animation(reduceMotion ? nil : Motion.reveal.delay(expanded ? min(Double(index) * 0.018, 0.072) : 0),
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

    private var newMenu: some View {
        ActionButton(title: "New request", tone: .outlined, height: ControlHeight.lg, size: Typography.Size.detail,
                     icon: "plus", disclosure: true, fills: true)
        .appMenu(edge: .top, matchWidth: true) {
            [.item("New request", subtitle: "starts in Default") { createRequest() },
             .item("New folder", subtitle: "groups related requests") {
                 renamingFolderID = store.addFolder().id
             }]
        }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let request = store.selected {
            // Keyed on the request so switching in the sidebar starts the editor over
            // on the new one rather than keeping the last one's draft.
            RequestDetail(request: request)
                .id(request.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 8)),
                                        removal: .identity))
        } else {
            VStack(spacing: Space.md) {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("Select a request or create a new one")
                    .font(Typography.title)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// The same question whether the delete starts from the sidebar or from the editor.
@MainActor
private func deleteDialog(for request: SavedRequest, store: DispatchStore,
                          auth: DispatchAuthStore) -> Dialog {
    Dialog.impact("Delete \"\(request.name.isEmpty ? "Untitled" : request.name)\"?",
                  rows: [.init(title: "Request",
                               detail: "The URL, headers, body and auth set up on it are deleted."),
                         .init(title: "Other requests and environment credentials", detail: "Kept in every environment.", kept: true)],
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

            Image(systemName: "folder.fill")
                .font(Typography.detail)
                .foregroundStyle(accent)

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
                        .foregroundStyle(.secondary)
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
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.md)
        .padding(.vertical, isRenaming ? 4 : 8)
        .surface(selected ? accent.opacity(0.10) : (hovering ? Theme.field : .clear), cornerRadius: Radius.control,
                 border: selected ? accent.opacity(0.3) : .clear)
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

// MARK: - Editing one request

private struct RequestDetail: View {
    @State private var draft: SavedRequest
    @State private var copiedCurl = false
    @State private var copyReset: Task<Void, Never>?
    @State private var renamingTitle = false

    @Environment(DispatchStore.self) private var store
    @Environment(DispatchRunner.self) private var runner
    @Environment(DispatchAuthStore.self) private var auth
    @Environment(DialogPresenter.self) private var dialogs

    @Environment(MenuPresenter.self) private var menus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var nameFocused: Bool
    @FocusState private var urlFocused: Bool
    @Namespace private var tabPanels
    @State private var dragHeight: CGFloat?

    private typealias Tab = DispatchWorkbenchState.RequestTab
    private var tab: Tab { store.workbench.requestTab }

    init(request: SavedRequest) {
        _draft = State(initialValue: request)
    }

    private var environment: ApiEnvironment { auth.active }
    private var running: Bool { runner.isRunning(draft.id, in: environment) }
    private var result: HTTPResult? { runner.result(draft.id, in: environment) }
    private var sendable: Bool {
        let resolved = DispatchRunner.resolve(draft, environment: environment, authorization: nil,
                                              properties: auth.properties(for: environment))
        return resolved.problems.isEmpty && DispatchRunner.isValidURL(resolved.url)
    }

    private var requestMenu: [MenuEntry] {
        [.item("Rename request") { renamingTitle = true; nameFocused = true },
         .item("Duplicate request") {
             if let copy = store.duplicate(draft.id) { auth.copyBasicPassword(from: draft.id, to: copy) }
         },
         .item("Copy as curl", icon: "terminal", subtitle: "Secrets masked", action: copyAsCurl),
         .separator,
         .item("Delete request", kind: .destructive) {
             dialogs.show(deleteDialog(for: draft, store: store, auth: auth))
         }]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            urlBar
            resolvedLine
            GeometryReader { geometry in
                let height = DispatchSplitLayout.responseHeight(dragHeight ?? store.responseHeight,
                                                               available: geometry.size.height)
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        tabs
                        ZStack {
                            ForEach(Tab.allCases) { item in
                                editor(for: item)
                                    .standbyPane(shown: tab == item)
                                    .allowsHitTesting(tab == item && !store.workbench.responseExpanded)
                                    .accessibilityHidden(tab != item || store.workbench.responseExpanded)
                                    .disabled(tab != item || store.workbench.responseExpanded)
                                    .accessibilityElement(children: .contain)
                                    .accessibilityLabel(item.rawValue)
                                    .accessibilityLabeledPair(role: .content, id: item, in: tabPanels)
                            }
                        }
                        .clipped()
                        .motion(Motion.reveal, value: tab)
                    }
                    .frame(height: store.workbench.responseExpanded ? 0
                           : max(0, geometry.size.height - height - DispatchSplitLayout.handleHeight))
                    .clipped()
                    .allowsHitTesting(!store.workbench.responseExpanded)
                    .disabled(store.workbench.responseExpanded)
                    .accessibilityHidden(store.workbench.responseExpanded)
                    if !store.workbench.responseExpanded {
                        DispatchResponseGrip(height: height, availableHeight: geometry.size.height,
                                             dragHeight: $dragHeight)
                            .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    }
                    DispatchResponsePane(result: result, running: running, environment: environment,
                                         cancel: cancel, retry: send)
                        .frame(maxHeight: .infinity)
                }
                .motion(Motion.control, value: store.workbench.responseExpanded)
            }
        }
        .onChange(of: draft) { _, new in store.update(new) }
        .onChange(of: store.selected) { _, request in
            if let request, request.id == draft.id, request != draft { draft = request }
        }
        .onChange(of: running) { wasRunning, running in
            if wasRunning, !running, let result {
                AccessibilityNotification.Announcement("\(environment.label): \(result.statusText)").post()
            }
        }
        .onExitCommand {
            if dialogs.current != nil { dialogs.dismiss() }
            else if menus.isOpen { menus.dismiss() }
            else if running { cancel() }
        }
    }

    private var title: some View {
        HStack(spacing: Space.md) {
            if let folder = store.folders.first(where: { $0.id == draft.folderID }) {
                Text(folder.name).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Group {
                if renamingTitle {
                    TextField("Request name", text: $draft.name)
                        .textFieldStyle(.plain).focused($nameFocused)
                        .padding(Space.xs).fieldSurface(cornerRadius: Radius.inset)
                        .overlay(RoundedRectangle(cornerRadius: Radius.inset).stroke(environment.accent))
                        .onSubmit { nameFocused = false }
                        .onExitCommand { nameFocused = false }
                        .onChange(of: nameFocused) { _, focused in if !focused { renamingTitle = false } }
                } else {
                    Text(draft.name.isEmpty ? "Untitled" : draft.name)
                        .lineLimit(1).truncationMode(.tail)
                        .contentShape(Rectangle())
                        .onTapGesture { renamingTitle = true; nameFocused = true }
                        .accessibilityAction(named: "Rename request") { renamingTitle = true; nameFocused = true }
                }
            }
            .font(Typography.display)
            .accessibilityLabel("Request name: \(draft.name)")
            Spacer(minLength: 0)
            if copiedCurl {
                Label("Copied curl", systemImage: "checkmark").font(Font.system(size: Typography.Size.micro)).foregroundStyle(environment.accent)
                    .transition(.fadeIn)
            }
            GlyphButton(icon: draft.isPinned ? "star.fill" : "star", side: ControlHeight.md, tint: environment.accent) {
                store.togglePin(draft.id)
            }
            .accessibilityLabel(draft.isPinned ? "Unpin request" : "Pin to top of folder")
            GlyphButton(icon: "ellipsis", side: ControlHeight.md)
                .appMenu { requestMenu }
                .accessibilityLabel("More request actions")
        }
        .padding(.horizontal, Space.xxl).frame(height: 55)
        .motion(Motion.reveal, value: copiedCurl)
    }

    private var urlBar: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Text(draft.method.rawValue).font(Typography.data.weight(.semibold)).foregroundStyle(draft.method.tint)
                    MenuChevron(size: 9)
                }
                .padding(.horizontal, Space.lg).frame(height: 40)
                .contentShape(Rectangle())
                .hoverLift()
                .appMenu {
                    HTTPMethod.allCases.map { method in
                        .item(method.rawValue, checked: method == draft.method) { draft.method = method }
                    }
                }
                .accessibilityLabel("Request method: \(draft.method.rawValue)")
                Rectangle().fill(Theme.border).frame(width: 1)
                TextField("https://host/path", text: $draft.url)
                    .textFieldStyle(.plain).font(Typography.code).lineLimit(1)
                    .focused($urlFocused)
                    .accessibilityLabel("Request URL")
                    .onSubmit(send)
                    .padding(.trailing, Space.md)
            }
            .frame(height: 40)
            .surface(Theme.field, cornerRadius: Radius.card,
                     border: urlFocused ? environment.accent : Theme.border)
            ActionButton(title: running ? "Cancel" : "Send request", tone: running ? .danger : .green,
                         height: ControlHeight.xl, size: Typography.Size.detail, shortcut: running ? "Esc" : "⌘↵",
                         keyboardShortcut: KeyboardShortcut(.return, modifiers: .command)) {
                guard dialogs.current == nil, !menus.isOpen else { return }
                if running { cancel() } else { send() }
            }
            .disabled(!running && !sendable)
            .background {
                Button("") {
                    guard dialogs.current == nil, !menus.isOpen else { return }
                    if running { cancel() } else { send() }
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .control)
                .disabled(!running && !sendable).opacity(0).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Space.xxl).padding(.bottom, Space.sm)
        .motion(Motion.control, value: draft.method)
    }

    // What the URL becomes on send, so the template stays editable above while the
    // real address is always in sight.
    private var resolvedLine: some View {
        let resolved = DispatchRunner.resolve(draft, environment: environment, authorization: nil,
                                              properties: auth.properties(for: environment), masked: true)
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text("→").font(Font.mono(Typography.Size.micro)).foregroundStyle(.tertiary)
                Text(resolved.url).font(Font.mono(Typography.Size.micro)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !resolved.problems.isEmpty {
                Text(resolved.problems.joined(separator: "\n"))
                    .font(Typography.caption).foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Space.xxl)
        .padding(.bottom, Space.lg)
    }

    private var tabs: some View {
        DispatchTabs(items: Tab.allCases, selection: Binding(get: { tab }, set: { store.workbench.requestTab = $0 }),
                     namespace: tabPanels, label: { $0.rawValue }, detail: detail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.xxl)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
            .accessibilityLabel("Request configuration tabs")
    }

    private func detail(for tab: Tab) -> String? {
        switch tab {
        case .parameters: countDetail(draft.queryParams.count + draft.pathParams.count)
        case .headers: countDetail(draft.headers.count)
        case .body: draft.bodyType == .none ? nil : draft.bodyType.label
        case .auth: draft.authMode == .none ? "off" : nil
        }
    }

    private func countDetail(_ count: Int) -> String? { count == 0 ? nil : "\(count)" }

    @ViewBuilder private func editor(for tab: Tab) -> some View {
        switch tab {
        case .parameters:
            VStack(spacing: 0) {
                HStack {
                    Text(store.workbench.pathParameters ? "Path parameters" : "Query parameters")
                        .font(Typography.caption).foregroundStyle(.secondary)
                    Spacer()
                    InlineLink(title: store.workbench.pathParameters ? "Query parameters" : "Path parameters",
                               size: Typography.Size.caption, tint: environment.accent, icon: "chevron.right") {
                        store.workbench.pathParameters.toggle()
                    }
                }.padding(.horizontal, Space.xxl).padding(.top, Space.lg)
                ZStack {
                    parameterEditor(paths: false)
                        .standbyPane(shown: !store.workbench.pathParameters)
                        .allowsHitTesting(!store.workbench.pathParameters)
                        .accessibilityHidden(store.workbench.pathParameters)
                        .disabled(store.workbench.pathParameters)
                    parameterEditor(paths: true)
                        .standbyPane(shown: store.workbench.pathParameters)
                        .allowsHitTesting(store.workbench.pathParameters)
                        .accessibilityHidden(!store.workbench.pathParameters)
                        .disabled(!store.workbench.pathParameters)
                }
            }
            .motion(Motion.reveal, value: store.workbench.pathParameters)
        case .headers: headerEditor
        case .body: bodyEditor
        case .auth: authEditor
        }
    }

    private func parameterEditor(paths: Bool) -> some View {
        paramsEditor(title: paths ? "PATH" : "QUERY",
                     note: paths ? "Values fill the :name segments in the URL." : "Added to the URL as ?key=value.",
                     keyPlaceholder: "Name", addLabel: "+ Add parameter",
                     params: paths ? $draft.pathParams : $draft.queryParams) {
            if paths { draft.pathParams.append(HeaderField(key: "", value: "")) }
            else { draft.queryParams.append(HeaderField(key: "", value: "")) }
        }
    }

    private func paramsEditor(title: String, note: String, keyPlaceholder: String,
                              addLabel: String, params: Binding<[HeaderField]>,
                              add: @escaping () -> Void) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                paramSection(title: title,
                             note: note,
                             keyPlaceholder: keyPlaceholder,
                             params: params)

                InlineLink(title: addLabel, size: Typography.Size.caption, tint: environment.accent, action: add)
                    .padding(.top, Space.md)
            }
            .padding(.horizontal, Space.xxl).padding(.vertical, Space.md)
        }
        .frame(maxHeight: .infinity)
        .motion(Motion.control, value: params.wrappedValue.map(\.id))
    }

    private func paramSection(title: String, note: String, keyPlaceholder: String,
                              params: Binding<[HeaderField]>) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                Text(note)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, Space.xxs)

            ForEach(params) { $param in
                HeaderRow(header: $param,
                          keyPlaceholder: keyPlaceholder,
                          valuePlaceholder: "value") {
                    params.wrappedValue.removeAll { $0.id == param.id }
                }
                .transition(.fadeIn)
            }
        }
    }

    private var authEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(spacing: Space.xs) {
                    ForEach(AuthMode.allCases) { mode in
                        ChoicePill(title: mode.label, selected: draft.authMode == mode) { draft.authMode = mode }
                    }
                }

                switch draft.authMode {
                case .none:
                    authNote("Nothing is added. A request that needs an Authorization header can still carry one of its own from the Headers tab.")
                case .environmentToken:
                    authNote("Adds \(auth.config(for: environment).headerPrefix) <token> as the Authorization header, from whichever environment is active when you send. An Authorization header of your own still wins.")
                    EnvironmentTokenControls(env: environment)
                case .basic:
                    LabeledField("USERNAME") {
                        TextField("username", text: $draft.basicUsername)
                            .appTextField(size: 11)
                    }
                    LabeledField("PASSWORD") {
                        SecretField(placeholder: "kept in the Keychain, never in the request file",
                                    text: basicPassword,
                                    accent: environment.accent)
                    }
                    authNote("Adds Authorization: Basic <username:password>. The pair is the same in every environment, and base64 hides nothing from anything on the way, so this belongs on https only. An Authorization header of your own still wins.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(Space.xxl)
        }
        .frame(maxHeight: .infinity)
    }

    private func authNote(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // The password is the one part of a request that is not in the request file, so it is
    // read and written straight through to the store that owns the Keychain.
    private var basicPassword: Binding<String> {
        let id = draft.id
        return Binding(get: { auth.basicPassword(for: id) },
                       set: { auth.setBasicPassword($0, for: id) })
    }

    private var headerEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach($draft.headers) { $header in
                    HeaderRow(header: $header, isHeader: true) {
                        draft.headers.removeAll { $0.id == header.id }
                    }
                }
                AddPill(label: "+ Add header") {
                    [.item("Content-Type",
                           subtitle: "arrives filled in as application/json") {
                         draft.headers.append(HeaderField(key: "Content-Type",
                                                          value: BodyType.json.contentType ?? ""))
                     },
                     .item("Accept",
                           subtitle: "asks the server to answer in JSON") {
                         draft.headers.append(HeaderField(key: "Accept",
                                                          value: BodyType.json.contentType ?? ""))
                     },
                     .item("Authorization",
                           subtitle: "a token of your own; it wins over the Auth tab's") {
                         draft.headers.append(HeaderField(key: "Authorization", value: ""))
                     },
                     .separator,
                     .item("Custom header",
                           subtitle: "starts empty") {
                         draft.headers.append(HeaderField(key: "", value: ""))
                     }]
                }
                .padding(.top, draft.headers.isEmpty ? 0 : 8)
            }
            .padding(Space.xxl)
        }
        .frame(maxHeight: .infinity)
        .motion(Motion.control, value: draft.headers.map(\.id))
    }

    // The type picker lives in the pane rather than on the tab row, which has no room
    // to spare once the tab labels carry their counts.
    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.xs) {
                ForEach(BodyType.allCases) { kind in
                    ChoicePill(title: kind.label, selected: draft.bodyType == kind) {
                        draft.bodyType = kind
                    }
                }
                Spacer(minLength: 12)
                // Offered only when it would change something, so a body that does not
                // parse yet or is already tidy shows nothing to press.
                if draft.bodyType == .json,
                   let formatted = JSONFormat.pretty(draft.body), formatted != draft.body {
                    InlineLink(title: "Format", tint: environment.accent) {
                        draft.body = formatted
                    }
                }
            }
            if draft.bodyType == .none {
                Text("This request is sent without a body. Pick JSON, Text or Form to add one.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
            } else {
                if !draft.method.canCarryBody {
                    Text("A \(draft.method.rawValue) request is sent without a body. "
                         + "This one is kept and goes out again if you switch to POST, PUT, PATCH or DELETE.")
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if draft.bodyType == .form {
                    Text("One key=value per line. Each pair is URL-encoded and joined with &.")
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                }
                if draft.bodyType == .json {
                    CodeEditorView(documentID: "\(draft.id)-body",
                                   text: $draft.body,
                                   language: .json,
                                   matches: [],
                                   currentMatch: nil)
                        .padding(.vertical, Space.xs)
                        .cardSurface(cornerRadius: Radius.card)
                } else {
                    TextEditor(text: $draft.body)
                        .font(Typography.code)
                        .scrollContentBackground(.hidden)
                        .padding(Space.md)
                        .cardSurface(cornerRadius: Radius.card)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Space.xxl)
    }

    private func send() {
        guard sendable, !running, dialogs.current == nil, !menus.isOpen else { return }
        // The draft is what the user is looking at, and it may be a keystroke ahead of
        // the store, so the run is built from it rather than from the saved copy.
        let request = draft
        let env = environment
        let properties = auth.properties(for: env)
        let resolved = DispatchRunner.resolve(request, environment: env, authorization: nil, properties: properties, masked: true)
        guard resolved.problems.isEmpty else {
            dialogs.show(Dialog(title: "Cannot send to \(env.label)", message: resolved.problems.joined(separator: "\n"),
                                actions: [Dialog.Action(label: "OK", kind: .cancel)]))
            return
        }
        guard env.isDangerous else {
            fire(request, in: env, properties: properties)
            return
        }
        // A live environment asks once per send. There is no way to stop it asking; the
        // prompt is the guard.
        var actions = [
            Dialog.Action(label: "Send", kind: .destructive) { fire(request, in: env, properties: properties) }
        ]
        if let safe = auth.environments.first(where: { !$0.isDangerous }) {
            actions.append(Dialog.Action(label: "Switch to \(safe.label)") {
                auth.active = safe
            })
        }
        actions.append(Dialog.Action(label: "Cancel", kind: .cancel))
        dialogs.show(Dialog(
            title: "Send to \(env.label)?",
            message: consequence(of: request.method),
            content: AnyView(ResolvedRequestBox(request: request, environment: env, properties: properties)),
            actions: actions,
            width: 440,
            isModal: true))
    }

    private func fire(_ request: SavedRequest, in env: ApiEnvironment, properties: [EnvironmentProperty]) {
        runner.start(request, environment: env, properties: properties) {
            await authorization(for: request, in: env)
        }
    }

    // Built per send rather than held, so an expired token is refreshed on the way out
    // instead of failing the call.
    private func authorization(for request: SavedRequest,
                               in env: ApiEnvironment) async -> String? {
        if request.headers.contains(where: { $0.enabled && $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }) { return nil }
        switch request.authMode {
        case .none:
            return nil
        case .environmentToken:
            return await auth.authorizationHeader(for: env)
        case .basic:
            return auth.basicHeader(username: request.basicUsername, requestID: request.id)
        }
    }

    private func cancel() {
        runner.cancel(draft.id, in: environment)
    }

    private func copyAsCurl() {
        let request = draft
        let env = environment
        let properties = auth.properties(for: env)
        let resolved = DispatchRunner.resolve(request, environment: env, authorization: nil,
                                              properties: properties, masked: true)
        guard resolved.problems.isEmpty else {
            dialogs.show(.notice("Cannot export this request", message: resolved.problems.joined(separator: "\n")))
            return
        }
        Pasteboard.copy(CurlCommand.text(for: request, environment: env,
                                         authorization: request.authMode == .none ? nil : "REDACTED",
                                         properties: properties))
        copiedCurl = true
        AccessibilityNotification.Announcement("Copied curl with secrets masked").post()
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedCurl = false
        }
    }

    private func consequence(of method: HTTPMethod) -> String {
        let verb = switch method {
        case .delete: "deletes"
        case .post: "creates"
        case .put, .patch: "changes"
        case .get, .head: "runs against"
        }
        return "This \(verb) live data. Switch to a non-live environment if you meant to test."
    }
}

// Exactly what the confirmation is about: the method and the URL as it will be sent.
private struct ResolvedRequestBox: View {
    let request: SavedRequest
    let environment: ApiEnvironment
    var properties: [EnvironmentProperty] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(request.method.rawValue)
                .font(Typography.data.weight(.semibold))
                .foregroundStyle(Theme.deletion)
            Text(DispatchRunner.resolve(request, environment: environment, authorization: nil,
                                        properties: properties, masked: true).url).font(Typography.data)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .cardSurface(cornerRadius: Radius.control)
    }
}

// The one "+ Add" button under a list: a pill that unfolds into a menu of the kinds of
// row it can add, each row saying where that kind lands.
private struct AddPill: View {
    let label: String
    let entries: () -> [MenuEntry]

    var body: some View {
        ActionButton(title: label, tone: .outlined, height: ControlHeight.lg, size: Typography.Size.detail, disclosure: true)
            .appMenu(entries)
    }
}

private struct HeaderRow: View {
    @Binding var header: HeaderField
    private enum Field: Hashable { case name, value }
    @FocusState private var focused: Field?
    var keyPlaceholder = "Header"
    var valuePlaceholder = "value"
    // Only real headers are held to the header name rules. A query or path param is
    // named by whoever wrote the API and may hold characters a header never could.
    var isHeader = false
    let onDelete: () -> Void

    // Shown once the name cannot be fixed by splitting it, so a name that arrives whole
    // is quietly put right and only a genuinely unusable one is called out.
    private var nameProblem: String? {
        guard isHeader, !header.key.isEmpty, !HeaderField.isValidName(header.key) else {
            return nil
        }
        return "A header name cannot hold spaces or colons."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.lg) {
                Toggle(isOn: $header.enabled) { EmptyView() }
                    .toggleStyle(.appCheckbox)
                    .accessibilityLabel("Enable \(header.key.isEmpty ? keyPlaceholder : header.key)")

                TextField(keyPlaceholder, text: $header.key)
                    .textFieldStyle(.plain)
                    .focused($focused, equals: .name)
                    .font(Typography.code.weight(.semibold))
                    .foregroundStyle(nameProblem == nil ? Color.primary : Theme.deletion)
                    .frame(minWidth: 80, idealWidth: 140, maxWidth: 180, alignment: .leading)
                    .accessibilityLabel("\(keyPlaceholder) name")
                    .onChange(of: header.key) {
                        if isHeader { header.splitPastedName() }
                    }

                TextField(valuePlaceholder, text: $header.value)
                    .textFieldStyle(.plain)
                    .focused($focused, equals: .value)
                    .font(Typography.code)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Value for \(header.key.isEmpty ? keyPlaceholder : header.key)")

                Button(action: onDelete) {
                    Image(systemName: "xmark").font(Typography.caption)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(header.key.isEmpty ? keyPlaceholder : header.key)")
                .hoverLift(amount: Motion.smallLift)
                .foregroundStyle(.secondary)
            }

            if let nameProblem {
                Text(nameProblem)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.deletion)
                    .padding(.leading, 32)
            }
        }
        .opacity(header.enabled ? 1 : 0.45)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .surface(Theme.card, cornerRadius: Radius.card,
                 border: nameProblem != nil ? Theme.deletion : focused != nil ? Theme.accent : Theme.border)
        .motion(Motion.hover, value: focused)
    }
}

// Reports the size of the window a sheet hangs off, and keeps reporting it as that
// window is resized, so the sheet can grow with it.
struct ParentWindowSize: NSViewRepresentable {
    @Binding var size: CGSize?

    func makeNSView(context: Context) -> NSView {
        let view = WatchingView()
        view.onChange = { size = $0 }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class WatchingView: NSView {
        var onChange: ((CGSize) -> Void)?
        private var observer: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // A sheet leaves its window before it goes away, which is where the observer is let go.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil else { return }
            // The view joins the sheet's window before AppKit hangs that window off its parent.
            DispatchQueue.main.async { [weak self] in self?.watchParent() }
        }

        private func watchParent() {
            guard observer == nil, let parent = window?.sheetParent else { return }
            onChange?(parent.contentLayoutRect.size)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: parent, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?(parent.contentLayoutRect.size) }
            }
        }
    }
}
