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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let maxListHeight: CGFloat = 390

    init(initialProjectIDs: [UUID] = [], onCreate: @escaping (ProjectWorkspace) -> Void) {
        var seen: Set<UUID> = []
        let projects = initialProjectIDs.filter { seen.insert($0).inserted }
        self.onCreate = onCreate
        _selected = State(initialValue: projects)
        _leadProjectID = State(initialValue: projects.first)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("New workspace")
                    .font(Typography.display)
                Text("Pick the projects that get worked on together. Every session starts with all of them.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Space.lg) {
                    SectionLabel("NAME", style: .field)
                    TextField("Workspace name", text: $name)
                        .textFieldStyle(.plain)
                        .font(Typography.body.weight(.semibold))
                }
                .padding(.horizontal, Space.lg)
                .frame(height: 44)
                .fieldSurface(cornerRadius: Radius.card)
                .padding(.top, Space.md)
            }
            .padding(Space.xxl)

            projectFilterField
                .padding(.horizontal, Space.xxl)
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
                .padding(.horizontal, Space.xxl)
                .padding(.bottom, Space.xxl)
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

            SheetFooter(title: "Projects can belong to several workspaces.",
                        primary: SheetAction(title: "Create", enabled: canCreate,
                                             shortcut: .defaultAction, action: create),
                        dismiss: { dismiss() })
        }
        .frame(width: 650)
        .background(Theme.background)
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
        !name.isBlank && selected.count >= 2 && leadProjectID != nil
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
        .padding(.horizontal, Space.xxl)
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
