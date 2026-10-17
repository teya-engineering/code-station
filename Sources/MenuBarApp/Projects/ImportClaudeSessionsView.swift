import SwiftUI

// What the import sheet opens with: the folder, the project it belongs to when there is
// one already, and the sessions found for it. The list is read before the sheet goes up,
// for the same reason OldSessionsView takes its rows in its init: a sheet is measured on
// its first pass.
struct ClaudeImportRequest: Identifiable {
    let id = UUID()
    let folder: String
    // Nil while the folder is still on its way to becoming a project. The project is only
    // added once the sheet is confirmed, so cancelling leaves nothing behind.
    let projectID: UUID?
    let known: Set<String>
    var root: URL
    var candidates: [ClaudeSessionCandidate]

    var addsProject: Bool { projectID == nil }

    @MainActor
    static func load(folder: String, projectID: UUID?, store: ProjectStore,
                     root: URL = ClaudeSessionCatalog.defaultRoot()) async -> ClaudeImportRequest {
        let folder = ClaudeSessionCatalog.standardized(folder)
        let known = projectID.map(store.knownClaudeSessionIDs(inProject:))
            ?? Set(store.sessions.compactMap(\.claudeSessionID))
        let candidates = await scan(folder: folder, known: known, root: root)
        return ClaudeImportRequest(folder: folder, projectID: projectID, known: known,
                                   root: root, candidates: candidates)
    }

    // Reading the history touches every file in it, so it never runs on the main thread.
    static func scan(folder: String, known: Set<String>, root: URL) async -> [ClaudeSessionCandidate] {
        await Task.detached(priority: .userInitiated) {
            ClaudeSessionCatalog.sessions(in: folder, excluding: known, root: root)
        }.value
    }
}

// The sessions Claude Code ran in one folder, offered for the app to carry on. Each ticked
// one becomes a session that resumes its conversation; the file Claude Code wrote stays
// as it was, so the same conversation can still be picked up from the terminal.
struct ImportClaudeSessionsView: View {
    // Called once the sessions are in, with the project they landed in.
    let onFinish: (UUID) -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var request: ClaudeImportRequest
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

