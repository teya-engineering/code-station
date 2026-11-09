import AppKit
import SwiftUI

@MainActor @Observable
final class NoteEditorController {
    @ObservationIgnored weak var view: NoteTextView?
    var bold = false
    var italic = false
    var block = NoteDocument.Block.text
    var indent = 0
    var checked = false

    func focus() { if let view { view.window?.makeFirstResponder(view) } }

    func readSelection() {
        guard let view else { return }
        let range = view.selectedRange()
        let attributes = range.length > 0 && range.location < (view.textStorage?.length ?? 0)
            ? view.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? [:]
            : view.typingAttributes
        let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        bold = traits.contains(.bold)
        italic = traits.contains(.italic)
        block = (attributes[.noteBlock] as? String).flatMap(NoteDocument.Block.init(rawValue:)) ?? .text
        indent = attributes[.noteIndent] as? Int ?? 0
        let paragraph = (view.string as NSString).paragraphRange(for: range)
        checked = (view.string as NSString).substring(with: paragraph).hasPrefix("☑")
    }

    func toggleTrait(_ trait: NSFontTraitMask) {
        guard let view, view.isEditable else { return }
        focus()
        let range = view.selectedRange()
        let removing = trait == .boldFontMask ? bold : italic
        func converted(_ attributes: [NSAttributedString.Key: Any]) -> NSFont {
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            return removing ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                : NSFontManager.shared.convert(font, toHaveTrait: trait)
        }
        if range.length == 0 {
            view.typingAttributes[.font] = converted(view.typingAttributes)
        } else if let storage = view.textStorage {
            let selection = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
            selection.enumerateAttributes(in: NSRange(location: 0, length: selection.length)) { attributes, range, _ in
                selection.addAttribute(.font, value: converted(attributes), range: range)
            }
            view.insertText(selection, replacementRange: range)
            view.setSelectedRange(range)
        }
        readSelection()
    }

    func setBlock(_ block: NoteDocument.Block) {
        guard let view, view.isEditable, let storage = view.textStorage else { return }
        focus()
        let selected = view.selectedRange()
        let range = (view.string as NSString).paragraphRange(for: selected)
        if range.length == 0 {
            view.typingAttributes = NoteDocument.attributes(block: block)
            let marker = Self.marker(for: block)
            if !marker.isEmpty { view.insertText(NSAttributedString(string: marker, attributes: view.typingAttributes), replacementRange: range) }
            readSelection()
            return
        }
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        var offset = 0
        var number = 1
        while offset < replacement.length {
            let line = (replacement.string as NSString).paragraphRange(for: NSRange(location: offset, length: 0))
            let old = (replacement.attribute(.noteBlock, at: offset, effectiveRange: nil) as? String)
                .flatMap(NoteDocument.Block.init(rawValue:)) ?? .text
            // A table keeps its own shape. Restyling it would turn its source into prose.
            if old == .table { offset = NSMaxRange(line); continue }
            let value = (replacement.string as NSString).substring(with: line)
            let markerLength = NoteDocument.markerLength(value, block: old)
            let text = NSMutableAttributedString(attributedString: replacement.attributedSubstring(from: line))
            if markerLength > 0 { text.deleteCharacters(in: NSRange(location: 0, length: markerLength)) }
            let normalized = NoteDocument(text)
            let indent = NoteDocument.Block.lists.contains(block) ? normalized.runs.first?.indent ?? 0 : 0
            text.setAttributedString(NoteDocument(runs: normalized.runs.map {
                var run = $0; run.block = block; run.indent = indent; return run
            }).attributed)
            let marker = Self.marker(for: block, number: number)
            text.insert(NSAttributedString(string: marker, attributes: NoteDocument.attributes(block: block, indent: indent)), at: 0)
            replacement.replaceCharacters(in: line, with: text)
            offset += text.length
            number += 1
        }
        view.insertText(replacement, replacementRange: range)
        if selected.length > 0 { view.setSelectedRange(NSRange(location: range.location, length: replacement.length)) }
        view.typingAttributes = NoteDocument.attributes(block: block)
        readSelection()
    }

