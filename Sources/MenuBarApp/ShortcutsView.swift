import SwiftUI

// Every saved command in one place, grouped by whose it is: the Mac's own first, then
// each project's. A project's shortcuts are managed here rather than in its sessions
// because this is the list you come to when you want to see all of them at once; the
// strip inside a session is for running them, not for keeping them.
//
// A run started here uses the shortcut's own folder - home, or the project checkout -
// since a sheet has no session in front of it to borrow a worktree from.
struct ShortcutsView: View {
    @Environment(ShortcutStore.self) private var store
    @Environment(ProjectStore.self) private var projects
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: CommandShortcut.ID?
    @State private var editor: ShortcutEditorRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            SheetFooter { dismiss() }
        }
        .frame(width: 700, height: 620)
        .background(Theme.background)
        .onAppear { selectAvailableShortcut() }
        .onChange(of: store.shortcuts.map(\.id)) { _, _ in selectAvailableShortcut() }
        .sheet(item: $editor) { request in
            ShortcutEditorView(request: request) { shortcut in
                if request.shortcut == nil {
                    if let id = store.add(name: shortcut.name, command: shortcut.command,
                                          projectID: shortcut.projectID,
                                          location: shortcut.location) {
                        selectedID = id
                    }
                } else {
                    store.update(shortcut)
                    selectedID = shortcut.id
                }
            }
            .appOverlays()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Shortcuts").font(.serif(18))
            Text(headerDetail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button { editor = ShortcutEditorRequest() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("Add shortcut")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentFill))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private var headerDetail: String {
        let saved = "\(store.shortcuts.count) saved"
        return store.runningCount > 0 ? "\(saved) · \(store.runningCount) running" : saved
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let error = store.loadError ?? store.saveError {
                errorBanner(error)
            }
            shortcutList
            Divider().overlay(Theme.hairline)
            output
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - The list

    // One section per owner. A project with no shortcuts is left out entirely, so the
    // list is as long as what has been saved rather than as long as the sidebar.
    private struct Group: Identifiable {
        let id: UUID?
        let title: String
        let project: Project?
        let shortcuts: [CommandShortcut]
    }

    private var groups: [Group] {
        var groups: [Group] = []
        let mac = store.macShortcuts
        if !mac.isEmpty {
            groups.append(Group(id: nil, title: "THIS MAC", project: nil, shortcuts: mac))
        }
        for project in projects.projects {
            let owned = store.shortcuts(for: project.id)
            guard !owned.isEmpty else { continue }
            groups.append(Group(id: project.id, title: project.name.uppercased(),
                                project: project, shortcuts: owned))
        }
        // Shortcuts whose project has since been removed would otherwise vanish from the
        // only screen that can delete them.
        let orphaned = store.shortcuts.filter { shortcut in
            guard let projectID = shortcut.projectID else { return false }
            return projects.project(projectID) == nil
        }
        if !orphaned.isEmpty {
            groups.append(Group(id: UUID(), title: "PROJECT NO LONGER ADDED",
                                project: nil, shortcuts: orphaned))
        }
        return groups
    }

    @ViewBuilder private var shortcutList: some View {
        if store.shortcuts.isEmpty {
            PaneMessage(
                icon: "bolt.slash",
                title: "No shortcuts saved",
                detail: "Add a shell command you want to run without leaving the app."
            )
            .frame(height: 220)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            groupHeading(group)
                            ForEach(group.shortcuts) { shortcut in
                                row(shortcut, in: group)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .frame(height: 280)
        }
    }

    private func groupHeading(_ group: Group) -> some View {
        HStack(spacing: 7) {
            if let project = group.project {
                ProjectDot(tint: Theme.projectTint(for: project.name))
            }
            SectionLabel(text: group.title)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
    }

    private func row(_ shortcut: CommandShortcut, in group: Group) -> some View {
        let run = self.run(for: shortcut, in: group.project)
        return ShortcutRow(
            shortcut: shortcut,
            state: store.state(run),
            selected: selectedID == shortcut.id,
            select: { selectedID = shortcut.id },
            run: { toggle(shortcut, in: group.project) },
            edit: { editor = ShortcutEditorRequest(shortcut: shortcut) },
            remove: { confirmRemoval(of: shortcut, in: group.project) }
        )
        .appContextMenu { contextMenu(for: shortcut, in: group.project) }
    }

    // MARK: - Output

    private var output: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                SectionLabel(text: "OUTPUT")
                if let selected {
                    Text(selected.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if let selectedRun, !store.log(selectedRun).isEmpty {
                    Button { store.clearLog(selectedRun) } label: {
                        Text("Clear")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollViewReader { scroller in
                ScrollView {
                    Text(outputText)
                        .font(.mono(10.5))
                        .foregroundStyle(outputIsPlaceholder ? AnyShapeStyle(.secondary)
                                                             : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id(Self.outputBottom)
                }
                .onChange(of: selectedLog) { _, _ in
                    scroller.scrollTo(Self.outputBottom, anchor: .bottom)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var selected: CommandShortcut? {
        selectedID.flatMap(store.shortcut)
    }

    private var selectedRun: ShortcutRun? {
        selected.map { run(for: $0, in: $0.projectID.flatMap(projects.project)) }
    }

    private var selectedLog: String {
        selectedRun.map(store.log) ?? ""
    }

    private var outputText: String {
        guard let selectedRun else { return "Select a shortcut to see its output." }
        let log = store.log(selectedRun)
        if !log.isEmpty { return log }
        switch store.state(selectedRun) {
        case .stopped: return "Run this shortcut to see its output."
        case .running: return "Waiting for output…"
        case .finished: return "Finished without output."
        case .failed(let message, _, _): return message
        }
    }

    private var outputIsPlaceholder: Bool {
        guard let selectedRun else { return true }
        return store.log(selectedRun).isEmpty
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(Theme.deletion)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(Theme.deletion.opacity(0.08))
    }

    // MARK: - Actions

    private func run(for shortcut: CommandShortcut, in project: Project?) -> ShortcutRun {
        ShortcutRun(shortcut.id, in: shortcut.directory(projectPath: project?.path))
    }

    private func toggle(_ shortcut: CommandShortcut, in project: Project?) {
        selectedID = shortcut.id
        let run = run(for: shortcut, in: project)
        if store.state(run).isActive {
            store.stop(run)
        } else {
            store.start(run)
        }
    }

    private func selectAvailableShortcut() {
        if selected == nil { selectedID = store.shortcuts.first?.id }
    }

    private func contextMenu(for shortcut: CommandShortcut, in project: Project?) -> [MenuEntry] {
        if store.state(run(for: shortcut, in: project)).isActive {
            return [
                .item("Stop", action: { toggle(shortcut, in: project) }),
                .separator,
                .item("Remove", kind: .destructive,
                      action: { confirmRemoval(of: shortcut, in: project) })
            ]
        }
        return [
            .item("Run", action: { toggle(shortcut, in: project) }),
            .item("Edit", action: { editor = ShortcutEditorRequest(shortcut: shortcut) }),
            .separator,
            .item("Remove", kind: .destructive,
                  action: { confirmRemoval(of: shortcut, in: project) })
        ]
    }

    private func confirmRemoval(of shortcut: CommandShortcut, in project: Project?) {
        let running = store.isRunningAnywhere(shortcut.id)
        dialogs.show(Dialog(
            title: "Remove \(shortcut.name)?",
            message: running
                ? "This stops the running command and removes the shortcut."
                : "The command and its saved shortcut will be removed.",
            actions: [
                Dialog.Action(label: "Remove", kind: .destructive) {
                    store.remove(shortcut.id)
                },
                Dialog.Action(label: "Cancel", kind: .cancel)
            ]
        ))
    }

    private static let outputBottom = "shortcut-output-bottom"
}

private struct ShortcutRow: View {
    let shortcut: CommandShortcut
    let state: ShortcutStore.State
    let selected: Bool
    let select: () -> Void
    let run: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColour)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(shortcut.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let badge = shortcut.location.badge {
                        MonoChip(text: badge, size: 9)
                    }
                }
                Text(commandSummary)
                    .font(.mono(10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            iconButton("pencil", label: "Edit \(shortcut.name)", action: edit)
                .disabled(state.isActive)
                .opacity(state.isActive ? 0.35 : 1)
            iconButton("trash", label: "Remove \(shortcut.name)", colour: Theme.deletion,
                       action: remove)
            runButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(selected ? Theme.accent.opacity(0.06) : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? Theme.accent.opacity(0.5) : Theme.border))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: select)
    }

    private var commandSummary: String {
        shortcut.command.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private var statusText: String {
        switch state {
        case .stopped: "Not running"
        case .running: "Running"
        case .finished: "Finished"
        case .failed(let message, _, _): "Failed: \(message)"
        }
    }

    private var statusColour: Color {
        switch state {
        case .stopped, .finished: Theme.dotOff
        case .running: Theme.dotOn
        case .failed: Theme.deletion
        }
    }

    private func iconButton(_ icon: String, label: String, colour: Color = Theme.accent,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(colour)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .appTooltip(label)
    }

    private var runButton: some View {
        Button(action: run) {
            Text(state.isActive ? "Stop" : "Run")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(state.isActive ? Theme.deletion : Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(state.isActive ? Theme.field : Color.black.opacity(0.88)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(state.isActive ? Theme.border : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
