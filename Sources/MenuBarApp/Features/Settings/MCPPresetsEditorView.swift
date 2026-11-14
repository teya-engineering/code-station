import AppKit
import SwiftUI

// The sheet for the site's MCP presets. A team can carry many presets, so they are a
// list on the left with one open editor on the right, grouped the way the add menu
// groups them. The dark line at the top of the editor shows what a preset will start or
// reach, so the effect of adding it is visible before anyone does.
struct MCPPresetsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onSave: (SiteDefaults) -> Void

    @State private var defaults: SiteDefaults
    @State private var drafts: [MCPPresetDraft]
    @State private var saved: [MCPPresetDraft]
    @State private var selection: UUID?
    @State private var query = ""
    @State private var failure: String?
    @State private var note: String?
    @State private var notes = 0
    @State private var fileActOuts = 0
    @FocusState private var focus: PresetFocus?
    @Namespace private var transportTrack

    init(defaults: SiteDefaults, onSave: @escaping (SiteDefaults) -> Void) {
        self.onSave = onSave
        let drafts = defaults.mcpPresets.map(MCPPresetDraft.init)
        _defaults = State(initialValue: defaults)
        _drafts = State(initialValue: drafts)
        _saved = State(initialValue: drafts)
        _selection = State(initialValue: drafts.first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 300)
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                editorPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            SheetFooter(primary: SheetAction(title: "Save changes", enabled: canSave,
                                             shortcut: KeyboardShortcut("s", modifiers: .command),
                                             action: save),
                        dismissTone: .outlined,
                        dismiss: { dismiss() }) {
                status
            }
        }
        .frame(width: 940, height: 660)
        .background(Theme.background)
        .overlay(alignment: .topTrailing) {
            ZStack {
                if let note {
                    HeaderNote(icon: "folder", text: note)
                        .padding(.top, Theme.headerHeight + 2).padding(.trailing, Space.xxl)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                }
            }
            .motion(Motion.reveal, value: note)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("MCP presets").font(Typography.title)
                Text("Ready-made servers people add with one click. Values set to *Ask* are filled in at that moment.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            fileChip
        }
        .padding(.horizontal, Space.xxl)
        .headerBand()
    }

    private var fileChip: some View {
        Button {
            fileActOuts += 1
            revealFile()
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "folder")
                    .font(Typography.caption.weight(.semibold))
                    .actOut("folder", trigger: fileActOuts)
                Text(SiteConfigurationImporter.destination.path.abbreviatedPath)
                    .font(Typography.data)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240)
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, Space.md)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.control)
        .hoverLift()
        .accessibilityLabel("Show the configuration file in Finder")
    }

    // Finder opens outside the window, so nothing in the sheet moves. The note is the
    // only trace the click leaves.
    private func revealFile() {
        let file = SiteConfigurationImporter.destination
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(file.deletingLastPathComponent())
        }
        notes += 1
        let shown = notes
        note = "Shown in Finder"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            if notes == shown { note = nil }
        }
    }

    // MARK: - List

    private var visible: [MCPPresetDraft] { drafts.filter { $0.matches(query) } }

    private var sidebar: some View {
        VStack(spacing: 0) {
            search
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.md)
            ScrollView {
                list
                    .padding(.horizontal, Space.md)
                    .padding(.bottom, Space.md)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            NewItemButton(title: "New preset", action: addPreset)
                .padding(Space.lg)
        }
        .background(Theme.sidebar)
    }

    private var search: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(Typography.label)
                .foregroundStyle(Theme.secondaryText)
            TextField("Find a preset", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.body)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .transition(.fadeIn)
            }
        }
        .padding(.horizontal, Space.md)
        .frame(height: 32)
        .surface(Theme.card, cornerRadius: Radius.card)
        .motion(Motion.hover, value: query.isEmpty)
    }

    @ViewBuilder private var list: some View {
        let groups = MCPPresetDraft.groups(visible)
        VStack(alignment: .leading, spacing: Space.lg) {
            if drafts.isEmpty {
                listMessage("No presets yet",
                            detail: "Make one so people can add a server without copying settings by hand.")
            } else if groups.isEmpty {
                VStack(spacing: Space.md) {
                    listMessage("Nothing matches", detail: "No preset is called “\(query.trimmed)”.")
                    InlineLink(title: "Clear search") { query = "" }
                }
                .frame(maxWidth: .infinity)
            } else {
                ForEach(groups, id: \.serverType) { group in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        groupHeader(group.serverType, count: group.drafts.count)
                        ForEach(group.drafts) { draft in
                            row(draft).transition(.fold)
                        }
                    }
                    .transition(.fadeIn)
                }
            }
        }
        .padding(.top, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Presets")
        .smoothlyResizes(when: groups.map { $0.drafts.map(\.id) })
    }

    private func listMessage(_ title: String, detail: String) -> some View {
        VStack(spacing: Space.xs) {
            Text(title).font(Typography.body.weight(.semibold))
            Text(detail)
                .font(Typography.detail)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.xxxl)
        .transition(.fadeIn)
    }

    private func groupHeader(_ serverType: String?, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(serverType ?? "No server type")
                    .font(Typography.label)
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(Typography.detail.weight(.medium).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .contentTransition(.numericText())
                    .motion(Motion.reveal, value: count)
            }
            Text("In the menu as “\(SiteDefaults.MCP.PresetGroup(serverType: serverType, presets: []).addTitle)”")
                .font(Typography.detail)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ draft: MCPPresetDraft) -> some View {
        let selected = draft.id == selection
        let dirty = isDirty(draft)
        let environment = defaults.deployEnvironment(named: draft.environment)
        return Button { select(draft.id) } label: {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(draft.title.trimmed.isEmpty ? "Untitled preset" : draft.title)
                        .font(Typography.body.weight(.medium))
                        .foregroundStyle(draft.title.trimmed.isEmpty ? Theme.secondaryText : Color.primary)
                        .lineLimit(1)
                    Text(draft.name.isEmpty ? "no name" : draft.name)
                        .font(Typography.data)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if dirty {
                    Circle()
                        .fill(Theme.attention)
                        .frame(width: 6, height: 6)
                        .transition(popTransition)
                        .accessibilityLabel("Unsaved changes")
                }
                if !draft.environment.isEmpty {
                    EnvironmentTag(name: draft.environment,
                                   live: environment?.isDangerous == true)
                        .transition(popTransition)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Radius.control)
                        .fill(Theme.card)
                        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.border))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill()
        .accessibilityAddTraits(selected ? .isSelected : [])
        .motion(Motion.control, value: selected)
        .motion(Motion.pop, value: dirty)
        .motion(Motion.pop, value: draft.environment.isEmpty)
    }

    // A mark landing grows from just over half its size, never from nothing, and goes
    // on the quicker leaving curve.
    private var popTransition: AnyTransition {
        .asymmetric(insertion: reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: HeaderMotion.seed)),
                    removal: .opacity.animation(Motion.leave))
    }

    private func select(_ id: UUID) {
        guard id != selection else { return }
        selection = id
    }

    // MARK: - Editor

    @ViewBuilder private var editorPane: some View {
        ZStack {
            if let selection, drafts.contains(where: { $0.id == selection }) {
                ScrollView {
                    editor(binding(selection))
                        .padding(.horizontal, Space.xxxl)
                        .padding(.vertical, Space.xxl)
                }
                .id(selection)
                .transition(paneTransition)
            } else {
                noSelection.transition(paneTransition)
            }
        }
    }

    // The old editor goes at once and only the new one moves in, so two heavy panes are
    // never drawn over each other.
    private var paneTransition: AnyTransition {
        let insertion: AnyTransition = reduceMotion
            ? .opacity.animation(Motion.reveal)
            : .opacity.combined(with: .offset(y: HeaderMotion.popoverLift)).animation(Motion.reveal)
        return .asymmetric(insertion: insertion, removal: .identity)
    }

    private var noSelection: some View {
        VStack(spacing: Space.sm) {
            Text(drafts.isEmpty ? "No presets yet" : "Pick a preset to edit").font(Typography.title)
            Text("Or make a new one for a server your team uses.")
                .font(Typography.body)
                .foregroundStyle(Theme.secondaryText)
            NewItemButton(title: "New preset", filled: true, action: addPreset)
                .padding(.top, Space.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func editor(_ draft: Binding<MCPPresetDraft>) -> some View {
        let value = draft.wrappedValue
        let problems = value.problems(among: drafts)
        return VStack(alignment: .leading, spacing: Space.xxl) {
            editorHeading(value)
            RunsAsPanel(draft: value)
            identity(draft, problems: problems)
            connection(draft, problems: problems)
            EntriesTable(draft: draft, problem: problems.values, focus: $focus)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func editorHeading(_ draft: MCPPresetDraft) -> some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(draft.title.trimmed.isEmpty ? "Untitled preset" : draft.title)
                    .font(Typography.title)
                    .lineLimit(2)
                Text(LocalizedStringKey(askLine(draft.askedCount)))
                    .font(Typography.body)
                    .foregroundStyle(Theme.secondaryText)
                    .contentTransition(.opacity)
                    .motion(Motion.reveal, value: draft.askedCount)
            }
            Spacer(minLength: 0)
            GlyphLink(icon: "trash", title: "Delete preset", tint: Theme.deletion) {
                confirmDelete(draft)
            }
        }
    }

    private func askLine(_ count: Int) -> String {
        count == 0
            ? "Adds without asking for anything."
            : "Asks for **\(counted(count, "value"))** when someone adds it."
    }

    private func identity(_ draft: Binding<MCPPresetDraft>,
                          problems: MCPPresetDraft.Problems) -> some View {
        let value = draft.wrappedValue
        let environment = defaults.deployEnvironment(named: value.environment)
        return VStack(alignment: .leading, spacing: Space.lg) {
            sectionHeading("Identity")
            HStack(alignment: .top, spacing: Space.xl) {
                PresetField(caption: "Label", note: problems.title ?? "What people pick from the menu.",
                            isError: problems.title != nil) {
                    PresetTextField(placeholder: "Grafana platform dev", text: draft.title,
                                    invalid: problems.title != nil, monospaced: false)
                        .focused($focus, equals: .label)
                }
                PresetField(caption: "Name", note: problems.name ?? nameNote(value),
                            isError: problems.name != nil) {
                    nameField(draft, invalid: problems.name != nil)
                }
            }
            HStack(alignment: .top, spacing: Space.xl) {
                PresetField(caption: "Server type", note: serverTypeNote(value), isError: false) {
                    PresetTextField(placeholder: "None", text: draft.serverType, monospaced: false)
                }
                PresetField(caption: "Environment",
                            note: environment?.isDangerous == true
                                ? "A live environment. Sessions there keep every check read-only."
                                : "Fills in {{env}} and sets the tag.",
                            isError: false,
                            noteTint: environment?.isDangerous == true ? Theme.attentionText : nil) {
                    OptionMenu(value: value.environment.isEmpty ? "Any environment" : value.environment) {
                        environmentEntries(draft)
                    }
                    .accessibilityLabel("Environment")
                }
            }
        }
    }

    private func nameNote(_ draft: MCPPresetDraft) -> String {
        draft.usesAutoName
            ? "Made from the server type and label. Click Auto to type your own."
            : "The key in the configuration file."
    }

    private func serverTypeNote(_ draft: MCPPresetDraft) -> String {
        let type = draft.serverType.trimmed
        return type.isEmpty
            ? "Leave empty to list it under “Add from preset”."
            : "Groups it under “Add \(type) MCP server”."
    }

    private func nameField(_ draft: Binding<MCPPresetDraft>, invalid: Bool) -> some View {
        let auto = draft.wrappedValue.usesAutoName
        return HStack(spacing: Space.sm) {
            if auto {
                Text(draft.wrappedValue.name.isEmpty ? "made from the label" : draft.wrappedValue.name)
                    .font(Typography.code)
                    .foregroundStyle(draft.wrappedValue.name.isEmpty ? Theme.secondaryText : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                TextField("service-environment", text: draft.customName)
                    .textFieldStyle(.plain)
                    .font(Typography.code)
                    .focused($focus, equals: .name)
            }
            Button {
                if auto {
                    draft.wrappedValue.customName = draft.wrappedValue.name
                    draft.wrappedValue.usesAutoName = false
                    focus = .name
                } else {
                    draft.wrappedValue.usesAutoName = true
                }
            } label: {
                Text(auto ? "Auto" : "Custom")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(auto ? Theme.accent : Theme.secondaryText)
                    .contentTransition(.opacity)
                    .padding(.horizontal, Space.md)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: Radius.inset)
                        .fill(auto ? Theme.accent.opacity(0.1) : Theme.sunken))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .motion(Motion.control, value: auto)
            .accessibilityLabel(auto ? "Name made from the label" : "Custom name")
            .accessibilityHint(auto ? "Type your own name" : "Make the name from the label again")
        }
        .padding(.leading, Space.lg)
        .padding(.trailing, Space.sm)
        .frame(height: ControlHeight.lg)
        .surface(Theme.field, cornerRadius: Radius.card, border: invalid ? Theme.deletion : Theme.border)
        .motion(Motion.hover, value: invalid)
    }

    private func environmentEntries(_ draft: Binding<MCPPresetDraft>) -> [MenuEntry] {
        let current = draft.wrappedValue.environment
        var environments = defaults.deployEnvironments
        if !current.isEmpty, !environments.contains(where: { $0.name == current }) {
            environments.append(SiteDefaults.Environment(name: current))
        }
        let any: MenuEntry = .item("Any environment", checked: current.isEmpty) {
            draft.wrappedValue.environment = ""
        }
        return [any] + environments.map { environment in
            .item(environment.name,
                  checked: environment.name == current,
                  badge: environment.isDangerous ? "Live" : nil,
                  badgeTint: environment.isDangerous ? Theme.attention : nil) {
                draft.wrappedValue.environment = environment.name
            }
        }
    }

    private func connection(_ draft: Binding<MCPPresetDraft>,
                            problems: MCPPresetDraft.Problems) -> some View {
        let transport = draft.wrappedValue.transport
        return VStack(alignment: .leading, spacing: Space.lg) {
            sectionHeading("Connection")
            HStack(spacing: Space.xs) {
                ChoicePill(title: "Local command", selected: transport == .local,
                           thumb: transportTrack, detail: "Runs on this Mac (stdio)",
                           fills: true) {
                    draft.wrappedValue.transport = .local
                }
                ChoicePill(title: "Remote server", selected: transport == .remote,
                           thumb: transportTrack, detail: "Connects over HTTP or SSE",
                           fills: true) {
                    draft.wrappedValue.transport = .remote
                }
            }
            .padding(Space.xs)
            .surface(Theme.sunken, cornerRadius: Radius.floating)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("How it connects")

            Group {
                if transport == .local {
                    localFields(draft, problems: problems).transition(.fadeIn)
                } else {
                    remoteFields(draft, problems: problems).transition(.fadeIn)
                }
            }
        }
        .smoothlyResizes(when: transport)
    }

    private func localFields(_ draft: Binding<MCPPresetDraft>,
                             problems: MCPPresetDraft.Problems) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            PresetField(caption: "Command", note: problems.command, isError: problems.command != nil) {
                PresetTextField(placeholder: "mcp-server", text: draft.command,
                                invalid: problems.command != nil)
                    .focused($focus, equals: .command)
            }
            PresetField(caption: "Arguments",
                        note: "One per line. A flag and its value go on separate lines.",
                        isError: false) {
                ArgumentsEditor(text: draft.arguments)
            }
        }
    }

    private func remoteFields(_ draft: Binding<MCPPresetDraft>,
                              problems: MCPPresetDraft.Problems) -> some View {
        HStack(alignment: .top, spacing: Space.xl) {
            PresetField(caption: "Address", note: problems.url, isError: problems.url != nil) {
                PresetTextField(placeholder: "https://mcp.example.com/mcp", text: draft.url,
                                invalid: problems.url != nil)
                    .focused($focus, equals: .url)
            }
            PresetField(caption: "Protocol", note: nil, isError: false) {
                OptionMenu(value: draft.wrappedValue.type.uppercased()) {
                    ["http", "sse"].map { type in
                        .item(type.uppercased(), checked: draft.wrappedValue.type == type) {
                            draft.wrappedValue.type = type
                        }
                    }
                }
                .accessibilityLabel("Protocol")
            }
            .frame(width: 140)
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(Typography.body.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Actions

    private func binding(_ id: UUID) -> Binding<MCPPresetDraft> {
        Binding(get: { drafts.first { $0.id == id } ?? MCPPresetDraft(id: id) },
                set: { draft in
                    guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
                    drafts[index] = draft
                })
    }

    private func addPreset() {
        let open = drafts.first { $0.id == selection }
        let draft = MCPPresetDraft(serverType: open?.serverType ?? "",
                                   environment: defaults.deployEnvironments.first?.name ?? "")
        query = ""
        drafts.append(draft)
        selection = draft.id
        // The field only exists once the new editor has been drawn.
        Task { @MainActor in focus = .label }
    }

    private func confirmDelete(_ draft: MCPPresetDraft) {
        let menu = SiteDefaults.MCP.PresetGroup(serverType: draft.serverType.trimmed.isEmpty
                                                    ? nil : draft.serverType.trimmed,
                                                presets: []).addTitle
        dialogs.show(.impact("Delete this preset?",
                             message: "Nothing changes on disk until you save.",
                             rows: [
                                .init(title: draft.title.trimmed.isEmpty ? "The preset" : draft.title,
                                      detail: "Leaves the “\(menu)” menu."),
                                .init(title: "Servers already added from it",
                                      detail: "Keep working as they are.", kept: true),
                             ],
                             action: "Delete preset") {
            guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
            let next = drafts.indices.contains(index + 1) ? drafts[index + 1]
                : index > 0 ? drafts[index - 1] : nil
            drafts.remove(at: index)
            selection = next?.id
        })
    }

    // MARK: - Saving

    private func isDirty(_ draft: MCPPresetDraft) -> Bool {
        saved.first { $0.id == draft.id } != draft
    }

    private var changedCount: Int {
        drafts.filter(isDirty).count + saved.filter { old in !drafts.contains { $0.id == old.id } }.count
    }

    private var invalidCount: Int {
        drafts.filter { !$0.problems(among: drafts).isEmpty }.count
    }

    private var hasChanges: Bool { drafts != saved }

    private var canSave: Bool { hasChanges && invalidCount == 0 }

    private var status: some View {
        let (text, colour) = statusLine
        return HStack(spacing: Space.md) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(text)
                .font(Typography.detail)
                .foregroundStyle(failure == nil ? Theme.secondaryText : Theme.deletion)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .motion(Motion.reveal, value: text)
        .accessibilityElement(children: .combine)
    }

    private var statusLine: (String, Color) {
        if let failure { return (failure, Theme.deletion) }
        let invalid = invalidCount
        if invalid > 0 {
            return (invalid == 1 ? "1 preset needs fixing before you can save."
                        : "\(invalid) presets need fixing before you can save.",
                    Theme.deletion)
        }
        if hasChanges {
            return ("Unsaved changes to \(counted(changedCount, "preset")). Cancel throws them away.",
                    Theme.attention)
        }
        return (drafts.isEmpty ? "No presets saved." : "\(counted(drafts.count, "preset")), all saved.",
                Theme.dotOn)
    }

    private func save() {
        guard canSave else { return }
        do {
            var next = defaults
            next.mcp = SiteDefaults.MCP(presets: drafts.map(\.preset))
            let cleaned = try SiteConfigurationForm.cleaned(next, aspect: .mcp)
            let installed = try SiteConfigurationImporter.install(cleaned)
            defaults = installed
            saved = drafts
            failure = nil
            onSave(installed)
        } catch {
            failure = error.localizedDescription
        }
    }
}

enum PresetFocus: Hashable {
    case label, name, command, url
    case key(UUID), value(UUID)
}

// MARK: - Pieces

// A field with its caption over it and a line of help or an error under it. The line
// changing kind fades in, so an error is seen arriving rather than swapped in.
private struct PresetField<Content: View>: View {
    let caption: String
    let note: String?
    let isError: Bool
    var noteTint: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(caption)
                .font(Typography.detail.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
            content
            if let note {
                Text(note)
                    .font(Typography.detail)
                    .foregroundStyle(isError ? Theme.deletion : noteTint ?? Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(isError)
                    .transition(.fadeIn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(Motion.reveal, value: isError)
    }
}

private struct PresetTextField: View {
    let placeholder: String
    @Binding var text: String
    var invalid = false
    var monospaced = true

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? Typography.code : Typography.body)
            .padding(.horizontal, Space.lg)
            .frame(height: ControlHeight.lg)
            .surface(Theme.field, cornerRadius: Radius.card, border: invalid ? Theme.deletion : Theme.border)
            .motion(Motion.hover, value: invalid)
    }
}

// Grows a line at a time as arguments are added, so a long list is read whole rather
// than scrolled inside a small box.
private struct ArgumentsEditor: View {
    @Binding var text: String

    private var lines: Int { max(2, text.components(separatedBy: .newlines).count) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("none")
                    .font(Typography.code)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(Typography.code)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.sm)
        }
        .frame(height: CGFloat(lines) * 16 + 16)
        .fieldSurface(cornerRadius: Radius.card)
        .accessibilityLabel("Arguments")
    }
}

// What the preset will start or reach, written the way a terminal would show it. Asked
// values are marked rather than left blank, so a prompt reads as a prompt.
private struct RunsAsPanel: View {
    let draft: MCPPresetDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text(draft.transport == .local ? "Starts as" : "Connects to")
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                Text("Updates as you type")
            }
            .font(Typography.detail)
            .foregroundStyle(Theme.terminalDim)
            .motion(Motion.reveal, value: draft.transport)
            Text(rendered)
                .font(Typography.code)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.terminal, in: RoundedRectangle(cornerRadius: Radius.floating))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("What this preset runs")
    }

    private var rendered: AttributedString {
        var result = AttributedString()
        for (index, line) in draft.runsAs.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            for part in line.parts {
                var piece: AttributedString
                switch part {
                case .plain(let text):
                    piece = AttributedString(text)
                    piece.foregroundColor = Theme.terminalText
                case .dim(let text):
                    piece = AttributedString(text)
                    piece.foregroundColor = Theme.terminalDim
                case .asked:
                    piece = AttributedString("‹asked›")
                    piece.foregroundColor = Theme.secret
                }
                result += piece
            }
        }
        return result
    }
}

