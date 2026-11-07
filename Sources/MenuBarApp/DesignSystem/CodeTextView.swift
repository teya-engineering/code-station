import AppKit

// What every text view that holds code shares with the others: no prose helpers, and
// colour laid on by the shared highlighter.
extension NSTextView {
    // None of the prose helpers belong in code: they rewrite quotes, dashes and words as
    // you type, and the rewrite is what would be saved or parsed.
    func turnOffProseHelpers() {
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        smartInsertDeleteEnabled = false
    }
}

extension NSTextStorage {
    // Colours one line, without its newline, that starts at `location` in the storage.
    // `state` is the state the line starts in, and is left as the one the next starts in.
    func paintCode(_ line: Substring, at location: Int, language: CodeLanguage,
                   state: inout CodeHighlight.State) {
        for token in CodeHighlight.tokens(in: line, language: language, state: &state) {
            let offset = NSRange(token.range, in: line)
            addAttribute(.foregroundColor, value: CodeStyle.nsColor(for: token.kind),
                         range: NSRange(location: location + offset.location, length: offset.length))
        }
    }
}
