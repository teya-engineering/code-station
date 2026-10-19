import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

struct HomeWorkMapTests {
    private func live(project: UUID = UUID(), workspace: UUID? = nil,
                      name: String = "Project", tone: SessionTone = .running,
                      permission: PermissionRequest? = nil, finished: Bool = false,
                      destination: SessionDestination = .conversation) -> HomeLive {
        var session = ChatSession(projectID: project, agent: .codex)
        session.workspaceID = workspace
        return HomeLive(session: session, liveID: session.id, containerName: name,
                        tint: Theme.projectTint(for: name),
                        avatar: SidebarAvatar(subject: workspace == nil ? .project : .workspace,
                                              id: workspace ?? project),
                        tone: tone, activity: "Working", location: "project folder",
                        destination: destination, permission: permission, finished: finished)
    }

    private var permission: PermissionRequest {
        PermissionRequest(id: "request", toolName: "Bash", title: "Run checks",
                          subject: "swift test", detail: "", input: Data(),
                          suggestions: nil, alwaysTitle: nil, questions: [])
    }

    @Test func groupsByIdentityAndKeepsWorkspaceSessionsTogether() {
        let project = UUID()
        let workspace = UUID()
        let standalone = live(project: project)
        let attached = live(project: project, workspace: workspace)
        let otherLead = live(workspace: workspace)
        let sameName = live()
        let idle = live(tone: .idle)
        let map = HomeWorkMap(sessions: [standalone, attached, otherLead, sameName, idle])

        #expect(map.groups.count == 3)
        #expect(map.groups.first { $0.id == workspace }?.sessions.count == 2)
        #expect(map.active.count == 4)
        #expect(map.sessions.count == 5)
    }

    @Test func countsWorkSeparatelyFromBackgroundWaitsAndAttention() {
        let map = HomeWorkMap(sessions: [live(), live(tone: .waiting),
                                        live(tone: .needsYou), live(tone: .idle)])
        #expect(map.runningCount == 1)
        #expect(map.waiting.count == 1)
        #expect(map.active.count == 3)
    }

    @Test func routesReviewToChangesOnlyWhenThereAreChanges() {
        let review = live(tone: .needsYou, finished: true)
        #expect(review.primaryAction(hasChanges: true).destination == .changes)
        #expect(review.primaryAction(hasChanges: false).destination == .conversation)
        let stale = live(tone: .needsYou)
        #expect(stale.primaryAction(hasChanges: true).title == "Open session")
        #expect(stale.status == "Needs your attention")
    }

    @Test func permissionsAndDesignsKeepTheirConversationDestination() {
        let request = live(tone: .needsYou, permission: permission)
        #expect(request.primaryAction(hasChanges: true).destination == .conversation)
        #expect(request.primaryAction(hasChanges: true).title == "View request")
        let design = live(tone: .needsYou, permission: permission, destination: .design)
        #expect(design.primaryAction(hasChanges: true).destination == .design)
        let designReview = live(tone: .needsYou, finished: true, destination: .design)
        #expect(designReview.primaryAction(hasChanges: true).destination == .design)
    }

    @Test func sortsSessionsByWhoNeedsYouThenWhatIsRunning() {
        let project = UUID()
        let waiting = live(project: project, tone: .waiting)
        let running = live(project: project, tone: .running)
        let needs = live(project: project, tone: .needsYou)
        let map = HomeWorkMap(sessions: [waiting, running, needs])
        #expect(map.groups[0].sessions.map(\.id) == [needs.id, running.id, waiting.id])
        #expect(map.backgroundWaitCount == 1)
    }

