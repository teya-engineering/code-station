import AppKit
import SwiftUI

// One press of the keyboard: a key and the modifiers held with it. It is the single form a
// shortcut takes, so a key the person changes reaches a SwiftUI button, a key monitor and
// the label that names it all at once.
struct KeyCombo: Hashable, Codable, Sendable {
    struct Modifiers: OptionSet, Hashable, Codable, Sendable {
        let rawValue: Int

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    // Either one character, in lower case, as the key types it, or the name of a key that
    // types nothing, such as "return". A name is always longer than one character, so
    // the two never meet.
    let key: String
    let modifiers: Modifiers

    init(_ key: String, _ modifiers: Modifiers = .command) {
        self.key = Self.names.values.contains(key) ? key : key.lowercased()
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        // A key that types nothing is told apart by where it sits, since what it "types"
        // is a control character that reads differently from one source to the next.
        if let name = Self.names[event.keyCode] {
            self.init(name, modifiers)
        } else {
            // A dead key, such as the backtick on a Brazilian or international layout,
            // types nothing on its own, so AppKit leaves its plain character empty. Held
            // with Control it still types its own mark, which is the key it is.
            let plain = event.charactersIgnoringModifiers ?? ""
            guard let characters = plain.isEmpty ? event.characters : plain, characters.count == 1,
                  let scalar = characters.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar),
                  // The arrow, function and page keys type characters from a private range.
                  !(0xF700...0xF8FF).contains(scalar.value)
            else { return nil }
            self.init(characters, modifiers)
        }
    }

    func matches(_ event: NSEvent) -> Bool { KeyCombo(event: event) == self }

    // MARK: - Named keys

    static let returnKey = "return"
    static let escape = "escape"
    static let tab = "tab"
    static let delete = "delete"
    static let space = "space"
    static let up = "up"
    static let down = "down"
    static let left = "left"
    static let right = "right"

    private static let names: [UInt16: String] = [
        36: returnKey, 76: returnKey, 53: escape, 48: tab, 51: delete, 49: space,
        126: up, 125: down, 123: left, 124: right
    ]

    var isNamed: Bool { key.count > 1 }

    // MARK: - Labels

    // The order every Mac menu writes them in.
    var parts: [String] {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyLabel)
        return parts
    }

    // Spaced, as a row in a list reads it: "⇧ ⌘ A".
    var label: String { parts.joined(separator: " ") }

    // Run together, for a hint squeezed beside something else: "⇧⌘A".
    var compactLabel: String { parts.joined() }

    // What VoiceOver reads: "Command-Shift-A".
    var spokenLabel: String {
        var words: [String] = []
        if modifiers.contains(.command) { words.append("Command") }
        if modifiers.contains(.shift) { words.append("Shift") }
        if modifiers.contains(.option) { words.append("Option") }
        if modifiers.contains(.control) { words.append("Control") }
        words.append(spokenKey)
        return words.joined(separator: "-")
    }

    private var keyLabel: String {
        switch key {
        case Self.returnKey: "⏎"
        case Self.escape: "Esc"
        case Self.tab: "⇥"
        case Self.delete: "⌫"
        case Self.space: "Space"
        case Self.up: "↑"
        case Self.down: "↓"
        case Self.left: "←"
        case Self.right: "→"
        default: key.uppercased()
        }
    }

    private var spokenKey: String {
        switch key {
        case Self.returnKey: "Return"
        case Self.escape: "Escape"
        case Self.tab: "Tab"
        case Self.delete: "Delete"
        case Self.space: "Space"
        case Self.up: "Up Arrow"
        case Self.down: "Down Arrow"
        case Self.left: "Left Arrow"
        case Self.right: "Right Arrow"
        default: key.uppercased()
        }
    }

    // MARK: - SwiftUI

    var shortcut: KeyboardShortcut {
        var held: EventModifiers = []
        if modifiers.contains(.control) { held.insert(.control) }
        if modifiers.contains(.option) { held.insert(.option) }
        if modifiers.contains(.command) { held.insert(.command) }
        // Shift with a letter is a modifier like any other. Shift with a symbol already
        // made the symbol, such as the brace from the bracket key, and AppKit expects
        // a key equivalent written that way to leave shift out of its mask.
        if modifiers.contains(.shift), isNamed || key.uppercased() != key {
            held.insert(.shift)
        }
        return KeyboardShortcut(keyEquivalent, modifiers: held)
    }

    private var keyEquivalent: KeyEquivalent {
        switch key {
        case Self.returnKey: .return
        case Self.escape: .escape
        case Self.tab: .tab
        case Self.delete: .delete
        case Self.space: .space
        case Self.up: .upArrow
        case Self.down: .downArrow
        case Self.left: .leftArrow
        case Self.right: .rightArrow
        default: KeyEquivalent(Character(key))
        }
    }
}
