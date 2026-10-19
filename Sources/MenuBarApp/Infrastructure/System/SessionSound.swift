import AppKit
import CodeStationCore

// The GUI plays the chosen sound with NSSound.
extension SessionSound {
    // NSSound keeps playing only while something holds it, so the one in flight is kept
    // here until the next sound takes its place.
    @MainActor private static var playing: NSSound?

    @MainActor
    func play() {
        guard self != .off, let sound = NSSound(named: rawValue) else { return }
        Self.playing?.stop()
        Self.playing = sound
        sound.play()
    }
}
