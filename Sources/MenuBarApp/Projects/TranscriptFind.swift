import AppKit
import Observation
import SwiftUI

struct TranscriptFindMatch: Equatable, Sendable {
    let messageID: UUID
    // Which match inside its message, counted in reading order.
    let occurrence: Int
}

struct TranscriptFindResult: Equatable, Sendable {
    var matches: [TranscriptFindMatch] = []
    var hasMore = false
}

// Searches what the conversation says rather than the text views on screen. Only the
// newest messages are built, so a search over the views would miss everything that has
// not been loaded yet. Tool calls are left out: their output is drawn as plain SwiftUI
// text, which has no way to mark a match inside it.
enum TranscriptSearch {
    static func search(_ query: String, in messages: [ChatMessage]) -> TranscriptFindResult {
        guard !query.isEmpty else { return TranscriptFindResult() }

        var result = TranscriptFindResult()
        for message in messages {
            var occurrence = 0
            for text in searchableTexts(of: message) {
                let found = FileFind.search(query, in: text)
                for _ in found.matches {
                    guard result.matches.count < FileFind.matchLimit else {
                        result.hasMore = true
                        return result
                    }
                    result.matches.append(TranscriptFindMatch(messageID: message.id,
                                                              occurrence: occurrence))
                    occurrence += 1
                }
                if found.hasMore {
                    result.hasMore = true
                    return result
                }
            }
        }
        return result
    }

    static func searchableTexts(of message: ChatMessage) -> [String] {
        switch message.role {
        case .assistant:
            return message.blocks.flatMap { block -> [String] in
                switch block {
                case .prose(_, let text):
                    return MessageSegment.split(text).flatMap { segment -> [String] in
                        if segment.isChart { return [] }
                        if segment.isCode { return [segment.text] }
                        return MarkdownBlock.parse(segment.text).flatMap { block -> [String] in
                            switch block.kind {
                            case .paragraph(let text), .heading(_, let text), .quote(let text):
                                return [String(AttributedString.inlineMarkdown(text).characters)]
                            case .list(let items):
                                return items.map { String(AttributedString.inlineMarkdown($0.text).characters) }
                            case .table(let table):
                                return (table.header + table.rows.flatMap { $0 }).map {
                                    String(AttributedString.inlineMarkdown($0).characters)
                                }
                            case .rule, .htmlPreview:
                                return []
                            }
                        }
                    }
                case .thinking(_, let text):
                    return [text.trimmed]
                case .tools:
                    return []
                }
            }
        case .user:
            return SentPrompt.segments(message.text).map {
                $0.isCode ? $0.text : String(AttributedString.inlineMarkdown($0.text).characters)
            }
        case .system, .instructions:
            return [message.text]
        }
    }

    // What a selection turns into when it starts a search: the first line that has
    // something on it, cut to a length a search field can show.
    static func query(fromSelection text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return String(line.prefix(200))
    }
}

// Find in a session's conversation. It is held by the pane, like the selection, and
// reaches every text view in the transcript through the environment, so each one can
// paint the matches that fall inside it.
@MainActor
@Observable
final class TranscriptFind {
    private(set) var isPresented = false
    private(set) var query = ""
    private(set) var result = TranscriptFindResult()
    private(set) var selection = 0
    // Bumped whenever the pane should bring the current match into view.
    private(set) var jumpRequest = 0

    @ObservationIgnored private var views: [ObjectIdentifier: Registration] = [:]
    @ObservationIgnored private weak var currentView: NSTextView?
    @ObservationIgnored private var currentRange: NSRange?

    private struct Registration {
        weak var view: NSTextView?
        let messageID: UUID
    }

    var currentMatch: TranscriptFindMatch? {
        guard isPresented, result.matches.indices.contains(selection) else { return nil }
        return result.matches[selection]
    }

    var summary: String {
        FindSummary.text(query: query, matchCount: result.matches.count,
                         hasMore: result.hasMore, selection: selection)
    }

    // Opening without a query picks up the last search again, against the conversation
    // as it is now.
    func open(query newQuery: String? = nil, in messages: [ChatMessage]) {
        isPresented = true
        search(newQuery ?? query, in: messages)
    }

    func close() {
        isPresented = false
        clearCurrent()
        redrawAll()
    }

    // A new search starts from the newest match, since the end of the conversation is
    // where a person usually is when they start looking back through it.
    func search(_ newQuery: String, in messages: [ChatMessage]) {
        query = newQuery
        result = TranscriptSearch.search(newQuery, in: messages)
        selection = max(0, result.matches.count - 1)
        clearCurrent()
        redrawAll()
        requestJump()
    }

