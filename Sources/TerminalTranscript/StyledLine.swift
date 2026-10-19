// One row of a rendered transcript: runs of text, each with what it is rather than how
// it looks. A theme decides the look, so the same lines serve any colour depth, and
// tests can read what a line says and what each part of it is without escape codes.

import CodeStationCore

// What a run of text is. The theme maps each to terminal styling.
public enum LineStyle: Hashable, Sendable {
    case plain
    // The marker in front of a prompt, and the prompt's own text.
    case userMarker, user
    case thinking
    // A tool call's summary, and its marker when the call is running or failed.
    case tool, toolRunning, toolError
    // Lines a call added and removed.
    case added, removed
    // Anything said about the session rather than in it: system notes, attachments.
    case notice
    // Markdown in a reply.
    case heading(Int)
    case strong, emphasis, strongEmphasis, strikethrough
    // Inline code. A code block's text is plain, with its tokens in `syntax`.
    case code
    // A link's text, and the address shown after it when the two differ.
    case link, linkTarget
    case listMarker
    // The rule in front of a quote, and a horizontal rule or table lines.
    case quote, rule
    case syntax(CodeHighlight.Kind)
    // What an open tool call ran and returned, and what a failed one returned.
    case output, outputError
    // A session's state word, in the colour the GUI gives its tone.
    case state(StateTone)
    // A mark that asks to be noticed without saying a state, such as an unread session.
    case attention
}

// The tones a session's state word is drawn in, as the GUI draws them: running and
// waiting share the live colour, anything that needs the person is amber, a failed turn
// is red, and idle recedes.
public enum StateTone: Hashable, Sendable {
    case running, waiting, needsYou, idle, failed

    // The tone of a state word as the station spells it (`SessionTone.word`, FAILED, and
    // the words a header adds while a turn is being stopped or answered).
    public init(word: String) {
        switch word {
        case "RUNNING", "STOPPING", "DIAGNOSING": self = .running
        case "WAITING": self = .waiting
        case "NEEDS YOU", "PERMISSION", "QUESTION": self = .needsYou
        case "FAILED": self = .failed
        default: self = .idle
        }
    }
}

public struct Span: Equatable, Sendable {
    public var text: String
    public var style: LineStyle

    public init(_ text: String, _ style: LineStyle = .plain) {
        self.text = text
        self.style = style
    }
}

// Where a line came from: the message, the block inside it, and the tool call when the
// line is one. What a front end needs to act on a line, such as copying its message or
// opening its tool.
public struct LineSource: Hashable, Sendable {
    public var messageID: String
    public var block: Int?
    public var toolID: String?
    // Which fenced code block of the prose block the line belongs to, counted from 0, so
    // the block under a line can be copied (see TranscriptCopy).
    public var code: Int?

    public init(messageID: String, block: Int? = nil, toolID: String? = nil, code: Int? = nil) {
        self.messageID = messageID
        self.block = block
        self.toolID = toolID
        self.code = code
    }
}

public struct StyledLine: Equatable, Sendable {
    public var spans: [Span]
    public var source: LineSource?

    public init(_ spans: [Span] = [], source: LineSource? = nil) {
        self.spans = spans
        self.source = source
    }

    // The line as plain text, with no styling.
    public var text: String { spans.map(\.text).joined() }

    public var width: Int { TerminalColumns.width(of: text) }
}
