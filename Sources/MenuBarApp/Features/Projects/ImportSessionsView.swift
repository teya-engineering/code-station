import SwiftUI

// What the import sheet opens with: the folder, the project it belongs to when there is
// one already, and the sessions found for it. The list is read before the sheet goes up,
// for the same reason OldSessionsView takes its rows in its init: a sheet is measured on
// its first pass.
struct SessionImportRequest: Identifiable {
    let id = UUID()
    let folder: String
    // Nil while the folder is still on its way to becoming a project. The project is only
    // added once the sheet is confirmed, so cancelling leaves nothing behind.
    var projectID: UUID?
    var roots: [AgentKind: URL]
    var candidates: [ExternalSessionCandidate]
    var failures: [String] = []

    var addsProject: Bool { projectID == nil }

    @MainActor
    static func load(folder: String, projectID: UUID?, store: ProjectStore,
                     roots: [AgentKind: URL] = SessionHistoryCatalog.roots(),
                     force: Bool = false) async -> SessionImportRequest {
        let folder = ClaudeSessionCatalog.standardized(folder)
        let known = await store.knownAgentSessionIDs(inProject: projectID ?? UUID())
        let listing = await SessionHistoryCatalog.shared.sessions(in: folder, roots: roots, force: force)
        return SessionImportRequest(folder: folder, projectID: projectID, roots: roots,
                                    candidates: listing.candidates.filter { !known.contains($0.id) },
                                    failures: listing.failures)
    }
}

// Each agent owns its continuation history; the app stores a readable copy of the conversation.
struct ImportSessionsView: View {
    // Called once the sessions are in, with the project they landed in.
    let onFinish: (UUID) -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var request: SessionImportRequest
    @State private var ticked: Set<String>
    @State private var query = ""
    @State private var progress: Progress?
    @State private var failure: String?
    @State private var rescanning = false

    private struct Progress {
        let total: Int
        var done = 0
    }

    // Recent sessions are the ones worth carrying on, so they arrive ticked. The rest is a
    // tick away, and past this many nobody reads the whole list anyway.
    private static let preselectDays = 30
    private static let preselectLimit = 50
    private static let searchThreshold = 10