private struct EnvironmentTag: View {
    let name: String
    let live: Bool

    var body: some View {
        Text(name)
            .font(Typography.data.weight(.medium))
            .foregroundStyle(live ? Theme.attentionText : Theme.secondaryText)
            .contentTransition(.opacity)
            .padding(.horizontal, Space.sm)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: Radius.inset)
                .fill(live ? Theme.attention.opacity(0.16) : Theme.sunken))
            .motion(Motion.reveal, value: name)
            .accessibilityLabel(live ? "\(name), a live environment" : name)
    }
}

// The environment variables of a local command or the headers of a remote server, as
// one table. Each value is fixed or asked for when the preset is added, and the choice
// is made out loud rather than by leaving a field empty.
private struct EntriesTable: View {
    @Binding var draft: MCPPresetDraft
    let problem: String?
    var focus: FocusState<PresetFocus?>.Binding

    @State private var addActOuts = 0

    private var noun: String { draft.entryNoun }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                Text(draft.transport == .local ? "Environment variables" : "Headers")
                    .font(Typography.body.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(draft.transport == .local ? "Set for the command when it starts."
                        : "Sent with every request to the server.")
                    .font(Typography.detail)
                    .foregroundStyle(Theme.secondaryText)
            }
            VStack(spacing: 0) {
                if draft.entries.isEmpty {
                    HStack {
                        Text(draft.transport == .local
                             ? "No variables. The server starts with none set."
                             : "No headers. Add one if the server needs a token.")
                            .font(Typography.detail)
                            .foregroundStyle(Theme.secondaryText)
                        Spacer(minLength: 0)
                        addButton
                    }
                    .padding(Space.lg)
                    .transition(.fadeIn)
                } else {
                    HStack(spacing: Space.md) {
                        Text("Name").frame(width: 210, alignment: .leading)
                        Text("Value")
                        Spacer(minLength: 0)
                    }
                    .font(Typography.detail.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                    .transition(.fadeIn)
                    ForEach($draft.entries) { $entry in
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        EntryRow(entry: $entry, noun: noun, focus: focus) {
                            draft.entries.removeAll { $0.id == entry.id }
                        }
                        .transition(.fold)
                    }
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    HStack {
                        addButton
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                }
            }
            .surface(Theme.card, cornerRadius: Radius.card)
            .smoothlyResizes(when: draft.entries.map(\.id))
            if let problem {
                Text(problem)
                    .font(Typography.detail)
                    .foregroundStyle(Theme.deletion)
                    .transition(.fadeIn)
            }
        }
        .motion(Motion.reveal, value: problem)
    }