    // The conversation grows while a turn runs. The selection is kept rather than moved,
    // so a reply streaming in does not pull someone away from what they were reading.
    func refresh(in messages: [ChatMessage]) {
        guard isPresented, !query.isEmpty else { return }
        let previous = currentMatch
        result = TranscriptSearch.search(query, in: messages)
        selection = min(selection, max(0, result.matches.count - 1))
        clearCurrent()
        _ = placeCurrent()
        redrawAll()
        if previous == nil { requestJump() }
    }

    func move(by offset: Int) {
        let count = result.matches.count
        guard count > 0 else { return }
        selection = (selection + offset + count) % count
        clearCurrent()
        redrawAll()
        requestJump()
    }

    // Folded text in the current match's message opens by itself, so a match inside it
    // can be shown rather than only counted.
    func reveals(_ text: String, in messageID: UUID?) -> Bool {
        guard let messageID, currentMatch?.messageID == messageID else { return false }
        return !FileFind.search(query, in: text).matches.isEmpty
    }

    // MARK: - Text views

    func register(_ view: NSTextView, messageID: UUID) {
        views[ObjectIdentifier(view)] = Registration(view: view, messageID: messageID)
    }

    func unregister(_ view: NSTextView) {
        views[ObjectIdentifier(view)] = nil
    }

    // Every match inside one text view, and which of them is the current one. The view's
    // own text is searched, not the stored message, because markdown is drawn without
    // its markup and the two do not line up character for character.
    func highlights(in view: NSTextView) -> (all: [NSRange], current: NSRange?) {
        guard isPresented, !query.isEmpty else { return ([], nil) }
        let all = FileFind.search(query, in: view.string).matches
        return (all, currentView === view ? currentRange : nil)
    }

    // Finds the current match among the text views of its message and marks it. Returns
    // nil while that message has not been drawn yet. When the drawn text has fewer
    // matches than the stored one, the last drawn match stands in for it.
    func placeCurrent() -> (view: NSTextView, range: NSRange)? {
        guard let match = currentMatch else { return nil }
        let placed = orderedViews(of: match.messageID).flatMap { view in
            FileFind.search(query, in: view.string).matches.map { (view: view, range: $0) }
        }
        guard !placed.isEmpty else { return nil }
        let found = placed[min(match.occurrence, placed.count - 1)]
        currentView?.needsDisplay = true
        currentView = found.view
        currentRange = found.range
        found.view.needsDisplay = true
        return found
    }

    // Whether the message holding the current match has drawn as many matches as it
    // holds, which is how the pane knows folded text has finished opening.
    var currentIsFullyDrawn: Bool {
        guard let match = currentMatch else { return true }
        let drawn = orderedViews(of: match.messageID).reduce(0) {
            $0 + FileFind.search(query, in: $1.string).matches.count
        }
        return drawn > match.occurrence
    }

    // Reading order comes from where the views sit on screen, in window coordinates,
    // which always run from the bottom left.
    private func orderedViews(of messageID: UUID) -> [NSTextView] {
        views = views.filter { $0.value.view != nil }
        return views.values
            .filter { $0.messageID == messageID }
            .compactMap { registration -> (NSTextView, CGRect)? in
                guard let view = registration.view, view.window != nil else { return nil }
                return (view, view.convert(view.bounds, to: nil))
            }
            .sorted { lhs, rhs in
                abs(lhs.1.maxY - rhs.1.maxY) > 0.5 ? lhs.1.maxY > rhs.1.maxY : lhs.1.minX < rhs.1.minX
            }
            .map(\.0)
    }

    private func requestJump() {
        guard !result.matches.isEmpty else { return }
        jumpRequest += 1
    }

    private func clearCurrent() {
        currentView?.needsDisplay = true
        currentView = nil
        currentRange = nil
    }

    private func redrawAll() {
        for registration in views.values { registration.view?.needsDisplay = true }
    }
}

extension EnvironmentValues {
    @Entry var transcriptFind: TranscriptFind?
    // The message a run of transcript text belongs to, so a find can tell which views
    // hold the match it is looking for.
    @Entry var transcriptMessageID: UUID?
}

extension NSTextView {
    // Brings a range to the middle of the transcript rather than to its edge, so the
    // lines around a match are on screen with it. A code block scrolls sideways in a
    // scroller of its own, so that one is moved first and the transcript after it.
    func revealCentered(_ range: NSRange) {
        scrollRangeToVisible(range)
        guard let layoutManager, let textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)

        var outermost: NSScrollView?
        var view: NSView? = self
        while let current = view {
            if let scrollView = current as? NSScrollView { outermost = scrollView }
            view = current.superview
        }
        guard let outermost, let document = outermost.documentView else { return }
        let margin = outermost.contentView.bounds.height / 3
        document.scrollToVisible(convert(rect, to: document).insetBy(dx: 0, dy: -margin))
    }
}
