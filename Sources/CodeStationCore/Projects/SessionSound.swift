import Foundation

// The sound a finished session plays. The choices are the alert sounds macOS ships with,
// so nothing has to be bundled and every name is one already seen in System Settings.
// Playing it is the host's: the GUI plays the named sound, a terminal rings its bell
// unless the choice is `.off`.
public enum SessionSound: String, CaseIterable, Identifiable, Sendable {
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

    public static let standard = SessionSound.glass

    public var id: String { rawValue }

    public var title: String { self == .off ? "No sound" : rawValue }
}

extension Preferences {
    // What a finished session plays. An unset key reads as the standard sound: a turn
    // ending while the person is elsewhere is the moment they most want to hear about,
    // so it is on until they say otherwise.
    public static func sessionFinishedSound(in store: UserDefaults = Preferences.defaults) -> SessionSound {
        guard let raw = store.string(forKey: "sessionFinishedSound") else {
            return .standard
        }
        return SessionSound(rawValue: raw) ?? .standard
    }

    public static func setSessionFinishedSound(_ sound: SessionSound,
                                               in store: UserDefaults = Preferences.defaults) {
        store.set(sound.rawValue, forKey: "sessionFinishedSound")
    }
}
