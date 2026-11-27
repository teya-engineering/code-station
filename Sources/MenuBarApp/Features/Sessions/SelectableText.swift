import SwiftUI

// How a block works out how wide it is.
enum TextWidth {
    // Fills the width it is offered and wraps to it. What page prose wants.
    case fills
    // Wraps to the width it is offered but claims only the width it used, so a short
    // line leaves the rest of the row alone. What a bubble drawn around text wants.
    case hugs
    // Keeps the line breaks it came with and lets the longest of them set the width,
    // running off the side into a scroller rather than folding. What code wants.
    case fixed
}

// Which typeface family a run asks for. Its own type rather than SwiftUI's Font.Design,
// because a style has to travel inside an attributed string, which stays a value.
enum TranscriptFontDesign: String, Codable, Hashable, Sendable {
    case standard, serif, monospaced
}

// One place that turns type choices into a font, so a block inside a shared text view and
// a whole text view of its own resolve theirs the same way.
func transcriptNSFont(size: CGFloat, weight: NSFont.Weight,
                      design: TranscriptFontDesign, italic: Bool) -> NSFont {
    let base: NSFont = switch design {
    case .serif:
        NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            .withDesign(.serif)
            .flatMap { NSFont(descriptor: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    case .monospaced:
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    case .standard:
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    guard italic else { return base }
    let slanted = base.fontDescriptor.withSymbolicTraits(.italic)
    return NSFont(descriptor: slanted, size: size) ?? base
}

// How one line of a shared text view is set. Several blocks draw in one view, so each
// block's type and the gap above it travel with the text rather than with a view.
struct TranscriptBlockStyle: Codable, Hashable, Sendable {
    // Before the text scale, so one setting still moves the whole page.
    var size: CGFloat
    var weight: CGFloat
    var design: TranscriptFontDesign
    // The air above this line. A paragraph style belongs to a whole paragraph, so only
    // the opening line of a block carries it: the newlines inside one are line breaks
    // rather than new blocks, and must not be pushed down as well.
    var spacingBefore: CGFloat
    // Set on a heading, so a copy can still tell it from the paragraphs beside it.
    var heading: Int? = nil
}

enum TranscriptBlockStyleAttribute: CodableAttributedStringKey {
    typealias Value = TranscriptBlockStyle
    static let name = "transcriptBlockStyle"
}

// Marks the newline standing between two blocks that share a text view. On screen it is
// one line break and a gap; copied, it has to become the blank line it looks like.
enum TranscriptBlockBreakAttribute: CodableAttributedStringKey {
    typealias Value = Bool
    static let name = "transcriptBlockBreak"
}

extension NSAttributedString.Key {
    static let transcriptBlockBreak = NSAttributedString.Key("transcriptBlockBreak")
    // A line's heading level and a run's Markdown emphasis, kept so a copy can write
    // them back out as HTML.
    static let transcriptHeading = NSAttributedString.Key("transcriptHeading")
    static let transcriptInline = NSAttributedString.Key("transcriptInline")
}

// Every run of text in the transcript, prose and code alike, is drawn by a text view
// rather than by SwiftUI's Text. A Text owns a selection that stops at its own edge, so
// a page built from one per block could only ever be selected a block at a time. A text
// view reports the character under a point and takes a selected range back, which is
// what lets TranscriptSelection run one selection across the whole page.
struct SelectableText: View {
    @Environment(\.openURL) private var openURL
    @Environment(TooltipPresenter.self) private var tooltipPresenter
    @Environment(\.textScale) private var textScale
    @Environment(\.transcriptSelection) private var transcriptSelection
    @Environment(\.transcriptFind) private var transcriptFind
    @Environment(\.transcriptMessageID) private var transcriptMessageID
    @Environment(\.transcriptReply) private var transcriptReply
    @Environment(\.explorerRoots) private var explorerRoots
    @Environment(\.previewsLocalServers) private var previewsLocalServers
    @Environment(\.fileReferenceAction) private var fileReferenceAction
    @Environment(\.linkHovered) private var linkHovered
    // Optional because a text view can sit in a sheet that has no menu layer of its own.
    @Environment(MenuPresenter.self) private var menus: MenuPresenter?
    @Environment(\.showExternalNote) private var showExternalNote

    private let attributed: AttributedString
    private let size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design
    private let secondary: Bool
    private let lineSpacing: CGFloat
    private let alignment: TextAlignment
    private let width: TextWidth
    private let italic: Bool
    private let role: TranscriptTextRole
    // Off for a sent prompt, since SentPrompt already decides its links.
    private let linksLocalServers: Bool

    @State private var tooltipOwner = UUID()
    @State private var tooltipURL: URL?
    @State private var pendingTooltip: Task<Void, Never>?

    init(_ text: String,
         size: CGFloat,
         weight: Font.Weight = .regular,
         design: Font.Design = .default,
         secondary: Bool = false,
         lineSpacing: CGFloat = 0,
         alignment: TextAlignment = .leading,
         role: TranscriptTextRole = .block) {
        self.init(attributed: .inlineMarkdown(text),
                  size: size,
                  weight: weight,
                  design: design,
                  secondary: secondary,
                  lineSpacing: lineSpacing,
                  alignment: alignment,
                  width: .fills,
                  italic: false,
                  role: role,
                  linksLocalServers: true)
    }

    // Code arrives already coloured by token, and its own line breaks are the only ones
    // it should have, so it is handed over whole rather than read as markdown.
    init(code: AttributedString, size: CGFloat) {
        self.init(attributed: code,
                  size: size,
                  weight: .regular,
                  design: .monospaced,
                  secondary: false,
                  lineSpacing: 0,
                  alignment: .leading,
                  width: .fixed,
                  italic: false,
                  role: .code,
                  linksLocalServers: false)
    }

    // Several blocks drawn as one text view. Each block's type and the gap above it
    // travel in the string, so the size and weight here are only what a run that carries
    // none of its own falls back to.
    init(prose: AttributedString, lineSpacing: CGFloat = 0, width: TextWidth = .fills,
         linksLocalServers: Bool = true, role: TranscriptTextRole = .block) {
        self.init(attributed: prose,
                  size: 13.5,
                  weight: .regular,
                  design: .default,
                  secondary: false,
                  lineSpacing: lineSpacing,
                  alignment: .leading,
                  width: width,
                  italic: false,
                  role: role,
                  linksLocalServers: linksLocalServers)
    }

    // Text that is shown exactly as it arrived. A model's reasoning is not markdown, so
    // the asterisks and backticks it happens to contain are characters, not formatting.
    init(plain text: String,
         size: CGFloat,
         design: Font.Design = .default,
         secondary: Bool = false,
         italic: Bool = false,
         lineSpacing: CGFloat = 0,
         width: TextWidth = .fills) {
        self.init(attributed: AttributedString(text),
                  size: size,
                  weight: .regular,
                  design: design,
                  secondary: secondary,
                  lineSpacing: lineSpacing,
                  alignment: .leading,
                  width: width,
                  italic: italic,
                  role: .plain(monospaced: design == .monospaced),
                  linksLocalServers: false)
    }

    private init(attributed: AttributedString,
                 size: CGFloat,
                 weight: Font.Weight,
                 design: Font.Design,
                 secondary: Bool,
                 lineSpacing: CGFloat,
                 alignment: TextAlignment,
                 width: TextWidth,
                 italic: Bool,
                 role: TranscriptTextRole,
                 linksLocalServers: Bool) {
        self.attributed = attributed
        self.size = size
        self.weight = weight
        self.design = design
        self.secondary = secondary
        self.lineSpacing = lineSpacing
        self.alignment = alignment
        self.width = width
        self.italic = italic
        self.role = role
        self.linksLocalServers = linksLocalServers
    }

    var body: some View {
        let font = resolvedNSFont
        let firstBaseline = font.ascender.rounded()
        LinkAwareText(
            attributed: attributed,
            linksLocalServers: linksLocalServers && previewsLocalServers,
            font: font,
            textScale: textScale,
            color: secondary ? .secondaryLabelColor : .labelColor,
            lineSpacing: lineSpacing,
            alignment: alignment,
            width: width,
            role: role,
            selection: transcriptSelection,
            find: transcriptFind,
            messageID: transcriptMessageID,
            openLink: openLink,
            linkHoverChanged: linkHoverChanged,
            showMenu: menus.map { menus in { entries, point in menus.show(entries, at: point) } },
            reply: transcriptReply?.action,
            note: showExternalNote.show)
            // NSViewRepresentable does not pass NSTextView's baseline to SwiftUI.
            // The font metric keeps this text on the baseline of whatever it sits
            // beside, such as the marker on a list row.
            .alignmentGuide(.firstTextBaseline) { _ in
                firstBaseline
            }
            .onDisappear(perform: hideLinkTooltip)
    }

    private func linkHoverChanged(_ hovered: TranscriptLink.Hovered?) {
        pendingTooltip?.cancel()
        linkHovered?(hovered?.url)
        guard let hovered, fileReferenceAction?.accepts(hovered.url) == true || hovered.url.isFileURL
                || (previewsLocalServers && TranscriptLink.isLocalServer(hovered.url)) else {
            tooltipPresenter.hide(owner: tooltipOwner)
            return
        }

        if tooltipURL != hovered.url {
            tooltipPresenter.hide(owner: tooltipOwner)
            tooltipOwner = UUID()
            tooltipURL = hovered.url
        }
        guard !tooltipPresenter.sourceEntered(owner: tooltipOwner) else { return }

        let owner = tooltipOwner
        pendingTooltip = Task {
            try? await Task.sleep(for: TooltipPresenter.hoverDelay)
            guard !Task.isCancelled else { return }
            tooltipPresenter.show(
                Tooltip(title: linkToolTip(for: hovered.url)) { openLink(hovered.url, hovered.frame) },
                from: hovered.frame,
                owner: owner)
        }
    }

    private func linkToolTip(for url: URL) -> String {
        if fileReferenceAction?.accepts(url) == true { return TranscriptLink.fileActionsToolTip }
        guard url.isFileURL else { return TranscriptLink.previewToolTip }
        return TranscriptLink.explorerTarget(for: url, roots: explorerRoots) == nil
            ? TranscriptLink.finderToolTip
            : TranscriptLink.explorerToolTip
    }

    private func hideLinkTooltip() {
        pendingTooltip?.cancel()
        tooltipPresenter.hide(owner: tooltipOwner)
    }

    private func openLink(_ url: URL, _ frame: CGRect?) {
        pendingTooltip?.cancel()
        tooltipPresenter.hideAll()
        if let fileReferenceAction, fileReferenceAction.accepts(url) {
            fileReferenceAction.perform(url, frame)
        } else {
            openURL(url)
        }
    }

    private var resolvedNSFont: NSFont {
        let resolved: TranscriptFontDesign = switch design {
        case .serif: .serif
        case .monospaced: .monospaced
        default: .standard
        }
        return transcriptNSFont(size: size * textScale,
                                weight: SelectableText.nsWeight(from: weight),
                                design: resolved,
                                italic: italic)
    }

    private static func nsWeight(from weight: Font.Weight) -> NSFont.Weight {
        if weight == .ultraLight { return .ultraLight }
        if weight == .thin { return .thin }
        if weight == .light { return .light }
        if weight == .medium { return .medium }
        if weight == .semibold { return .semibold }
        if weight == .bold { return .bold }
        if weight == .heavy { return .heavy }
        if weight == .black { return .black }
        return .regular
    }
}

// AppKit ignores selectedTextAttributes in a text view that is not first responder and
// fills its selection with the system's grey instead. A transcript selection spans
// many blocks and LinkTextView paints it in one colour, so while that is the case the
// AppKit fill is dropped. A background the text itself asks for is still drawn.
final class TranscriptLayoutManager: NSLayoutManager {
    var dropsSelectionFill = false

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard draws(color, over: charRange) else { return }
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }

    func draws(_ color: NSColor, over characters: NSRange) -> Bool {
        guard dropsSelectionFill else { return true }
        // AppKit only lays out and draws text on the main thread, but NSLayoutManager is
        // not marked as main-actor, so the compiler cannot see that on its own.
        let textView = firstTextView
        guard let selected = MainActor.assumeIsolated({ textView?.selectedRange() }), selected.length > 0,
              characters.location >= selected.location,
              NSMaxRange(characters) <= NSMaxRange(selected) else { return true }
        return ownBackground(at: characters.location) == color
    }

    private func ownBackground(at index: Int) -> NSColor? {
        guard let textStorage, index < textStorage.length else { return nil }
        if let temporary = temporaryAttribute(.backgroundColor, atCharacterIndex: index,
                                              effectiveRange: nil) as? NSColor {
            return temporary
        }
        return textStorage.attribute(.backgroundColor, at: index, effectiveRange: nil) as? NSColor
    }
}

// NSTextView keeps the pointing-hand cursor over link ranges and the I-beam elsewhere,
// which SwiftUI's Text cannot do, since it exposes no per-run hover geometry.
private final class LinkTextView: NSTextView {
    var openLink: ((URL, CGRect?) -> Void)?
    var linkHoverChanged: ((TranscriptLink.Hovered?) -> Void)?
    var showMenu: (([MenuEntry], CGPoint) -> Void)?
    var reply: ((String) -> Void)?
    // A copy changes nothing on screen, so this is how the click shows.
    var note: ((_ text: String, _ icon: String) -> Void)?
    // Absent for a text view outside a transcript, such as one in a file preview,
    // which selects on its own exactly as AppKit intends, highlight included.
    var selection: TranscriptSelection? {
        didSet {
            guard (selection == nil) != (oldValue == nil) else { return }
            (layoutManager as? TranscriptLayoutManager)?.dropsSelectionFill = selection != nil
            if selection == nil {
                selectedTextAttributes = nativeSelectedTextAttributes
            } else {
                // Selected text keeps its own colours, the same in every block, since
                // the focused block would otherwise take the system's selected text colour.
                nativeSelectedTextAttributes = selectedTextAttributes
                selectedTextAttributes = [:]
            }
        }
    }
    private var nativeSelectedTextAttributes: [NSAttributedString.Key: Any] = [:]
    weak var find: TranscriptFind?
    var reflows = true

    private var linkTrackingArea: NSTrackingArea?
    private var hoveredLink: TranscriptLink.Hovered?
    private var pressedLink: URL?
    private var linkMouseDown: NSEvent?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), showMenu != nil {
            openMenu(for: event)
            return
        }
        pressedLink = nil
        linkMouseDown = nil
        let point = convert(event.locationInWindow, from: nil)

        // A plain press on a link might still turn into a drag, so nothing is decided
        // until the pointer either moves or comes back up.
        if event.clickCount == 1,
           event.modifierFlags.intersection([.shift, .control, .option]).isEmpty,
           let link = TranscriptLink.hoveredLink(in: self, at: point) {
            pressedLink = link.url
            linkMouseDown = event
            return
        }

        guard let selection else {
            super.mouseDown(with: event)
            return
        }

        // A double or triple click takes a word or a line, which AppKit already does
        // inside one block and which no sweep across blocks would improve.
        guard event.clickCount == 1 else {
            selection.clear()
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.shift) {
            selection.extend(toWindowPoint: event.locationInWindow)
        } else {
            selection.begin(in: self, at: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressedLink else {
            // A selection drag has already consumed its own press, so only a text view
            // left to AppKit still needs the release passed on.
            if selection == nil { super.mouseUp(with: event) }
            return
        }
        self.pressedLink = nil
        linkMouseDown = nil
        let point = convert(event.locationInWindow, from: nil)
        guard let link = TranscriptLink.hoveredLink(in: self, at: point), link.url == pressedLink else { return }
        window?.makeFirstResponder(self)
        openLink?(pressedLink, windowFrame(for: link.frame))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let selection else {
            linkDragForOneTextView(event)
            return
        }

        // The press landed on a link and has now moved far enough to be a drag, so the
        // selection starts from where the press was rather than from here.
        if let down = linkMouseDown {
            guard dragBegan(from: down, to: event) else { return }
            pressedLink = nil
            linkMouseDown = nil
            window?.makeFirstResponder(self)
            selection.begin(in: self, at: convert(down.locationInWindow, from: nil))
        }

        selection.extend(toWindowPoint: event.locationInWindow)
        scrollTranscript(with: event)
    }

    // A drag that runs past the edge of the transcript keeps going, so a selection can
    // reach a message that was not on screen when it started. It has to be the
    // transcript that moves: a code block sits in a scroller of its own, and letting
    // the nearest one win would shunt that block sideways instead.
    private func scrollTranscript(with event: NSEvent) {
        var outermost: NSScrollView?
        var view: NSView? = self
        while let current = view {
            if let scrollView = current as? NSScrollView { outermost = scrollView }
            view = current.superview
        }
        outermost?.documentView?.autoscroll(with: event)
    }

    // A text view that selects only within itself hands the drag straight to AppKit
    // once the press is no longer a link click.
    private func linkDragForOneTextView(_ event: NSEvent) {
        guard let down = linkMouseDown else {
            super.mouseDragged(with: event)
            return
        }
        guard dragBegan(from: down, to: event) else { return }
        pressedLink = nil
        linkMouseDown = nil
        // Replay the press and drag together so NSTextView can select from the
        // original character without treating the drag as a link click.
        NSApp.postEvent(event, atStart: true)
        super.mouseDown(with: down)
    }

    private func dragBegan(from down: NSEvent, to event: NSEvent) -> Bool {
        hypot(event.locationInWindow.x - down.locationInWindow.x,
              event.locationInWindow.y - down.locationInWindow.y) >= 4
    }

    // AppKit asks a text view for a menu on right-click and would put up its own, which
    // is a piece of another program in the middle of the page. The app's own menu takes
    // its place. A row with a menu of its own, such as a sent prompt, lays a catcher
    // over this view and still gets the click first.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        guard showMenu != nil else { return super.rightMouseDown(with: event) }
        openMenu(for: event)
    }

    // The click leaves the selection alone, so text picked out before the menu opened
    // is still what Copy takes.
    private func openMenu(for event: NSEvent) {
        guard let showMenu, let content = window?.contentView else { return }
        var entries: [MenuEntry] = []
        let point = convert(event.locationInWindow, from: nil)
        if let link = TranscriptLink.hoveredLink(in: self, at: point) {
            let isFile = link.url.isFileURL
            let address = isFile ? link.url.path : link.url.absoluteString
            entries.append(.item(isFile ? "Copy path" : "Copy link", icon: "link") { [note] in
                Pasteboard.copy(address)
                note?(isFile ? "Copied the path" : "Copied the link", "checkmark")
            })
        }
        let copied = selection?.selectedContent
        if let text = copied?.text ?? ownSelectedText {
            entries.append(.item("Copy", icon: "doc.on.doc") { [note] in
                if let copied {
                    Pasteboard.copy(copied.plain, html: copied.html)
                } else {
                    Pasteboard.copy(text)
                }
                note?("Copied", "checkmark")
            })
            if let reply {
                entries.append(.item("Reply", icon: "arrowshape.turn.up.left") { reply(text) })
            }
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.item("Select all", icon: "text.cursor") { [weak self] in
            self?.window?.makeFirstResponder(self)
            self?.selectAll(nil)
        })
        showMenu(entries, FrameAnchor.fromTop(content.convert(event.locationInWindow, from: nil),
                                              in: content))
    }

    // Only used when the view is not part of a transcript selection.
    private var ownSelectedText: String? {
        guard selection == nil else { return nil }
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage,
              NSMaxRange(range) <= storage.length else { return nil }
        return storage.attributedSubstring(from: range).string
    }

    // MARK: - Selection

    override func copy(_ sender: Any?) {
        guard let copied = selection?.selectedContent else {
            super.copy(sender)
            return
        }
        Pasteboard.copy(copied.plain, html: copied.html)
    }

    override func selectAll(_ sender: Any?) {
        guard let selection else {
            super.selectAll(sender)
            return
        }
        selection.selectAll()
    }

    // Only one block of a transcript can be first responder, so the selection is painted
    // here, in one colour for every block it reaches (see TranscriptLayoutManager).
    override func draw(_ dirtyRect: NSRect) {
        drawFindHighlights()
        drawSelectionHighlight()
        super.draw(dirtyRect)
    }

    private func drawFindHighlights() {
        guard let find else { return }
        let highlights = find.highlights(in: self)
        for range in highlights.all {
            fill(range, with: range == highlights.current
                    ? CodeEditorStyle.currentMatch : CodeEditorStyle.match)
        }
    }

    private func drawSelectionHighlight() {
        let characters = selectedRange()
        guard selection != nil, characters.length > 0 else { return }
        fill(characters, with: Theme.accentNSColor.withAlphaComponent(0.28))
    }

    private func fill(_ characters: NSRange, with color: NSColor) {
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        color.setFill()
        let glyphs = layoutManager.glyphRange(forCharacterRange: characters,
                                              actualCharacterRange: nil)
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                              withinSelectedGlyphRange: glyphs,
                                              in: textContainer) { box, _ in
            box.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
    }

    // The text container reflows when its width changes, so SwiftUI must measure its
    // new height before laying out the next block.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = frame.width != newSize.width
        super.setFrameSize(newSize)
        // Only text that reflows has a new height to report when its width changes.
        if widthChanged, reflows { invalidateIntrinsicContentSize() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTrackingArea { removeTrackingArea(linkTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(trackingArea)
        linkTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHoveredLink(with: event)
    }

    // The tracking area reports moves even where a SwiftUI control, such as the copy
    // pill, sits on top of the text. Over that control the text gives up its I-beam
    // and link hover, so the pointer reads as a click target and not as text.
    override func mouseMoved(with event: NSEvent) {
        if isCovered(at: event) {
            NSCursor.arrow.set()
            setHoveredLink(nil)
            return
        }
        super.mouseMoved(with: event)
        updateHoveredLink(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isCovered(at: event) {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    private func isCovered(at event: NSEvent) -> Bool {
        guard let frameView = window?.contentView?.superview,
              let hit = frameView.hitTest(event.locationInWindow) else { return false }
        return !hit.isDescendant(of: self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredLink(nil)
    }

    private func updateHoveredLink(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hovered = TranscriptLink.hoveredLink(in: self, at: point).flatMap { link in
            windowFrame(for: link.frame).map { TranscriptLink.Hovered(url: link.url, frame: $0) }
        }
        setHoveredLink(hovered)
    }

    private func setHoveredLink(_ hovered: TranscriptLink.Hovered?) {
        guard hovered != hoveredLink else { return }
        hoveredLink = hovered
        ScrollActivity.shared.whenRested { [weak self] in
            guard let self, self.hoveredLink == hovered else { return }
            self.linkHoverChanged?(hovered)
        }
    }

    private func windowFrame(for rect: CGRect) -> CGRect? {
        guard let content = window?.contentView else { return nil }
        let converted = convert(rect, to: content)
        guard !content.isFlipped else { return converted }
        return CGRect(x: converted.minX,
                      y: content.bounds.height - converted.maxY,
                      width: converted.width,
                      height: converted.height)
    }
}

private struct LinkAwareText: NSViewRepresentable {
    let attributed: AttributedString
    let linksLocalServers: Bool
    let font: NSFont
    // Only for the block styles inside the string: the fallback font arrives scaled.
    let textScale: CGFloat
    let color: NSColor
    let lineSpacing: CGFloat
    let alignment: TextAlignment
    let width: TextWidth
    let role: TranscriptTextRole
    let selection: TranscriptSelection?
    let find: TranscriptFind?
    let messageID: UUID?
    let openLink: (URL, CGRect?) -> Void
    let linkHoverChanged: (TranscriptLink.Hovered?) -> Void
    let showMenu: (([MenuEntry], CGPoint) -> Void)?
    let reply: ((String) -> Void)?
    let note: ((_ text: String, _ icon: String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(openLink: openLink) }

    func makeNSView(context: Context) -> NSTextView {
        let view = LinkTextView(usingTextLayoutManager: false)
        view.textContainer?.replaceLayoutManager(TranscriptLayoutManager())
        view.isEditable = false
        view.isSelectable = true
        // Per-link hints belong to TooltipPresenter, including their Finder action.
        view.displaysLinkToolTips = false
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = width != .fixed
        view.textContainer?.heightTracksTextView = false
        // SwiftUI owns the frame. A text view that sized itself would grow or shrink
        // every time it is measured at a width it is never placed at, and then its frame
        // no longer matches where SwiftUI thinks it is, so clicks miss it.
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.reflows = width != .fixed
        if width == .fixed {
            view.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        }
        view.delegate = context.coordinator
        view.linkTextAttributes = [
            .foregroundColor: Theme.accentNSColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        view.openLink = openLink
        view.linkHoverChanged = linkHoverChanged
        view.showMenu = showMenu
        view.reply = reply
        view.note = note
        view.selection = selection
        selection?.register(view, role: role)
        view.find = find
        if let messageID { find?.register(view, messageID: messageID) }
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.openLink = openLink
        (view as? LinkTextView)?.openLink = openLink
        (view as? LinkTextView)?.linkHoverChanged = linkHoverChanged
        (view as? LinkTextView)?.showMenu = showMenu
        (view as? LinkTextView)?.reply = reply
        (view as? LinkTextView)?.note = note
        (view as? LinkTextView)?.selection = selection
        // Unconditional: this is how a block joins the selection that runs across the
        // page, and a view that stopped re-registering would drop out of it.
        selection?.register(view, role: role)
        (view as? LinkTextView)?.find = find
        if let messageID { find?.register(view, messageID: messageID) }

        // Handing the view a new string throws away the layout it has already done and
        // the range it is holding, and every block in the transcript is asked to update
        // whenever anything in the pane changes. Only the blocks whose text really moved
        // pay for it.
        let content = Coordinator.Content(attributed: attributed,
                                          linksLocalServers: linksLocalServers,
                                          font: font,
                                          textScale: textScale,
                                          color: color,
                                          lineSpacing: lineSpacing,
                                          alignment: alignment)
        guard context.coordinator.applied != content else { return }
        context.coordinator.applied = content
        view.textStorage?.setAttributedString(makeNSAttributedString())
        view.invalidateIntrinsicContentSize()
    }

    static func dismantleNSView(_ view: NSTextView, coordinator: Coordinator) {
        (view as? LinkTextView)?.selection?.unregister(view)
        (view as? LinkTextView)?.find?.unregister(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layoutManager = view.layoutManager else { return nil }

        guard width != .fixed else {
            // The width on offer says nothing here: the longest line decides how wide
            // the block is, and its scroller deals with the overflow.
            container.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                             height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            return CGSize(width: ceil(used.width), height: ceil(used.height))
        }

        guard let offered = proposal.width, offered.isFinite, offered > 0 else { return nil }
        container.containerSize = CGSize(width: offered, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = ceil(layoutManager.usedRect(for: container).height)
        guard width == .hugs else { return CGSize(width: offered, height: height) }

        // The used rect reports the width of the container rather than of the words in
        // it, so the glyphs are measured to find how much room the text really takes.
        // Claiming that re-wraps at exactly the longest line, which is the same layout,
        // so the size settles rather than shrinking away over repeated passes.
        let glyphs = layoutManager.glyphRange(for: container)
        let laidOut = ceil(layoutManager.boundingRect(forGlyphRange: glyphs, in: container).width)
        return CGSize(width: laidOut > 0 ? min(offered, laidOut) : offered, height: height)
    }

    private func makeNSAttributedString() -> NSAttributedString {
        let attributed = linksLocalServers ? self.attributed.linkingLocalServers() : self.attributed
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = switch alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }

        // A run of blocks sharing this view repeats the same handful of styles, so each
        // one is built once rather than per run of text.
        var paragraphs: [TranscriptBlockStyle: NSParagraphStyle] = [:]
        func paragraphStyle(for block: TranscriptBlockStyle) -> NSParagraphStyle {
            if let known = paragraphs[block] { return known }
            let made = NSMutableParagraphStyle()
            made.setParagraphStyle(paragraph)
            made.paragraphSpacingBefore = block.spacingBefore
            paragraphs[block] = made
            return made
        }

        let result = NSMutableAttributedString()
        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            // A block that brought its own type sets the run; anything else is the one
            // font this whole view was made with.
            let block = run[TranscriptBlockStyleAttribute.self]
            let blockFont = block.map {
                transcriptNSFont(size: $0.size * textScale,
                                 weight: NSFont.Weight(rawValue: $0.weight),
                                 design: $0.design,
                                 italic: false)
            } ?? font
            var runFont = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: blockFont.pointSize, weight: .regular)
                : blockFont
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty {
                let descriptor = runFont.fontDescriptor.withSymbolicTraits(traits)
                runFont = NSFont(descriptor: descriptor, size: runFont.pointSize) ?? runFont
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .paragraphStyle: block.map(paragraphStyle(for:)) ?? paragraph,
            ]
            if run[TranscriptBlockBreakAttribute.self] == true {
                attrs[.transcriptBlockBreak] = true
            }
            if let heading = block?.heading { attrs[.transcriptHeading] = heading }
            if !intent.isEmpty { attrs[.transcriptInline] = intent.rawValue }
            if let link = run.link {
                attrs[.link] = link
            } else {
                // Highlighted code arrives with a colour per token. Anything that does
                // not ask for one reads as body text.
                attrs[.foregroundColor] = run.appKit.foregroundColor
                    ?? run.swiftUI.foregroundColor.map(NSColor.init)
                    ?? color
            }
            result.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return result
    }

    // A click inside an AppKit view never reaches SwiftUI's openURL environment, so the
    // link is handed back to it by hand. That is what keeps a "path:line" link opening
    // the enclosing folder in Finder rather than whatever app owns the file type.
    final class Coordinator: NSObject, NSTextViewDelegate {
        // Everything makeNSAttributedString reads. The other stored properties reach the
        // string through the font and the colour, which are resolved before they arrive.
        struct Content: Equatable {
            let attributed: AttributedString
            let linksLocalServers: Bool
            let font: NSFont
            let textScale: CGFloat
            let color: NSColor
            let lineSpacing: CGFloat
            let alignment: TextAlignment
        }

        var openLink: (URL, CGRect?) -> Void
        // What the view's storage was last built from. Nil until the first update, so a
        // freshly made view always gets its text.
        var applied: Content?

        init(openLink: @escaping (URL, CGRect?) -> Void) {
            self.openLink = openLink
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            guard let url else { return false }
            var frame: CGRect?
            if let layout = textView.layoutManager, let container = textView.textContainer,
               let content = textView.window?.contentView {
                let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                    .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
                frame = FrameAnchor.fromTop(textView.convert(rect, to: content), in: content)
            }
            openLink(url, frame)
            return true
        }
    }
}
