import AppKit
import SwiftUI

// The small pieces the pull request review views share, and how the model's words are drawn.

struct PullRequestAnsweredTick: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill").font(Typography.detail).foregroundStyle(Theme.dotOn)
            .accessibilityLabel("Answered")
    }
}

// A reviewer's words, drawn the way the transcript draws the agent's: same markdown,
// same code blocks, same type. GitHub's HTML is turned into markdown first.
struct GitHubProse: View {
    @Environment(AppSettings.self) private var appSettings
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        MarkdownProse(text: GitHubMarkdown.clean(text), projectPath: "", textScale: appSettings.textSize.scale) {
            MarkdownCodeBlock(segment: $0).equatable()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// GitHub lets a review body carry HTML next to its markdown, and bots lean on it: hidden
// comments, <details> folds, anchors. The transcript's renderer speaks markdown only, so
// the HTML is turned into the markdown it stands for before it gets there.
enum GitHubMarkdown {
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        result = replace(#"<!--[\s\S]*?-->"#, in: result, with: "")
        result = replace(#"<summary>\s*(?:<strong>|<b>)?\s*(.*?)\s*(?:</strong>|</b>)?\s*</summary>"#,
                         in: result, with: "**$1**\n")
        result = replace(#"<a\s[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>"#, in: result, with: "[$2]($1)")
        result = replace(#"</?(strong|b)>"#, in: result, with: "**")
        result = replace(#"</?(em|i)>"#, in: result, with: "_")
        result = replace(#"<br\s*/?>"#, in: result, with: "\n")
        // Whatever is left is layout the renderer cannot use: <details>, <picture> and its
        // <source>s, <sub>, <img>. The words inside stay; the tags go.
        result = replace(#"</?[a-zA-Z][^>]*>"#, in: result, with: "")
        // Removed tags leave their lines behind; more than one blank line is noise.
        result = replace(#"\n{3,}"#, in: result, with: "\n\n")
        return result.trimmed
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: template)
    }
}

// The reviewer's GitHub picture, or their initial while it loads or when it cannot.
struct PullRequestReviewerAvatar: View {
    let reviewer: Reviewer
    let side: CGFloat

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(Theme.projectTint(for: reviewer.login).colour)
                Text(reviewer.login.prefix(1).uppercased())
                    .font(.system(size: side * 0.5, weight: .bold))
                    .foregroundStyle(Theme.projectTint(for: reviewer.login).ink)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .task(id: reviewer.avatarURL) { image = await AvatarCache.image(reviewer.avatarURL) }
    }
}

@MainActor
private enum AvatarCache {
    private static var images: [String: NSImage] = [:]

    static func image(_ urlString: String?) async -> NSImage? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        if let cached = images[urlString] { return cached }
        guard let fetched = try? await URLSession.shared.data(from: url), let image = NSImage(data: fetched.0) else {
            return nil
        }
        images[urlString] = image
        return image
    }
}

// A review thread carries the hunk it hangs off as plain diff text. The rows need no
// line numbers, so a first-character read is all the parsing the diff view needs here.
enum PullRequestReviewHunk {
    static func lines(_ hunk: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        for raw in hunk.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(raw)
            let kind: DiffLine.Kind = if text.hasPrefix("@@") { .hunk }
                else if text.hasPrefix("+") { .addition }
                else if text.hasPrefix("-") { .deletion }
                else { .context }
            lines.append(DiffLine(id: lines.count, kind: kind, text: text))
        }
        return lines
    }

    static func render(_ hunk: String, path: String) async -> NSAttributedString? {
        let lines = lines(hunk)
        guard !lines.isEmpty else { return nil }
        return await DiffText.build(lines, language: CodeLanguage(path: path))
    }
}

extension PullRequestReview.Kind {
    var title: String {
        switch self {
        case .approved: "APPROVED"
        case .changesRequested: "CHANGES REQUESTED"
        case .commented: "COMMENTED"
        }
    }

    var ink: Color {
        switch self {
        case .approved: Theme.dotOnText
        case .changesRequested: Theme.deletion
        case .commented: Theme.attentionText
        }
    }
}

extension PullRequestReviewProposal.Action {
    var title: String {
        switch self {
        case .fix: "FIX"
        case .reply: "REPLY"
        case .pushback: "PUSHBACK"
        }
    }

    var ink: Color {
        switch self {
        case .fix: Theme.dotOnText
        case .reply: Theme.accent
        case .pushback: Theme.warningText
        }
    }
}
