import AppKit
import SwiftUI
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

struct ActivitySpineTests {

    @Test func flattensAgentCallsIntoPermanentReceiptsInEventOrder() {
        let child = ToolNode(tool: ToolUse(id: "child", name: "Read", input: "{}"),
                             order: 1)
        let agent = ToolNode(tool: ToolUse(id: "agent", name: "Agent", input: "{}"),
                             children: [child], order: 0)
        let edit = ToolNode(tool: ToolUse(id: "edit", name: "Edit", input: "{}"),
                            order: 2)

        #expect(ActivitySpine.flattened([agent, edit]).map(\.id)
                == ["agent", "child", "edit"])
    }

    @Test func summarizesTheCallsAndTheirUniqueVerbs() {
        let calls = [
            ToolNode(tool: ToolUse(id: "1", name: "Bash", input: "{}")),
            ToolNode(tool: ToolUse(id: "2", name: "Read", input: "{}")),
            ToolNode(tool: ToolUse(id: "3", name: "Bash", input: "{}")),
            ToolNode(tool: ToolUse(id: "4", name: "Edit", input: "{}"))
        ]

        #expect(ActivitySpine.summary(calls) == "4 CALLS · BASH, READ, EDIT")
    }
}

@MainActor
struct SpineCardTests {

    @Test func aFinishedCallKnowsHowLongItTook() {
        let started = Date(timeIntervalSinceReferenceDate: 1_000)
        var tool = ToolUse(id: "b1", name: "Bash", input: "{}", result: "ok")
        tool.startedAt = started
        tool.finishedAt = started.addingTimeInterval(2.5)
        #expect(tool.duration == 2.5)
    }

    @Test func aRunningCallHasNoDurationYet() {
        var tool = ToolUse(id: "b1", name: "Bash", input: "{}")
        tool.startedAt = Date()
        #expect(tool.duration == nil)
    }

    @Test func aCallRecordedWithoutTimesHasNoDuration() {
        let tool = ToolUse(id: "b1", name: "Read", input: "{}", result: "ok")
        #expect(tool.duration == nil)
    }

    @Test func shortSpansKeepTheirTenths() {
        #expect(ElapsedTime.duration(0.34) == "0.3s")
        #expect(ElapsedTime.duration(2) == "2.0s")
    }

    @Test func longerSpansReadLikeTheLiveClock() {
        #expect(ElapsedTime.duration(41.6) == "41s")
        #expect(ElapsedTime.duration(161) == "2m 41s")
        #expect(ElapsedTime.reading(161) == "2m 41s")
    }

    @Test func theBandSaysTheStateInWords() {
        #expect(SpineCardState(isWorking: true, isError: false).word == "RUNNING")
        #expect(SpineCardState(isWorking: false, isError: false).word == "DONE")
        #expect(SpineCardState(isWorking: false, isError: true).word == "FAILED")
    }

    // A background agent's call reports in at once and keeps going, so the band goes by
    // the work, not by the call having a result.
    @Test func aCallStillWorkingIsRunningWhateverItsResultSays() {
        #expect(SpineCardState(isWorking: true, isError: true) == .running)
    }
}

@MainActor
struct ActivitySpineLayoutTests {
    // A transcript that follows the bottom shows a different slice of the spine on every
    // frame while a turn runs. If the spine's height depended on that slice, the transcript
    // would keep resizing itself and never settle.
    @Test func theSpinesHeightDoesNotDependOnHowMuchOfItIsOnScreen() async throws {
        let nodes = (0..<6).map { index in
            ToolNode(tool: ToolUse(id: "call-\(index)", name: index == 0 ? "Read" : "Bash",
                                   input: "{\"command\":\"ls -la\"}"),
                     order: index)
        }
        var heights: Set<CGFloat> = []
        for viewport in [90.0, 120.0, 151.0, 400.0] {
            let hosting = NSHostingView(rootView:
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Color.clear.frame(height: 80)
                        ActivitySpine(nodes: nodes, projectPath: "/tmp")
                    }
                    .padding(14)
                }
                .defaultScrollAnchor(.bottom)
                .frame(width: 700, height: viewport))
            let window = testWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: viewport),
                                    styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = hosting
            window.center()
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(10))
                hosting.layoutSubtreeIfNeeded()
            }
            func descendants(_ view: NSView) -> [NSView] {
                view.subviews + view.subviews.flatMap(descendants)
            }
            let scroll = try #require(descendants(hosting).compactMap { $0 as? NSScrollView }.first)
            heights.insert(try #require(scroll.documentView).frame.height)
        }
        #expect(heights.count == 1)
    }
}
