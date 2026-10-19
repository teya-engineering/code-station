import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// The start and end of a turn are told by motion, but what the motion lands on has to
// say the same thing without it: the node's resting look, the card's word and the seal's
// words. These hold those, and the timing the motion is built from.
@MainActor
struct TurnMotionTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - Thread

    @Test func aRunningTurnOutranksEverythingTheLastOneLeft() {
        #expect(ThreadPhase(busy: true, failed: true, finished: true) == .running)
        #expect(ThreadPhase(busy: false, failed: true, finished: true) == .failed)
        #expect(ThreadPhase(busy: false, failed: false, finished: true) == .finished)
        #expect(ThreadPhase(busy: false, failed: false, finished: false) == .idle)
    }

    @Test func eachPhaseRestsOnItsOwnMark() {
        let idle = ThreadLook.resting(.idle)
        #expect(idle == ThreadLook())

        let running = ThreadLook.resting(.running)
        #expect(running.ring == 1)
        #expect(running.tick == 0 && running.bang == 0)

        // Done is a full dot with a tick, and the orbit is gone.
        let finished = ThreadLook.resting(.finished)
        #expect(finished.tick == 1)
        #expect(finished.ring == 0)
        #expect(finished.alarm == 0)

        // Failure is never told by colour alone: the dot also carries its own mark.
        let failed = ThreadLook.resting(.failed)
        #expect(failed.alarm == 1)
        #expect(failed.bang == 1)
        #expect(failed.tick == 0)
    }

    @Test func theOrbitIsSlowerThanTheFastestLoopAllowed() {
        #expect(TurnMotion.orbitPeriod >= 1.2)
        #expect(TurnMotion.arcPeriod >= 1.2)
    }

    @Test func theArcNeitherVanishesNorClosesWhileRunning() {
        #expect(TurnMotion.arcShortest > 0)
        #expect(TurnMotion.arcLongest < 1)
        #expect(TurnMotion.arcShortest < TurnMotion.arcLongest)
        #expect((TurnMotion.arcShortest...TurnMotion.arcLongest).contains(TurnMotion.arcResting))
    }

    @Test func aRunningArcTurnsAndSwells() {
        let arc = OrbitArcView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        arc.update(colour: .black, moving: true, closed: false)
        #expect(Set(arc.loops) == ["turn", "swell"])

        arc.update(colour: .black, moving: false, closed: false)
        #expect(arc.loops.isEmpty)
        #expect(arc.arcEnd == TurnMotion.arcResting)
    }

    // Closing keeps the turn going while the arc sweeps round, and leaves a whole ring.
    @Test func closingSweepsTheArcIntoAWholeRing() {
        let arc = OrbitArcView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        arc.update(colour: .black, moving: true, closed: false)
        arc.update(colour: .black, moving: true, closed: true)
        #expect(Set(arc.loops) == ["turn", "close"])
        #expect(arc.arcEnd == 1)

        // A new turn before the orbit has gone opens the arc again.
        arc.update(colour: .black, moving: true, closed: false)
        #expect(Set(arc.loops) == ["turn", "swell"])
        #expect(arc.arcEnd == TurnMotion.arcResting)
    }

    @Test func theBeadWaitsAtTheTopThenLandsInTheNode() {
        #expect(TurnMotion.fall(0) == 0)
        #expect(TurnMotion.fall(0.1) == 0)
        #expect(Double(TurnMotion.fall(1)).isNear(1))
        var previous: CGFloat = 0
        for step in 0...100 {
            let fall = TurnMotion.fall(CGFloat(step) / 100)
            #expect(fall >= previous, "the bead rose at step \(step)")
            previous = fall
        }
    }

    @Test func theShakeSettlesWhereItBegan() {
        #expect(TurnMotion.shake(0) == 0)
        #expect(TurnMotion.shake(1) == 0)
        for step in 0...100 {
            #expect(abs(TurnMotion.shake(CGFloat(step) / 100)) <= 4)
        }
    }

    // A replayed effect counts up by one each run, so a whole number is always rest.
    @Test func aCountedRunRestsBetweenRuns() {
        #expect(TurnMotion.stage(0) == 0)
        #expect(TurnMotion.stage(3) == 0)
        #expect(Double(TurnMotion.stage(2.25)).isNear(0.25))
    }

    // MARK: - Hand-off

    @Test func aTurnsLengthReadsAsAClock() {
        #expect(TurnReceipt.clock(0) == "0:00")
        #expect(TurnReceipt.clock(7.9) == "0:07")
        #expect(TurnReceipt.clock(760) == "12:40")
        #expect(TurnReceipt.clock(3725) == "1:02:05")
    }

    @Test func theSealSaysHowTheTurnEnded() {
        let finished = ending(seconds: 7, .finished)
        let changes = TurnReceipt(added: 48, removed: 6, files: 3)
        #expect(changes.summary(finished) == "Finished in 0:07 · +48 \u{2212}6 · 3 files")
        #expect(TurnReceipt().summary(finished) == "Finished in 0:07")
        #expect(TurnReceipt(added: 2, removed: 0, files: 1).summary(finished)
            == "Finished in 0:07 · +2 \u{2212}0 · 1 file")
        #expect(TurnReceipt().summary(ending(seconds: 65, .failed)) == "Stopped after 1:05")
        #expect(TurnReceipt().summary(ending(seconds: 3, .stopped)) == "Stopped after 0:03")
    }

    @Test func theSealIsSpokenInWords() {
        let spoken = TurnReceipt(added: 48, removed: 6, files: 3)
            .spokenSummary(ending(seconds: 7, .finished))
        #expect(spoken.contains("48 lines added, 6 removed, in 3 files"))
        #expect(!spoken.contains("\u{2212}"))
    }

    @Test func onlyAnEndingJustNowStampsItself() {
        let ended = ending(seconds: 7, .finished)
        #expect(ended.isFresh(now: ended.ended.addingTimeInterval(0.5)))
        #expect(!ended.isFresh(now: ended.ended.addingTimeInterval(30)))
    }

    @Test func theReceiptCountsOnlyTheLastTurn() throws {
        let earlier = assistant([edit("e1", path: "/repo/old.swift", old: "a", new: "b")])
        let messages = [
            ChatMessage(role: .user, text: "first"),
            earlier,
            ChatMessage(role: .user, text: "second"),
            assistant([
                edit("e2", path: "/repo/a.swift", old: "x", new: "y\nz"),
                edit("e3", path: "/repo/a.swift", old: "p", new: "q"),
                write("w1", path: "/repo/b.swift", content: "1\n2\n3"),
                ToolUse(id: "r1", name: "Read", input: #"{"file_path":"/repo/c.swift"}"#,
                        result: "…"),
            ]),
        ]
        let receipt = try #require(TurnReceipt(lastTurnIn: messages, projectPath: "/repo"))
        // Two edits to one file count it once; a file that was only read is not counted.
        #expect(receipt.files == 2)
        #expect(receipt.added == 2 + 1 + 3)
        #expect(receipt.removed == 1 + 1)
    }

    @Test func onlyThePromptJustSentLiftsIntoPlace() {
        let sent = Self.start.addingTimeInterval(100)
        var prompt = ChatMessage(role: .user, text: "Add a filter")
        prompt.date = sent.addingTimeInterval(0.01)

        #expect(prompt.isArriving(sentAt: sent, now: sent.addingTimeInterval(0.2)))
        // Drawn again once it has landed, it stays where it is.
        #expect(!prompt.isArriving(sentAt: sent, now: sent.addingTimeInterval(5)))
        #expect(!prompt.isArriving(sentAt: nil, now: sent))

        // A prompt older than the send was queued earlier and run by the runner.
        var queued = prompt
        queued.date = sent.addingTimeInterval(-60)
        #expect(!queued.isArriving(sentAt: sent, now: sent.addingTimeInterval(0.2)))

        var answer = prompt
        answer.role = .assistant
        #expect(!answer.isArriving(sentAt: sent, now: sent.addingTimeInterval(0.2)))
    }

    @Test func aTranscriptWithNoPromptHasNoReceipt() {
        #expect(TurnReceipt(lastTurnIn: [], projectPath: "/repo") == nil)
        #expect(TurnReceipt(lastTurnIn: [ChatMessage(role: .system, text: "note")],
                            projectPath: "/repo") == nil)
    }

    // MARK: - Helpers

    private func ending(seconds: TimeInterval, _ outcome: TurnEnding.Outcome) -> TurnEnding {
        TurnEnding(started: Self.start, ended: Self.start.addingTimeInterval(seconds),
                   outcome: outcome)
    }

    private func assistant(_ tools: [ToolUse]) -> ChatMessage {
        var message = ChatMessage(role: .assistant, text: "Done.")
        message.tools = tools
        return message
    }

    private func edit(_ id: String, path: String, old: String, new: String) -> ToolUse {
        ToolUse(id: id, name: "Edit", input: json(["file_path": path, "old_string": old,
                                                   "new_string": new]),
                result: "ok")
    }

    private func write(_ id: String, path: String, content: String) -> ToolUse {
        ToolUse(id: id, name: "Write", input: json(["file_path": path, "content": content]),
                result: "ok")
    }

    private func json(_ fields: [String: String]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

private extension Double {
    func isNear(_ other: Double) -> Bool { abs(self - other) < 0.000_1 }
}