    init(request: ClaudeImportRequest, onFinish: @escaping (UUID) -> Void) {
        self.onFinish = onFinish
        _request = State(initialValue: request)
        _ticked = State(initialValue: Self.preselected(request.candidates))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
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
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        }
                    }
                    if let failure { notice(failure) }
                }
                .padding(20)
            }
            .frame(maxHeight: 420)

            SheetFooter(primary: SheetAction(title: primaryTitle,
                                             enabled: canConfirm,
                                             action: confirm),
                        dismiss: { if progress == nil { dismiss() } }) {
                if !request.candidates.isEmpty {
                    InlineLink(title: "Change folder…", size: 11, action: chooseHistoryFolder)
                        .disabled(progress != nil)
                }
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
        VStack(alignment: .leading, spacing: 3) {
            Text(request.addsProject ? "Add \(folderName)" : "Claude Code sessions")
                .font(.serif(16))
                .lineLimit(1)
            Text(request.folder.abbreviatedPath)
                .font(.mono(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .headerBand()
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No sessions found")
                .font(.system(size: 14, weight: .semibold))
            Text("Searched \(request.root.path.abbreviatedPath)")
                .font(.mono(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            ActionButton(title: rescanning ? "Searching…" : "Choose folder…",
                         tone: .outlined, icon: "folder") {
                chooseHistoryFolder()
            }
            .disabled(rescanning)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find a session", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Find a session")
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
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text(counted(request.candidates.count, "session"))
                .font(.mono(10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            // One link that does whichever is the change: all, or none once all are in.
            let ids = visible.map(\.id)
            let allTicked = !ids.isEmpty && ids.allSatisfy(ticked.contains)
            InlineLink(title: allTicked ? "Select none" : "Select all", size: 11) {
                if allTicked { ticked.subtract(ids) } else { ticked.formUnion(ids) }
            }
        }
        .padding(.horizontal, 2)
    }

    private func notice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.deletion)
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .surface(Theme.deletion.opacity(0.07), cornerRadius: 10,
                 border: Theme.deletion.opacity(0.25))
    }

    // MARK: - State

    private var folderName: String {
        (request.folder as NSString).lastPathComponent
    }

    private var visible: [ClaudeSessionCandidate] {
        let needle = query.trimmed
        guard !needle.isEmpty else { return request.candidates }
        return request.candidates.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(needle)
                || ($0.firstPrompt ?? "").localizedCaseInsensitiveContains(needle)
                || ($0.gitBranch ?? "").localizedCaseInsensitiveContains(needle)
        }
    }

    private var chosen: [ClaudeSessionCandidate] {
        request.candidates.filter { ticked.contains($0.id) }
    }

    private var canConfirm: Bool {
        progress == nil && (request.addsProject || !ticked.isEmpty)
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

    private static func preselected(_ candidates: [ClaudeSessionCandidate]) -> Set<String> {
        let cutoff = Date().addingTimeInterval(-Double(preselectDays) * 86_400)
        return Set(candidates.filter { $0.lastActivity >= cutoff }
            .prefix(preselectLimit)
            .map(\.id))
    }

    private func toggle(_ candidate: ClaudeSessionCandidate) {
        if ticked.contains(candidate.id) { ticked.remove(candidate.id) } else { ticked.insert(candidate.id) }
    }

    // MARK: - Actions

    private func chooseHistoryFolder() {
        guard let picked = FilePicker.chooseFolder(
            prompt: "Use Folder",
            message: "Pick the folder Claude Code keeps its sessions in: .claude, or the projects folder inside it.",
            directory: FileManager.default.homeDirectoryForCurrentUser) else { return }
        let root = ClaudeSessionCatalog.historyFolder(from: picked)
        UserDefaults.standard.set(root.path, forKey: ClaudeSessionCatalog.chosenRootKey)
        rescanning = true
        Task {
            let found = await ClaudeImportRequest.scan(folder: request.folder, known: request.known, root: root)
            request.root = root
            request.candidates = found
            ticked = Self.preselected(found)
            rescanning = false
        }
    }

    private func confirm() {
        let picked = chosen
        failure = nil
        progress = Progress(total: max(picked.count, 1))
        Task {
            var imports: [ProjectStore.ClaudeSessionImport] = []
            var unreadable: [String] = []
            for candidate in picked {
                do {
                    let folder = request.folder
                    let messages = try await Task.detached(priority: .userInitiated) {
                        try ClaudeTranscriptImport.messages(from: candidate.file, projectPath: folder)
                    }.value
                    imports.append(.init(candidate: candidate, messages: messages))
                } catch {
                    unreadable.append(candidate.displayTitle)
                }
                progress?.done += 1
            }
            finish(imports, unreadable: unreadable)
        }
    }

    private func finish(_ imports: [ProjectStore.ClaudeSessionImport], unreadable: [String]) {
        guard let projectID = request.projectID ?? addProject() else {
            progress = nil
            failure = "The folder could not be added as a project."
            return
        }
        switch store.importClaudeSessions(imports, into: projectID) {
        case .success:
            progress = nil
            if unreadable.isEmpty {
                onFinish(projectID)
                dismiss()
            } else {
                // What did arrive stays; the sheet stays up to say what did not.
                request.candidates.removeAll { candidate in imports.contains { $0.candidate.id == candidate.id } }
                ticked = Set(request.candidates.filter { ticked.contains($0.id) }.map(\.id))
                failure = "Could not read \(unreadable.joined(separator: ", ")). The others were imported."
                onFinish(projectID)
            }
        case .failure(let error):
            progress = nil
            failure = error.message
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
    let candidate: ClaudeSessionCandidate
    let ticked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { ticked }, set: { _ in toggle() })) {
                EmptyView()
            }
            .toggleStyle(.appCheckbox)

            Text(candidate.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let branch {
                MonoChip(text: branch)
            }
            Text(SessionAge.phrase(since: candidate.lastActivity))
                .font(.mono(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .surface(Theme.card, cornerRadius: 10, border: ticked ? Theme.accent.opacity(0.45) : Theme.border)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
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
