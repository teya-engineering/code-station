import Foundation
import CodeStationCore

enum AppMarkGesture: CaseIterable {
    case ripple, magnetic, orbit, bloom
    case elasticHello, gridShuffle, flipSide, secretHandshake

    var duration: TimeInterval {
        switch self {
        case .ripple: 0.96
        case .magnetic: 0.3
        case .orbit: 1.2
        case .bloom: 1.4
        case .elasticHello: 1.1
        case .gridShuffle: 1.2
        case .flipSide: 1.3
        case .secretHandshake: 1.4
        }
    }

    func pose(at progress: Double, pointer: CGPoint) -> AppMarkPose {
        let t = min(1, max(0, progress))
        guard t > 0, t < 1 || self == .magnetic else { return .rest }
        var pose = AppMarkPose.rest
        let wave = sin(.pi * t)
        switch self {
        case .ripple:
            for i in pose.dots.indices {
                let dx = pose.dots[i].x - AppMark.centres[2]
                let dy = pose.dots[i].y - AppMark.centres[0]
                let phase = (t - hypot(dx, dy) / 0.1638 * 0.075) / 0.4
                let pulse = phase > 0 && phase < 1 ? sin(phase * .pi) : 0
                pose.dots[i].radius *= 1 + pulse * (i == 2 ? 0.2 : 0.4)
                pose.dots[i].x += dx * 0.04 * pulse
                pose.dots[i].y += dy * 0.04 * pulse
                pose.dots[i].shade = pulse * 0.7
            }
            pose.scale += 0.025 * wave
            pose.ringRadius = 0.07 + 0.35 * Self.ease(t / 0.6)
            pose.ringOpacity = t < 0.6 ? sin(.pi * t / 0.6) * 0.19 : 0
        case .magnetic:
            let envelope = Self.ease(t)
            pose.tiltX = -pointer.y * 7 * envelope
            pose.tiltY = pointer.x * 9 * envelope
            pose.x = pointer.x * 0.005 * envelope
            pose.y = pointer.y * 0.005 * envelope
            pose.scale += 0.035 * envelope
            for i in pose.dots.indices {
                let depth = i == 2 ? 0.055 : 0.025 + Double(i % 3) * 0.0045
                pose.dots[i].x += pointer.x * depth * envelope
                pose.dots[i].y += pointer.y * depth * envelope
                pose.dots[i].shade = 0.15 * envelope
            }
        case .orbit:
            let angle = Self.smooth((t - 0.06) / 0.83) * .pi * 2
            let expand = 1 + 0.23 * wave
            for i in pose.dots.indices {
                let dx = pose.dots[i].x - AppMark.centres[1]
                let dy = pose.dots[i].y - AppMark.centres[1]
                pose.dots[i].x = AppMark.centres[1] + (dx * cos(angle) - dy * sin(angle)) * expand
                pose.dots[i].y = AppMark.centres[1] + (dx * sin(angle) + dy * cos(angle)) * expand
                pose.dots[i].radius *= 1 + 0.12 * wave
                pose.dots[i].shade = 0.35 * wave
            }
            pose.rotation = -5 * wave
            pose.scale += 0.04 * wave
        case .bloom:
            let envelope = t < 0.42 ? Self.ease((t - 0.09) / 0.33) : 1 - Self.smooth((t - 0.65) / 0.35)
            let targets = [(0.4, 0.29), (0.29, 0.43), (0.5, 0.5), (0.29, 0.57), (0.4, 0.71),
                           (0.6, 0.29), (0.71, 0.43), (0.71, 0.57), (0.6, 0.71)]
            for i in pose.dots.indices {
                pose.dots[i].x += (targets[i].0 - pose.dots[i].x) * envelope
                pose.dots[i].y += (targets[i].1 - pose.dots[i].y) * envelope
                pose.dots[i].radius += ((i == 2 ? 0.024 : 0.036) - pose.dots[i].radius) * envelope
                pose.dots[i].stretch = i == 2 ? 1 + 2.9 * envelope : 1
                pose.dots[i].shade = 0.65 * envelope
            }
            pose.bracketsOpacity = min(1, max(0, (envelope - 0.6) * 2.5)) * 0.8
            pose.scale += 0.045 * wave
            pose.rotation = 1.4 * wave
        case .elasticHello:
            pose.y = Self.keyed(t, [(0, 0), (0.14, 0.04), (0.37, -0.16), (0.60, 0),
                                    (0.69, 0.03), (0.81, -0.03), (1, 0)])
            pose.scaleX = Self.keyed(t, [(0, 1), (0.14, 1.10), (0.28, 0.94), (0.48, 0.98),
                                         (0.65, 1.075), (0.81, 0.98), (1, 1)])
            pose.scaleY = Self.keyed(t, [(0, 1), (0.14, 0.86), (0.28, 1.08), (0.48, 1.02),
                                         (0.65, 0.92), (0.81, 1.02), (1, 1)])
            pose.rotation = Self.keyed(t, [(0, 0), (0.14, -5), (0.37, -8), (0.58, 4), (0.72, -2), (1, 0)])
            for i in pose.dots.indices {
                let delay = i == 2 ? 0.075 : Double(i) * 0.004
                let lift = Self.keyed(max(0, t - delay), [(0, 0), (0.16, 0.01), (0.39, -0.038),
                                                         (0.59, 0.02), (0.73, -0.02), (0.9, 0), (1, 0)])
                pose.dots[i].y += lift * (i == 2 ? 1.8 : 0.6)
                pose.dots[i].stretch = 1 - lift * 2.5
            }
        case .gridShuffle:
            for i in pose.dots.indices {
                let row = i / 3
                let column = i % 3
                let local = min(1, max(0, (t - Double(row) * 0.046) / 0.908))
                let exchange = Self.keyed(local, [(0, 0), (0.40, 1), (0.49, 1), (0.93, 0), (1, 0)])
                let target = (column + (row == 1 ? -1 : 1) + 3) % 3
                let arc = sin(.pi * exchange)
                pose.dots[i].x += (AppMark.centres[target] - AppMark.centres[column]) * exchange
                pose.dots[i].y += arc * (abs(target - column) > 1 ? -0.10 : 0.03) * (row == 1 ? -1 : 1)
                pose.dots[i].shade = sin(.pi * local) * 0.18
                pose.dots[i].radius *= 1 + arc * (i == 2 ? 0.07 : -0.035)
            }
        case .flipSide:
            pose.tiltY = Self.keyed(t, [(0, 0), (0.14, -22), (0.62, 374), (0.78, 353), (0.90, 362), (1, 360)])
            pose.tiltX = Self.keyed(t, [(0, 0), (0.14, 8), (0.40, -14), (0.67, 5), (1, 0)])
            pose.rotation = Self.keyed(t, [(0, 0), (0.14, -3), (0.45, 7), (0.72, -2), (1, 0)])
            pose.y = Self.keyed(t, [(0, 0), (0.14, 0.01), (0.40, -0.07), (0.68, 0), (0.82, -0.01), (1, 0)])
            pose.edgeOpacity = 1
            for i in pose.dots.indices {
                let settle = sin(.pi * min(1, max(0, (t - 0.58 - Double(i) * 0.012) / 0.35)))
                pose.dots[i].radius *= 1 + settle * 0.13
            }
        case .secretHandshake:
            let envelope = Self.keyed(t, [(0, 0), (0.28, 1), (0.73, 1), (1, 0)])
            let face = [(0.355, 0.41), (0.29, 0.55), (0.645, 0.41), (0.35, 0.63), (0.42, 0.68),
                        (0.50, 0.695), (0.58, 0.68), (0.65, 0.63), (0.71, 0.55)]
            for i in pose.dots.indices {
                pose.dots[i].x += (face[i].0 - pose.dots[i].x) * envelope
                pose.dots[i].y += (face[i].1 - pose.dots[i].y) * envelope
                pose.dots[i].radius += ((i == 0 || i == 2 ? 0.061 : 0.028) - pose.dots[i].radius) * envelope
                pose.dots[i].shade = (i == 0 ? 0.8 : 0.32) * envelope
            }
            let wink = Self.keyed(t, [(0, 0), (0.44, 0), (0.49, 1), (0.54, 1), (0.60, 0), (1, 0)])
            pose.dots[2].stretch = 1 - wink * 0.8
            pose.rotation = Self.keyed(t, [(0, 0), (0.30, -5), (0.53, -8), (0.70, -3), (1, 0)])
            pose.y = -0.02 * envelope
        }
        return pose
    }