    private var addButton: some View {
        GlyphLink(icon: "plus", title: "Add \(noun)", tint: Theme.accent) {
            let entry = MCPPresetDraft.Entry()
            draft.entries.append(entry)
            Task { @MainActor in focus.wrappedValue = .key(entry.id) }
        }
    }
}

private struct EntryRow: View {
    @Binding var entry: MCPPresetDraft.Entry
    let noun: String
    var focus: FocusState<PresetFocus?>.Binding
    let remove: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var focused: Bool {
        focus.wrappedValue == .key(entry.id) || focus.wrappedValue == .value(entry.id)
    }

    var body: some View {
        HStack(spacing: Space.md) {
            TextField(noun == "header" ? "Authorization" : "SERVICE_TOKEN", text: $entry.key)
                .textFieldStyle(.plain)
                .font(Typography.code)
                .padding(.horizontal, Space.md)
                .frame(width: 210, height: ControlHeight.md)
                .fieldSurface(cornerRadius: Radius.control)
                .focused(focus, equals: .key(entry.id))
                .accessibilityLabel("\(noun.capitalized) name")
            valueCell
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .opacity(hovering || focused ? 1 : 0)
            .accessibilityLabel(entry.key.trimmed.isEmpty
                                ? "Remove this \(noun)" : "Remove \(noun) \(entry.key.trimmed)")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .hoverFill(cornerRadius: 0)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering || focused)
    }

