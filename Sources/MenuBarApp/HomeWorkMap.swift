import SwiftUI

struct HomeLive: Identifiable {
    let session: ChatSession
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
}

struct HomeWorkMap {
    struct Group: Identifiable {
        let id: UUID
        let sessions: [HomeLive]
        var identity: HomeLive { sessions[0] }
    }

    let sessions: [HomeLive]

    var active: [HomeLive] { sessions.filter { $0.tone != .idle } }
    var waiting: [HomeLive] { active.filter(\.needsAttention) }
    var runningCount: Int { active.count { $0.tone == .running } }

    // Which cards and rows are on the map, so the home page can animate when that changes.
    var shape: [[UUID]] { groups.map { [$0.id] + $0.sessions.map(\.id) } }

    var containerSummary: String {
        let workspaces = groups.count { $0.identity.session.workspaceID != nil }
        let projects = groups.count - workspaces
        var parts: [String] = []
        if projects > 0 { parts.append(counted(projects, "project")) }
        if workspaces > 0 { parts.append(counted(workspaces, "workspace")) }
        return parts.joined(separator: " · ")
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

    private static func comesFirst(_ first: HomeLive, _ second: HomeLive) -> Bool {
        if (first.permission != nil) != (second.permission != nil) { return first.permission != nil }
        if first.needsAttention != second.needsAttention { return first.needsAttention }
        if first.session.lastActivity != second.session.lastActivity {
            return first.session.lastActivity > second.session.lastActivity
        }
        return first.id.uuidString < second.id.uuidString
    }
}

struct HomeWorkMapView: View {
    let map: HomeWorkMap
    let compact: Bool
    let open: (HomeLive) -> Void

    static let reflow = Animation.smooth(duration: 0.3)

    private var spatial: Bool {
        !compact && !map.groups.isEmpty && map.groups.count <= 4
            && map.groups.allSatisfy { $0.sessions.count <= 4 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading
            if map.active.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "circle.grid.cross")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Room for your next idea").font(.serif(15, .semibold))
                        Text("No sessions are active. Start something new or pick up a recent conversation.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else if spatial {
                spatialMap
            } else {
                HStack(spacing: 8) {
                    Text("\(map.runningCount)").font(.serif(28))
                    Text("sessions working").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                // No inner scroll: the home page already scrolls, and a nested one with a height
                // cap cut cards off halfway with no sign that more were hidden below.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 12) {
                    ForEach(map.groups) { group in groupCard(group) }
                }
            }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Work map")
    }

    private var heading: some View {
        Label("Your work map", systemImage: "square.grid.2x2")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.accent)
    }

    private var spatialMap: some View {
        let groups = map.groups
        let left = Array(groups.prefix(groups.count == 4 ? 2 : 1))
        let right = Array(groups.dropFirst(left.count))
        return HStack(spacing: 22) {
            column(left)
            VStack(spacing: 22) {
                VStack(spacing: 5) {
                    Text("\(map.runningCount)").font(.serif(48, .medium))
                    Text("sessions working").font(.system(size: 11))
                    Circle().fill(map.runningCount > 0 ? Theme.addition : Theme.dotOff)
                        .frame(width: 5, height: 5)
                }
                .foregroundStyle(Theme.accent)
                .frame(width: 126, height: 126)
                .background(Circle().fill(Theme.card))
                .overlay(Circle().stroke(Theme.accent.opacity(0.3)))
                .padding(8)
                .background(Circle().fill(Theme.accent.opacity(0.06)))
                .overlay(Circle().stroke(Theme.accent.opacity(0.15)))
                .anchorPreference(key: MapAnchors.self, value: .bounds) { [.hub: $0] }
                Text("Across \(map.containerSummary)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 142)
            if !right.isEmpty { column(right) }
        }
        .backgroundPreferenceValue(MapAnchors.self) { anchors in
            GeometryReader { geometry in
                if let hub = anchors[.hub] {
                    let center = geometry[hub]
                    ForEach(groups) { group in
                        if let anchor = anchors[.group(group.id)] {
                            let rect = geometry[anchor]
                            let isLeft = rect.midX < center.midX
                            MapConnector(start: CGPoint(x: isLeft ? center.minX : center.maxX, y: center.midY),
                                         end: CGPoint(x: isLeft ? rect.maxX : rect.minX, y: rect.midY))
                                .stroke(Theme.accent.opacity(0.3), lineWidth: 1.3)
                        }
                    }
                }
            }
            // The anchors already hold where the cards end up, so without this the lines
            // would jump there while the cards are still moving.
            .animation(Self.reflow, value: map.shape)
            .accessibilityHidden(true)
        }
    }

    private func column(_ groups: [HomeWorkMap.Group]) -> some View {
        VStack(spacing: 24) {
            ForEach(groups) { group in
                groupCard(group)
                    .anchorPreference(key: MapAnchors.self, value: .bounds) { [.group(group.id): $0] }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func groupCard(_ group: HomeWorkMap.Group) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SidebarIdentityTile(avatar: group.identity.avatar, name: group.identity.containerName,
                                    tint: group.identity.tint,
                                    stacked: group.identity.session.workspaceID != nil, side: 25)
                Text(group.identity.containerName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(group.sessions.count)").font(.mono(10)).foregroundStyle(.secondary)
            }
            .padding(12)
            ForEach(group.sessions) { live in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HomeMapSessionRow(live: live) { open(live) }
            }
        }
        .cardSurface(cornerRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.identity.containerName)
    }
}

private struct MapAnchors: PreferenceKey {
    enum Key: Hashable { case hub, group(UUID) }
    static var defaultValue: [Key: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [Key: Anchor<CGRect>], nextValue: () -> [Key: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct MapConnector: Shape {
    var start: CGPoint
    var end: CGPoint

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(start.animatableData, end.animatableData) }
        set { start.animatableData = newValue.first; end.animatableData = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let middle = (start.x + end.x) / 2
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end,
                      control1: CGPoint(x: middle, y: start.y),
                      control2: CGPoint(x: middle, y: end.y))
        return path
    }
}

private struct HomeMapSessionRow: View {
    let live: HomeLive
    let open: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                StateLight(tone: live.tone)
                VStack(alignment: .leading, spacing: 5) {
                    Text(live.session.title)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text("\(live.status) · \(live.session.agent.title)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
            .padding(12)
            .background(hovering ? Theme.field : .clear)
            .overlay { if focused { Rectangle().stroke(Theme.accent, lineWidth: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(live.session.title), \(live.status), \(live.containerName)")
        .accessibilityHint("Opens this session")
    }
}
