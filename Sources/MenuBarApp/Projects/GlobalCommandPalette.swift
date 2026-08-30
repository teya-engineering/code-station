import Observation
import SwiftUI

@MainActor
@Observable
final class GlobalCommandPaletteController {
    var isPresented = false
    private(set) var newSessionRequest = 0

    func open() {
        isPresented = true
    }

    func close() {
        isPresented = false
    }

    func requestNewSession() {
        newSessionRequest += 1
        close()
    }
}

enum GlobalCommandCategory: String, CaseIterable, Identifiable {
    case all
    case sessions
    case projects
    case actions

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .sessions: "Sessions"
        case .projects: "Projects"
        case .actions: "Actions"
        }
    }
}

enum GlobalCommandGroup: Int, CaseIterable, Comparable {
    case needsYou
    case recent
    case projects
    case actions

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .needsYou: "NEEDS YOU"
        case .recent: "RECENT"
        case .projects: "PROJECTS"
        case .actions: "ACTIONS"
        }
    }
}

enum GlobalCommandDestination: Hashable {
    case session(UUID)
    case project(UUID)
    case workspace(UUID)
    case newSession
    case settings
}

struct GlobalCommandItem: Identifiable, Equatable {
    let destination: GlobalCommandDestination
    let category: GlobalCommandCategory
    let group: GlobalCommandGroup
    let title: String
    let subtitle: String
    var keywords = ""
    var badge: String?
    var needsAttention = false
    var priority = 0
    var activity = Date.distantPast

    var id: GlobalCommandDestination { destination }

    fileprivate var searchableText: String {
        [title, subtitle, keywords].joined(separator: " ").foldedForSearch
    }
}

enum GlobalCommandSearch {
    static func results(in items: [GlobalCommandItem], query: String,
                        category: GlobalCommandCategory) -> [GlobalCommandItem] {
        let words = query.foldedForSearch.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            guard category == .all || item.category == category else { return false }
            return words.allSatisfy(item.searchableText.contains)
        }
        .sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            let leftScore = matchScore(lhs, query: query)
            let rightScore = matchScore(rhs, query: query)
            if leftScore != rightScore { return leftScore < rightScore }
            if lhs.activity != rhs.activity { return lhs.activity > rhs.activity }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func matchScore(_ item: GlobalCommandItem, query: String) -> Int {
        let query = query.foldedForSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return 0 }
        let title = item.title.foldedForSearch
        if title == query { return 0 }
        if title.hasPrefix(query) { return 1 }
        if title.contains(query) { return 2 }
        return 3
    }
}

struct GlobalCommandResultWindow: Equatable {
    let openingPage: Int
    let step: Int
    private(set) var visibleCount: Int

    init(openingPage: Int = 40, step: Int = 40) {
        self.openingPage = max(1, openingPage)
        self.step = max(1, step)
        visibleCount = self.openingPage
    }

    func visibleResults<Element>(in results: [Element]) -> ArraySlice<Element> {
        results.prefix(visibleCount)
    }

    func hasMore(totalCount: Int) -> Bool {
        visibleCount < totalCount
    }

    mutating func loadMore(totalCount: Int) {
        guard hasMore(totalCount: totalCount) else { return }
        visibleCount = min(totalCount, visibleCount + step)
    }

    mutating func reset() {
        visibleCount = openingPage
    }
}