    @ViewBuilder private var valueCell: some View {
        Group {
            if entry.asks {
                HStack(spacing: Space.md) {
                    Button {
                        entry.asks = false
                        Task { @MainActor in focus.wrappedValue = .value(entry.id) }
                    } label: {
                        HStack(spacing: Space.xs) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                                .transition(lockTransition)
                            Text("Ask when added")
                                .font(Typography.label)
                        }
                        .foregroundStyle(Theme.secret)
                        .padding(.horizontal, Space.md)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.secret.opacity(0.13)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverLift()
                    .accessibilityLabel("Asked when added")
                    .accessibilityHint("Use a fixed value instead")
                    Text("Never stored")
                        .font(Typography.detail)
                        .foregroundStyle(Theme.secondaryText)
                }
                .transition(.opacity)
            } else {
                HStack(spacing: Space.sm) {
                    TextField("Fixed value", text: $entry.value)
                        .textFieldStyle(.plain)
                        .font(Typography.code)
                        .focused(focus, equals: .value(entry.id))
                        .accessibilityLabel("\(noun.capitalized) value")
                    Button {
                        entry.asks = true
                        entry.value = ""
                    } label: {
                        Text("Ask instead")
                            .font(Typography.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, Space.sm)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: Radius.inset).fill(Theme.sunken))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverLift()
                }
                .padding(.leading, Space.md)
                .padding(.trailing, Space.xs)
                .frame(height: ControlHeight.md)
                .fieldSurface(cornerRadius: Radius.control)
                .transition(.opacity)
            }
        }
        .motion(Motion.pop, value: entry.asks)
    }

    private var lockTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: HeaderMotion.seed))
    }
}
