import AppKit

// The word a prompt can carry to ask Claude to reason harder on that one turn. Claude's
// CLI finds it in the prompt text itself and acts on it, whether the prompt was typed in
// a terminal or sent to it by this app, so all there is to do here is show that the word
// counts for something. The other agents have no word like it.
enum ThinkingKeyword {
    static let word = "ultrathink"

    // How long the colours take to travel once around the spectrum.
    private static let cycle: TimeInterval = 6

    // How much of the spectrum the word covers at any one moment. A whole turn of it
    // would put the same colour at both ends of the word.
    private static let spread = 0.62

    // The moment a word that is not animated takes its colours from: the start of the
    // sweep, so the word still runs across the spectrum but stays where it is.
    static let still = Date(timeIntervalSinceReferenceDate: 0)

    // Every standalone use of the word. A letter or a digit against either end makes it
    // part of a longer word, which the CLI would not act on.
    static func ranges(in text: String) -> [NSRange] {
        let text = text as NSString
        var found: [NSRange] = []
        var start = 0
        while start < text.length {
            let match = text.range(of: word, options: .caseInsensitive,
                                   range: NSRange(location: start, length: text.length - start))
            guard match.location != NSNotFound else { break }
            if !isWordCharacter(at: match.location - 1, in: text),
               !isWordCharacter(at: NSMaxRange(match), in: text) {
                found.append(match)
            }
            start = NSMaxRange(match)
        }
        return found
    }

    // The colour one letter of the word takes at a given moment. The letters run through
    // the spectrum in order and the whole band drifts along the word, so it reads as one
    // ribbon of colour moving rather than as a row of separate colours.
    static func colour(letter: Int, of count: Int, at date: Date, dark: Bool) -> NSColor {
        let across = count > 1 ? Double(letter) / Double(count - 1) * spread : 0
        // The absolute clock keeps redraws from restarting the sweep.
        let drift = date.timeIntervalSinceReferenceDate / cycle
        let hue = (across + drift).truncatingRemainder(dividingBy: 1)
        // A pale colour disappears against the light field and a deep one against the
        // dark one, so the two sides of the theme need different ends of the scale.
        return NSColor(hue: hue,
                       saturation: dark ? 0.52 : 0.85,
                       brightness: dark ? 1 : 0.62,
                       alpha: 1)
    }

    private static func isWordCharacter(at index: Int, in text: NSString) -> Bool {
        guard index >= 0, index < text.length,
              let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }
}
