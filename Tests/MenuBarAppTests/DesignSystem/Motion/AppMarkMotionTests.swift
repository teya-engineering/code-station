import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

struct AppMarkMotionTests {
    @Test func everyEntryOffersAllGesturesExceptTheLastOne() {
        var motion = AppMarkMotion()
        #expect(motion.playback == nil)
        for (index, gesture) in AppMarkGesture.allCases.enumerated() {
            let last = motion.lastGesture
            motion.update(.init(hovered: true), at: Double(index)) { choices in
                #expect(choices == AppMarkGesture.allCases.filter { $0 != last })
                #expect(choices.contains(gesture))
                return gesture
            }
            #expect(motion.lastGesture == gesture)
            motion.update(.init(), at: Double(index) + 0.5)
        }
    }

    @Test(arguments: AppMarkGesture.allCases)
    func pointerMovementDoesNotChooseAnotherGesture(_ gesture: AppMarkGesture) {
        var motion = AppMarkMotion()
        motion.update(.init(hovered: true), at: 0) { _ in gesture }
        for i in 1...10 {
            motion.update(.init(hovered: true, pointer: CGPoint(x: Double(i) / 10, y: -1)),
                          at: Double(i) / 10) { _ in
                Issue.record("Pointer movement must not choose a gesture")
                return .ripple
            }
            #expect(motion.lastGesture == gesture)
        }
    }

    @Test(arguments: AppMarkGesture.allCases.filter { $0 != .magnetic })
    func finiteGesturesReturnExactlyToRest(_ gesture: AppMarkGesture) {
        var motion = AppMarkMotion()
        motion.update(.init(hovered: true), at: 0) { _ in gesture }
        #expect(motion.pose(at: 0) == .rest)
        #expect(motion.pose(at: gesture.duration / 2) != .rest)
        #expect(motion.pose(at: gesture.duration) == .rest)
        #expect(motion.pose(at: gesture.duration * 10) == .rest)
        motion.update(.init(), at: 100)
        let later = 1_000_000.123
        motion.update(.init(hovered: true), at: later) { _ in gesture }
        #expect(motion.pose(at: later + gesture.duration) == .rest)
    }

    @Test func magneticFieldFollowsThenHoldsWithoutMorePlayback() throws {
        var motion = AppMarkMotion()
        let input = AppMarkMotion.Input(hovered: true, pointer: CGPoint(x: 1, y: -1))
        motion.update(input, at: 0) { _ in .magnetic }
        let held = motion.pose(at: 0.3)
        #expect(held.tiltY == 9)
        #expect(held.tiltX == 7)
        #expect(abs((held.dots[2].x - AppMarkPose.rest.dots[2].x) * 41 - 2.255) < 0.001)
        #expect(motion.pose(at: 20) == held)
        let stationary = motion.update(input, at: 20)
        #expect(!stationary)

        let moved = AppMarkMotion.Input(hovered: true, pointer: CGPoint(x: -1, y: 1))
        let follows = motion.update(moved, at: 20)
        #expect(follows)
        #expect(motion.pose(at: 20) == held)
        let playback = try #require(motion.playback)
        #expect(motion.pose(at: 20 + playback.duration).tiltY == -9)
        #expect(motion.pose(at: 21) == motion.pose(at: 40))
    }

