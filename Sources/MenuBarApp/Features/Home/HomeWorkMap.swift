import SwiftUI
import CodeStationCore

struct HomeLive: Identifiable {
    let session: ChatSession
    // The conversation the runner holds for this row: the Design one while Design is the
    // side working, which is also the one any question was asked from.
    let liveID: UUID
    let containerName: String
    let tint: Theme.ProjectTint
    let avatar: SidebarAvatar
    let tone: SessionTone
    let activity: String
    let location: String
    let destination: SessionDestination
    let permission: PermissionRequest?
    var finished = false

    var id: UUID { session.id }
    var containerID: UUID { session.workspaceID ?? session.projectID }
    var needsAttention: Bool { tone == .needsYou }

    var status: String {
        if let permission { return permission.isQuestion ? "Answer needed" : "Permission needed" }
        if finished { return "Ready to review" }
        switch tone {
        case .running: return destination == .design ? "Designing" : "Working"
        case .waiting: return "Waiting on a task"
        case .needsYou: return "Needs your attention"
        case .idle: return session.hasStarted ? "Ready to resume" : "Not started"
        }
    }

    func primaryAction(hasChanges: Bool) -> (title: String, destination: SessionDestination) {
        if permission != nil { return ("View request", destination) }
        if destination == .design { return ("Open Design", .design) }
        if finished {
            return hasChanges ? ("Review changes", .changes) : ("Review result", destination)
        }
        return (tone == .idle ? "Resume session" : "Open session", destination)
    }

    // The answers that can be given from Home without reading more than its card shows.
    // A plan is a page to read and a question with many parts needs the full form, so
    // those are answered in the session.
    var quickAnswers: [(title: String, answer: PermissionAnswer)] {
        guard let permission else { return [] }
        if permission.isQuestion {
            guard permission.questions.count == 1, let question = permission.questions.first,
                  !question.multiSelect, question.options.count <= 3 else { return [] }
            return question.options.map { ($0.label, .answers([question.text: $0.label])) }
        }
        guard !permission.subjectIsMarkdown else { return [] }
        return [("Allow", .allowOnce), ("Deny", .deny)]
    }
}

struct HomeWorkMap {
    struct Group: Identifiable {
        let id: UUID
        let sessions: [HomeLive]
        var identity: HomeLive { sessions[0] }
    }

    // The shape the map takes. It changes as the work grows, so the map is only ever as
    // tall as what is on it.
    enum Layout: Equatable {
        // Nothing running: one line saying so.
        case quiet
        // Projects around a hub, each with its first sessions beside it.
        case orbit
        // Too much for the orbit, or too little width: what needs you first, then every
        // project as a small card.
        case board
    }

    let sessions: [HomeLive]

    var active: [HomeLive] { sessions.filter { $0.tone != .idle } }
    var waiting: [HomeLive] { active.filter(\.needsAttention) }
    var runningCount: Int { active.count { $0.tone == .running } }
    var backgroundWaitCount: Int { active.count { $0.tone == .waiting } }

    // Which cards and rows are on the map, so the home page can animate when that changes.
    var shape: [[UUID]] { groups.map { [$0.id] + $0.sessions.map(\.id) } }

    var containerSummary: String {
        let workspaces = groups.count { $0.identity.session.workspaceID != nil }
        let projects = groups.count - workspaces
        var parts: [String] = []
        if projects > 0 { parts.append(counted(projects, "project")) }
        if workspaces > 0 { parts.append(counted(workspaces, "workspace")) }
        return parts.joined(separator: " and ")
    }

