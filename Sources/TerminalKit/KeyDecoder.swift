// Turns the bytes a terminal sends into keys. Pure: it never touches the tty, so it is
// tested with byte fixtures. A read can end in the middle of a character or an escape
// sequence, so whatever is incomplete is kept for the next feed.

public struct Modifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = Modifiers(rawValue: 1)
    public static let alt = Modifiers(rawValue: 2)
    public static let ctrl = Modifiers(rawValue: 4)
}

public enum Key: Sendable, Hashable {
    case char(Character, Modifiers)
    case enter(Modifiers), tab(Modifiers), backspace(Modifiers), escape
    case up(Modifiers), down(Modifiers), left(Modifiers), right(Modifiers)
    case home(Modifiers), end(Modifiers), pageUp(Modifiers), pageDown(Modifiers)
    case delete(Modifiers)
    // Everything between the bracketed-paste markers, as one value.
    case paste(String)
}

public struct KeyDecoder: Sendable {
    private var pending: [UInt8] = []
    private var pasting: [UInt8]?

    private static let pasteStart: [UInt8] = Array("\u{1B}[200~".utf8)
    private static let pasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)

    public init() {}

    public mutating func feed<C: Collection>(_ bytes: C) -> [Key] where C.Element == UInt8 {
        pending.append(contentsOf: bytes)
        var keys: [Key] = []
        while let (key, used) = next() {
            pending.removeFirst(used)
            if let key { keys.append(key) }
        }
        return keys
    }

    // An ESC on its own is either the Escape key or the start of a sequence whose rest
    // has not arrived yet. Only time can tell them apart, so the caller waits a moment
    // and then flushes.
    public var hasLoneEscape: Bool { pasting == nil && pending == [0x1B] }

    public mutating func flush() -> [Key] {
        guard hasLoneEscape else { return [] }
        pending.removeAll()
        return [.escape]
    }

    // The next key and how many bytes it used. A nil key with a count means the bytes
    // were consumed without a key (an unknown sequence, the start of a paste). Nil
    // altogether means more bytes are needed.
    private mutating func next() -> (Key?, Int)? {
        if pasting != nil { return pasted() }
        guard let byte = pending.first else { return nil }
        switch byte {
        case 0x0D: return (.enter([]), 1)
        case 0x09: return (.tab([]), 1)
        case 0x7F, 0x08: return (.backspace([]), 1)
        case 0x01...0x1A: return (.char(Character(UnicodeScalar(byte + 0x60)), .ctrl), 1)
        case 0x1B: return escape()
        case 0x00, 0x1C...0x1F: return (nil, 1)
        default: return character()
        }
    }

    private mutating func pasted() -> (Key?, Int)? {
        if let end = pending.firstRange(of: Self.pasteEnd) {
            let text = (pasting ?? []) + pending[..<end.lowerBound]
            pasting = nil
            return (.paste(String(decoding: text, as: UTF8.self)), end.upperBound)
        }
        // Keep back anything that could be the start of the end marker.
        var keep = 0
        for length in stride(from: min(Self.pasteEnd.count - 1, pending.count), to: 0, by: -1)
            where pending.suffix(length).elementsEqual(Self.pasteEnd.prefix(length)) {
            keep = length
            break
        }
        let take = pending.count - keep
        guard take > 0 else { return nil }
        pasting?.append(contentsOf: pending[..<take])
        return (nil, take)
    }

    private func character() -> (Key?, Int)? {
        let lead = pending[0]
        let length = lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
        guard pending.count >= length else { return nil }
        let text = String(decoding: pending[0..<length], as: UTF8.self)
        return (.char(text.first ?? "\u{FFFD}", []), length)
    }

    private mutating func escape() -> (Key?, Int)? {
        guard pending.count >= 2 else { return nil }
        let second = pending[1]
        // A second ESC means the first was the Escape key on its own: Escape pressed
        // twice, or just before another key's sequence. The rest is decoded after it.
        if second == 0x1B { return (.escape, 1) }
        if second == 0x0D { return (.enter(.alt), 2) }
        if second == UInt8(ascii: "O") { return ss3() }
        if second != UInt8(ascii: "[") {
            // Alt+key arrives as the key with ESC in front of it.
            var inner = KeyDecoder()
            inner.pending = Array(pending[1...])
            guard let (key, used) = inner.next() else { return nil }
            switch key {
            case .char(let c, let m)?: return (.char(c, m.union(.alt)), used + 1)
            case .backspace(let m)?: return (.backspace(m.union(.alt)), used + 1)
            default: return (key, used + 1)
            }
        }
        return csi()
    }

    // ESC O x: cursor keys in application mode.
    private func ss3() -> (Key?, Int)? {
        guard pending.count >= 3 else { return nil }
        switch pending[2] {
        case UInt8(ascii: "A"): return (.up([]), 3)
        case UInt8(ascii: "B"): return (.down([]), 3)
        case UInt8(ascii: "C"): return (.right([]), 3)
        case UInt8(ascii: "D"): return (.left([]), 3)
        case UInt8(ascii: "H"): return (.home([]), 3)
        case UInt8(ascii: "F"): return (.end([]), 3)
        default: return (nil, 3)
        }
    }

    // ESC [ parameters final, where the final byte is in 0x40...0x7E.
    private mutating func csi() -> (Key?, Int)? {
        guard let finalIndex = pending.dropFirst(2).firstIndex(where: { (0x40...0x7E).contains($0) })
        else { return nil }
        let params = String(decoding: pending[2..<finalIndex], as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        let final = pending[finalIndex]
        let used = finalIndex + 1
        let mods = params.count >= 2 ? Self.modifiers(params[1]) : []

        switch (Character(UnicodeScalar(final)), params.first ?? 1) {
        case ("A", _): return (.up(mods), used)
        case ("B", _): return (.down(mods), used)
        case ("C", _): return (.right(mods), used)
        case ("D", _): return (.left(mods), used)
        case ("H", _): return (.home(mods), used)
        case ("F", _): return (.end(mods), used)
        case ("Z", _): return (.tab(.shift), used)
        case ("~", 200):
            pasting = []
            return (nil, used)
        case ("~", 1), ("~", 7): return (.home(mods), used)
        case ("~", 4), ("~", 8): return (.end(mods), used)
        case ("~", 3): return (.delete(mods), used)
        case ("~", 5): return (.pageUp(mods), used)
        case ("~", 6): return (.pageDown(mods), used)
        case ("~", 27) where params.count == 3:
            // xterm modifyOtherKeys: 27 ; modifiers ; code
            return (Self.key(code: params[2], Self.modifiers(params[1])), used)
        case ("u", let code):
            // kitty: code ; modifiers u
            return (Self.key(code: code, mods), used)
        default:
            return (nil, used)
        }
    }

    // The modifier parameter is one more than the bit set.
    private static func modifiers(_ parameter: Int) -> Modifiers {
        Modifiers(rawValue: UInt8(clamping: max(0, parameter - 1)) & 0b111)
    }

    private static func key(code: Int, _ mods: Modifiers) -> Key? {
        switch code {
        case 13: return .enter(mods)
        case 9: return .tab(mods)
        case 27: return .escape
        case 127, 8: return .backspace(mods)
        default:
            guard let scalar = UnicodeScalar(UInt32(clamping: code)) else { return nil }
            return .char(Character(scalar), mods)
        }
    }
}
