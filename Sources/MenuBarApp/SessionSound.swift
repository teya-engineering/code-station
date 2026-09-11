import AppKit

// The sound a finished session plays. The choices are the alert sounds macOS ships with,
// so nothing has to be bundled and every name is one already seen in System Settings.
enum SessionSound: String, CaseIterable, Identifiable {
    case off
    case basso = "Basso"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case glass = "Glass"
    case hero = "Hero"
    case morse = "Morse"
    case ping = "Ping"
    case pop = "Pop"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case tink = "Tink"

    static let standard = SessionSound.glass

    var id: String { rawValue }

    var title: String { self == .off ? "No sound" : rawValue }

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
