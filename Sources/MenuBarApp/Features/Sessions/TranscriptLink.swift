import SwiftUI

// Inline markdown only: `code`, bold, italics and links render, newlines stay as
// they are. Block structure is the parser's job, so none of it reaches here.
extension AttributedString {
    static func inlineMarkdown(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }

        // Markdown keeps filesystem paths as scheme-less URLs, which Launch Services
        // cannot open. Turn only filesystem-shaped links into file URLs and leave web,
        // mail, and relative links to SwiftUI's normal handling.
        for run in Array(attributed.runs) {
            guard let link = run.link else { continue }
            if link.scheme == nil, link.host == nil {
                let path = link.path
                if path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") {
                    var file = URLComponents(url: URL(
                        fileURLWithPath: (path as NSString).expandingTildeInPath), resolvingAgainstBaseURL: false)
                    file?.fragment = link.fragment
                    attributed[run.range].link = file?.url
                }
            }
        }
        return attributed
    }

    var hasLocalFileLink: Bool {
        runs.contains { $0.link?.isFileURL == true }
    }

    // Markdown leaves an address in backticks unlinked. A code span is linked only when
    // it holds the address alone, so a command that mentions one still reads as code.
    func linkingLocalServers() -> AttributedString {
        let rendered = String(characters)
        let addresses = TranscriptLink.localServers(in: rendered)
        guard !addresses.isEmpty else { return self }

        let code = runs[\.inlinePresentationIntent].compactMap { intent, range in
            intent?.contains(.code) == true ? Range(range, in: rendered) : nil
        }
        var linked = self
        for (span, url) in addresses {
            guard code.allSatisfy({ !$0.overlaps(span) || $0 == span }),
                  let start = AttributedString.Index(span.lowerBound, within: linked),
                  let end = AttributedString.Index(span.upperBound, within: linked),
                  linked[start..<end].runs.allSatisfy({ $0.link == nil }) else { continue }
            linked[start..<end].link = url
        }
        return linked
    }
}

struct LinkHoverAction {
    let perform: (URL?) -> Void

    func callAsFunction(_ url: URL?) { perform(url) }
}

extension EnvironmentValues {
    // The recorded session folders that can accept a file in Explorer. Files outside
    // them can still be read in a preview.
    @Entry var explorerRoots: [String] = []
    // Off where there is no preview, so text and its links stay as they were.
    @Entry var previewsLocalServers = false
    @Entry var fileReferenceAction: FileReferenceAction? = nil
    // Told which link the pointer is over, and nil when it leaves, where a screen lights
    // what a link points at before it is clicked.
    @Entry var linkHovered: LinkHoverAction? = nil
}

enum TranscriptLink {
    static let fileActionsToolTip = "File actions"
    static let finderToolTip = "Open in Finder"
    static let explorerToolTip = "Show in Explorer"
    static let previewToolTip = "Open in preview"

    struct ExplorerTarget: Equatable {
        let root: String
        let path: String
        let line: Int?
    }

    struct Hovered: Equatable {
        let url: URL
        let frame: CGRect
    }