    @Test(arguments: AppMarkGesture.allCases)
    func exitAndRapidReentryBlendFromTheCurrentPose(_ gesture: AppMarkGesture) throws {
        var motion = AppMarkMotion()
        motion.update(.init(hovered: true), at: 0) { _ in gesture }
        let beforeExit = motion.pose(at: 0.25)
        motion.update(.init(), at: 0.25)
        #expect(motion.pose(at: 0.25) == beforeExit)
        #expect(motion.pose(at: 0.44) == .rest)

        let beforeReentry = motion.pose(at: 0.3)
        motion.update(.init(hovered: true), at: 0.3) { $0.first! }
        #expect(motion.lastGesture != gesture)
        #expect(motion.pose(at: 0.3) == beforeReentry)
        let playback = try #require(motion.playback)
        #expect(motion.pose(at: 0.42) == playback.gesture?.pose(at: (0.42 - playback.start) / playback.duration,
                                                            pointer: playback.pointer))
        motion.update(.init(), at: 0.42)
        #expect(motion.pose(at: 1) == .rest)
    }

    @Test(arguments: AppMarkGesture.allCases)
    func visibleKeyboardFocusStartsOnceAndKeepsTheGestureAfterPointerExit(_ gesture: AppMarkGesture) {
        var motion = AppMarkMotion()
        motion.update(.init(focused: true), at: 0) { _ in gesture }
        #expect(motion.lastGesture == gesture)
        let staysFocused = motion.update(.init(focused: true), at: 0.1)
        #expect(!staysFocused)
        motion.update(.init(hovered: true, focused: true), at: 0.2) { _ in .orbit }
        #expect(motion.lastGesture == .orbit)
        let pointerExited = motion.update(.init(focused: true), at: 0.3)
        #expect(!pointerExited)
        #expect(motion.playback?.gesture == .orbit)
        motion.update(.init(), at: 0.4)
        #expect(motion.pose(at: 0.6) == .rest)
    }

    @Test(arguments: AppMarkGesture.allCases)
    func reducedMotionAndHiddenWindowsStopWithoutShufflingOrRestarting(_ gesture: AppMarkGesture) {
        for hidden in [false, true] {
            var motion = AppMarkMotion()
            motion.update(.init(hovered: true), at: 0) { _ in gesture }
            motion.update(.init(hovered: true, reducedMotion: !hidden, visible: !hidden), at: 0.2)
            #expect(motion.playback == nil)
            #expect(motion.pose(at: 0.2) == .rest)
            #expect(motion.lastGesture == gesture)
            motion.update(.init(reducedMotion: !hidden, visible: !hidden), at: 0.3)
            motion.update(.init(hovered: true, reducedMotion: !hidden, visible: !hidden), at: 0.4) { _ in
                Issue.record("Suppressed motion must not choose a gesture")
                return .bloom
            }
            motion.update(.init(hovered: true), at: 0.5)
            #expect(motion.playback == nil)
            #expect(motion.lastGesture == gesture)
        }
    }

    @Test func bloomFormsBracketsAndACursorBeforeRebuilding() {
        let pose = AppMarkGesture.bloom.pose(at: 0.5, pointer: .zero)
        #expect(pose.dots[2].x == 0.5)
        #expect(pose.dots[2].y == 0.5)
        #expect(pose.dots[2].stretch == 3.9)
        #expect(pose.bracketsOpacity == 0.8)
        #expect(AppMarkGesture.bloom.pose(at: 1, pointer: .zero) == .rest)
    }

    @Test func elasticHelloAnticipatesHopsAndLandsWithALateAccentDot() {
        let gather = AppMarkGesture.elasticHello.pose(at: 0.14, pointer: .zero)
        #expect(gather.y > 0 && gather.scaleX > 1 && gather.scaleY < 1)
        let hop = AppMarkGesture.elasticHello.pose(at: 0.37, pointer: .zero)
        #expect(hop.y == -0.16)
        let landing = AppMarkGesture.elasticHello.pose(at: 0.65, pointer: .zero)
        #expect(landing.scaleX > 1 && landing.scaleY < 1)
        let settling = AppMarkGesture.elasticHello.pose(at: 0.94, pointer: .zero)
        #expect(settling.dots[2].y != AppMarkPose.rest.dots[2].y)
        #expect(settling.dots.enumerated().filter { $0.offset != 2 }.allSatisfy {
            $0.element.y == AppMarkPose.rest.dots[$0.offset].y
        })
    }

    @Test func gridShuffleStaggersRowsAndExchangesColumnsWithoutMovingTheTile() {
        let start = AppMarkGesture.gridShuffle.pose(at: 0.04, pointer: .zero)
        #expect(start.dots[0].x > AppMark.centres[0])
        #expect(start.dots[3] == AppMarkPose.rest.dots[3])
        #expect(start.dots[6] == AppMarkPose.rest.dots[6])
        for row in 0..<3 {
            let exchange = AppMarkGesture.gridShuffle.pose(at: 0.44 * 0.908 + Double(row) * 0.046, pointer: .zero)
            for column in 0..<3 {
                let target = (column + (row == 1 ? -1 : 1) + 3) % 3
                #expect(abs(exchange.dots[row * 3 + column].x - AppMark.centres[target]) < 0.000001)
            }
        }
        for sample in 0...100 {
            var pose = AppMarkGesture.gridShuffle.pose(at: Double(sample) / 100, pointer: .zero)
            pose.dots = AppMarkPose.rest.dots
            #expect(pose == .rest)
        }
    }

    @Test func flipWindsUpTurnsFullyAndSettlesWithoutRewindingOnExit() {
        #expect(AppMarkGesture.flipSide.pose(at: 0.14, pointer: .zero).tiltY == -22)
        #expect(AppMarkGesture.flipSide.pose(at: 0.62, pointer: .zero).tiltY == 374)
        #expect(AppMarkGesture.flipSide.pose(at: 0.78, pointer: .zero).tiltY == 353)
        for progress in [0.36, 0.5, 0.62, 0.78, 0.95] {
            var motion = AppMarkMotion()
            motion.update(.init(hovered: true), at: 0) { _ in .flipSide }
            let exit = progress * AppMarkGesture.flipSide.duration
            let before = motion.pose(at: exit)
            motion.update(.init(), at: exit)
            let returning = motion.pose(at: exit + 0.09)
            #expect(abs(returning.tiltY - before.tiltY) <= 180)
            #expect(motion.pose(at: exit + 0.19) == .rest)
            motion.update(.init(hovered: true), at: exit + 0.09) { _ in .gridShuffle }
            #expect(motion.pose(at: exit + 0.09) == returning)
            #expect(abs(motion.pose(at: exit + 0.13).tiltY - returning.tiltY) <= 180)
        }
    }

    @Test func secretHandshakeFormsASmileAndWinksOnlyTheAccentEye() {
        let smile = AppMarkGesture.secretHandshake.pose(at: 0.3, pointer: .zero)
        #expect(abs(smile.dots[0].y - smile.dots[2].y) < 0.000001)
        #expect(smile.dots[5].y > smile.dots[3].y)
        #expect(smile.dots[5].y > smile.dots[7].y)
        let wink = AppMarkGesture.secretHandshake.pose(at: 0.52, pointer: .zero)
        #expect(abs(wink.dots[2].stretch - 0.2) < 0.000001)
        #expect(wink.dots.enumerated().filter { $0.offset != 2 }.allSatisfy { $0.element.stretch == 1 })
        #expect(AppMarkGesture.secretHandshake.pose(at: 0.68, pointer: .zero).dots[2].stretch == 1)
    }

    @Test(arguments: [AppMarkGesture.elasticHello, .gridShuffle, .flipSide, .secretHandshake])
    func newGesturesKeepFiniteGeometryAndDotsInsideTheTile(_ gesture: AppMarkGesture) {
        for sample in 0...1_000 {
            let pose = gesture.pose(at: Double(sample) / 1_000, pointer: .zero)
            #expect([pose.x, pose.y, pose.scale, pose.scaleX, pose.scaleY,
                     pose.rotation, pose.tiltX, pose.tiltY, pose.edgeOpacity].allSatisfy { $0.isFinite })
            #expect(pose.scaleX > 0 && pose.scaleY > 0)
            #expect(pose.dots.allSatisfy { dot in
                let radiusY = dot.radius * dot.stretch
                return [dot.x, dot.y, dot.radius, dot.stretch, dot.shade].allSatisfy(\.isFinite)
                    && dot.radius > 0 && radiusY > 0
                    && dot.x - dot.radius > AppMark.margin && dot.x + dot.radius < 1 - AppMark.margin
                    && dot.y - radiusY > AppMark.margin && dot.y + radiusY < 1 - AppMark.margin
            })
        }
        #expect(gesture.pose(at: -1, pointer: .zero) == .rest)
        #expect(gesture.pose(at: 2, pointer: .zero) == .rest)
    }
}
