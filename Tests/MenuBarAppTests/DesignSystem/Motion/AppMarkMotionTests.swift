import Foundation
import Testing
@testable import MenuBarApp

struct AppMarkMotionTests {
    @Test func orbitGathersOpensAndReturnsAllNineDots() {
        let rest = AppMarkPose.rest
        let gathered = AppMarkPose.orbit(at: 0.13)
        let open = AppMarkPose.orbit(at: 0.34)
        for i in rest.dots.indices {
            #expect(gathered.dots[i].radius < rest.dots[i].radius)
            #expect(open.dots[i] != rest.dots[i])
        }
        #expect(abs(gathered.dots[0].x - AppMark.centres[1]) < abs(rest.dots[0].x - AppMark.centres[1]))
        #expect(AppMarkPose.orbit(at: 0) == rest)
        #expect(AppMarkPose.orbit(at: 1) == rest)
        #expect(AppMarkPose.orbit(at: 2) == rest)
    }

    @Test func orbitKeepsFiniteGeometryAndTheLargerAccentDotInsideTheTile() {
        for sample in 0...1_000 {
            let pose = AppMarkPose.orbit(at: Double(sample) / 1_000)
            #expect(pose.dots.count == 9)
            #expect(pose.dots.enumerated().filter { $0.offset != 2 }.allSatisfy {
                $0.element.radius < pose.dots[2].radius
            })
            #expect(pose.dots.allSatisfy { dot in
                [dot.x, dot.y, dot.radius].allSatisfy(\.isFinite)
                    && dot.radius > 0
                    && dot.x - dot.radius > AppMark.margin && dot.x + dot.radius < 1 - AppMark.margin
                    && dot.y - dot.radius > AppMark.margin && dot.y + dot.radius < 1 - AppMark.margin
            })
        }
    }

    @Test func holdingHoverDoesNotRepeatTheOrbit() {
        var motion = AppMarkMotion()
        #expect(motion.playback == nil)
        motion.enter(at: 0)
        #expect(motion.pose(at: 0) == .rest)
        #expect(motion.pose(at: Motion.brandOrbitDuration / 2) != .rest)
        #expect(motion.pose(at: Motion.brandOrbitDuration) == .rest)
        #expect(motion.pose(at: 100) == .rest)
        motion.leave(at: 100)
        #expect(motion.playback == nil)
    }

    @Test(arguments: [0.05, 0.15, 0.38, 0.64, 0.95])
    func interruptedOrbitReturnsInLeaveDurationAndReentryIsContinuous(_ exit: Double) throws {
        var motion = AppMarkMotion()
        motion.enter(at: 0)
        let beforeExit = motion.pose(at: exit)
        motion.leave(at: exit)
        #expect(motion.pose(at: exit) == beforeExit)
        #expect(motion.playback?.duration == Motion.leaveDuration)
        #expect(motion.pose(at: exit + Motion.leaveDuration) == .rest)
        let reentry = exit + Motion.leaveDuration / 2
        let beforeReentry = motion.pose(at: reentry)
        motion.enter(at: reentry)
        #expect(motion.pose(at: reentry) == beforeReentry)
        #expect(motion.pose(at: reentry + Motion.brandOrbitDuration) == .rest)
        motion.stop()
        #expect(motion.playback == nil)
        #expect(motion.pose(at: 100) == .rest)
    }

    @Test func hoverStartsOnlyOnEntryAndEnvironmentChangesCannotReplayIt() {
        var hover = BrandHover()
        hover.update(.init())
        #expect(hover.style == .rest)
        hover.update(.init(hovered: true))
        #expect(hover.style == .moving)
        hover.update(.init(hovered: true, visible: false))
        #expect(hover.style == .rest)
        hover.update(.init(hovered: true))
        #expect(hover.style == .rest)
        hover.update(.init())
        hover.update(.init(hovered: true))
        #expect(hover.style == .moving)
        hover.update(.init(hovered: true, reducedMotion: true))
        #expect(hover.style == .still)
        hover.update(.init(hovered: true))
        #expect(hover.style == .rest)
    }

    @Test func reducedHoverIsStaticAndHiddenEntryDoesNotWaitToPlay() {
        var hover = BrandHover()
        hover.update(.init(hovered: true, reducedMotion: true))
        #expect(hover.style == .still)
        hover.update(.init(reducedMotion: true))
        #expect(hover.style == .rest)
        hover.update(.init(hovered: true, visible: false))
        hover.update(.init(hovered: true))
        #expect(hover.style == .rest)
    }
}