    var groups: [Group] {
        let grouped = Dictionary(grouping: active, by: \.containerID)
        return grouped.map { Group(id: $0.key, sessions: $0.value.sorted(by: Self.comesFirst)) }
            .sorted {
                let order = $0.identity.containerName.localizedStandardCompare($1.identity.containerName)
                return order == .orderedSame
                    ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
    }

    // Projects and sessions are counted together, because one project with many sessions
    // overflows a layout just as many projects do.
    func layout(width: CGFloat) -> Layout {
        let projects = groups.count
        let count = active.count
        if count == 0 { return .quiet }
        if projects <= OrbitLayout.maxProjects && count <= OrbitLayout.maxSessions
            && width >= OrbitLayout.minWidth { return .orbit }
        return .board
    }

    static let boardShownPerProject = 4
    static let boardColumnWidth: CGFloat = 220
    static let boardGap: CGFloat = 10

    // The board's project cards split into columns of about the same height. Each card
    // goes to the shortest column so far, which keeps the order readable left to right.
    func boardColumns(width: CGFloat) -> [[Group]] {
        let groups = groups
        let fits = Int((width + Self.boardGap) / (Self.boardColumnWidth + Self.boardGap))
        let count = min(max(1, fits), max(1, groups.count))
        var columns = Array(repeating: [Group](), count: count)
        var heights = Array(repeating: CGFloat(0), count: count)
        for group in groups {
            let rows = min(group.sessions.count, Self.boardShownPerProject)
                + (group.sessions.count > Self.boardShownPerProject ? 1 : 0)
            let index = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[index].append(group)
            heights[index] += 41 + 30 * CGFloat(rows) + Self.boardGap
        }
        return columns
    }

    private static func comesFirst(_ first: HomeLive, _ second: HomeLive) -> Bool {
        if (first.permission != nil) != (second.permission != nil) { return first.permission != nil }
        if first.needsAttention != second.needsAttention { return first.needsAttention }
        if (first.tone == .running) != (second.tone == .running) { return first.tone == .running }
        if first.session.lastActivity != second.session.lastActivity {
            return first.session.lastActivity > second.session.lastActivity
        }
        return first.id.uuidString < second.id.uuidString
    }
}

struct HomeWorkMapView: View {
    let map: HomeWorkMap
    // The room the map has inside its card.
    let width: CGFloat
    let hasChanges: (HomeLive) -> Bool
    // How long a session has spent working, across every turn it has taken.
    let workTime: (HomeLive) -> TimeInterval
    let open: (HomeLive, SessionDestination) -> Void
    let answer: (HomeLive, PermissionAnswer) -> Void
    // Shows a project or workspace in the sidebar, where all of its sessions are listed.
    let reveal: (HomeWorkMap.Group) -> Void
    // Whether the orbit builds itself up as it appears. It does once each time Home opens,
    // and the map reports when that has been used up.
    let opening: Bool
    let onOpened: () -> Void

    static let reflow = Animation.smooth(duration: 0.3)