    static func marker(for block: NoteDocument.Block, number: Int = 1) -> String {
        switch block {
        case .bullet: "• "
        case .numbered: "\(number). "
        case .checklist: "☐ "
        default: ""
        }
    }

    // A list item can sit at most one level below the item before it, so Markdown can
    // still nest it under a parent.
    func changeIndent(by delta: Int) {
        guard let view, view.isEditable, let storage = view.textStorage, storage.length > 0 else { return }
        let string = view.string as NSString
        let range = string.paragraphRange(for: view.selectedRange())
        guard range.location < storage.length else { return }
        func listIndent(at location: Int) -> Int? {
            guard location >= 0, location < storage.length,
                  let block = (storage.attribute(.noteBlock, at: location, effectiveRange: nil) as? String)
                    .flatMap(NoteDocument.Block.init(rawValue:)),
                  NoteDocument.Block.lists.contains(block) else { return nil }
            return storage.attribute(.noteIndent, at: location, effectiveRange: nil) as? Int ?? 0
        }
        let previous = range.location > 0 ? string.paragraphRange(for: NSRange(location: range.location - 1, length: 0)).location : -1
        var limit = (listIndent(at: previous) ?? -1) + 1
        let replacement = NSMutableAttributedString()
        var offset = range.location
        while offset < NSMaxRange(range) {
            let line = string.paragraphRange(for: NSRange(location: offset, length: 0))
            let current = listIndent(at: line.location) ?? 0
            let indent = max(0, min(current + delta, limit))
            let document = NoteDocument(storage.attributedSubstring(from: line))
            replacement.append(NoteDocument(runs: document.runs.map {
                var run = $0
                if NoteDocument.Block.lists.contains(run.block) { run.indent = indent }
                return run
            }).attributed)
            limit = indent + 1
            offset = NSMaxRange(line)
        }
        let selected = view.selectedRange()
        view.insertText(replacement, replacementRange: range)
        view.setSelectedRange(selected)
        readSelection()
    }

    func toggleChecklist() {
        guard let view, view.isEditable else { return }
        view.toggleChecklist(at: view.selectedRange().location)
        readSelection()
    }

    func insertLink(_ url: String) {
        guard let view, view.isEditable, let url = NoteDocument.safeLink(url) else { return }
        focus()
        let range = view.selectedRange()
        let text = range.length > 0
            ? NSMutableAttributedString(attributedString: view.attributedSubstring(forProposedRange: range, actualRange: nil) ?? NSAttributedString())
            : NSMutableAttributedString(string: url, attributes: view.typingAttributes)
        text.addAttribute(.link, value: url, range: NSRange(location: 0, length: text.length))
        view.insertText(text, replacementRange: range)
        view.typingAttributes.removeValue(forKey: .link)
    }
}