    init(request: SessionImportRequest, onFinish: @escaping (UUID) -> Void) {
        self.onFinish = onFinish
        _request = State(initialValue: request)
        _ticked = State(initialValue: Self.preselected(request.candidates))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.md) {
                    if request.candidates.isEmpty {
                        emptyCard
                    } else {
                        if request.candidates.count > Self.searchThreshold { searchField }
                        selectionBar
                        ForEach(visible) { candidate in
                            CandidateRow(candidate: candidate,
                                         ticked: ticked.contains(candidate.id),
                                         toggle: { toggle(candidate) })
                        }
                        if visible.isEmpty {
                            Text("No session matches \"\(query)\".")
                                .font(Typography.detail)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Space.xxl)
                        }
                    }
                    ForEach(request.failures, id: \.self) { notice($0) }
                    if let failure { notice(failure) }
                }
                .disabled(progress != nil || rescanning)
                .padding(Space.xxl)
            }
            .frame(maxHeight: 420)

            SheetFooter(primary: SheetAction(title: primaryTitle,
                                             enabled: canConfirm,
                                             action: confirm),
                        dismiss: { if progress == nil { dismiss() } }) {
                historyFolderMenu
                InlineLink(title: rescanning ? "Refreshing…" : "Refresh", size: Typography.Size.caption, action: refresh)
                    .disabled(rescanning)
            }
            .disabled(progress != nil)
        }
        .frame(width: 620)
        .background(Theme.background)
        .interactiveDismissDisabled(progress != nil)
    }

    // MARK: - Pieces

    private var header: some View {
        // The band has a fixed height, so this stays at two short lines.
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(request.addsProject ? "Add \(folderName)" : "Import sessions")
                .font(Typography.title)
                .lineLimit(1)
            Text(request.folder.abbreviatedPath)
                .font(Typography.data)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.xxl)
        .headerBand()
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("No sessions found")
                .font(Typography.body.weight(.semibold))
            Text("Choose a history folder if your sessions are stored elsewhere.")
                .font(Typography.data)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            historyFolderMenu
                .padding(.top, Space.xxs)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.floating).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: Radius.floating)
            .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private var searchField: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find a session", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Find a session")
            if !query.isEmpty {
                GlyphButton(icon: "xmark.circle.fill", side: ControlHeight.lg, tint: .secondary) { query = "" }
                    .accessibilityLabel("Clear search")
            }
        }
        .font(Typography.detail)
        .padding(.leading, Space.lg)
        .padding(.trailing, Space.xs)
        .frame(height: 37)
        .fieldSurface(cornerRadius: Radius.control)
    }

    private var selectionBar: some View {
        HStack(spacing: Space.lg) {
            Text(counted(request.candidates.count, "session"))
                .font(Font.mono(Typography.Size.micro))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            // One link that does whichever is the change: all, or none once all are in.
            let ids = visible.map(\.id)
            let allTicked = !ids.isEmpty && ids.allSatisfy(ticked.contains)
            InlineLink(title: allTicked ? "Select none" : "Select all", size: Typography.Size.caption) {
                if allTicked { ticked.subtract(ids) } else { ticked.formUnion(ids) }
            }
        }
        .padding(.horizontal, Space.xxs)
    }

    private func notice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(Typography.body)
                .foregroundStyle(Theme.deletion)
            Text(message)
                .font(Typography.detail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.lg)
        .surface(Theme.deletion.opacity(0.07), cornerRadius: Radius.card,
                 border: Theme.deletion.opacity(0.25))
    }

    // MARK: - State

    private var folderName: String {
        (request.folder as NSString).lastPathComponent
    }

    private var visible: [ExternalSessionCandidate] {
        let needle = query.trimmed
        guard !needle.isEmpty else { return request.candidates }
        return request.candidates.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(needle)
                || ($0.firstPrompt ?? "").localizedCaseInsensitiveContains(needle)
                || ($0.gitBranch ?? "").localizedCaseInsensitiveContains(needle)
                || $0.agent.title.localizedCaseInsensitiveContains(needle)
        }
    }

    private var chosen: [ExternalSessionCandidate] {
        request.candidates.filter { ticked.contains($0.id) }
    }

    private var canConfirm: Bool {
        progress == nil && !rescanning && (request.addsProject || !ticked.isEmpty)
    }

    private var primaryTitle: String {
        if let progress {
            return "Reading \(min(progress.done + 1, progress.total)) of \(progress.total)…"
        }
        guard request.addsProject else {
            return ticked.isEmpty ? "Import" : "Import \(counted(ticked.count, "session"))"
        }
        return ticked.isEmpty ? "Add project" : "Add with \(counted(ticked.count, "session"))"
    }

    private static func preselected(_ candidates: [ExternalSessionCandidate]) -> Set<String> {
        let cutoff = Date().addingTimeInterval(-Double(preselectDays) * 86_400)
        return Set(candidates.filter { $0.lastActivity >= cutoff }
            .prefix(preselectLimit)
            .map(\.id))
    }

    private func toggle(_ candidate: ExternalSessionCandidate) {
        if ticked.contains(candidate.id) { ticked.remove(candidate.id) } else { ticked.insert(candidate.id) }
    }

    // MARK: - Actions

    private var historyFolderMenu: some View {
        Text("History folders…")
            .font(Typography.caption.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.vertical, Space.sm)
            .contentShape(Rectangle())
            .appMenu {
                AgentKind.allCases.map { agent in
                    MenuEntry.item("\(agent.title)…") { chooseHistoryFolder(for: agent) }
                }
            }
            .disabled(progress != nil || rescanning)
    }

    private func chooseHistoryFolder(for agent: AgentKind) {
        guard let picked = FilePicker.chooseFolder(
            prompt: "Use Folder",
            message: "Pick the folder \(agent.title) keeps its configuration and session history in.",
            directory: FileManager.default.homeDirectoryForCurrentUser) else { return }
        let root = agent == .claudeCode ? ClaudeSessionCatalog.historyFolder(from: picked) : picked
        UserDefaults.standard.set(root.path, forKey: agent == .claudeCode
            ? ClaudeSessionCatalog.chosenRootKey : SessionHistoryCatalog.chosenRootKey(agent))
        request.roots[agent] = root
        refresh()
    }

    private func refresh() {
        rescanning = true
        Task {
            request = await SessionImportRequest.load(folder: request.folder, projectID: request.projectID,
                                                      store: store, roots: request.roots, force: true)
            ticked = Self.preselected(request.candidates)
            rescanning = false
        }
    }

    private func confirm() {
        let picked = chosen
        guard let projectID = request.projectID ?? addProject() else {
            failure = "The folder could not be added as a project."
            return
        }
        request.projectID = projectID
        failure = nil
        progress = Progress(total: max(picked.count, 1))
        Task {
            var failed: [String] = []
            for candidate in picked {
                do {
                    let item: ProjectStore.SessionImport
                    if candidate.agent == .claudeCode {
                        let folder = request.folder
                        let messages = try await Task.detached(priority: .userInitiated) {
                            try ClaudeTranscriptImport.messages(from: candidate.file, projectPath: folder)
                        }.value
                        item = .init(candidate: candidate, messages: messages)
                    } else {
                        let reading = try await AgentHistoryReader.prepare(candidate)
                        item = .init(candidate: candidate, messages: reading.messages, resumeID: reading.resumeID)
                    }
                    _ = try await store.importSession(item, into: projectID).get()
                    request.candidates.removeAll { $0.id == candidate.id }
                    ticked.remove(candidate.id)
                } catch {
                    failed.append("\(candidate.displayTitle): \(error.localizedDescription)")
                }
                progress?.done += 1
            }
            progress = nil
            onFinish(projectID)
            if failed.isEmpty { dismiss() }
            else { failure = failed.joined(separator: "\n") }
        }
    }

    // A folder that is already a project comes back as nil from the store, which has
    // pointed itself at the one it has.
    private func addProject() -> UUID? {
        let url = URL(fileURLWithPath: request.folder, isDirectory: true)
        if let added = store.addProject(at: url) { return added.id }
        return store.projects.first { ClaudeSessionCatalog.standardized($0.path) == request.folder }?.id
    }
}

private struct CandidateRow: View {
    let candidate: ExternalSessionCandidate
    let ticked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: Space.lg) {
            Toggle(isOn: Binding(get: { ticked }, set: { _ in toggle() })) {
                EmptyView()
            }
            .toggleStyle(.appCheckbox)

            Text(candidate.displayTitle)
                .font(Typography.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            MonoChip(text: candidate.agent.title)

            if let branch {
                MonoChip(text: branch)
            }
            Text(SessionAge.phrase(since: candidate.lastActivity))
                .font(Typography.data)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .surface(Theme.card, cornerRadius: Radius.card, border: ticked ? Theme.accent.opacity(0.45) : Theme.border)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .hoverFill(cornerRadius: Radius.card)
        .motion(Motion.control, value: ticked)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(ticked ? .isSelected : [])
    }

    // The branch only says something when it is not the usual one. A folder that is not
    // a checkout reports HEAD.
    private var branch: String? {
        guard let name = candidate.gitBranch, !["HEAD", "main", "master"].contains(name) else { return nil }
        return name
    }
}