    // File links can carry a source line after the path. Finder needs the real path,
    // while web and mail links keep SwiftUI's normal system action.
    static func finderTarget(
        for url: URL,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL? {
        guard url.isFileURL else { return nil }
        guard !fileExists(url.path),
              let suffix = url.path.range(of: #":\d+(?::\d+)?$"#,
                                          options: .regularExpression) else { return url }

        let file = URL(fileURLWithPath: String(url.path[..<suffix.lowerBound]))
        return fileExists(file.path) ? file : url
    }

    // A file inside one of the session's folders is shown in the app's own explorer
    // instead of Finder. When folders nest, the deepest one wins, so a worktree inside
    // its project opens as itself.
    static func explorerTarget(
        for url: URL,
        roots: [String],
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> ExplorerTarget? {
        guard let reference = fileReference(for: url, relativeTo: roots.first ?? "", fileExists: fileExists),
              fileExists(reference.url.path),
              let root = reference.explorerRoot(in: roots) else { return nil }
        let canonicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let relative = reference.url.path.pathRelative(to: canonicalRoot) ?? ""
        return ExplorerTarget(root: root,
                              path: URL(fileURLWithPath: root).appendingPathComponent(relative).path,
                              line: reference.line)
    }

    static func fileReference(for url: URL, relativeTo directory: String,
                              fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> FileReference? {
        guard url.isFileURL || (url.scheme == nil && url.host == nil && !url.path.isEmpty) else { return nil }
        let expanded = (url.path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") || !directory.isEmpty else { return nil }
        var file = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: directory).appendingPathComponent(expanded)
        var line: Int?
        if !fileExists(file.path), let suffix = file.path.range(of: #":\d+(?::\d+)?$"#,
                                                               options: .regularExpression) {
            line = Int(file.path[suffix.lowerBound...].dropFirst().prefix(while: \.isNumber))
            file = URL(fileURLWithPath: String(file.path[..<suffix.lowerBound]))
        }
        if let fragment = url.fragment,
           let match = fragment.range(of: #"^(?:L|line=)?[1-9]\d*(?:$|[-:]|C)"#, options: .regularExpression) {
            line = Int(fragment[match].drop(while: { !$0.isNumber }).prefix(while: \.isNumber))
        }
        return FileReference(url: file.resolvingSymlinksInPath().standardizedFileURL,
                             line: line.flatMap { $0 > 0 ? $0 : nil }, fragment: url.fragment)
    }

    // The hosts the sign-in callback trusts. A name such as app.localhost is left out,
    // as it goes through the resolver like any other host.
    static let localServerHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    static func isLocalServer(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host
        else { return false }
        return localServerHosts.contains(host.lowercased())
    }

    static func localServers(in text: String) -> [(span: Range<String.Index>, url: URL)] {
        guard mentionsLocalServer(text) else { return [] }
        return text.matches(of: localServerAddress).compactMap { match in
            let address = trimmingSentence(from: match.output)
            guard let url = URL(string: String(address)), isLocalServer(url) else { return nil }
            return (address.startIndex..<address.endIndex, url)
        }
    }

    static func latestLocalServer(in messages: [ChatMessage]) -> URL? {
        messages.reversed().lazy.compactMap { lastLocalServer(in: $0) }.first
    }

    // Read as the transcript draws it, so only an address shown as a link counts.
    private static func lastLocalServer(in message: ChatMessage) -> URL? {
        guard mentionsLocalServer(message.text) else { return nil }
        let prose: [AttributedString]
        switch message.role {
        case .assistant:
            prose = MessageSegment.split(message.text).filter { !$0.isCode }
                .map { AttributedString.inlineMarkdown($0.text).linkingLocalServers() }
        case .user:
            prose = SentPrompt.segments(message.text).filter { !$0.isCode }
                .map { SentPrompt.inline($0.text, commands: SlashCommandNames()) }
        case .system, .instructions:
            return nil
        }
        return prose.flatMap { $0.runs[\.link].compactMap { link, _ in link } }
            .last(where: isLocalServer)
    }

    private static func mentionsLocalServer(_ text: String) -> Bool {
        ["://localhost", "://127.0.0.1", "://[::1]"].contains(where: {
            text.range(of: $0, options: .caseInsensitive) != nil
        })
    }

    private static var localServerAddress: Regex<Substring> {
        #/https?://[A-Za-z0-9\-._~:\/?#\[\]@!$&()*+,;=%]+/#
    }

    private static func trimmingSentence(from match: Substring) -> Substring {
        var address = match
        func count(_ character: Character) -> Int { address.filter { $0 == character }.count }
        while let last = address.last,
              ".,:;!?".contains(last)
                || (last == ")" && count(")") > count("("))
                || (last == "]" && count("]") > count("[")) {
            address = address.dropLast()
        }
        return address
    }

    // NSTextView fills the available row even when its link is only a few words. Use
    // the link's glyphs so its hint follows the text instead of the edge of that row.
    @MainActor
    static func hoveredLink(in textView: NSTextView, at point: CGPoint) -> Hovered? {
        guard let storage = textView.textStorage,
              let container = textView.textContainer,
              let layoutManager = textView.layoutManager,
              storage.length > 0 else { return nil }

        layoutManager.ensureLayout(for: container)
        let origin = textView.textContainerOrigin
        let containerPoint = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: containerPoint,
            in: container,
            fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }

        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: container)
        guard glyphRect.insetBy(dx: -1, dy: -1).contains(containerPoint) else { return nil }

        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        var linkCharacters = NSRange()
        guard let value = storage.attribute(.link,
                                            at: character,
                                            effectiveRange: &linkCharacters),
              let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        else { return nil }

        let linkGlyphs = layoutManager.glyphRange(
            forCharacterRange: linkCharacters,
            actualCharacterRange: nil)
        var lineGlyphs = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let visibleLinkGlyphs = NSIntersectionRange(linkGlyphs, lineGlyphs)
        guard visibleLinkGlyphs.length > 0 else { return nil }

        let rect = layoutManager.boundingRect(forGlyphRange: visibleLinkGlyphs, in: container)
            .offsetBy(dx: origin.x, dy: origin.y)
        return Hovered(url: url, frame: rect)
    }
}