    var body: some View {
        let layout = map.layout(width: width)
        VStack(alignment: .leading, spacing: 14) {
            heading
            // A new layout fades in over the old one while the card resizes around it.
            ZStack(alignment: .topLeading) {
                switch layout {
                case .quiet:
                    quiet
                case .orbit:
                    OrbitMap(map: map, width: width, hasChanges: hasChanges, workTime: workTime,
                             open: open, answer: answer, reveal: reveal,
                             opening: opening, onOpened: onOpened)
                case .board:
                    HomeBoard(map: map, width: width, hasChanges: hasChanges, open: open,
                              answer: answer, reveal: reveal)
                }
            }
            .id(layout)
            .transition(.opacity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Canvas { context, size in
                for x in stride(from: 0.0, to: size.width, by: 16) {
                    for y in stride(from: 0.0, to: size.height, by: 16) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                                     with: .color(Theme.border))
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .cardSurface(cornerRadius: 16)
        .motion(Self.reflow, value: layout)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Work map")
    }

    private var heading: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 12)
            if map.active.isEmpty {
                Text("Nothing running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                let needs = map.waiting.count
                if needs > 0 {
                    HStack(spacing: 6) {
                        MapLight(tone: .needsYou)
                        Text("\(needs) need\(needs == 1 ? "s" : "") you")
                    }
                }
                let waits = map.backgroundWaitCount
                if waits > 0 {
                    HStack(spacing: 6) {
                        MapLight(tone: .waiting)
                        Text("\(waits) waiting")
                    }
                }
                Text("\(counted(map.active.count, "session")) across \(map.containerSummary)")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    // The same ring the orbit is drawn around, empty, so a quiet day still reads as the map.
    // It is drawn smaller than the orbit's hub, since there is nothing around it to balance.
    private static let quietScale: CGFloat = 0.7

    private var quiet: some View {
        let scale = Self.quietScale
        return VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .frame(width: 2 * OrbitLayout.orbitRadius * scale,
                           height: 2 * OrbitLayout.orbitRadius * scale)
                Circle()
                    .stroke(Theme.hairline, lineWidth: OrbitLayout.ringWidth * scale)
                    .frame(width: 2 * OrbitLayout.ringRadius * scale,
                           height: 2 * OrbitLayout.ringRadius * scale)
                Circle()
                    .stroke(Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                    .frame(width: 2 * OrbitLayout.projectRingRadius * scale,
                           height: 2 * OrbitLayout.projectRingRadius * scale)
                VStack(spacing: 2) {
                    Text("0")
                        .font(.serif(36, .medium))
                        .foregroundStyle(.tertiary)
                    Text("working")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: OrbitLayout.hubSide * scale, height: OrbitLayout.hubSide * scale)
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Room for your next idea").font(.serif(15, .semibold))
                Text("Nothing is running.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
    }
}

// The map for a busy day or a narrow window. A band sums up the day, every session that
// needs you is listed first with its buttons, and then each project is a small card. No
// wires: at this size they would cross each other and stop meaning anything.
private struct HomeBoard: View {
    let map: HomeWorkMap
    let width: CGFloat
    let hasChanges: (HomeLive) -> Bool
    let open: (HomeLive, SessionDestination) -> Void
    let answer: (HomeLive, PermissionAnswer) -> Void
    let reveal: (HomeWorkMap.Group) -> Void

    var body: some View {
        let groups = map.groups
        // Listed here and again in their project's card, so each card's count stays true.
        let needsYou = groups.flatMap(\.sessions).filter(\.needsAttention)
        let columns = map.boardColumns(width: width)
        VStack(alignment: .leading, spacing: 14) {
            band
            if !needsYou.isEmpty {
                VStack(spacing: 6) {
                    ForEach(needsYou) { live in
                        HomeMapActionRow(live: live, hasChanges: hasChanges(live), showsProject: true,
                                         open: { open(live, $0) }, answer: { answer(live, $0) })
                            .frame(height: 46)
                    }
                }
            }
            HStack(alignment: .top, spacing: HomeWorkMap.boardGap) {
                ForEach(columns.indices, id: \.self) { index in
                    VStack(spacing: HomeWorkMap.boardGap) {
                        ForEach(columns[index]) { card($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
    }

    private var band: some View {
        HStack(spacing: 16) {
            OrbitHub(map: map, side: 64, ringWidth: 5, numberSize: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(counted(map.runningCount, "session")) working")
                    .font(.serif(18, .semibold))
                HStack(spacing: 14) {
                    let needs = map.waiting.count
                    if needs > 0 {
                        Label { Text("\(needs) need\(needs == 1 ? "s" : "") you") } icon: {
                            MapLight(tone: .needsYou)
                        }
                    }
                    let waits = map.backgroundWaitCount
                    if waits > 0 {
                        Label { Text("\(waits) waiting on a task") } icon: { MapLight(tone: .waiting) }
                    }
                }
                .labelStyle(BandTallyStyle())
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func card(_ group: HomeWorkMap.Group) -> some View {
        let identity = group.identity
        let shown = group.sessions.prefix(HomeWorkMap.boardShownPerProject)
        let hidden = group.sessions.count - shown.count
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                SidebarIdentityTile(avatar: identity.avatar, name: identity.containerName,
                                    tint: identity.tint,
                                    stacked: identity.session.workspaceID != nil, side: 22)
                    .accessibilityHidden(true)
                Text(identity.containerName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(group.sessions.count)").font(.mono(10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ForEach(shown) { live in
                BoardSessionItem(live: live) {
                    open(live, live.primaryAction(hasChanges: hasChanges(live)).destination)
                }
            }
            if hidden > 0 {
                BoardMoreItem(count: hidden, name: identity.containerName) { reveal(group) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .cardSurface(cornerRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(identity.containerName)
    }
}

private struct BandTallyStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

private struct BoardSessionItem: View {
    let live: HomeLive
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                MapLight(tone: live.tone)
                Text(live.session.title)
                    .font(.system(size: 11.5, weight: live.needsAttention ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(RelativeTime.short(live.session.lastActivity))
                    .font(.mono(10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(hovering ? Theme.field : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(live.session.title), \(live.status), \(live.containerName)")
        .accessibilityHint("Opens this session")
    }
}

private struct BoardMoreItem: View {
    let count: Int
    let name: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("+\(count) more")
                .font(.system(size: 11.5))
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(hovering ? Theme.field : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityHint("Shows \(name) in the sidebar")
    }
}

struct MapConnector: Shape {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint

    init(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) {
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
    }

    // Bends halfway across, so the line leaves and arrives level.
    init(start: CGPoint, end: CGPoint) {
        let middle = (start.x + end.x) / 2
        self.init(start: start, control1: CGPoint(x: middle, y: start.y),
                  control2: CGPoint(x: middle, y: end.y), end: end)
    }

    var animatableData: AnimatablePair<AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>,
                                       AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>> {
        get {
            AnimatablePair(AnimatablePair(start.animatableData, control1.animatableData),
                           AnimatablePair(control2.animatableData, end.animatableData))
        }
        set {
            start.animatableData = newValue.first.first
            control1.animatableData = newValue.first.second
            control2.animatableData = newValue.second.first
            end.animatableData = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)
        return path
    }
}

// A session as a full row with its buttons on it, for the board's list of what needs you. A short request is answered right here; anything else opens the
// session.
struct HomeMapActionRow: View {
    let live: HomeLive
    let hasChanges: Bool
    // The board lists sessions from every project in one place, so each row names its own.
    var showsProject = false
    let open: (SessionDestination) -> Void
    let answer: (PermissionAnswer) -> Void

    @State private var hovering = false

    var body: some View {
        let needs = live.needsAttention
        let shape = RoundedRectangle(cornerRadius: 12)
        HStack(spacing: 12) {
            if showsProject {
                HStack(spacing: 6) {
                    SidebarIdentityTile(avatar: live.avatar, name: live.containerName, tint: live.tint,
                                        stacked: live.session.workspaceID != nil, side: 18)
                        .accessibilityHidden(true)
                    Text(live.containerName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(width: 150, alignment: .leading)
            }
            MapLight(tone: live.tone)
            VStack(alignment: .leading, spacing: 3) {
                Text(live.session.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                if let request {
                    request
                        .font(.system(size: 11.5))
                        .foregroundStyle(needs ? Theme.attentionText : .secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(showsProject ? age : "\(live.session.agent.title) · \(age)")
                .font(.mono(10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
            actions
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            shape.fill(Theme.card)
            if needs { shape.fill(Theme.attention.opacity(0.08)) }
        }
        .overlay(shape.stroke(needs ? Theme.attention.opacity(0.55)
                              : hovering ? Theme.accent.opacity(0.4) : Theme.border))
        .shadow(color: .black.opacity(0.05), radius: 4.5, y: 3)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(live.session.title), \(live.status), \(live.containerName)")
    }

    private var age: String { RelativeTime.short(live.session.lastActivity) }

    // What the session is asking for. A row with nothing to ask shows only its title.
    private var request: Text? {
        guard let permission = live.permission else { return nil }
        if let question = permission.questions.first { return Text(question.text) }
        let subject = permission.subject.components(separatedBy: .newlines).first ?? ""
        guard !permission.subjectIsMarkdown, !subject.isEmpty else { return Text(permission.title) }
        return Text("\(permission.title) ")
            + Text(subject).font(.mono(11)).foregroundStyle(Color.primary)
    }

    @ViewBuilder private var actions: some View {
        let quick = live.quickAnswers
        let primary = live.primaryAction(hasChanges: hasChanges)
        HStack(spacing: 6) {
            if !quick.isEmpty {
                if !showsProject {
                    ActionButton(title: "Open session", tone: .outlined, height: 26, size: 12) {
                        open(live.destination)
                    }
                }
                ForEach(quick.indices, id: \.self) { index in
                    ActionButton(title: quick[index].title, tone: index == 0 ? .green : .outlined,
                                 height: 26, size: 12) { answer(quick[index].answer) }
                }
            } else {
                let title = showsProject && live.permission?.isQuestion == true ? "Answer" : primary.title
                ActionButton(title: title, tone: live.needsAttention ? .green : .outlined,
                             height: 26, size: 12) { open(primary.destination) }
            }
        }
    }
}