private extension String {
    var foldedForSearch: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

struct GlobalCommandPalette: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(GlobalCommandPaletteController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let openSettings: () -> Void

    @State private var query = ""
    @State private var category = GlobalCommandCategory.all
    @State private var selected: GlobalCommandDestination?
    @State private var resultWindow = GlobalCommandResultWindow()
    @FocusState private var searchFocused: Bool

    private var results: [GlobalCommandItem] {
        GlobalCommandSearch.results(in: items, query: query, category: category)
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            searchBar
            categories
            resultList(results)
            footer
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.settingsBorder))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter Code Station")
        .accessibilityAddTraits(.isModal)
        .task {
            resultWindow.reset()
            selected = results.first?.destination
            await Task.yield()
            searchFocused = true
        }
        .onChange(of: query) { _, _ in resetResults() }
        .onChange(of: category) { _, _ in resetResults() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14),
                   value: resultWindow.visibleResults(in: results).map(\.id))
    }

    private var searchBar: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Filter projects, sessions, and actions", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit { activateSelection() }
                .onExitCommand { controller.close() }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
            Text("ESC")
                .font(.mono(9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .fieldSurface(cornerRadius: 5)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
    }

    private var categories: some View {
        HStack(spacing: 6) {
            ForEach(GlobalCommandCategory.allCases) { option in
                ChoicePill(title: option.title, selected: category == option) {
                    category = option
                    searchFocused = true
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }

    private func resultList(_ results: [GlobalCommandItem]) -> some View {
        let visibleResults = resultWindow.visibleResults(in: results)
        return ScrollViewReader { proxy in
            ScrollView {
                if results.isEmpty {
                    Text("No matching projects, sessions, or actions.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 44)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(GlobalCommandGroup.allCases, id: \.self) { group in
                            let grouped = visibleResults.filter { $0.group == group }
                            if !grouped.isEmpty {
                                Text(group.title)
                                    .font(.mono(9, .semibold))
                                    .kerning(1.1)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)
                                ForEach(grouped) { item in
                                    resultRow(item)
                                        .id(item.id)
                                }
                            }
                        }
                        if resultWindow.hasMore(totalCount: results.count) {
                            Color.clear
                                .frame(height: 1)
                                .id(resultWindow.visibleCount)
                                .onAppear {
                                    resultWindow.loadMore(totalCount: results.count)
                                }
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
            .onChange(of: selected) { _, destination in
                guard let destination else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    proxy.scrollTo(destination, anchor: .center)
                }
            }
        }
    }

    private func resultRow(_ item: GlobalCommandItem) -> some View {
        let isSelected = selected == item.destination
        return Button {
            activate(item)
        } label: {
            HStack(spacing: 10) {
                resultIcon(item)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(item.subtitle)
                        .font(.mono(9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let badge = item.badge {
                    Text(badge)
                        .font(.mono(9, .semibold))
                        .foregroundStyle(item.needsAttention ? Theme.attentionText : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(
                            item.needsAttention ? Theme.attention.opacity(0.12) : Theme.field))
                }
                if item.activity != .distantPast {
                    Text(RelativeTime.short(item.activity))
                        .font(.mono(9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Theme.accent.opacity(0.08) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering in
            if hovering { selected = item.destination }
        }
    }

    @ViewBuilder private func resultIcon(_ item: GlobalCommandItem) -> some View {
        switch item.destination {
        case .project(let id):
            if let project = store.project(id) {
                SidebarIdentityTile(avatar: project.sidebarAvatar,
                                    name: project.name,
                                    tint: Theme.projectTint(for: project.name),
                                    dashed: project.kind == .adHoc,
                                    side: 32)
            }
        case .workspace(let id):
            if let workspace = store.workspace(id) {
                SidebarIdentityTile(avatar: workspace.sidebarAvatar,
                                    name: workspace.name,
                                    tint: Theme.workspaceTint,
                                    stacked: true,
                                    side: 32)
            }
        case .session(let id):
            if let session = store.sidebarSession(id) ?? store.session(id),
               let workspace = session.workspaceID.flatMap(store.workspace) {
                SidebarIdentityTile(avatar: workspace.sidebarAvatar,
                                    name: workspace.name,
                                    tint: Theme.workspaceTint,
                                    stacked: true,
                                    side: 32)
            } else if let session = store.sidebarSession(id) ?? store.session(id),
                      let project = store.project(session.projectID) {
                SidebarIdentityTile(avatar: project.sidebarAvatar,
                                    name: project.name,
                                    tint: Theme.projectTint(for: project.name),
                                    dashed: project.kind == .adHoc,
                                    side: 32)
            }
        case .newSession:
            paletteSymbol("plus", tint: Theme.accent)
        case .settings:
            paletteSymbol("gearshape.fill", tint: Theme.accent)
        }
    }

    private func paletteSymbol(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
    }

    private var footer: some View {
        HStack(spacing: 16) {
            keyHint("↑↓", "move")
            keyHint("↵", "open")
            keyHint("esc", "close")
            Spacer(minLength: 0)
            Text("⌘K from anywhere")
        }
        .font(.mono(9))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .frame(height: 37)
        .background(Theme.field)
        .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .frame(height: 19)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
            Text(label)
        }
    }

    private func resetResults() {
        resultWindow.reset()
        selected = results.first?.destination
    }

    private func moveSelection(by offset: Int) {
        let results = results
        let visibleResults = resultWindow.visibleResults(in: results)
        guard !visibleResults.isEmpty else { return }
        let index = selected.flatMap { destination in
            visibleResults.firstIndex { $0.destination == destination }
        } ?? (offset > 0 ? -1 : 0)
        if offset > 0,
           index == visibleResults.count - 1,
           resultWindow.hasMore(totalCount: results.count) {
            resultWindow.loadMore(totalCount: results.count)
            selected = results[index + 1].destination
            return
        }
        selected = visibleResults[
            (index + offset + visibleResults.count) % visibleResults.count
        ].destination
    }

    private func activateSelection() {
        guard let selected,
              let item = results.first(where: { $0.destination == selected }) else { return }
        activate(item)
    }

    private func activate(_ item: GlobalCommandItem) {
        controller.close()
        switch item.destination {
        case .session(let id):
            store.selectSession(id)
        case .project(let id):
            store.selectProject(id, revealingInSidebar: true)
        case .workspace(let id):
            store.selectWorkspace(id)
        case .newSession:
            controller.requestNewSession()
        case .settings:
            openSettings()
        }
    }

    private var items: [GlobalCommandItem] {
        var found: [GlobalCommandItem] = []
        let selectedSessionID: UUID? = switch store.selection {
        case .session(let id): id
        case .home, .workspace, nil: nil
        }

        for session in store.sidebarSessions.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            let project = store.project(session.projectID)
            let workspace = session.workspaceID.flatMap(store.workspace)
            let container = workspace?.name ?? project?.name ?? "Missing project"
            let question = runner.question(session.id)
            let finished = store.hasFinished(session.id)
            let busy = runner.state(session.id).isBusy
            let needsAttention = question != nil || finished
            let badge: String? = if question != nil {
                "ANSWER"
            } else if finished {
                "REVIEW"
            } else if busy {
                "RUNNING"
            } else {
                nil
            }
            let activity = SessionActivity.line(for: session, store: store, runner: runner)
            found.append(GlobalCommandItem(
                destination: .session(session.id),
                category: .sessions,
                group: needsAttention ? .needsYou : .recent,
                title: session.title,
                subtitle: "\(container) · \(activity)",
                keywords: [project?.path, workspace?.name, session.isTroubleshooting ? "troubleshoot" : nil]
                    .compactMap { $0 }.joined(separator: " "),
                badge: badge,
                needsAttention: needsAttention,
                priority: needsAttention ? 0 : (session.id == selectedSessionID ? 1 : 2),
                activity: session.lastActivity))
        }

        for workspace in store.workspaces {
            let names = workspace.projectIDs.compactMap(store.project).map(\.name)
            found.append(GlobalCommandItem(
                destination: .workspace(workspace.id),
                category: .projects,
                group: .projects,
                title: workspace.name,
                subtitle: "Workspace · \(counted(workspace.projectIDs.count, "project"))",
                keywords: names.joined(separator: " "),
                badge: "WORKSPACE",
                priority: 3))
        }

        for project in store.projects {
            let sessions = store.sidebarSessions.count { $0.projectID == project.id }
            found.append(GlobalCommandItem(
                destination: .project(project.id),
                category: .projects,
                group: .projects,
                title: project.name,
                subtitle: "\(project.kind == .adHoc ? "Task" : "Project") · \(counted(sessions, "session"))",
                keywords: project.path,
                badge: project.kind == .adHoc ? "TASK" : "PROJECT",
                priority: 3))
        }

        found.append(GlobalCommandItem(
            destination: .newSession,
            category: .actions,
            group: .actions,
            title: "New session",
            subtitle: "Start in the selected project or workspace",
            keywords: "add start command n",
            badge: "⌘N",
            priority: 5))
        found.append(GlobalCommandItem(
            destination: .settings,
            category: .actions,
            group: .actions,
            title: "Open Settings",
            subtitle: "Agents, appearance, projects, and integrations",
            keywords: "preferences configure command comma",
            badge: "⌘,",
            priority: 5))
        return found
    }
}