struct NoteTextEditor: NSViewRepresentable {
    let document: NoteDocument
    let controller: NoteEditorController
    let editable: Bool
    let onChange: (NoteDocument) -> Void
    let onFiles: ([URL]) -> Void
    let onImage: (Data) -> Void
    let onLink: (URL) -> Void
    // Opens a table's source, given the Markdown it was read from. Without it a table
    // is drawn but offers nothing on a double-click.
    var onTable: ((String) -> Void)?
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NoteTextView {
        let view = NoteTextView(frame: .zero)
        // Tables are drawn by TextKit 1 attachment cells. Asking for the layout manager
        // before any text arrives keeps the view on TextKit 1 from the start.
        _ = view.layoutManager
        view.isRichText = true
        view.importsGraphics = false
        view.usesFontPanel = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainerInset = NSSize(width: 0, height: 3)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(document.attributed)
        view.typingAttributes = NoteDocument.attributes()
        view.insertionPointColor = .labelColor
        view.setAccessibilityLabel("Note body")
        view.setAccessibilityHelp("Rich text. Use Command-B for bold, Command-I for italic, Tab and Shift-Tab to nest list items, and Command-Shift-Return to toggle the checklist item at the cursor.")
        view.delegate = context.coordinator
        view.controller = controller
        controller.view = view
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.measure() }
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NoteTextView, context: Context) {
        context.coordinator.parent = self
        if NoteDocument(view.attributedString()) != document {
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(document.attributed)
            view.setSelectedRange(NSRange(location: min(selection.location, (view.string as NSString).length), length: 0))
        }
        view.isEditable = editable
        view.onTable = onTable
        view.onFiles = onFiles
        view.onImage = onImage
        controller.view = view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NoteTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 500
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        return CGSize(width: width, height: max(160, (view.layoutManager?.usedRect(for: view.textContainer!).height ?? 0) + 12))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextEditor
        init(_ parent: NoteTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.onChange(NoteDocument(view.attributedString()))
            measure()
        }

        // Text typed beside a table must not take on its attributes, or it would be read
        // back as part of the table.
        func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
                      toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            guard newTypingAttributes[.noteBlock] as? String == NoteDocument.Block.table.rawValue else { return newTypingAttributes }
            return NoteDocument.attributes()
        }

        // A table is a block of its own, so text typed against either side of it starts
        // on a new line rather than sharing the table's line.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let text, !text.isEmpty, let storage = textView.textStorage else { return true }
            func isTable(_ location: Int) -> Bool {
                location >= 0 && location < storage.length
                    && NoteTableCell.source(of: storage.attribute(.attachment, at: location, effectiveRange: nil)) != nil
            }
            let before = isTable(range.location - 1) && !text.hasPrefix("\n")
            let after = isTable(NSMaxRange(range)) && !text.hasSuffix("\n")
            guard before || after else { return true }
            var attributes = textView.typingAttributes
            if attributes[.noteBlock] as? String == NoteDocument.Block.table.rawValue { attributes = NoteDocument.attributes() }
            attributes.removeValue(forKey: .attachment)
            let padded = (before ? "\n" : "") + text + (after ? "\n" : "")
            textView.insertText(NSAttributedString(string: padded, attributes: attributes), replacementRange: range)
            if after { textView.setSelectedRange(NSRange(location: textView.selectedRange().location - 1, length: 0)) }
            return false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Selection callbacks can arrive during AppKit layout inside a SwiftUI update.
            Task { @MainActor [weak self] in self?.parent.controller.readSelection() }
        }

        func measure() {
            guard let view = parent.controller.view, let container = view.textContainer,
                  let layout = view.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = max(160, layout.usedRect(for: container).height + 12)
            if abs(parent.height - height) > 1 {
                Task { @MainActor [weak self] in self?.parent.height = height }
            }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let kept = NoteDocument.keptLink(String(describing: link)), let url = URL(string: kept) {
                parent.onLink(url)
            }
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let inList = NoteDocument.Block.lists.contains(parent.controller.block)
            if selector == #selector(NSResponder.insertTab(_:)) {
                if inList { parent.controller.changeIndent(by: 1) } else { textView.window?.selectNextKeyView(nil) }
                return true
            }
            if selector == #selector(NSResponder.insertBacktab(_:)) {
                if inList { parent.controller.changeIndent(by: -1) } else { textView.window?.selectPreviousKeyView(nil) }
                return true
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let selected = textView.selectedRange()
            let paragraph = (textView.string as NSString).paragraphRange(for: selected)
            let line = (textView.string as NSString).substring(with: paragraph)
            let block = parent.controller.block
            if [.title, .heading, .subheading].contains(block) {
                textView.insertText(NSAttributedString(string: "\n", attributes: NoteDocument.attributes()), replacementRange: selected)
                textView.typingAttributes = NoteDocument.attributes()
                return true
            }
            guard [.bullet, .numbered, .checklist].contains(block) else { return false }
            let marker = NoteDocument.markerLength(line, block: block)
            if line.dropFirst(marker).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parent.controller.setBlock(.text)
            } else {
                let number = Int(line.prefix(while: \.isNumber)) ?? 0
                let attributes = NoteDocument.attributes(block: block, indent: parent.controller.indent)
                textView.insertText(NSAttributedString(string: "\n" + NoteEditorController.marker(for: block, number: number + 1),
                                                       attributes: attributes), replacementRange: selected)
                textView.typingAttributes = attributes
            }
            return true
        }
    }
}