    @Test func offersQuickAnswersOnlyForShortRequests() {
        let allow = live(tone: .needsYou, permission: permission)
        #expect(allow.quickAnswers.map(\.title) == ["Allow", "Deny"])
        #expect(allow.quickAnswers.map(\.answer) == [.allowOnce, .deny])

        var plan = permission
        plan.subjectIsMarkdown = true
        #expect(live(tone: .needsYou, permission: plan).quickAnswers.isEmpty)

        let question = AgentQuestion(id: 0, header: "", text: "Keep the hub?", multiSelect: false,
                                     options: [.init(id: 0, label: "Keep it", description: ""),
                                               .init(id: 1, label: "Replace it", description: "")])
        let asked = live(tone: .needsYou, permission: request(questions: [question]))
        #expect(asked.quickAnswers.map(\.title) == ["Keep it", "Replace it"])
        #expect(asked.quickAnswers.first?.answer == .answers(["Keep the hub?": "Keep it"]))

        let several = AgentQuestion(id: 0, header: "", text: "Which?", multiSelect: true,
                                    options: question.options)
        #expect(live(tone: .needsYou, permission: request(questions: [several])).quickAnswers.isEmpty)
        #expect(live(tone: .needsYou, permission: request(questions: [question, question]))
            .quickAnswers.isEmpty)
        #expect(live(tone: .needsYou, finished: true).quickAnswers.isEmpty)
    }

    // A day with one project per entry in `counts`, holding that many running sessions.
    private func day(_ counts: [Int], tone: SessionTone = .running) -> [HomeLive] {
        counts.enumerated().flatMap { index, count in
            let project = UUID()
            return (0..<count).map { _ in live(project: project, name: "Project \(index)", tone: tone) }
        }
    }

    @Test func picksTheLayoutFromProjectsSessionsAndWidth() {
        #expect(HomeWorkMap(sessions: [live(tone: .idle)]).layout(width: 1000) == .quiet)
        #expect(HomeWorkMap(sessions: day([1])).layout(width: 1000) == .orbit)
        #expect(HomeWorkMap(sessions: day([2, 1])).layout(width: 1000) == .orbit)
        #expect(HomeWorkMap(sessions: day([3, 2])).layout(width: 1000) == .orbit)
        #expect(HomeWorkMap(sessions: day([1, 1, 1])).layout(width: 1000) == .orbit)
        #expect(HomeWorkMap(sessions: day([3, 1, 2, 1])).layout(width: 1000) == .orbit)
        #expect(HomeWorkMap(sessions: day([6])).layout(width: 1000) == .orbit)
        #expect(HomeWorkMap(sessions: day([11])).layout(width: 1000) == .orbit)
        #expect(HomeWorkMap(sessions: day([3, 2, 2, 2, 2, 2, 2, 2, 1])).layout(width: 1000) == .orbit)
        #expect(HomeWorkMap(sessions: day([21])).layout(width: 1000) == .board)
        #expect(HomeWorkMap(sessions: day(Array(repeating: 1, count: 11))).layout(width: 1400) == .board)
        // A window too narrow for the orbit gets the board, however little is running.
        #expect(HomeWorkMap(sessions: day([3, 1, 2, 1])).layout(width: 700) == .board)
        #expect(HomeWorkMap(sessions: day([1])).layout(width: 700) == .board)
    }

    @Test func orbitLaysOutABusyDayWithoutOverlaps() {
        var sessions: [HomeLive] = []
        let counts = [3, 2, 2, 1, 2, 1, 1]
        for (index, count) in counts.enumerated() {
            let project = UUID()
            for slot in 0..<count {
                sessions.append(live(project: project, name: "Project \(index)",
                                     tone: slot == 0 && index.isMultiple(of: 2) ? .needsYou : .running))
            }
        }
        #expect(sessions.count == 12)
        for width in [OrbitLayout.minWidth, 1000, 1400] {
            let layout = OrbitLayout(map: HomeWorkMap(sessions: sessions), width: width)
            #expect(layout.nodes.count == 7)
            #expect(layout.pills.count == 12)
            #expect(layout.more.isEmpty)
            expectNoOverlaps(layout)
        }
    }

    @Test func orbitStaysShortForAMediumDay() {
        let project = UUID()
        let sessions = [live(project: project), live(project: project, tone: .needsYou, permission: permission),
                        live(project: project, tone: .waiting)] + day([1, 1, 2])
        let map = HomeWorkMap(sessions: sessions)
        #expect(map.layout(width: 1100) == .orbit)
        let layout = OrbitLayout(map: map, width: 1100)
        #expect(layout.size.height == OrbitLayout.minHeight)
        expectNoOverlaps(layout)
    }

    @Test func phoneBandPushesTheWholeMapDownWithoutReshapingIt() {
        let map = HomeWorkMap(sessions: day([2, 1, 3]))
        let plain = OrbitLayout(map: map, width: 1100)
        let banded = OrbitLayout(map: map, width: 1100, phoneBand: OrbitLayout.phoneBand)
        #expect(banded.size.height == plain.size.height + OrbitLayout.phoneBand)
        #expect(banded.hub.y == plain.hub.y + OrbitLayout.phoneBand)
        #expect(banded.pills.map(\.frame.minY) == plain.pills.map { $0.frame.minY + OrbitLayout.phoneBand })
        // The line from a pill at the top of the band has room to fall before it meets the ring.
        #expect(banded.ringTop.y - OrbitPhoneBeacon.height > 30)
        expectNoOverlaps(banded)
    }

    @Test func phonePillSaysWhetherAPhoneJoinedAndWhereItIs() {
        let waiting = OrbitPhoneLink(connected: false, openSession: nil, openTitle: nil)
        #expect(waiting.state == "Waiting for phone")
        #expect(waiting.reachText == "Code is out for every project")

        let connected = OrbitPhoneLink(connected: true, openSession: nil, openTitle: nil)
        #expect(connected.state == "Phone connected")
        #expect(connected.reachText == "Can reach every project")

        let reading = OrbitPhoneLink(connected: true, openSession: UUID(), openTitle: "Fix the share sheet")
        #expect(reading.reachText == "Open on Fix the share sheet")
        #expect(reading.accessibilityLabel
                == "Phone connected. Open on Fix the share sheet. Show the code or stop sharing.")

        // A session the code still remembers from a phone that dropped is not where a phone is now.
        let dropped = OrbitPhoneLink(connected: false, openSession: UUID(), openTitle: "Fix the share sheet")
        #expect(dropped.openSession == nil)
        #expect(dropped.reachText == "Code is out for every project")
    }

    @Test func aConnectedPhoneLightsThePathToTheSessionItHasOpen() {
        let other = live()
        let map = HomeWorkMap(sessions: [live(), other])

        let reading = OrbitPhoneLink(connected: true, openSession: other.id, openTitle: "Other")
        let onSession = OrbitPhoneReach(link: reading, map: map)
        #expect(onSession.wires == ["hub:\(other.containerID)", "session:\(other.id)"])
        #expect(onSession.sessions == [other.id])

        let onList = OrbitPhoneLink(connected: true, openSession: nil, openTitle: nil)
        #expect(OrbitPhoneReach(link: onList, map: map) == OrbitPhoneReach())
        #expect(OrbitPhoneReach(link: nil, map: map) == OrbitPhoneReach())
    }

    private func tile(_ node: OrbitLayout.Node) -> CGRect {
        // The tile with its halo, and the name under it.
        CGRect(x: node.center.x - 26, y: node.center.y - 26, width: 52, height: 72)
    }

    private func expectNoOverlaps(_ layout: OrbitLayout) {
        let hub = CGRect(x: layout.hub.x - OrbitLayout.hubSide / 2, y: layout.hub.y - OrbitLayout.hubSide / 2,
                         width: OrbitLayout.hubSide, height: OrbitLayout.hubSide)
        let shapes = layout.pills.map(\.frame) + layout.more.map(\.frame) + layout.nodes.map(tile) + [hub]
        expectApart(shapes, in: layout.size)
    }

    private func expectApart(_ shapes: [CGRect], in size: CGSize) {
        for (index, shape) in shapes.enumerated() {
            #expect(shape.minX >= 0 && shape.maxX <= size.width && shape.minY >= 0
                    && shape.maxY <= size.height)
            for other in shapes[(index + 1)...] {
                #expect(!shape.intersects(other))
            }
        }
    }

    @Test func orbitGrowsTallerInsteadOfSqueezingAColumn() {
        var sessions: [HomeLive] = []
        for index in 0..<8 {
            let project = UUID()
            sessions += (0..<3).map { _ in live(project: project, name: "P\(index)", tone: .needsYou) }
        }
        let layout = OrbitLayout(map: HomeWorkMap(sessions: sessions), width: 1000)
        #expect(layout.size.height > OrbitLayout.minHeight)
        let frames = layout.pills.map(\.frame)
        for (index, frame) in frames.enumerated() {
            #expect(frame.height == OrbitLayout.tallPillHeight)
            for other in frames[(index + 1)...] { #expect(!frame.intersects(other)) }
        }
    }

    @Test func orbitFoldsSessionsPastTheShownOnesIntoAChip() {
        let project = UUID()
        let sessions = (0..<5).map { _ in live(project: project, name: "Busy") }
        let layout = OrbitLayout(map: HomeWorkMap(sessions: sessions), width: 1000)
        #expect(layout.shownPerProject == 3)
        #expect(layout.pills.count == 3)
        #expect(layout.more.map(\.count) == [2])
        #expect(layout.more[0].frame.minY > layout.pills.map(\.frame.maxY).max() ?? 0)
        // The ring still shows every session.
        #expect(layout.arcs.count == 5)
    }

    // Every arc's view covers the whole hub, so the arc under the pointer is found from
    // where on the ring the pointer is, not from which view it is over.
    @Test func orbitFindsTheArcUnderThePointer() throws {
        let layout = OrbitLayout(map: HomeWorkMap(sessions: day([1, 1, 1])), width: 1100)
        #expect(layout.arcs.count == 3)
        let middle = OrbitLayout.hubSide / 2
        let radius = OrbitLayout.ringRadius
        func onRing(degreesFromTop degrees: Double) -> CGPoint {
            let angle = (degrees - 90) * .pi / 180
            return CGPoint(x: middle + radius * cos(angle), y: middle + radius * sin(angle))
        }

        for degrees in [10.0, 90, 170, 190, 225, 270, 350] {
            let arc = try #require(layout.arc(at: onRing(degreesFromTop: degrees)))
            let turn = degrees / 360
            #expect(arc.start <= turn && turn < arc.end)
            #expect(arc.left == (degrees > 180))
        }
        #expect(layout.arc(at: CGPoint(x: middle, y: middle)) == nil)
        #expect(layout.arc(at: CGPoint(x: middle - radius * 0.5, y: middle + radius * 0.5)) == nil)
        #expect(layout.arc(at: .zero) == nil)
    }

    @Test func orbitShowsTwoPerProjectOnABusyDay() {
        let sessions = day([4, 3, 3, 2, 2, 2, 1]) + [live(workspace: UUID(), name: "Workspace")]
        #expect(sessions.count == 18)
        let layout = OrbitLayout(map: HomeWorkMap(sessions: sessions), width: 1200)
        #expect(layout.shownPerProject == 2)
        #expect(layout.pills.count == 14)
        #expect(layout.more.map(\.count).sorted() == [1, 1, 2])
        #expect(layout.arcs.count == 18)
        expectNoOverlaps(layout)
    }

    @Test func orbitFitsFiveProjectsInEachColumnWithoutOverlaps() {
        var sessions = day([3, 3, 2, 2, 2, 2, 2, 2, 1, 1])
        sessions[0] = live(project: sessions[0].session.projectID, name: "Project 0", tone: .needsYou,
                           permission: permission)
        #expect(sessions.count == OrbitLayout.maxSessions)
        let map = HomeWorkMap(sessions: sessions)
        for width in [OrbitLayout.minWidth, 1100, 1400] {
            #expect(map.layout(width: width) == .orbit)
            let layout = OrbitLayout(map: map, width: width)
            #expect(layout.nodes.filter(\.left).count == 5)
            #expect(layout.nodes.filter { !$0.left }.count == 5)
            expectNoOverlaps(layout)
        }
    }

    @Test func ringSplitsLikeTheColumns() {
        let layout = OrbitLayout(map: HomeWorkMap(sessions: day([3, 1, 2, 2])), width: 1100)
        for node in layout.nodes {
            // The right column holds the right half of the ring and the left column the left.
            #expect(node.left ? node.segment.lowerBound >= 0.5 : node.segment.upperBound <= 0.5)
            let arcs = layout.arcs.filter { $0.live.containerID == node.id }
            #expect(arcs.count == node.group.sessions.count)
            for arc in arcs {
                #expect(arc.start >= node.segment.lowerBound - 1e-9 && arc.end <= node.segment.upperBound + 1e-9)
            }
        }
        // Both halves start at the top and fill it completely, without arcs over each other.
        let sorted = layout.arcs.sorted { $0.start < $1.start }
        #expect(abs(sorted.first!.start) < 1e-9 && abs(sorted.last!.end - 1) < 1e-9)
        for (first, second) in zip(sorted, sorted.dropFirst()) {
            #expect(abs(first.end - second.start) < 1e-9)
        }
        // The top row on each side is first on its side of the ring.
        let topRight = layout.nodes.filter { !$0.left }.min { $0.center.y < $1.center.y }!
        #expect(topRight.segment.lowerBound == 0)
        let topLeft = layout.nodes.filter(\.left).min { $0.center.y < $1.center.y }!
        #expect(topLeft.segment.upperBound == 1)
    }

    @Test func aSingleProjectTakesTheWholeRing() {
        let layout = OrbitLayout(map: HomeWorkMap(sessions: day([5])), width: 1000)
        #expect(layout.nodes.count == 1)
        #expect(layout.nodes[0].segment == 0...1)
        #expect(layout.arcs.count == 5)
    }

    @Test func everyHubWireStartsInsideItsProjectsSegment() {
        let layout = OrbitLayout(map: HomeWorkMap(sessions: day([3, 1, 2, 4, 1, 2, 1])), width: 1200)
        for node in layout.nodes {
            let wire = layout.wires.first { $0.id == "hub:\(node.id)" }!
            let angle = atan2(wire.start.y - layout.hub.y, wire.start.x - layout.hub.x)
            var turn = (angle + .pi / 2) / (2 * .pi)
            if turn < 0 { turn += 1 }
            #expect(node.segment.contains(turn))
            let distance = hypot(wire.start.x - layout.hub.x, wire.start.y - layout.hub.y)
            #expect(distance > OrbitLayout.projectRingRadius)
            #expect(wire.group == node.id)
        }
    }

    @Test func cardOpensBesideItsPillTowardsTheMiddle() {
        let layout = OrbitLayout(map: HomeWorkMap(sessions: day([2, 2, 1])), width: 1200)
        let card = CGSize(width: 330, height: 200)
        for pill in layout.pills {
            let center = layout.cardCenter(for: pill.id, size: card)
            if pill.left {
                #expect(abs(center.x - card.width / 2 - pill.frame.minX) < 1e-6)
            } else {
                #expect(abs(center.x + card.width / 2 - pill.frame.maxX) < 1e-6)
            }
            #expect(center.x - card.width / 2 >= 10 && center.x + card.width / 2 <= layout.size.width - 10)
        }
        // A session with no pill opens under the ring.
        let ringOnly = layout.cardCenter(for: UUID(), size: card)
        #expect(ringOnly.x == layout.hub.x)
    }

    @Test func orbitWiresFollowTheStateOfWhatTheyLeadTo() {
        let project = UUID()
        let needs = live(project: project, tone: .needsYou)
        let running = live(project: project)
        let waiting = live(tone: .waiting)
        let layout = OrbitLayout(map: HomeWorkMap(sessions: [needs, running, waiting]), width: 1000)
        let kinds = Dictionary(uniqueKeysWithValues: layout.wires.map { ($0.id, $0.kind) })
        #expect(kinds["hub:\(project)"] == .attention)
        #expect(kinds["session:\(needs.id)"] == .attention)
        #expect(kinds["session:\(running.id)"] == .running)
        #expect(kinds["session:\(waiting.id)"] == .quiet)
        #expect(layout.wires.first { $0.id == "session:\(needs.id)" }?.session == needs.id)
        #expect(layout.pills.first { $0.id == needs.id }?.frame.height == OrbitLayout.tallPillHeight)
    }

    @Test func orbitHasNoMinimumBeyondTheHub() {
        let layout = OrbitLayout(map: HomeWorkMap(sessions: day([2, 1])), width: 1000)
        #expect(layout.size.height == OrbitLayout.minHeight)
    }

    @Test func boardBalancesProjectCardsAcrossColumns() {
        let map = HomeWorkMap(sessions: day([5, 1, 1, 1, 1, 2, 1, 2]))
        let columns = map.boardColumns(width: 940)
        #expect(columns.count == 4)
        #expect(columns.flatMap { $0 }.count == 8)
        // The busiest project fills its column for a while, so the next ones go elsewhere.
        #expect(columns[0].count < columns[1].count || columns[0].count < columns[2].count)
        #expect(map.boardColumns(width: 300).count == 1)
        #expect(HomeWorkMap(sessions: day([1, 1])).boardColumns(width: 1400).count == 2)
    }

    private func request(questions: [AgentQuestion]) -> PermissionRequest {
        PermissionRequest(id: "question", toolName: "AskUserQuestion", title: "Question",
                          subject: "", detail: "", input: Data(), suggestions: nil,
                          alwaysTitle: nil, questions: questions)
    }
}