    static func ease(_ progress: Double) -> Double {
        1 - pow(1 - min(1, max(0, progress)), 3)
    }

    private static func smooth(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }

    private static func keyed(_ progress: Double, _ points: [(Double, Double)]) -> Double {
        for index in 1..<points.count where progress <= points[index].0 {
            let (start, from) = points[index - 1]
            let (end, to) = points[index]
            return from + (to - from) * smooth((progress - start) / (end - start))
        }
        return points[points.count - 1].1
    }
}

// All coordinates are fractions of the mark's drawing, including its original margin.
// Text and layout never enter the poses or the playback clock.
struct AppMarkPose: Equatable {
    struct Dot: Equatable {
        var x: Double
        var y: Double
        var radius: Double
        var stretch = 1.0
        var shade = 0.0
    }

    var dots: [Dot]
    var scale = 1.0
    var scaleX = 1.0
    var scaleY = 1.0
    var rotation = 0.0
    var tiltX = 0.0
    var tiltY = 0.0
    var x = 0.0
    var y = 0.0
    var ringRadius = 0.07
    var ringOpacity = 0.0
    var bracketsOpacity = 0.0
    var edgeOpacity = 0.0

    static var rest: Self {
        Self(dots: (0..<9).map { i in
            Dot(x: AppMark.centres[i % 3], y: AppMark.centres[i / 3],
                radius: i == 2 ? AppMark.accentRadius : AppMark.dotRadius)
        })
    }

