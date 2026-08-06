import SwiftUI

// A small HTTP client for the services a session is working on: the saved requests on
// the left, the one being edited and its answer on the right.
struct PostmanView: View {
    @Environment(PostmanStore.self) private var store
    @Environment(PostmanAuthStore.self) private var auth
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss

    @State private var showingAuth = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Theme.hairline)
                detail
            }
            SheetFooter { dismiss() }
        }
        // Kept inside the window's minimum size, since a sheet wider than its window
        // gets clipped rather than growing it.
        .frame(width: 940, height: 640)
        .background(Theme.background)
        .sheet(isPresented: $showingAuth) { AuthorizationView() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Postman").font(.serif(16))
            Text("\(store.requests.count) request\(store.requests.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.card)
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
                    ForEach(store.requests) { request in
                        RequestRow(request: request, selected: request.id == store.selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture { store.selectedID = request.id }
                            .appContextMenu {
                                [.item("Duplicate") { store.duplicate(request.id) },
                                 .separator,
                                 .item("Delete", kind: .destructive) {
                                     dialogs.show(deleteDialog(for: request, store: store))
                                 }]
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            VStack(spacing: 10) {
                Button {
                    store.add()
                } label: {
                    Text("+ New request")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.88)))
                }
                .buttonStyle(.plain)

                authRow
            }
            .padding(16)
        }
        .frame(width: 268)
        .background(Theme.sidebar)
    }

    // The token is shared by every request, so its state belongs next to the list rather
    // than inside whichever request happens to be open.
    private var authRow: some View {
        Button {
            showingAuth = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(auth.isAuthenticated ? Theme.dotOn : Theme.dotOff)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Authorization")
                        .font(.system(size: 12, weight: .semibold))
                    Text(authState)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var authState: String {
        if auth.busy { return "Signing in…" }
        if auth.awaitingPaste { return "Waiting for the code" }
        return auth.tokenStatus
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
                Text("Pick a request, or make a new one")
                    .font(.serif(18))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// The same question whether the delete starts from the sidebar or from the editor.
@MainActor
private func deleteDialog(for request: SavedRequest, store: PostmanStore) -> Dialog {
    Dialog(
        title: "Delete \"\(request.name.isEmpty ? "Untitled" : request.name)\"?",
        message: "The request and everything set up on it are gone for good.",
        actions: [
            .init(label: "Delete request", kind: .destructive) { store.remove(request.id) },
            .init(label: "Cancel", kind: .cancel)
        ])
}

private struct RequestRow: View {
    let request: SavedRequest
    let selected: Bool

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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(selected ? Theme.card : (hovering ? Theme.field : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.border : .clear))
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

// MARK: - Editing one request

private struct RequestDetail: View {
    @State private var draft: SavedRequest
    @State private var tab = Tab.headers

    @Environment(PostmanStore.self) private var store
    @Environment(PostmanRunner.self) private var runner
    @Environment(PostmanAuthStore.self) private var auth
    @Environment(DialogPresenter.self) private var dialogs

    private enum Tab: String, CaseIterable, Identifiable {
        case headers = "Headers", body = "Body", auth = "Auth"
        var id: String { rawValue }
    }

    init(request: SavedRequest) {
        _draft = State(initialValue: request)
    }

    private var running: Bool { runner.isRunning(draft.id) }
    private var result: HTTPResult? { runner.result(draft.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            urlBar
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

            TextField("https://host/path", text: $draft.url)
                .textFieldStyle(.plain)
                .font(.mono(12))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                .onSubmit(send)

            Button(action: send) {
                Text(running ? "Sending…" : "Send")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(running ? Color.black.opacity(0.4) : Color.black.opacity(0.88)))
            }
            .buttonStyle(.plain)
            .disabled(running || draft.url.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { item in
                TabButton(title: label(for: item), selected: tab == item) { tab = item }
            }
            Spacer()
            if tab == .body {
                Picker("", selection: $draft.bodyType) {
                    ForEach(BodyType.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func label(for tab: Tab) -> String {
        switch tab {
        case .headers: draft.headers.isEmpty ? tab.rawValue : "\(tab.rawValue) · \(draft.headers.count)"
        case .body: draft.bodyType == .none ? tab.rawValue : "\(tab.rawValue) · \(draft.bodyType.label)"
        case .auth: draft.useAuth ? "\(tab.rawValue) · on" : "\(tab.rawValue) · off"
        }
    }

    @ViewBuilder private var editor: some View {
        switch tab {
        case .headers: headerEditor
        case .body: bodyEditor
        case .auth: authEditor
        }
    }

    private var authEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $draft.useAuth) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send the collection's token")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Adds \(auth.config.headerPrefix) <token> as the Authorization header. An Authorization header of your own still wins.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(auth.isAuthenticated ? Theme.dotOn : Theme.dotOff)
                    .frame(width: 7, height: 7)
                Text(auth.tokenStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let failure = auth.failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AuthenticateButton().frame(width: 220)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private var headerEditor: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach($draft.headers) { $header in
                    HeaderRow(header: $header) {
                        draft.headers.removeAll { $0.id == header.id }
                    }
                }
                Button {
                    draft.headers.append(HeaderField(key: "", value: ""))
                } label: {
                    Text("+ Add header")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var bodyEditor: some View {
        if draft.bodyType == .none {
            Text("This request is sent without a body. Pick JSON, Text or Form to add one.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
        } else {
            TextEditor(text: $draft.body)
                .font(.mono(12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                .padding(20)
                .frame(maxHeight: .infinity)
        }
    }

    private func send() {
        // The draft is what the user is looking at, and it may be a keystroke ahead of
        // the store, so the run is built from it rather than from the saved copy.
        let request = draft
        Task {
            // Asked for per send rather than held, so an expired token is refreshed on
            // the way out instead of failing the call.
            let authorization = request.useAuth ? await auth.authorizationHeader() : nil
            await runner.send(request, authorization: authorization)
        }
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

private struct HeaderRow: View {
    @Binding var header: HeaderField
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $header.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)

            TextField("Header", text: $header.key)
                .textFieldStyle(.plain)
                .font(.mono(12, .semibold))
                .frame(width: 200, alignment: .leading)

            TextField("value", text: $header.value)
                .textFieldStyle(.plain)
                .font(.mono(12))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .opacity(header.enabled ? 1 : 0.45)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }
}

// MARK: - The answer

private struct ResponsePane: View {
    let result: HTTPResult?
    let running: Bool

    @State private var showingHeaders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
            Divider().overlay(Theme.hairline)
            content
        }
        .frame(height: 230)
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

                Text("\(Int(result.duration * 1000)) ms · \(byteText(result.byteCount))")
                    .font(.mono(11))
                    .foregroundStyle(.secondary)

                if !result.headers.isEmpty {
                    Button(showingHeaders ? "Body" : "Headers · \(result.headers.count)") {
                        showingHeaders.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
            }

            Spacer()

            if running {
                Text("Waiting…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let text = copyable, !text.isEmpty {
                Button("Copy") {
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
    }

    @ViewBuilder private var content: some View {
        if let result {
            ScrollView {
                if let failure = result.failure {
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.deletion)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                } else if showingHeaders {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.headers) { header in
                            HStack(alignment: .top, spacing: 8) {
                                Text(header.key)
                                    .font(.mono(11, .semibold))
                                    .frame(width: 200, alignment: .leading)
                                Text(header.value)
                                    .font(.mono(11))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .padding(20)
                } else {
                    Text(result.body.isEmpty ? "No body came back." : result.body)
                        .font(.mono(11))
                        .foregroundStyle(result.body.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
        } else {
            Text(running ? "Sending…" : "Send the request to see what comes back.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
        }
    }

    private var copyable: String? {
        guard let result else { return nil }
        return result.failure ?? result.body
    }

    private func byteText(_ count: Int) -> String {
        count < 1024 ? "\(count) B" : String(format: "%.1f kB", Double(count) / 1024)
    }
}
