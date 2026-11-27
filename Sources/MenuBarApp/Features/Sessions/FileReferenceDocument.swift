import Foundation

struct MarkdownLocation: Hashable {
    let segment: Int
    let block: Int
}

struct FileReferenceHeading: Identifiable {
    let id: MarkdownLocation
    let title: String
    let level: Int
    let fragment: String
}

enum FileReferenceDocument {
    static func outline(_ text: String) -> [FileReferenceHeading] {
        let segments = MessageSegment.split(MarkdownHTML.removingComments(text))
        let blocks = MarkdownBlock.parse(document: segments)
        var slugs: [String: Int] = [:]
        return segments.flatMap { segment in
            (blocks[segment.id] ?? []).compactMap { block in
                let kind: MarkdownBlock.Kind
                if case .centered(let inner) = block.kind { kind = inner } else { kind = block.kind }
                guard case .heading(let level, let text) = kind else { return nil }
                let title = String(AttributedString.inlineMarkdown(text).characters)
                let base = title.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "-" || $0 == "_" }
                    .map { $0.isWhitespace ? "-" : String($0) }.joined()
                let occurrence = slugs[base, default: 0]
                slugs[base] = occurrence + 1
                return FileReferenceHeading(id: MarkdownLocation(segment: segment.id, block: block.id),
                                            title: title, level: level,
                                            fragment: occurrence == 0 ? base : "\(base)-\(occurrence)")
            }
        }
    }
}