    func blended(to target: Self, by progress: Double) -> Self {
        if progress <= 0 { return self }
        if progress >= 1 { return target }
        var result = self
        for key in [\Self.scale, \.scaleX, \.scaleY, \.x, \.y,
                    \.ringRadius, \.ringOpacity, \.bracketsOpacity, \.edgeOpacity] {
            result[keyPath: key] += (target[keyPath: key] - self[keyPath: key]) * progress
        }
        // A full turn has the same resting angle. Interruptions take the short way home.
        for key in [\Self.rotation, \.tiltX, \.tiltY] {
            var delta = (target[keyPath: key] - self[keyPath: key]).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            result[keyPath: key] += delta * progress
        }
        for i in dots.indices {
            for key in [\Dot.x, \.y, \.radius, \.stretch, \.shade] {
                result.dots[i][keyPath: key] += (target.dots[i][keyPath: key] - dots[i][keyPath: key]) * progress
            }
        }
        return result
    }
}

struct AppMarkMotion {
    struct Input: Equatable {
        var hovered = false
        var focused = false
        var pointer = CGPoint(x: 0.6, y: -0.4)
        var reducedMotion = false
        var visible = true

        var active: Bool { hovered || focused }
    }

    struct Playback {
        let start: TimeInterval
        let duration: TimeInterval
        let from: AppMarkPose
        let gesture: AppMarkGesture?
        let pointer: CGPoint
        let target: AppMarkPose

        var finalPose: AppMarkPose { gesture?.pose(at: 1, pointer: pointer) ?? target }

        func pose(at time: TimeInterval) -> AppMarkPose {
            if time >= start + duration { return finalPose }
            let elapsed = max(0, time - start)
            if let gesture {
                let next = gesture.pose(at: elapsed / duration, pointer: pointer)
                return from.blended(to: next, by: AppMarkGesture.ease(elapsed / 0.11))
            }
            return from.blended(to: target, by: AppMarkGesture.ease(elapsed / duration))
        }
    }

    private(set) var input = Input()
    private(set) var lastGesture: AppMarkGesture?
    private(set) var playback: Playback?

    func pose(at time: TimeInterval) -> AppMarkPose { playback?.pose(at: time) ?? .rest }

    // A new input replaces the current flight. Sampling it first makes even a rapid
    // exit and re-entry continuous, without timers or queued completion callbacks.
    @discardableResult
    mutating func update(_ next: Input, at time: TimeInterval,
                         choose: ([AppMarkGesture]) -> AppMarkGesture = { $0.randomElement()! }) -> Bool {
        let previous = input
        input = next
        let from = pose(at: time)
        guard next.visible, !next.reducedMotion else {
            let changed = playback != nil
            playback = nil
            return changed
        }
        let entered = (next.hovered && !previous.hovered) || (next.focused && !previous.focused)
        if entered {
            let gesture = choose(AppMarkGesture.allCases.filter { $0 != lastGesture })
            lastGesture = gesture
            playback = Playback(start: time, duration: gesture.duration, from: from, gesture: gesture,
                                pointer: next.pointer, target: .rest)
            return true
        }
        if previous.active && !next.active {
            guard from != .rest else { playback = nil; return false }
            playback = Playback(start: time, duration: Motion.revealDuration, from: from, gesture: nil,
                                pointer: next.pointer, target: .rest)
            return true
        }
        if next.hovered, lastGesture == .magnetic, let playback,
           next.pointer != previous.pointer {
            let remainingEntry = playback.gesture == .magnetic ? playback.start + playback.duration - time : 0
            self.playback = Playback(start: time, duration: max(Motion.hoverDuration, remainingEntry), from: from, gesture: nil,
                                     pointer: next.pointer, target: AppMarkGesture.magnetic.pose(at: 1, pointer: next.pointer))
            return true
        }
        return false
    }

    mutating func stop() { playback = nil }
}
