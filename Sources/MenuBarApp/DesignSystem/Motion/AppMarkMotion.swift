import Foundation

// Only the dots move. Coordinates include the original artwork's outer margin.
struct AppMarkPose: Equatable {
    struct Dot: Equatable {
        var x: Double
        var y: Double
        var radius: Double
    }

    var dots: [Dot]

    static var rest: Self {
        Self(dots: (0..<9).map { i in
            Dot(x: AppMark.centres[i % 3], y: AppMark.centres[i / 3],
                radius: i == 2 ? AppMark.accentRadius : AppMark.dotRadius)
        })
    }

    static func orbit(at progress: Double) -> Self {
        guard progress > 0, progress < 1 else { return .rest }
        var pose = rest
        let tileSide = 1 - AppMark.margin * 2
        for i in pose.dots.indices {
            let dot = pose.dots[i]
            let x = dot.x - AppMark.centres[1]
            let y = dot.y - AppMark.centres[1]
            let angle = atan2(y, x) + (i == 4 ? -0.6 : 0)
            let radius = tileSide * (i == 4 ? 0.08 : 0.34)
            let frames: [(time: Double, x: Double, y: Double, scale: Double)] = [
                (0, x, y, 1),
                (0.13, x * 0.75, y * 0.75, 0.72),
                (0.34, cos(angle + 0.48) * radius, sin(angle + 0.48) * radius, i == 2 ? 1.05 : 1.22),
                (0.57, cos(angle + 2.3) * radius, sin(angle + 2.3) * radius, i == 2 ? 1.15 : 1),
                (0.84, x * 0.92, y * 0.92, 1.12),
                (1, x, y, 1)
            ]
            let end = frames.firstIndex { $0.time >= progress }!
            let from = frames[end - 1]
            let to = frames[end]
            let t = (progress - from.time) / (to.time - from.time)
            let eased = t * t * (3 - 2 * t)
            pose.dots[i].x = AppMark.centres[1] + from.x + (to.x - from.x) * eased
            pose.dots[i].y = AppMark.centres[1] + from.y + (to.y - from.y) * eased
            pose.dots[i].radius = dot.radius * (from.scale + (to.scale - from.scale) * eased)
        }
        return pose
    }

    func blended(to target: Self, by progress: Double) -> Self {
        if progress <= 0 { return self }
        if progress >= 1 { return target }
        var result = self
        for i in dots.indices {
            for key in [\Dot.x, \.y, \.radius] {
                result.dots[i][keyPath: key] += (target.dots[i][keyPath: key] - dots[i][keyPath: key]) * progress
            }
        }
        return result
    }
}

struct AppMarkMotion {
    struct Playback {
        let start: TimeInterval
        let duration: TimeInterval
        let from: AppMarkPose
        let entering: Bool

        func pose(at time: TimeInterval) -> AppMarkPose {
            if time >= start + duration { return .rest }
            let elapsed = max(0, time - start)
            let progress = elapsed / duration
            if entering {
                return from.blended(to: .orbit(at: progress), by: min(1, elapsed / Motion.hoverDuration))
            }
            return from.blended(to: .rest, by: 1 - pow(1 - progress, 3))
        }
    }

    private(set) var playback: Playback?

    func pose(at time: TimeInterval) -> AppMarkPose { playback?.pose(at: time) ?? .rest }

    // Sampling before replacing playback makes rapid exits and re-entries continuous.
    // There are no delayed tasks or completion callbacks to restart an old gesture.
    mutating func enter(at time: TimeInterval) {
        playback = Playback(start: time, duration: Motion.brandOrbitDuration,
                            from: pose(at: time), entering: true)
    }

    mutating func leave(at time: TimeInterval) {
        let from = pose(at: time)
        playback = from == .rest ? nil : Playback(start: time, duration: Motion.leaveDuration,
                                                 from: from, entering: false)
    }

    mutating func stop() { playback = nil }
}