final class NoteTextView: NSTextView {
    weak var controller: NoteEditorController?
    var onFiles: (([URL]) -> Void)?
    var onImage: ((Data) -> Void)?
    var onLayout: (() -> Void)?
    var onTable: ((String) -> Void)?
    private let tableHover = NoteTableHoverState()
    private var tableHoverHost: NoteTableHoverHost?
    private var hoveredTable: Int?
    private var tableTracking: NSTrackingArea?

    // A new width moves and resizes the tables, so the hover follows the one it is on.
    override func layout() {
        super.layout()
        onLayout?()
        if let hoveredTable, tableHover.lit {
            if let table = tables().first(where: { $0.location == hoveredTable }) { placeTableHover(over: table.frame) }
            else { tableHover.lit = false }
        }
    }

    // Where each table sits in the view: the bounds of its attachment glyph, which is
    // where TextKit draws the grid.
    private func tables() -> [(location: Int, source: String, frame: NSRect)] {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return [] }
        var result: [(Int, String, NSRect)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let source = NoteTableCell.source(of: value) else { return }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
            let frame = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            result.append((range.location, source, frame))
        }
        return result
    }

    private func table(at point: NSPoint) -> (location: Int, source: String, frame: NSRect)? {
        tables().first { $0.frame.contains(point) }
    }

    private func updateTableHover(at point: NSPoint) {
        guard onTable != nil, visibleRect.contains(point), let hit = table(at: point) else {
            tableHover.lit = false
            return
        }
        hoveredTable = hit.location
        placeTableHover(over: hit.frame)
        tableHover.lit = true
    }

    private func placeTableHover(over frame: NSRect) {
        let host = tableHoverHost ?? {
            let host = NoteTableHoverHost(rootView: NoteTableHover(state: tableHover))
            addSubview(host)
            tableHoverHost = host
            return host
        }()
        host.frame = NSRect(x: frame.minX, y: frame.minY - NoteTableHover.tagRoom,
                            width: frame.width, height: frame.height + NoteTableHover.tagRoom)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tableTracking { removeTrackingArea(tableTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tableTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateTableHover(at: convert(event.locationInWindow, from: nil))
        if tableHover.lit { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        tableHover.lit = false
    }

    override func scrollWheel(with event: NSEvent) {
        tableHover.lit = false
        super.scrollWheel(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        tableHover.lit = false
    }

    // Rich text and plain text on the pasteboard both lose a table's attachment, so a
    // selection holding a table also goes out as the document itself. Other apps get
    // the table's Markdown as plain text.
    static let documentPasteboardType = NSPasteboard.PasteboardType("com.teya.code-station.note-document")

    private var selectionHoldsTable: Bool {
        guard let storage = textStorage else { return false }
        return selectedRanges.map(\.rangeValue).contains { range in
            var found = false
            storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
                if NoteTableCell.source(of: value) != nil { found = true; stop.pointee = true }
            }
            return found
        }
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        selectionHoldsTable ? [Self.documentPasteboardType, .string] : super.writablePasteboardTypes
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard selectionHoldsTable, let storage = textStorage,
              let data = try? JSONEncoder().encode(NoteDocument(storage.attributedSubstring(from: selectedRange()))) else {
            return super.writeSelection(to: pboard, types: types)
        }
        pboard.declareTypes([Self.documentPasteboardType, .string], owner: nil)
        pboard.setData(data, forType: Self.documentPasteboardType)
        pboard.setString(NoteDocument(storage.attributedSubstring(from: selectedRange())).markdown, forType: .string)
        return true
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.documentPasteboardType] + super.readablePasteboardTypes
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == Self.documentPasteboardType else { return super.readSelection(from: pboard, type: type) }
        return insertDocument(from: pboard, replacing: rangeForUserTextChange)
    }

    private func insertDocument(from pboard: NSPasteboard, replacing range: NSRange) -> Bool {
        guard isEditable, range.location != NSNotFound, let storage = textStorage,
              let data = pboard.data(forType: Self.documentPasteboardType),
              let document = try? JSONDecoder().decode(NoteDocument.self, from: data) else { return false }
        // A table always sits on a line of its own, so the pasted text is set apart from
        // a table it lands against, and a table it carries is set apart from the text
        // around it.
        let string = storage.string as NSString
        func isTable(_ location: Int) -> Bool {
            location >= 0 && location < storage.length
                && NoteTableCell.source(of: storage.attribute(.attachment, at: location, effectiveRange: nil)) != nil
        }
        let text = NSMutableAttributedString(attributedString: document.attributed)
        let startsWithTable = document.runs.first?.block == .table, endsWithTable = document.runs.last?.block == .table
        if range.location > 0, string.character(at: range.location - 1) != 0x0A,
           startsWithTable || isTable(range.location - 1) {
            text.insert(NSAttributedString(string: "\n", attributes: NoteDocument.attributes()), at: 0)
        }
        if NSMaxRange(range) < string.length, string.character(at: NSMaxRange(range)) != 0x0A,
           endsWithTable || isTable(NSMaxRange(range)) {
            text.append(NSAttributedString(string: "\n", attributes: NoteDocument.attributes()))
        }
        insertText(text, replacementRange: range)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isEditable, flags == .command {
            if event.charactersIgnoringModifiers == "b" { controller?.toggleTrait(.boldFontMask); return true }
            if event.charactersIgnoringModifiers == "i" { controller?.toggleTrait(.italicFontMask); return true }
        }
        if isEditable, flags == [.command, .shift], event.keyCode == 36 {
            controller?.toggleChecklist(); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pasteboard = NSPasteboard.general
        if takeFiles(pasteboard) { return }
        if insertDocument(from: pasteboard, replacing: selectedRange()) { return }
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            onImage?(png); return
        }
        if let rtf = pasteboard.data(forType: .rtf),
           let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            insertText(NoteDocument(attributed).attributed, replacementRange: selectedRange())
        } else if let text = pasteboard.string(forType: .string) {
            insertText(NSAttributedString(string: text, attributes: typingAttributes), replacementRange: selectedRange())
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return isEditable ? .copy : []
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if isEditable, takeFiles(sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    private func takeFiles(_ pasteboard: NSPasteboard) -> Bool {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let onTable, let hit = table(at: point) {
            tableHover.lit = false
            onTable(hit.source)
            return
        }
        let index = characterIndexForInsertion(at: point)
        let paragraph = (string as NSString).paragraphRange(for: NSRange(location: min(index, (string as NSString).length), length: 0))
        if isEditable, index <= paragraph.location + 1, toggleChecklist(at: paragraph.location) { return }
        super.mouseDown(with: event)
    }

    @discardableResult func toggleChecklist(at index: Int) -> Bool {
        guard isEditable, let storage = textStorage, storage.length > 0 else { return false }
        let paragraph = (string as NSString).paragraphRange(for: NSRange(location: min(index, storage.length), length: 0))
        guard paragraph.location < storage.length,
              storage.attribute(.noteBlock, at: paragraph.location, effectiveRange: nil) as? String == NoteDocument.Block.checklist.rawValue,
              let first = (string as NSString).substring(with: paragraph).first, first == "☐" || first == "☑" else { return false }
        let selected = selectedRange()
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraph))
        replacement.replaceCharacters(in: NSRange(location: 0, length: 1), with: first == "☐" ? "☑" : "☐")
        breakUndoCoalescing()
        insertText(NoteDocument(replacement).attributed, replacementRange: paragraph)
        breakUndoCoalescing()
        setSelectedRange(selected)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: first == "☐" ? "Item checked" : "Item unchecked",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        return true
    }
}
