import SwiftUI

// Creates a reusable group of projects. The order matters because the first selected
// project is the lead and supplies the working directory for every session.
struct NewWorkspaceView: View {
    let onCreate: (ProjectWorkspace) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var name = ""
    @State private var projectFilter = ""
    @State private var selected: [UUID] = []
    @State private var leadProjectID: UUID?
    @State private var listHeight: CGFloat?
    // Off by default: a workspace stays until it is deleted unless asked otherwise.
    @State private var removesWhenEmpty = false
    // Nil until the stepper is touched, so the count follows the old session setting.
    @State private var removalDays: Int?
    @State private var showsWhy = false
    // Counts clicks on the dead Create button, so each one plays the hint in again.
    @State private var blockedClicks = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let maxListHeight: CGFloat = 390

    init(initialProjectIDs: [UUID] = [], initialName: String = "",
         onCreate: @escaping (ProjectWorkspace) -> Void) {
        var seen: Set<UUID> = []
        let projects = initialProjectIDs.filter { seen.insert($0).inserted }
        self.onCreate = onCreate
        _name = State(initialValue: initialName)
        _selected = State(initialValue: projects)
        _leadProjectID = State(initialValue: projects.first)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(1)
            readings

            HStack(spacing: Space.lg) {
                SectionLabel("NAME", style: .field)
                TextField("Workspace name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Typography.body.weight(.semibold))
            }
            .padding(.horizontal, Space.lg)
            .frame(height: 44)
            .fieldSurface(cornerRadius: Radius.card)
            .padding(Space.pane)

            projectFilterField
                .padding(.horizontal, Space.pane)
                .padding(.bottom, Space.lg)

            ScrollView {
                VStack(spacing: Space.md) {
                    if filteredProjects.isEmpty && !projectFilter.isBlank {
                        Text("No project matches this filter.")
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                            .padding(Space.lg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(filteredProjects) { project in
                        projectRow(project)
                    }

                    ActionButton(title: "Add a folder that isn't a project yet", tone: .outlined,
                                 height: ControlHeight.xl, size: Typography.Size.body, icon: "plus", action: addFolder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Space.xs)
                }
                .padding(.horizontal, Space.pane)
                .padding(.bottom, Space.pane)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    // The first height is taken as it is, so the sheet opens at its
                    // final size instead of growing into it.
                    guard listHeight != nil, !reduceMotion else { listHeight = height; return }
                    withAnimation(Motion.reveal) { listHeight = height }
                }
            }
            .modifier(AnimatedHeight(height: min(listHeight ?? Self.maxListHeight, Self.maxListHeight)))
            // Keyed on the rows rather than the typed text, so a keystroke that leaves the
            // list as it was does not start an animation.
            .motion(Motion.reveal, value: filteredProjects.map(\.id))

            RemoveWhenEmptyBand(isOn: $removesWhenEmpty,
                                days: Binding(get: { removalDays ?? settings.oldSessionDays },
                                              set: { removalDays = $0 }),
                                oldSessionDays: settings.oldSessionDays)

            SheetFooter(primary: SheetAction(title: "Create", enabled: canCreate,
                                             shortcut: .defaultAction,
                                             blockedReason: gap?.sentence,
                                             onBlockedClick: { blockedClicks += 1 },
                                             action: create),
                        dismiss: closeOrDismiss) {
                CreateHint(gap: gap, replay: blockedClicks)
            }
        }
        .frame(width: 650)
        .background(Theme.background)
        .onChange(of: gap) { _, gap in
            AccessibilityNotification.Announcement(gap?.sentence ?? "Ready to create the workspace.").post()
        }
    }

    private var gap: NewWorkspaceGap? {
        NewWorkspaceGap(picked: selected.count, name: name)
    }

    // Escape puts the explanation away before it closes the sheet.
    private func closeOrDismiss() {
        if showsWhy {
            showsWhy = false
        } else {
            dismiss()
        }
    }

    private var header: some View {
        SheetTitle(name: "New workspace", icon: "square.stack.3d.up") {
            WhyButton(label: "What a workspace is", isOpen: $showsWhy) {
                Text("A group of projects that get worked on together. Every session starts with all of them, and the lead project is where the agent works.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Space.pane)
        .headerBand()
    }

    // How many projects are picked, and which one leads. A workspace needs two.
    private var readings: some View {
        let lead = leadProjectID.flatMap(store.project)?.name
        return HStack(spacing: Space.md) {
            StatusCaps(text: selected.count < 2 ? "PICK AT LEAST 2 PROJECTS" : "\(selected.count) PROJECTS")
                .contentTransition(.numericText())
            if let lead {
                StatusRule()
                StatusCaps(text: "LEAD")
                StatusValue(text: lead, tint: Theme.accent)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .motion(Motion.control, value: selected.count)
        .motion(Motion.control, value: leadProjectID)
        .accessibilityElement(children: .combine)
        .statusBand(padding: Space.pane)
    }

    private var projectFilterField: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            TextField("Filter projects by name or path", text: $projectFilter)
                .textFieldStyle(.plain)
                .font(Typography.body)
            if !projectFilter.isEmpty {
                Button { projectFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverLift(amount: Motion.smallLift)
                .accessibilityLabel("Clear project filter")
                .appTooltip("Clear filter")
            }
        }
        .padding(.horizontal, Space.md)
        .frame(height: 36)
        .fieldSurface(cornerRadius: Radius.control)
    }

    private var filteredProjects: [Project] {
        let query = projectFilter.trimmed
        guard !query.isEmpty else { return store.regularProjects }
        return store.regularProjects.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
                || $0.collapsedPath.localizedCaseInsensitiveContains(query)
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let isSelected = selected.contains(project.id)
        let isLead = leadProjectID == project.id
        return HStack(spacing: Space.lg) {
            Toggle(isOn: Binding(get: { selected.contains(project.id) },
                                 set: { _ in toggle(project.id) })) {
                EmptyView()
            }
            .toggleStyle(.appCheckbox)

            ProjectDot(tint: Theme.projectTint(for: project.name), size: 10)

            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.sm) {
                    Text(project.name)
                        .font(Typography.body.weight(.semibold))
                        .lineLimit(1)
                    if isLead {
                        MonoChip(text: "LEAD", size: Typography.Size.micro, tint: Theme.accent)
                            .transition(.fadeIn)
                    }
                }
                Text(project.collapsedPath)
                    .font(Typography.data)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)

            if isSelected && !isLead {
                ActionButton(title: "Make lead", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.caption) {
                    leadProjectID = project.id
                }
                .transition(.fadeIn)
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: Radius.floating).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.floating)
            .stroke(isSelected ? Theme.accent : Theme.border,
                    lineWidth: isSelected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: Radius.floating))
        .onTapGesture { toggle(project.id) }
        .hoverFill(cornerRadius: Radius.floating)
        .motion(Motion.control, value: isSelected)
        .motion(Motion.control, value: isLead)
    }

    private var canCreate: Bool {
        gap == nil && leadProjectID != nil
    }

    private func toggle(_ id: UUID) {
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
            if leadProjectID == id { leadProjectID = selected.first }
        } else {
            selected.append(id)
            if leadProjectID == nil { leadProjectID = id }
        }
    }

    private func addFolder() {
        guard let url = FilePicker.chooseFolder(prompt: "Add Folder",
                                                message: "Pick a folder to add to this workspace.")
        else { return }
        let added = store.addProject(at: url)
        guard let id = added?.id ?? store.selectedProjectID else { return }
        if !selected.contains(id) { selected.append(id) }
        if leadProjectID == nil { leadProjectID = id }
    }

    private func create() {
        guard let leadProjectID,
              let workspace = store.addWorkspace(
                  name: name, projectIDs: selected, leadProjectID: leadProjectID,
                  removeWhenEmptyAfterDays: removesWhenEmpty
                      ? removalDays ?? settings.oldSessionDays : nil) else { return }
        onCreate(workspace)
        dismiss()
    }
}

// What the sheet still needs before Create works, in the order a person fixes it. The
// projects come first because that is the step they are on; the name is usually filled in.
enum NewWorkspaceGap: Equatable {
    case projects(picked: Int, nameMissing: Bool)
    case name

