import AppKit
import SwiftUI

// The Docker sheet does two jobs: show what is running, and get disk space back. The rail
// picks a kind and shows where the disk went; the table beside it lists that kind with a
// box on every line, so a whole run of things can be acted on at once.
struct DockerView: View {
    @Environment(DockerService.self) private var docker
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(MenuPresenter.self) private var menus
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Filter: String {
        case all, running, stopped, used, unused, untagged, anonymous, yours
    }

    enum Sort { case name, size }

    @State private var kind = DockerKind.containers
    @State private var filters: [DockerKind: Filter] = [:]
    @State private var sorts: [DockerKind: Sort] = [.images: .size, .volumes: .size]
    @State private var grouped = true
    @State private var collapsed: Set<String> = []
    @State private var query = ""
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var animatesRows = false
    @State private var note: String?
    @State private var noteIcon = "checkmark"
    @State private var notes = 0
    @State private var keys = WindowKeyHandler(handlesTyping: true)
    @FocusState private var searchFocused: Bool

    private static let standalone = "standalone"

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                rail
                Rectangle().fill(Theme.hairline).frame(width: 1)
                pane
            }
            SheetFooter(title: "Shift-click picks a range, ⌘A picks everything shown.") {
                dismiss()
            }
        }
        .frame(width: 1000, height: 680)
        .background(Theme.background)
        .overlay(alignment: .topTrailing) {
            ZStack {
                if let note {
                    HeaderNote(icon: noteIcon, text: note)
                        .padding(.top, Theme.headerHeight + 8).padding(.trailing, Space.xxl)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                }
            }
            .motion(Motion.reveal, value: note)
        }
        .background(WindowKeyAnchor(handler: keys))
        .onAppear { keys.start { handleKey($0) } }
        .onDisappear { keys.stop() }
        .task { await docker.refresh(sizes: true) }
        .onChange(of: kind) { selection = []; anchor = nil }
        .onChange(of: allIDs) { selection.formIntersection($1) }
    }

    // MARK: - Header

    private var engine: (text: String, colour: Color) {
        if !docker.containers.hasLoaded { return ("Connecting", Theme.attention) }
        if docker.containers.failure != nil { return ("Engine stopped", Theme.dotOff) }
        return ("Engine running", Theme.dotOn)
    }

    private var safeToFree: Int64 {
        DockerCleanUp.safeTotal(containers: docker.containers.items, images: docker.images.items,
                                volumes: docker.volumes.items, networks: docker.networks.items,
                                volumeSizes: docker.volumeSizes, disk: docker.disk)
    }

    private var isUp: Bool { docker.containers.hasLoaded && docker.containers.failure == nil }

    private var header: some View {
        HStack(spacing: Space.lg) {
            Text("Docker").font(Typography.display)
            HStack(spacing: Space.sm) {
                Circle().fill(engine.colour).frame(width: 6, height: 6)
                Text(engine.text)
                    .contentTransition(.opacity)
            }
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(isUp ? Theme.accent : Theme.secondaryText)
            .padding(.horizontal, Space.md)
            .frame(height: 22)
            .background(isUp ? Theme.accent.opacity(0.1) : Theme.field, in: RoundedRectangle(cornerRadius: Radius.inset))
            .motion(Motion.control, value: engine.text)
            .accessibilityElement(children: .combine)

            Spacer()

            searchField
            GlyphButton(icon: "arrow.clockwise", tint: Theme.accent) {
                Task {
                    await docker.refresh(sizes: true)
                    showNote("Up to date", icon: "checkmark")
                }
            }
            .appTooltip("Refresh everything")
            .accessibilityLabel("Refresh")

            ActionButton(title: safeToFree > 0 ? "Clean up  \(DockerSize.text(safeToFree))" : "Clean up",
                         tone: .outlined, icon: "sparkles", action: cleanUp)
                .disabled(!isUp)
        }
        .padding(.horizontal, Space.xxl)
        .headerBand()
    }

    private var searchField: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            TextField("Filter by name or image", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .focused($searchFocused)
                .onChange(of: query) { selection = []; anchor = nil }
            if query.isEmpty {
                Text("⌘F")
                    .font(Typography.micro)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: Radius.tag).stroke(Theme.border))
            } else {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the filter")
            }
        }
        .padding(.horizontal, Space.md)
        .frame(width: 240, height: 32)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control)
            .stroke(searchFocused ? Theme.accent.opacity(0.5) : Theme.border))
        .motion(Motion.hover, value: searchFocused)
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(DockerKind.allCases) { item in
                railItem(item)
            }
            Spacer(minLength: 12)
            diskCard
        }
        .padding(Space.lg)
        .frame(width: 216)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Docker resources")
    }

    private func railSubtitle(_ item: DockerKind) -> String {
        switch item {
        case .containers: "\(docker.runningCount) of \(docker.containers.items.count) running"
        case .images: "\(DockerSize.text(docker.disk.images)) on disk"
        case .volumes: "\(DockerSize.text(docker.disk.volumes)) on disk"
        case .networks:
            "\(docker.networks.items.count { !$0.isBuiltIn }) yours, \(docker.networks.items.count(where: \.isBuiltIn)) built in"
        }
    }

    private func count(_ item: DockerKind) -> Int {
        switch item {
        case .containers: docker.containers.items.count
        case .images: docker.images.items.count
        case .volumes: docker.volumes.items.count
        case .networks: docker.networks.items.count
        }
    }

    private func railItem(_ item: DockerKind) -> some View {
        let current = kind == item
        let restarting = item == .containers ? docker.containers.items.count { $0.state == .restarting } : 0
        return Button { switchKind(item) } label: {
            HStack(spacing: Space.md) {
                Image(systemName: item.icon)
                    .font(Typography.body.weight(.medium))
                    .foregroundStyle(current ? Theme.onFill : Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(current ? Theme.accentFill : Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(item.title).font(Typography.body.weight(.semibold))
                    Group {
                        if !docker.containers.hasLoaded {
                            RoundedRectangle(cornerRadius: Radius.tag).fill(Theme.field).frame(width: 80, height: 8)
                        } else if !isUp {
                            Text("Not available")
                        } else {
                            Text(railSubtitle(item)).contentTransition(.numericText())
                        }
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isUp {
                    HStack(spacing: Space.xs) {
                        if restarting > 0 {
                            BreathingCircle(colour: Theme.attention, restingOpacity: 1, fullOpacity: 0.35)
                                .frame(width: 6, height: 6)
                        }
                        Text("\(count(item))").contentTransition(.numericText())
                    }
                    .font(Typography.label)
                    .monospacedDigit()
                    .foregroundStyle(restarting > 0 ? Theme.attentionText : Theme.secondaryText)
                    .appTooltip(restarting > 0 ? "\(counted(restarting, "container keeps", plural: "containers keep")) restarting" : "\(item.amount(count(item)))")
                }
            }
            .padding(Space.md)
            .background(current ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(current ? Theme.border : .clear))
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.card)
        .motion(Motion.control, value: current)
        .accessibilityLabel("\(item.title), \(count(item))")
        .accessibilityHint("⌘\(item.rawValue + 1)")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private var diskSegments: [(title: String, bytes: Int64, colour: Color)] {
        [("Images", docker.disk.images, Theme.chartSeries[0]),
         ("Volumes", docker.disk.volumes, Theme.chartSeries[2]),
         ("Build cache", docker.disk.buildCache, Theme.chartSeries[1]),
         ("Containers", docker.disk.containers, Theme.chartSeries[3])]
    }

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Docker on this Mac")
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
            if !docker.containers.hasLoaded {
                RoundedRectangle(cornerRadius: Radius.tag).fill(Theme.field).frame(width: 110, height: 22)
                RoundedRectangle(cornerRadius: Radius.tag).fill(Theme.field).frame(height: 6)
            } else if !isUp {
                Text("Waiting for Docker").font(Typography.detail).foregroundStyle(Theme.secondaryText)
            } else {
                Text(DockerSize.text(docker.disk.total))
                    .font(Typography.display)
                    .contentTransition(.numericText())
                diskMeter
                VStack(spacing: Space.xs) {
                    ForEach(diskSegments, id: \.title) { segment in
                        HStack(spacing: Space.sm) {
                            RoundedRectangle(cornerRadius: 2).fill(segment.colour).frame(width: 8, height: 8)
                            Text(segment.title)
                            Spacer(minLength: 4)
                            Text(DockerSize.text(segment.bytes)).monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        .font(Typography.detail)
                        .accessibilityElement(children: .combine)
                    }
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if safeToFree > 0 {
                    HStack(spacing: Space.xs) {
                        (Text(DockerSize.text(safeToFree)).fontWeight(.semibold) + Text(" is safe to free"))
                            .font(Typography.detail)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 2)
                        InlineLink(title: "Clean up", size: Typography.Size.detail, action: cleanUp)
                    }
                } else {
                    Label("Nothing to free", systemImage: "checkmark")
                        .font(Typography.detail.weight(.medium))
                        .foregroundStyle(Theme.dotOnText)
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.floating))
        .overlay(RoundedRectangle(cornerRadius: Radius.floating).stroke(Theme.border))
    }

    // One bar split by kind, drawn rather than built from `Meter`s, since its parts share
    // a single track.
    private var diskMeter: some View {
        let total = max(docker.disk.total, 1)
        return GeometryReader { geometry in
            HStack(spacing: Space.xxs) {
                ForEach(diskSegments, id: \.title) { segment in
                    Capsule()
                        .fill(segment.colour)
                        .frame(width: max(2, (geometry.size.width - 6) * CGFloat(segment.bytes) / CGFloat(total)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 7)
        .background(Theme.field, in: Capsule())
        .motion(Motion.draw, value: docker.disk)
        .accessibilityElement()
        .accessibilityLabel("Disk use by kind")
        .accessibilityValue(diskSegments.map { "\($0.title) \(DockerSize.text($0.bytes))" }.joined(separator: ", "))
    }

    // MARK: - Pane

    @ViewBuilder private var pane: some View {
        Group {
            if docker.containers.hasLoaded, docker.containers.failure != nil {
                notRunning
            } else {
                VStack(spacing: Space.lg) {
                    toolbar
                    table
                }
                .padding(Space.xxl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notRunning: some View {
        let installed = docker.isAvailable
        return PaneMessage(icon: "power",
                           title: installed ? "Docker is not running" : "Docker is not installed",
                           detail: installed
                               ? "Start Docker. This sheet connects on its own once the engine is up."
                               : "Install Docker, then come back here.") {
            // An engine that is up but fails the list looks the same as one that is down,
            // so what docker said is the only way to tell them apart.
            if installed, let failure = docker.containers.failure {
                Text(failure)
                    .font(Typography.data)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                    .frame(maxWidth: 460, alignment: .leading)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.border))
                    .contentTransition(.opacity)
                    .motion(Motion.reveal, value: failure)
                    .padding(.top, Space.sm)
            }
            HStack(spacing: Space.md) {
                if let desktop = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker") {
                    ActionButton(title: "Open Docker Desktop", tone: .green, icon: "arrow.up.forward.app") {
                        NSWorkspace.shared.openApplication(at: desktop, configuration: NSWorkspace.OpenConfiguration())
                        showNote("Opened Docker Desktop", icon: "arrow.up.forward.app")
                    }
                }
                ActionButton(title: "Try again", tone: .outlined) {
                    Task { await docker.refresh(sizes: true) }
                }
            }
            .padding(.top, Space.md)
        }
        .transition(.fadeIn)
    }

    private func filterOptions(_ kind: DockerKind) -> [(Filter, String, Int)] {
        let usage = DockerUsage(containers: docker.containers.items)
        switch kind {
        case .containers:
            let items = docker.containers.items
            return [(.all, "All", items.count), (.running, "Running", items.count(where: \.isRunning)),
                    (.stopped, "Stopped", items.count { !$0.isRunning })]
        case .images:
            let items = docker.images.items
            return [(.all, "All", items.count),
                    (.used, "In use", items.count { !usage.users(of: $0).isEmpty }),
                    (.unused, "Not used", items.count { !$0.isUntagged && usage.users(of: $0).isEmpty }),
                    (.untagged, "Untagged", items.count(where: \.isUntagged))]
        case .volumes:
            let items = docker.volumes.items
            return [(.all, "All", items.count),
                    (.used, "In use", items.count { !usage.users(of: $0).isEmpty }),
                    (.unused, "Not used", items.count { usage.users(of: $0).isEmpty }),
                    (.anonymous, "Anonymous", items.count(where: \.isAnonymous))]
        case .networks:
            let items = docker.networks.items
            return [(.all, "All", items.count), (.yours, "Yours", items.count { !$0.isBuiltIn }),
                    (.unused, "Not used", items.count { !$0.isBuiltIn && usage.users(of: $0).isEmpty })]
        }
    }

    private var filter: Filter { filters[kind] ?? .all }
    private var sort: Sort { sorts[kind] ?? .name }

    @Namespace private var filterTrack

    private var toolbar: some View {
        HStack(spacing: Space.sm) {
            ForEach(filterOptions(kind), id: \.0) { option, title, number in
                ChoicePill(title: "\(title)  \(number)", selected: filter == option,
                           enabled: number > 0 || option == .all || filter == option,
                           thumb: filterTrack) {
                    filters[kind] = option
                    selection = []
                    anchor = nil
                }
            }
            Spacer()
            sortButton
        }
        .motion(Motion.control, value: filter)
    }

    private var sortLabel: String {
        if kind == .containers, grouped { return "By project" }
        return sort == .size ? "Size" : "Name"
    }

    private var sortButton: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "arrow.up.arrow.down").font(Typography.caption.weight(.semibold))
            Text(sortLabel).font(Typography.label)
            MenuChevron()
        }
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, Space.md)
        .frame(height: 28)
        .contentShape(Rectangle())
        .hoverLift()
        .appMenu {
            var entries: [MenuEntry] = []
            if kind == .containers {
                entries.append(.item("Group by compose project", checked: grouped) { grouped.toggle() })
                entries.append(.separator)
            }
            entries.append(.item("Sort by name", checked: sort == .name) { sorts[kind] = .name })
            if kind != .networks {
                entries.append(.item("Sort by size", checked: sort == .size) { sorts[kind] = .size })
            }
            return entries
        }
        .accessibilityLabel("Sort, \(sortLabel)")
    }

    // MARK: - Table

    @ViewBuilder private var table: some View {
        VStack(spacing: 0) {
            columnHeader
            ZStack(alignment: .bottom) {
                tableBody
                    .id(kind)
                    .transition(.headerPage(reduceMotion: reduceMotion))
                ZStack {
                    if let bar = selectionBar {
                        bar
                            .padding(.bottom, Space.lg)
                            .transition(reduceMotion
                                ? .opacity.animation(Motion.reveal)
                                : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity).animation(Motion.arrive),
                                              removal: .move(edge: .bottom).combined(with: .opacity).animation(Motion.leave)))
                    }
                }
            }
            .clipped()
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.floating))
        .clipShape(RoundedRectangle(cornerRadius: Radius.floating))
        .overlay(RoundedRectangle(cornerRadius: Radius.floating).stroke(Theme.border))
    }

    private var headCheck: (on: Bool, mixed: Bool) {
        let ids = selectableVisibleIDs
        let picked = ids.count { selection.contains($0) }
        return (picked > 0 && picked == ids.count, picked > 0 && picked < ids.count)
    }

    private var columnHeader: some View {
        let titles = DockerColumns.titles(kind)
        let widths = DockerColumns.widths(kind)
        return HStack(spacing: 0) {
            Button(action: toggleAll) {
                CheckboxMark(isOn: headCheck.on, mixed: headCheck.mixed)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .disabled(selectableVisibleIDs.isEmpty)
            .frame(width: DockerColumns.check, alignment: .leading)
            .motion(Motion.control, value: selection)
            .accessibilityLabel("Select everything shown")

            headerTitle(titles.name, sortsBy: kind == .containers && grouped ? nil : .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(titles.rest.enumerated()), id: \.offset) { index, title in
                headerTitle(title, sortsBy: title == "Size" ? .size : nil)
                    .frame(width: widths[index], alignment: DockerColumns.trailing(kind, index) ? .trailing : .leading)
            }
        }
        .padding(.horizontal, DockerColumns.inset)
        .frame(height: 36)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private func headerTitle(_ title: String, sortsBy: Sort?) -> some View {
        let label = HStack(spacing: Space.xs) {
            Text(title)
            if let sortsBy, sort == sortsBy {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
        }
        .font(Typography.label)
        .foregroundStyle(Theme.secondaryText)
        if let sortsBy {
            Button { sorts[kind] = sortsBy } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort by \(title.lowercased())")
        } else {
            label
        }
    }

    @ViewBuilder private var tableBody: some View {
        if !docker.containers.hasLoaded {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach([90, 70, 110, 60, 84, 100, 76], id: \.self) { width in
                        DockerSkeletonRow(width: CGFloat(width))
                    }
                }
            }
            .scrollDisabled(true)
        } else if let failure = failure(kind) {
            PaneMessage(icon: "exclamationmark.triangle", title: "Could not load \(kind.noun)s",
                        detail: failure, mono: true)
        } else if visibleIDs.isEmpty, !(kind == .containers && grouped && !groups.isEmpty) {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    rows
                }
                // Room for the selection bar, so the last line is never hidden under it.
                .padding(.bottom, selection.isEmpty ? 0 : 64)
                // Keyed on the rows only while a delete runs. Keyed on them all the time, it
                // would wipe out the animation of every other change to the rows, such as a
                // group folding shut.
                .motion(Motion.leave, value: animatesRows ? visibleIDs : [])
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func failure(_ kind: DockerKind) -> String? {
        switch kind {
        case .containers: docker.containers.failure
        case .images: docker.images.failure
        case .volumes: docker.volumes.failure
        case .networks: docker.networks.failure
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !query.isEmpty {
            PaneMessage(icon: "magnifyingglass", title: "No \(kind.noun)s match \"\(query)\"",
                        detail: "Try part of a name, an image or a compose project.") {
                ActionButton(title: "Clear filter", tone: .outlined, height: ControlHeight.md, size: Typography.Size.detail) { query = "" }
                    .padding(.top, Space.sm)
            }
            .transition(.fadeIn)
        } else if filter != .all {
            let label = filterOptions(kind).first { $0.0 == filter }?.1.lowercased() ?? ""
            let everyInUse = filter == .unused && kind != .containers
            PaneMessage(icon: everyInUse ? "checkmark" : kind.icon,
                        title: everyInUse ? "Every \(kind.noun) is in use" : "No \(label) \(kind.noun)s",
                        detail: everyInUse
                            ? "\(kind.title) that nothing uses show up here, ready to clean up."
                            : "Nothing fits this filter right now.") {
                ActionButton(title: "Show all \(kind.noun)s", tone: .outlined, height: ControlHeight.md, size: Typography.Size.detail) {
                    filters[kind] = .all
                }
                .padding(.top, Space.sm)
            }
            .transition(.fadeIn)
        } else {
            PaneMessage(icon: kind.icon, title: "No \(kind.noun)s",
                        detail: "\(kind.title) you create or pull will appear here.")
                .transition(.fadeIn)
        }
    }

    @ViewBuilder private var rows: some View {
        let usage = DockerUsage(containers: docker.containers.items)
        switch kind {
        case .containers:
            if grouped {
                ForEach(groups, id: \.key) { group in
                    groupHeader(group)
                    if !collapsed.contains(group.key) {
                        ForEach(group.containers) { containerRow($0, short: true) }
                    }
                }
            } else {
                ForEach(visibleContainers) { containerRow($0, short: false) }
            }
        case .images:
            ForEach(visibleImages) { imageRow($0, usage: usage) }
        case .volumes:
            ForEach(visibleVolumes) { volumeRow($0, usage: usage) }
        case .networks:
            ForEach(visibleNetworks) { networkRow($0, usage: usage) }
        }
    }

    private func containerRow(_ container: DockerContainer, short: Bool) -> some View {
        let working = docker.working[container.id]
        return DockerTableRow(
            kind: .containers, name: container.name, selectable: true,
            selected: selection.contains(container.id), busy: working != nil,
            toggle: { toggle(container.id) }, click: { click(container.id) },
            menu: { containerMenu(container) }
        ) {
            DockerNameCell(title: short ? container.shortName : container.name,
                           subtitle: container.image, fullName: container.name)
        } cells: {
            let widths = DockerColumns.widths(.containers)
            DockerStatusCell(container: container, working: working)
                .frame(width: widths[0], alignment: .leading)
            DockerPortsCell(ports: container.hostPorts) { openPort($0) }
                .frame(width: widths[1], alignment: .leading)
            DockerSizeCell(bytes: container.bytes)
                .frame(width: widths[2], alignment: .trailing)
        } actions: {
            HStack(spacing: Space.xs) {
                if container.isRunning {
                    rowGlyph("stop.fill", "Stop") { act(.stop, on: [container]) }
                } else {
                    rowGlyph("play.fill", "Start") { act(.start, on: [container]) }
                }
                rowGlyph("arrow.clockwise", "Restart") { act(.restart, on: [container]) }
                    .disabled(!container.isRunning)
                moreButton { containerMenu(container) }
            }
            .disabled(working != nil)
        }
        .transition(.fold)
    }

    private func imageRow(_ image: DockerImage, usage: DockerUsage) -> some View {
        DockerTableRow(
            kind: .images, name: image.reference, selectable: true,
            selected: selection.contains(image.id), busy: docker.images.busy.contains(image.id),
            toggle: { toggle(image.id) }, click: { click(image.id) },
            menu: { resourceMenu(id: image.imageID, name: image.reference) { delete([image.id]) } }
        ) {
            if image.isUntagged {
                DockerNameCell(title: "Untagged", untagged: true,
                               subtitle: "\(image.shortID)  built \(image.createdSince)")
            } else {
                DockerNameCell(title: image.repository, tag: image.tag,
                               subtitle: "\(image.shortID)  built \(image.createdSince)",
                               fullName: image.reference)
            }
        } cells: {
            let widths = DockerColumns.widths(.images)
            DockerUsersCell(users: usage.users(of: image))
                .frame(width: widths[0], alignment: .leading)
            DockerSizeCell(bytes: image.bytes)
                .frame(width: widths[1], alignment: .trailing)
        } actions: {
            HStack(spacing: Space.xs) {
                rowGlyph("trash", "Delete image") { delete([image.id]) }
                moreButton { resourceMenu(id: image.imageID, name: image.reference) { delete([image.id]) } }
            }
        }
        .transition(.fold)
    }

    private func volumeRow(_ volume: DockerVolume, usage: DockerUsage) -> some View {
        let title = volume.isAnonymous ? "\(volume.id.prefix(12))…\(volume.id.suffix(6))" : volume.id
        let shown = volume.isAnonymous ? "\(volume.id.prefix(12))…" : volume.id
        return DockerTableRow(
            kind: .volumes, name: volume.id, selectable: true,
            selected: selection.contains(volume.id), busy: docker.volumes.busy.contains(volume.id),
            toggle: { toggle(volume.id) }, click: { click(volume.id) },
            menu: { resourceMenu(id: volume.id, name: volume.id) { delete([volume.id]) } }
        ) {
            DockerNameCell(title: title,
                           subtitle: volume.mountpoint.isEmpty ? "/var/lib/docker/volumes/\(shown)/_data" : volume.mountpoint,
                           fullName: volume.id) {
                if volume.isAnonymous { DockerBadge(text: "Anonymous", tone: .grey) }
                if let project = volume.composeProject {
                    HStack(spacing: Space.xs) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.projectTint(for: project).colour)
                            .frame(width: 6, height: 6)
                        Text(project)
                    }
                    .font(Typography.micro)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xxs)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.inset))
                }
            }
        } cells: {
            let widths = DockerColumns.widths(.volumes)
            DockerUsersCell(users: usage.users(of: volume))
                .frame(width: widths[0], alignment: .leading)
            DockerSizeCell(bytes: docker.volumeSizes[volume.id] ?? volume.bytes)
                .frame(width: widths[1], alignment: .trailing)
        } actions: {
            HStack(spacing: Space.xs) {
                rowGlyph("trash", "Delete volume") { delete([volume.id]) }
                moreButton { resourceMenu(id: volume.id, name: volume.id) { delete([volume.id]) } }
            }
        }
        .transition(.fold)
    }

    private func networkRow(_ network: DockerNetwork, usage: DockerUsage) -> some View {
        let users = usage.users(of: network)
        let menu = { resourceMenu(id: network.id, name: network.name,
                                  delete: network.isBuiltIn ? nil : { delete([network.id]) }) }
        return DockerTableRow(
            kind: .networks, name: network.name, selectable: !network.isBuiltIn,
            selected: selection.contains(network.id), busy: docker.networks.busy.contains(network.id),
            toggle: { toggle(network.id) }, click: { click(network.id) }, menu: menu
        ) {
            DockerNameCell(title: network.name, subtitle: "\(network.shortID)  \(network.scope)") {
                if network.isBuiltIn { DockerBadge(text: "Built in", tone: .grey) }
                if network.isInternal { DockerBadge(text: "Internal") }
                if network.supportsIPv6 { DockerBadge(text: "IPv6") }
            }
        } cells: {
            let widths = DockerColumns.widths(.networks)
            Text(network.driver)
                .font(Typography.detail)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: widths[0], alignment: .leading)
            Group {
                if users.isEmpty {
                    Text("None").font(Typography.detail).foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: Space.sm) {
                        Circle().fill(users.contains(where: \.isRunning) ? Theme.dotOn : Theme.dotOff)
                            .frame(width: 6, height: 6)
                        Text(counted(users.count, "container")).font(Typography.detail)
                    }
                    .appTooltip(users.map(\.name).joined(separator: ", "))
                }
            }
            .frame(width: widths[1], alignment: .leading)
        } actions: {
            HStack(spacing: Space.xs) {
                if !network.isBuiltIn {
                    rowGlyph("trash", "Delete network") { delete([network.id]) }
                }
                moreButton(menu)
            }
        }
        .transition(.fold)
    }

    private func rowGlyph(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        GlyphButton(icon: icon, side: ControlHeight.sm, action: action)
            .appTooltip(label)
            .accessibilityLabel(label)
    }

    private func moreButton(_ entries: @escaping () -> [MenuEntry]) -> some View {
        GlyphButton(icon: "ellipsis", side: ControlHeight.sm)
            .appMenu(entries)
            .accessibilityLabel("More actions")
    }

    private func groupHeader(_ group: ContainerGroup) -> some View {
        let ids = group.containers.map(\.id)
        return DockerGroupHeader(
            project: group.project, containers: group.containers,
            selectedCount: ids.count { selection.contains($0) },
            collapsed: collapsed.contains(group.key),
            busy: ids.contains { docker.working[$0] != nil },
            toggle: {
                if ids.allSatisfy(selection.contains) { selection.subtract(ids) } else { selection.formUnion(ids) }
            },
            collapse: {
                // The rows only fade, so with Reduce Motion they keep the fade at a gentle pace.
                let closing = !collapsed.contains(group.key)
                withAnimation(closing && !reduceMotion ? Motion.leave : Motion.reveal) {
                    collapsed.formSymmetricDifference([group.key])
                }
            },
            act: { verb in
                guard let project = group.project else { return }
                let targets = group.containers.filter { verb == .stop ? $0.isRunning : !$0.isRunning }
                run(verb, on: targets, named: project) { await docker.compose(verb, project: project, containers: targets) }
            })
    }

    // MARK: - What is shown

    private struct ContainerGroup {
        let key: String
        let project: String?
        let containers: [DockerContainer]
    }

    private func matches(_ fields: [String?]) -> Bool {
        guard !query.isEmpty else { return true }
        return fields.compactMap(\.self).joined(separator: " ").localizedCaseInsensitiveContains(query)
    }

    private func sorted<Item>(_ items: [Item], name: (Item) -> String, bytes: (Item) -> Int64) -> [Item] {
        switch sort {
        case .name: items.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        case .size: items.sorted { bytes($0) > bytes($1) }
        }
    }

    private var visibleContainers: [DockerContainer] {
        let items = docker.containers.items.filter { container in
            switch filter {
            case .running: container.isRunning
            case .stopped: !container.isRunning
            default: true
            }
        }
        .filter { matches([$0.name, $0.image, $0.composeProject, $0.composeService, $0.shortID]) }
        return sorted(items, name: \.name) { $0.bytes ?? 0 }
    }

    private var groups: [ContainerGroup] {
        Dictionary(grouping: visibleContainers) { $0.composeProject }
            .map { ContainerGroup(key: $0.key ?? Self.standalone, project: $0.key, containers: $0.value) }
            .sorted { left, right in
                switch (left.project, right.project) {
                case let (left?, right?): left.localizedStandardCompare(right) == .orderedAscending
                case (.some, .none): true
                default: false
                }
            }
    }

    private var visibleImages: [DockerImage] {
        let usage = DockerUsage(containers: docker.containers.items)
        let items = docker.images.items.filter { image in
            switch filter {
            case .used: !usage.users(of: image).isEmpty
            case .unused: !image.isUntagged && usage.users(of: image).isEmpty
            case .untagged: image.isUntagged
            default: true
            }
        }
        .filter { matches([$0.reference, $0.shortID]) }
        let ordered = sorted(items, name: \.reference) { $0.bytes ?? 0 }
        // Untagged images have no name to sort by, so they gather at the end.
        return sort == .name ? ordered.filter { !$0.isUntagged } + ordered.filter(\.isUntagged) : ordered
    }

    private var visibleVolumes: [DockerVolume] {
        let usage = DockerUsage(containers: docker.containers.items)
        let items = docker.volumes.items.filter { volume in
            switch filter {
            case .used: !usage.users(of: volume).isEmpty
            case .unused: usage.users(of: volume).isEmpty
            case .anonymous: volume.isAnonymous
            default: true
            }
        }
        .filter { matches([$0.id, $0.composeProject]) }
        return sorted(items, name: \.id) { docker.volumeSizes[$0.id] ?? $0.bytes ?? 0 }
    }

    private var visibleNetworks: [DockerNetwork] {
        let usage = DockerUsage(containers: docker.containers.items)
        let items = docker.networks.items.filter { network in
            switch filter {
            case .yours: !network.isBuiltIn
            case .unused: !network.isBuiltIn && usage.users(of: network).isEmpty
            default: true
            }
        }
        .filter { matches([$0.name, $0.composeProject, $0.shortID]) }
        let ordered = sorted(items, name: \.name) { _ in 0 }
        return ordered.filter { !$0.isBuiltIn } + ordered.filter(\.isBuiltIn)
    }

    // In the order they are drawn, so a shift-click picks the run the user can see.
    private var visibleIDs: [String] {
        switch kind {
        case .containers:
            grouped ? groups.filter { !collapsed.contains($0.key) }.flatMap { $0.containers.map(\.id) }
                : visibleContainers.map(\.id)
        case .images: visibleImages.map(\.id)
        case .volumes: visibleVolumes.map(\.id)
        case .networks: visibleNetworks.map(\.id)
        }
    }

    private var selectableVisibleIDs: [String] {
        guard kind == .networks else { return visibleIDs }
        let builtIn = Set(docker.networks.items.filter(\.isBuiltIn).map(\.id))
        return visibleIDs.filter { !builtIn.contains($0) }
    }

    private var allIDs: Set<String> {
        switch kind {
        case .containers: Set(docker.containers.items.map(\.id))
        case .images: Set(docker.images.items.map(\.id))
        case .volumes: Set(docker.volumes.items.map(\.id))
        case .networks: Set(docker.networks.items.map(\.id))
        }
    }

    // MARK: - Selecting

    private func toggle(_ id: String) {
        if selection.remove(id) == nil { selection.insert(id) }
        anchor = id
    }

    private func click(_ id: String) {
        let ids = selectableVisibleIDs
        if NSEvent.modifierFlags.contains(.shift), let anchor,
           let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: id) {
            selection.formUnion(ids[min(from, to)...max(from, to)])
        } else {
            toggle(id)
        }
    }

    private func toggleAll() {
        let ids = selectableVisibleIDs
        if headCheck.on { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    private var selectionBar: DockerSelectionBar? {
        guard !selection.isEmpty else { return nil }
        let bytes: Int64
        var running = 0
        switch kind {
        case .containers:
            let chosen = docker.containers.items.filter { selection.contains($0.id) }
            bytes = chosen.reduce(0) { $0 + ($1.bytes ?? 0) }
            running = chosen.count(where: \.isRunning)
        case .images:
            bytes = docker.images.items.filter { selection.contains($0.id) }.reduce(0) { $0 + ($1.bytes ?? 0) }
        case .volumes:
            bytes = docker.volumes.items.filter { selection.contains($0.id) }
                .reduce(0) { $0 + (docker.volumeSizes[$1.id] ?? $1.bytes ?? 0) }
        case .networks:
            bytes = 0
        }
        return DockerSelectionBar(
            kind: kind, count: selection.count, bytes: bytes, running: running,
            delete: { delete(Array(selection)) },
            act: { verb in act(verb, on: docker.containers.items.filter { selection.contains($0.id) }) },
            clear: { selection = []; anchor = nil })
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard dialogs.current == nil, !menus.isOpen else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let escape = event.keyCode == 53
        if flags == .command, key == "f" {
            searchFocused = true
            return true
        }
        if flags == .command, let number = Int(key), let target = DockerKind(rawValue: number - 1) {
            switchKind(target)
            return true
        }
        if WindowKeyHandler.isTyping(event.window?.firstResponder) {
            guard escape, searchFocused else { return false }
            searchFocused = false
            return true
        }
        if flags == .command, key == "a" {
            selection.formUnion(selectableVisibleIDs)
            return true
        }
        if escape, !selection.isEmpty, flags.isEmpty {
            selection = []
            anchor = nil
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117, flags.isEmpty || flags == .command, !selection.isEmpty {
            delete(Array(selection))
            return true
        }
        return false
    }

    private func switchKind(_ target: DockerKind) {
        guard target != kind else { return }
        withAnimation(reduceMotion ? nil : Motion.reveal) { kind = target }
    }

    // MARK: - Acting

    private func act(_ verb: DockerVerb, on containers: [DockerContainer]) {
        let targets = containers.filter { verb == .start ? !$0.isRunning : $0.isRunning }
        guard !targets.isEmpty else { return }
        let name = targets.count == 1 ? targets[0].name : counted(targets.count, "container")
        run(verb, on: targets, named: name) { await docker.perform(verb, on: targets) }
    }

    private func run(_ verb: DockerVerb, on containers: [DockerContainer], named name: String,
                     _ work: @escaping () async -> String?) {
        guard !containers.isEmpty else { return }
        Task {
            if let failure = await work() {
                dialogs.show(.notice("Could not \(String(describing: verb)) \(name)", message: failure))
            } else {
                showNote("\(verb.past) \(name)", icon: noteIcon(verb))
            }
        }
    }

    private func noteIcon(_ verb: DockerVerb) -> String {
        switch verb {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        case .remove: "trash"
        }
    }

    private func openPort(_ port: String) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
        showNote("Opened localhost:\(port) in your browser", icon: "arrow.up.forward.app")
    }

    private var dockerCommand: String {
        (ProcessManager.resolve("docker") ?? "docker").shellQuoted
    }

    private func containerMenu(_ container: DockerContainer) -> [MenuEntry] {
        [
            .item("Show logs in a terminal", icon: "text.alignleft") {
                if SystemTerminal.run("\(dockerCommand) logs --follow --tail 500 \(container.name.shellQuoted)") {
                    showNote("Opened the logs of \(container.name) in \(SystemTerminal.appName)", icon: "terminal")
                }
            },
            .item("Open a shell inside", icon: "terminal", disabled: container.state != .running) {
                if SystemTerminal.run("\(dockerCommand) exec -it \(container.name.shellQuoted) sh") {
                    showNote("Opened a shell in \(container.name)", icon: "terminal")
                }
            },
            .separator,
            .item("Copy ID", icon: "doc.on.doc") { copy(container.id, note: "Copied \(container.shortID)") },
            .item("Copy name", icon: "doc.on.doc") { copy(container.name, note: "Copied the name") },
            .separator,
            .item("Delete container…", kind: .destructive, icon: "trash") { delete([container.id]) }
        ]
    }

    private func resourceMenu(id: String, name: String, delete: (() -> Void)?) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("Copy ID", icon: "doc.on.doc") { copy(id, note: "Copied the ID") },
            .item("Copy name", icon: "doc.on.doc") { copy(name, note: "Copied the name") }
        ]
        if let delete {
            entries.append(.separator)
            entries.append(.item("Delete…", kind: .destructive, icon: "trash", action: delete))
        }
        return entries
    }

    private func copy(_ text: String, note: String) {
        Pasteboard.copy(text)
        showNote(note, icon: "doc.on.doc")
    }

    // MARK: - Deleting

    private func delete(_ ids: [String]) {
        let ids = Set(ids)
        let usage = DockerUsage(containers: docker.containers.items)
        switch kind {
        case .containers:
            let chosen = docker.containers.items.filter { ids.contains($0.id) }
            confirm(DockerDeletion.containers(chosen)) { going in
                let targets = chosen.filter { going.contains($0.id) }
                let failure = await docker.perform(.remove, on: targets)
                return failure.map { message in Dictionary(uniqueKeysWithValues: targets.map { ($0.id, message) }) } ?? [:]
            }
        case .images:
            let chosen = docker.images.items.filter { ids.contains($0.id) }
            confirm(DockerDeletion.images(chosen, usage: usage)) { going in
                await docker.delete(chosen.filter { going.contains($0.id) })
            }
        case .volumes:
            let chosen = docker.volumes.items.filter { ids.contains($0.id) }
            confirm(DockerDeletion.volumes(chosen, sizes: docker.volumeSizes, usage: usage)) { going in
                await docker.delete(chosen.filter { going.contains($0.id) })
            }
        case .networks:
            let chosen = docker.networks.items.filter { ids.contains($0.id) && !$0.isBuiltIn }
            guard !chosen.isEmpty else { return }
            confirm(DockerDeletion.networks(chosen, usage: usage)) { going in
                await docker.delete(chosen.filter { going.contains($0.id) })
            }
        }
    }

    // Docker's own complaint is shown once the question is answered, so a failed removal
    // says why rather than quietly leaving the row where it was. What failed stays ticked,
    // so trying again is one click.
    private func confirm(_ plan: DockerDeletion,
                         _ work: @escaping (Set<String>) async -> [String: String]) {
        let kind = plan.kind
        var dialog = Dialog.impact(plan.title,
                                   rows: plan.rows.map { .init(title: $0.title, detail: $0.detail, kept: $0.kept) },
                                   warning: plan.warning, action: plan.action) {
            let going = Set(plan.going.map(\.id))
            Task {
                animatesRows = true
                let failures = await work(going)
                let done = plan.going.filter { failures[$0.id] == nil }
                selection = Set(failures.keys)
                try? await Task.sleep(for: .milliseconds(250))
                animatesRows = false
                if failures.isEmpty {
                    let freed = done.reduce(0) { $0 + $1.bytes }
                    showNote("Deleted \(kind.amount(done.count))" + (freed > 0 ? ", freed \(DockerSize.text(freed))" : ""),
                             icon: "trash")
                } else {
                    reportFailures(failures, of: plan, deleted: done)
                }
            }
        }
        if !plan.canDelete { dialog.actions[0].isEnabled = { false } }
        dialogs.show(dialog)
    }

    private func reportFailures(_ failures: [String: String], of plan: DockerDeletion,
                                deleted: [DockerDeletion.Item]) {
        let kind = plan.kind
        let failed = plan.going.filter { failures[$0.id] != nil }
        let title = deleted.isEmpty
            ? (failed.count == 1 ? "Could not delete \"\(failed[0].label)\"" : "Could not delete \(kind.amount(failed.count))")
            : "Deleted \(deleted.count) of \(kind.amount(plan.going.count))"
        var lines: [String] = []
        if !deleted.isEmpty {
            let freed = deleted.reduce(0) { $0 + $1.bytes }
            lines.append(deleted.map(\.label).joined(separator: ", ")
                         + (deleted.count == 1 ? " is gone" : " are gone")
                         + (freed > 0 ? ", freeing \(DockerSize.text(freed))." : "."))
        }
        for item in failed {
            lines.append("\(item.label): \(failures[item.id] ?? "")")
        }
        let message = lines.joined(separator: "\n\n")
        // Docker refuses an image another tag points at until it is forced. That is the
        // one refusal with a clear way through, so it is offered here.
        let forcible = kind == .images && failed.contains { failures[$0.id]?.contains("must be forced") == true }
        guard forcible else {
            dialogs.show(.notice(title, message: message))
            return
        }
        let images = docker.images.items.filter { image in failed.contains { $0.id == image.id } }
        dialogs.show(.confirm(title, message: message, action: "Force delete", cancel: "Keep it") {
            Task {
                animatesRows = true
                let again = await docker.delete(images, force: true)
                selection = Set(again.keys)
                try? await Task.sleep(for: .milliseconds(250))
                animatesRows = false
                if let first = again.values.first {
                    dialogs.show(.notice("Could not delete \(kind.amount(again.count))", message: first))
                } else {
                    showNote("Deleted \(kind.amount(images.count))", icon: "trash")
                }
            }
        })
    }

    // MARK: - Clean up

    private func cleanUp() {
        guard isUp else { return }
        let plan = { (removing: Bool) in
            DockerCleanUp(containers: docker.containers.items, images: docker.images.items,
                          volumes: docker.volumes.items, networks: docker.networks.items,
                          volumeSizes: docker.volumeSizes, disk: docker.disk, removingStopped: removing)
        }
        let run = DockerCleanUpRun()
        dialogs.show(Dialog(
            title: "Clean up Docker",
            content: AnyView(DockerCleanUpView(plans: (plan(false), plan(true)), run: run) { freed in
                selection = []
                showNote("Freed \(DockerSize.text(freed))", icon: "sparkles")
            }),
            actions: [], width: 560, isModal: true, framesItself: true, fitsWindow: true,
            hugsContent: true, maximumHeight: 640, canDismiss: { !run.isWorking }))
    }

    // MARK: - Notes

    // A second note keeps the line up rather than letting the first one's timer take it
    // down early.
    private func showNote(_ text: String, icon: String) {
        notes += 1
        let shown = notes
        noteIcon = icon
        note = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            if notes == shown { note = nil }
        }
    }
}
