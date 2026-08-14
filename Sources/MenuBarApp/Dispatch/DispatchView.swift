import SwiftUI

// A small HTTP client for the services a session is working on: the saved requests on
// the left, the one being edited and its answer on the right. Two environments share the
// one request list; the active one picks the credentials, the {{env}} value and the
// colour of the chrome, so where a send lands is legible at a glance.
struct DispatchView: View {
    @Environment(DispatchStore.self) private var store
    @Environment(DispatchAuthStore.self) private var auth
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss

    @State private var showingEnvironments = false
    @State private var renamingFolderID: UUID?

    private var environment: ApiEnvironment { auth.active }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(environment.brightAccent).frame(height: 5)
            header
            Divider().overlay(Theme.hairline)
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Theme.hairline)
                detail
            }
            SheetFooter(done: { dismiss() }) {
                Text(environment == .production
                     ? "Production asks once per send. Staging never asks."
                     : "Requests are shared by both environments. Each environment keeps its own credentials and its own responses.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        // Kept inside the window's minimum size, since a sheet wider than its window
        // gets clipped rather than growing it.
        .frame(width: 940, height: 660)
        .background(Theme.background)
        .sheet(isPresented: $showingEnvironments) { EnvironmentsView() }
        .onAppear { store.selectedID = nil }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Dispatch").font(.serif(16))
            Text("\(store.requests.count) request\(store.requests.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if environment == .production {
                Circle()
                    .fill(Theme.deletion)
                    .frame(width: 7, height: 7)
                    .padding(.leading, 2)
                Text("PRODUCTION")
                    .font(.mono(11, .bold))
                    .kerning(1)
                    .foregroundStyle(Theme.deletion)
            }
            Spacer()
            environmentSwitch
            Button("Environments") { showingEnvironments = true }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(environment.accent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(environment == .production ? Theme.deletion.opacity(0.10) : Theme.card)
    }

    private var environmentSwitch: some View {
        HStack(spacing: 2) {
            ForEach(ApiEnvironment.allCases) { env in
                EnvironmentSegment(env: env, selected: env == environment) {
                    auth.active = env
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.05)))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "REQUESTS")
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.folders) { folder in
                        folderSection(folder)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            VStack(spacing: 10) {
                newMenu

                tokenCard
            }
            .padding(16)
        }
        .frame(width: 268)
        .background(Theme.sidebar)
    }

    private func folderSection(_ folder: RequestFolder) -> some View {
        let expanded = store.isExpanded(folder.id)
        let requests = store.requests(in: folder.id)
        return VStack(alignment: .leading, spacing: 0) {
            FolderRow(folder: folder,
                      expanded: expanded,
                      requestCount: store.requestCount(in: folder.id),
                      isRenaming: renamingFolderID == folder.id,
                      accent: environment.accent,
                      onNewRequest: { store.add(to: folder.id) },
                      onDropRequest: { store.move($0, to: folder.id) },
                      onRename: { name in
                          store.renameFolder(folder.id, to: name)
                          renamingFolderID = nil
                      },
                      onCancelRename: { renamingFolderID = nil })
                .contentShape(Rectangle())
                .onTapGesture {
                    guard renamingFolderID != folder.id else { return }
                    store.toggleFolder(folder.id)
                }
                .appContextMenu {
                    folderContextMenu(for: folder)
                }

            if expanded, !requests.isEmpty {
                SidebarRail(colour: environment.brightAccent) {
                    ForEach(requests) { request in
                        SidebarRailRow(colour: environment.brightAccent,
                                       selectedColour: environment.accent,
                                       selected: request.id == store.selectedID) {
                            requestRow(request)
                        }
                    }
                }
            }
        }
    }

    private func requestRow(_ request: SavedRequest) -> some View {
        RequestRow(request: request,
                   selected: request.id == store.selectedID,
                   accent: environment.accent)
            .contentShape(Rectangle())
            .onTapGesture { store.selectedID = request.id }
            .appContextMenu { requestContextMenu(for: request) }
            .draggable(request.id.uuidString)
    }

    private func folderContextMenu(for folder: RequestFolder) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("New request") { store.add(to: folder.id) }
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
            .item("Duplicate") { store.duplicate(request.id) },
            .separator
        ]
        entries.append(contentsOf: store.folders.map { folder in
            .item("Move to \(folder.name)", checked: request.folderID == folder.id) {
                store.move(request.id, to: folder.id)
            }
        })
        entries.append(.separator)
        entries.append(.item("Delete", kind: .destructive) {
            dialogs.show(deleteDialog(for: request, store: store))
        })
        return entries
    }

    private var newMenu: some View {
        HStack(spacing: 7) {
            Text("+ New")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.88)))
        .contentShape(Rectangle())
        .appMenu(edge: .top, matchWidth: true) {
            [.item("New request", subtitle: "starts in Default") { store.add() },
             .item("New folder", subtitle: "groups related requests") {
                 renamingFolderID = store.addFolder().id
             }]
        }
    }

    // The active environment's token, next to the list because every request borrows it.
    private var tokenCard: some View {
        let config = auth.config(for: environment)
        let ready = config.missing.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(auth.isAuthenticated(for: environment)
                          ? environment.brightAccent : Theme.dotOff)
                    .frame(width: 7, height: 7)
                Text("\(environment.label) token")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if let token = auth.tokens[environment], auth.isAuthenticated(for: environment) {
                    Text(token.remainingText)
                        .font(.mono(10))
                        .foregroundStyle(.secondary)
                }
            }

            Text(ready ? config.tokenHost : "No credentials yet")
                .font(.mono(10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if auth.busy.contains(environment) || auth.awaitingPaste.contains(environment) {
                // Nothing tells the app that the browser tab was closed, so the wait
                // has to be something the user can call off from right here.
                HStack(spacing: 10) {
                    Text(auth.busy.contains(environment)
                         ? (config.grant.usesBrowser ? "Waiting for the browser…" : "Signing in…")
                         : "Waiting for the code")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Cancel") { auth.cancelAuthentication(environment) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.deletion)
                }
            } else {
                Button(tokenAction) {
                    guard ready else {
                        showingEnvironments = true
                        return
                    }
                    auth.authenticate(environment)
                    // A callback that is not ours needs the paste field, which lives in
                    // the Environments sheet, so the sign-in and the sheet arrive together.
                    if config.grant.usesBrowser && !config.usesLoopback {
                        showingEnvironments = true
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(environment.accent)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(environment.accent.opacity(0.3)))
    }

    private var tokenAction: String {
        auth.config(for: environment).missing.isEmpty ? "Re-authenticate" : "Set up credentials"
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let request = store.selected {
            // Keyed on the request so switching in the sidebar starts the editor over
            // on the new one rather than keeping the last one's draft.
            RequestDetail(request: request)
                .id(request.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("Select a request or create a new one")
                    .font(.serif(18))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct EnvironmentSegment: View {
    let env: ApiEnvironment
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(env.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? env.accentFill : (hovering ? Theme.field : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// The same question whether the delete starts from the sidebar or from the editor.
@MainActor
private func deleteDialog(for request: SavedRequest, store: DispatchStore) -> Dialog {
    Dialog(
        title: "Delete \"\(request.name.isEmpty ? "Untitled" : request.name)\"?",
        message: "The request and everything set up on it are gone for good.",
        actions: [
            .init(label: "Delete request", kind: .destructive) { store.remove(request.id) },
            .init(label: "Cancel", kind: .cancel)
        ])
}

@MainActor
private func deleteFolderDialog(for folder: RequestFolder, store: DispatchStore) -> Dialog {
    let count = store.requestCount(in: folder.id)
    let requests = "\(count) request\(count == 1 ? "" : "s")"
    return Dialog(
        title: "Delete \"\(folder.name)\"?",
        message: count == 0
            ? "This empty folder is gone for good."
            : "The folder is gone. Its \(requests) move to Default.",
        actions: [
            .init(label: "Delete folder", kind: .destructive) { store.removeFolder(folder.id) },
            .init(label: "Cancel", kind: .cancel)
        ])
}

private struct FolderRow: View {
    let folder: RequestFolder
    let expanded: Bool
    let requestCount: Int
    let isRenaming: Bool
    let accent: Color
    let onNewRequest: () -> Void
    let onDropRequest: (UUID) -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var draftName = ""
    @State private var hovering = false
    @State private var isDropTarget = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)

            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(accent)

            if isRenaming {
                TextField("Folder name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                    .focused($nameFocused)
                    .onSubmit { onRename(draftName) }
                    .onExitCommand(perform: onCancelRename)
            } else {
                Text(folder.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Group {
                if hovering && !isRenaming {
                    Button(action: onNewRequest) {
                        Text("+ Request")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Capsule().fill(accent.opacity(0.12)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .appTooltip("New request in \(folder.name)")
                } else {
                    Text("\(requestCount)")
                        .font(.mono(10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: 62, height: 20)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isRenaming ? 5 : 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isDropTarget ? accent.opacity(0.12) : (hovering ? Theme.field : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isDropTarget ? accent.opacity(0.65) : (hovering ? accent.opacity(0.18) : .clear),
                    lineWidth: isDropTarget ? 1.5 : 1))
        .onHover { hovering = $0 }
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

private struct RequestRow: View {
    let request: SavedRequest
    let selected: Bool
    let accent: Color

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            MethodTag(method: request.method)
            Text(request.name.isEmpty ? "Untitled" : request.name)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(selected ? Theme.card : (hovering ? Theme.field : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? accent.opacity(0.3) : .clear))
        .onHover { hovering = $0 }
    }
}

private struct MethodTag: View {
    let method: HTTPMethod

    var body: some View {
        Text(method.rawValue)
            .font(.mono(9, .bold))
            .foregroundStyle(method.tint)
            .frame(width: 42, alignment: .leading)
    }
}

// The template with every {{env}} swapped for what it resolves to, the resolved parts
// picked out in the environment's colour.
private func resolvedText(_ template: String, env: ApiEnvironment,
                          size: CGFloat, base: Color) -> Text {
    let parts = template.components(separatedBy: "{{env}}")
    var text = Text(verbatim: "")
    for (index, part) in parts.enumerated() {
        if index > 0 {
            text = text + Text(env.envValue).font(.mono(size, .bold)).foregroundStyle(env.brightAccent)
        }
        text = text + Text(part).font(.mono(size)).foregroundStyle(base)
    }
    return text
}

// MARK: - Editing one request

private struct RequestDetail: View {
    @State private var draft: SavedRequest
    @State private var tab = Tab.queryParams
    @State private var copiedCurl = false

    @Environment(DispatchStore.self) private var store
    @Environment(DispatchRunner.self) private var runner
    @Environment(DispatchAuthStore.self) private var auth
    @Environment(DialogPresenter.self) private var dialogs

    private enum Tab: String, CaseIterable, Identifiable {
        case queryParams = "Query params", pathParams = "Path params"
        case headers = "Headers", body = "Body", auth = "Auth"
        var id: String { rawValue }
    }

    init(request: SavedRequest) {
        _draft = State(initialValue: request)
    }

    private var environment: ApiEnvironment { auth.active }
    private var running: Bool { runner.isRunning(draft.id, in: environment) }
    private var result: HTTPResult? { runner.result(draft.id, in: environment) }
    private var sendable: Bool { !draft.url.isEmpty }

    private var curlMenu: [MenuEntry] {
        [.item("Copy as curl", icon: "terminal", action: copyAsCurl)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            urlBar
            resolvedLine
            tabs
            Divider().overlay(Theme.hairline)
            editor
            Divider().overlay(Theme.hairline)
            ResponsePane(result: result, running: running)
        }
        .onChange(of: draft) { _, new in store.update(new) }
    }

    private var title: some View {
        HStack(spacing: 10) {
            TextField("Name", text: $draft.name)
                .textFieldStyle(.plain)
                .font(.serif(18))
            Spacer(minLength: 8)
            Button("Delete") {
                dialogs.show(deleteDialog(for: draft, store: store))
            }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.deletion)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var urlBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(draft.method.rawValue)
                    .font(.mono(12, .bold))
                    .foregroundStyle(draft.method.tint)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            .appMenu {
                HTTPMethod.allCases.map { method in
                    .item(method.rawValue) { draft.method = method }
                }
            }

            TextField("https://host/path - {{env}} resolves per environment", text: $draft.url)
                .textFieldStyle(.plain)
                .font(.mono(12))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(environment.accent.opacity(0.35)))
                .onSubmit(send)

            HStack(spacing: 0) {
                Button {
                    if running {
                        cancel()
                    } else {
                        send()
                    }
                } label: {
                    Text(running ? "Cancel" : "Send")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .opacity(sendable || running ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .disabled(!running && !sendable)

                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 1, height: 16)

                // A tick in place of the chevron says the copy landed, since the menu
                // closes on the click and takes the only other place to say so with it.
                Image(systemName: copiedCurl ? "checkmark" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 30)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .appMenu { curlMenu }
                    .accessibilityLabel("More request actions")
            }
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(running ? Theme.deletion : environment.accentFill))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    // What the URL becomes on send, so the template stays editable above while the
    // real address is always in sight.
    private var resolvedLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("→")
                .font(.mono(10))
                .foregroundStyle(.tertiary)
            resolvedText(draft.expandedURL, env: environment, size: 10, base: .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { item in
                TabButton(title: label(for: item), selected: tab == item) { tab = item }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func label(for tab: Tab) -> String {
        switch tab {
        case .queryParams:
            let count = draft.queryParams.count
            return count == 0 ? tab.rawValue : "\(tab.rawValue) · \(count)"
        case .pathParams:
            let count = draft.pathParams.count
            return count == 0 ? tab.rawValue : "\(tab.rawValue) · \(count)"
        case .headers:
            return draft.headers.isEmpty ? tab.rawValue : "\(tab.rawValue) · \(draft.headers.count)"
        case .body:
            return draft.bodyType == .none ? tab.rawValue : "\(tab.rawValue) · \(draft.bodyType.label)"
        case .auth:
            return draft.useAuth ? "\(tab.rawValue) · \(environment.rawValue) bearer" : "\(tab.rawValue) · off"
        }
    }

    @ViewBuilder private var editor: some View {
        switch tab {
        case .queryParams:
            paramsEditor(title: "QUERY PARAMS",
                         note: "Added to the URL as ?key=value on send.",
                         keyPlaceholder: "key",
                         addLabel: "+ Add query param",
                         params: $draft.queryParams) {
                draft.queryParams.append(HeaderField(key: "", value: ""))
            }
        case .pathParams:
            paramsEditor(title: "PATH PARAMS",
                         note: "Values fill the :name segments typed into the URL.",
                         keyPlaceholder: "name",
                         addLabel: "+ Add path param",
                         params: $draft.pathParams) {
                draft.pathParams.append(HeaderField(key: "", value: ""))
            }
        case .headers: headerEditor
        case .body: bodyEditor
        case .auth: authEditor
        }
    }

    private func paramsEditor(title: String, note: String, keyPlaceholder: String,
                              addLabel: String, params: Binding<[HeaderField]>,
                              add: @escaping () -> Void) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                paramSection(title: title,
                             note: note,
                             keyPlaceholder: keyPlaceholder,
                             params: params)

                Button(action: add) {
                    Text(addLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
            .padding(20)
        }
        .frame(maxHeight: .infinity)
    }

    private func paramSection(title: String, note: String, keyPlaceholder: String,
                              params: Binding<[HeaderField]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel(text: title)
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            ForEach(params) { $param in
                HeaderRow(header: $param,
                          keyPlaceholder: keyPlaceholder,
                          valuePlaceholder: "value") {
                    params.wrappedValue.removeAll { $0.id == param.id }
                }
            }
        }
    }

    private var authEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $draft.useAuth) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send the environment's token")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Adds \(auth.config(for: environment).headerPrefix) <token> as the Authorization header, from whichever environment is active when you send. An Authorization header of your own still wins.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.appCheckbox)

            EnvironmentTokenControls(env: environment)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private var headerEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
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
            .padding(20)
        }
        .frame(maxHeight: .infinity)
    }

    // The type picker lives in the pane rather than on the tab row, which has no room
    // to spare once the tab labels carry their counts.
    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(BodyType.allCases) { kind in
                    ChoicePill(title: kind.label, selected: draft.bodyType == kind) {
                        draft.bodyType = kind
                    }
                }
            }
            if draft.bodyType == .none {
                Text("This request is sent without a body. Pick JSON, Text or Form to add one.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                TextEditor(text: $draft.body)
                    .font(.mono(12))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private func send() {
        // The draft is what the user is looking at, and it may be a keystroke ahead of
        // the store, so the run is built from it rather than from the saved copy.
        let request = draft
        let env = environment
        guard env == .production else {
            fire(request, in: env)
            return
        }
        // Production asks once per send. There is no way to stop it asking; the prompt
        // is the guard.
        dialogs.show(Dialog(
            title: "Send to production?",
            message: consequence(of: request.method),
            content: AnyView(ResolvedRequestBox(request: request)),
            actions: [
                .init(label: "Send", kind: .destructive) { fire(request, in: env) },
                .init(label: "Switch to staging") { auth.active = .staging },
                .init(label: "Cancel", kind: .cancel)
            ],
            width: 400))
    }

    private func fire(_ request: SavedRequest, in env: ApiEnvironment) {
        Task {
            // Asked for per send rather than held, so an expired token is refreshed on
            // the way out instead of failing the call.
            let authorization = request.useAuth ? await auth.authorizationHeader(for: env) : nil
            await runner.send(request, environment: env, authorization: authorization)
        }
    }

    private func cancel() {
        runner.cancel(draft.id, in: environment)
    }

    private func copyAsCurl() {
        let request = draft
        let env = environment
        Task {
            // Asked for the same way a send does, so the copied command carries a token
            // that is live rather than one that expired while the window sat open.
            let authorization = request.useAuth ? await auth.authorizationHeader(for: env) : nil
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                CurlCommand.text(for: request, environment: env, authorization: authorization),
                forType: .string)
            copiedCurl = true
            try? await Task.sleep(for: .seconds(2))
            copiedCurl = false
        }
    }

    private func consequence(of method: HTTPMethod) -> String {
        switch method {
        case .delete: "This deletes real data. Switch to staging if you meant to test."
        case .post: "This creates real data. Switch to staging if you meant to test."
        case .put, .patch: "This changes real data. Switch to staging if you meant to test."
        case .get, .head: "This runs against live data. Switch to staging if you meant to test."
        }
    }
}

// Exactly what the confirmation is about: the method and the URL as it will be sent.
private struct ResolvedRequestBox: View {
    let request: SavedRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(request.method.rawValue)
                .font(.mono(11, .bold))
                .foregroundStyle(Theme.deletion)
            resolvedText(request.expandedURL, env: .production, size: 11, base: .primary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}

private struct TabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.card : .clear))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Theme.border : .clear))
        }
        .buttonStyle(.plain)
    }
}

// The one "+ Add" button under a list: a pill that unfolds into a menu of the kinds of
// row it can add, each row saying where that kind lands.
private struct AddPill: View {
    let label: String
    let entries: () -> [MenuEntry]

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Theme.field : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        .onHover { hovering = $0 }
        .appMenu(entries)
    }
}

private struct HeaderRow: View {
    @Binding var header: HeaderField
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle(isOn: $header.enabled) { EmptyView() }
                    .toggleStyle(.appCheckbox)

                TextField(keyPlaceholder, text: $header.key)
                    .textFieldStyle(.plain)
                    .font(.mono(12, .semibold))
                    .foregroundStyle(nameProblem == nil ? Color.primary : Theme.deletion)
                    .frame(width: 200, alignment: .leading)
                    .onChange(of: header.key) {
                        if isHeader { header.splitPastedName() }
                    }

                TextField(valuePlaceholder, text: $header.value)
                    .textFieldStyle(.plain)
                    .font(.mono(12))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if let nameProblem {
                Text(nameProblem)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.deletion)
                    .padding(.leading, 32)
            }
        }
        .opacity(header.enabled ? 1 : 0.45)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(nameProblem == nil ? Theme.border : Theme.deletion))
    }
}

// MARK: - The answer

private struct ResponsePane: View {
    let result: HTTPResult?
    let running: Bool

    @Environment(DispatchStore.self) private var store

    @State private var tab = ResponseTab.body
    // Height while a drag is in flight; the store keeps it once the drag ends.
    @State private var dragHeight: CGFloat?
    // Height at the moment the drag began; the translation is measured from there.
    @State private var dragStartHeight: CGFloat?

    private enum ResponseTab: String, CaseIterable, Identifiable {
        case body = "Body", headers = "Headers"
        var id: String { rawValue }
    }

    private var height: CGFloat { dragHeight ?? store.responseHeight }

    // The tabs are only worth showing once there is a choice to make: a failure never
    // reaches the point of having headers, and neither does a body-only result.
    private func tabbed(_ result: HTTPResult) -> Bool {
        result.failure == nil && !result.headers.isEmpty
    }

    // The pane falls back to the body whenever the headers tab has nothing behind it,
    // so a result with no headers cannot strand it on an empty list with the tab that
    // would lead back out of it hidden.
    private func shown(for result: HTTPResult) -> ResponseTab {
        tabbed(result) ? tab : .body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
            Divider().overlay(Theme.hairline)
            content
        }
        .frame(height: height)
        .background(Theme.sidebar)
    }

    private var status: some View {
        HStack(spacing: 10) {
            SectionLabel(text: "RESPONSE")

            if let result {
                Text(result.statusText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(result.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(result.tint.opacity(0.14)))

                Text("\(Int(result.duration * 1000)) ms · \(byteText(result.byteCount))"
                     + (result.isTruncated ? " · truncated" : ""))
                    .font(.mono(11))
                    .foregroundStyle(.secondary)

                if tabbed(result) {
                    HStack(spacing: 4) {
                        ForEach(ResponseTab.allCases) { item in
                            TabButton(title: item == .headers
                                        ? "\(item.rawValue) · \(result.headers.count)"
                                        : item.rawValue,
                                      selected: shown(for: result) == item) {
                                tab = item
                            }
                        }
                    }
                    .padding(.leading, 2)
                }
            }

            Spacer()

            if running {
                Text("Waiting…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let text = copyable, !text.isEmpty {
                Button(copyLabel) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // The status bar doubles as the resize handle, which is where the hand
        // naturally goes when the pane is the wrong size.
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? height
                    dragStartHeight = start
                    dragHeight = max(DispatchStore.minimumResponseHeight, start - value.translation.height)
                }
                .onEnded { _ in
                    if let dragHeight { store.responseHeight = dragHeight }
                    dragHeight = nil
                    dragStartHeight = nil
                })
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
    }

    @ViewBuilder private var content: some View {
        if let result {
            ScrollView {
                if let failure = result.failure {
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(ResponseStyle.failure)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                } else if shown(for: result) == .headers {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.headers) { header in
                            HStack(alignment: .top, spacing: 8) {
                                Text(header.key)
                                    .font(.mono(11, .semibold))
                                    .foregroundStyle(ResponseStyle.key)
                                    .frame(width: 200, alignment: .leading)
                                Text(header.value)
                                    .font(.mono(11))
                                    .foregroundStyle(ResponseStyle.base)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .padding(20)
                } else if result.body.isEmpty {
                    Text("No body came back.")
                        .font(.mono(11))
                        .foregroundStyle(ResponseStyle.base.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                } else {
                    Text(ResponseStyle.highlight(result.body))
                        .font(.mono(11))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
            .frame(maxWidth: .infinity)
            .background(ResponseStyle.background)
        } else {
            Text(running ? "Sending…" : "Send the request to see what comes back.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
        }
    }

    // The button sits beside the tabs, so it copies whichever of them is open rather
    // than always reaching past the headers for the body.
    private var copyable: String? {
        guard let result else { return nil }
        if let failure = result.failure { return failure }
        guard shown(for: result) == .headers else { return result.body }
        return result.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private var copyLabel: String {
        guard let result, shown(for: result) == .headers else { return "Copy response" }
        return "Copy headers"
    }

    private func byteText(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f kB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / Double(1024 * 1024))
    }
}