    static let minimumProjects = 2

    init?(picked: Int, name: String) {
        if picked < Self.minimumProjects {
            self = .projects(picked: picked, nameMissing: name.isBlank)
        } else if name.isBlank {
            self = .name
        } else {
            return nil
        }
    }

    // The part that says what to do, set in bold.
    var instruction: String {
        switch self {
        case .projects(let picked, _):
            picked == Self.minimumProjects - 1 ? "Pick one more project." : "Pick at least two projects."
        case .name:
            "Give the workspace a name"
        }
    }

    var detail: String {
        switch self {
        case .projects(_, nameMissing: true): "Then give the workspace a name."
        case .projects(let picked, _) where picked == Self.minimumProjects - 1: "A workspace needs two or more."
        case .projects: "A workspace holds projects worked on together."
        case .name: "to create it."
        }
    }

    var sentence: String { "\(instruction) \(detail)" }

    var picked: Int? {
        if case .projects(let picked, _) = self { picked } else { nil }
    }
}

// The left end of the footer. While Create is off it says what is missing, next to a
// count of the projects picked so far; once Create is on it is the usual small print.
private struct CreateHint: View {
    let gap: NewWorkspaceGap?
    let replay: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.md) {
            if let picked = gap?.picked {
                ProjectTally(picked: picked)
                    .transition(.fadeIn)
            }
            // A new identity only when the words change or a dead click asks for them
            // again, so typing in the name field does not replay the line.
            ZStack(alignment: .leading) {
                message
                    .id("\(gap?.sentence ?? "")#\(replay)")
                    .transition(.asymmetric(insertion: .popover(reduceMotion: reduceMotion),
                                            removal: .identity))
            }
        }
        .motion(Motion.reveal, value: gap?.picked == nil)
    }

    @ViewBuilder private var message: some View {
        if let gap {
            Text("\(Text(gap.instruction).fontWeight(.semibold)) \(gap.detail)")
                .font(Typography.detail)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Projects can belong to several workspaces.")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// How many of the two projects a workspace needs have been picked: the number, then a pip
// for each project that fills as it is picked. It reads as one figure, so it is spoken by
// the sentence beside it rather than on its own.
private struct ProjectTally: View {
    let picked: Int

    var body: some View {
        HStack(spacing: Space.xxs) {
            HStack(spacing: 0) {
                Text("\(picked)")
                    .contentTransition(.numericText(value: Double(picked)))
                    .motion(Motion.pop, value: picked)
                Text("/\(NewWorkspaceGap.minimumProjects)")
            }
            HStack(spacing: Space.xxs) {
                ForEach(0..<NewWorkspaceGap.minimumProjects, id: \.self) { index in
                    Circle()
                        .fill(index < picked ? Theme.workspaceTint.ink : .clear)
                        .overlay(Circle().strokeBorder(Theme.workspaceTint.ink, lineWidth: 1.25))
                        .frame(width: Space.sm, height: Space.sm)
                }
            }
            .padding(.leading, Space.xxs)
            .motion(Motion.control, value: picked)
        }
        .font(Typography.data.weight(.semibold))
        .foregroundStyle(Theme.workspaceTint.ink)
        .padding(.horizontal, Space.sm)
        .frame(height: ControlHeight.xs)
        .background(Theme.workspaceTint.fill, in: Capsule())
        .fixedSize()
        .accessibilityHidden(true)
    }
}

// The one setting about a workspace's life. Off, it reads as a quiet note that the
// workspace stays; on, it opens a sentence that says when it goes.
private struct RemoveWhenEmptyBand: View {
    @Binding var isOn: Bool
    @Binding var days: Int
    let oldSessionDays: Int

    @State private var detailHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: Binding(get: { isOn }, set: { on in
                if reduceMotion { isOn = on } else { withAnimation(Motion.reveal) { isOn = on } }
            })) {
                HStack(spacing: Space.lg) {
                    Image(systemName: "hourglass")
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(isOn ? Theme.workspaceTint.ink : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(isOn ? Theme.workspaceTint.fill : Theme.field,
                                    in: RoundedRectangle(cornerRadius: Radius.control))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Remove it when it sits empty")
                            .font(Typography.body.weight(.semibold))
                        Text(isOn
                             ? "On: it goes once it has had no session for a while. Its projects stay."
                             : "Off: the workspace stays until you delete it. Turn on for a short job.")
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
            }
            .toggleStyle(.appSwitch)

            // Always laid out and measured, so the band grows by the sentence's real
            // height and the sheet's window glides with it rather than jumping.
            detail
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailHeight = $0 }
                .opacity(isOn ? 1 : 0)
                .offset(y: isOn || reduceMotion ? 0 : -3)
                .modifier(AnimatedHeight(height: isOn ? detailHeight : 0, alignment: .top))
                .clipped()
                .allowsHitTesting(isOn)
                .accessibilityHidden(!isOn)
        }
        .padding(.horizontal, Space.pane)
        .padding(.vertical, Space.lg)
        .background(Theme.statusBand)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var detail: some View {
        HStack(spacing: Space.md) {
            Text("Remove after")
            DayField(days: $days, accessibilityLabel: "Days the workspace may sit empty")
            Text("with no session in it.")
            if days == oldSessionDays {
                Text("Same as old sessions")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.workspaceTint.ink)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xxs)
                    .background(Theme.workspaceTint.fill, in: Capsule())
                    .transition(.fadeIn)
            }
            Spacer(minLength: 0)
        }
        .font(Typography.body)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Theme.border, lineWidth: 1))
        .motion(Motion.control, value: days == oldSessionDays)
        .padding(.leading, 40)
        .padding(.top, Space.md)
    }
}

// The sheet's window takes the size of its content but jumps straight to a new size, even
// inside an animation. Being animatable makes SwiftUI lay the list out again at every step
// of the curve, so the window is handed each height in turn and glides to the new one.
nonisolated private struct AnimatedHeight: ViewModifier, Animatable {
    var height: CGFloat
    var alignment: Alignment = .center

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(height: height, alignment: alignment)
    }
}
