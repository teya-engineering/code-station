import AppKit
import SwiftUI

@MainActor @Observable
final class NoteEditorController {
    @ObservationIgnored weak var view: NoteTextView?
    var bold = false
    var italic = false
    var block = NoteDocument.Block.text
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
            let value = (replacement.string as NSString).substring(with: line)
            let markerLength = NoteDocument.markerLength(value, block: old)
            let text = NSMutableAttributedString(attributedString: replacement.attributedSubstring(from: line))
            if markerLength > 0 { text.deleteCharacters(in: NSRange(location: 0, length: markerLength)) }
            let normalized = NoteDocument(text)
            text.setAttributedString(NoteDocument(runs: normalized.runs.map {
                var run = $0; run.block = block; return run
            }).attributed)
            let marker = Self.marker(for: block, number: number)
            text.insert(NSAttributedString(string: marker, attributes: NoteDocument.attributes(block: block)), at: 0)
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
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NoteTextView {
        let view = NoteTextView(frame: .zero)
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
        view.setAccessibilityHelp("Rich text. Use Command-B for bold, Command-I for italic, and Command-Shift-Return to toggle the checklist item at the cursor.")
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
            view.setSelectedRange(NSRange(location: min(selection.location, document.text.utf16.count), length: 0))
        }
        view.isEditable = editable
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
            if let safe = NoteDocument.safeLink(String(describing: link)), let url = URL(string: safe) {
                parent.onLink(url)
            }
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) {
                textView.window?.selectNextKeyView(nil)
                return true
            }
            if selector == #selector(NSResponder.insertBacktab(_:)) {
                textView.window?.selectPreviousKeyView(nil)
                return true
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let selected = textView.selectedRange()
            let paragraph = (textView.string as NSString).paragraphRange(for: selected)
            let line = (textView.string as NSString).substring(with: paragraph)
            let block = parent.controller.block
            if [.heading, .subheading].contains(block) {
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
                textView.insertText(NSAttributedString(string: "\n" + NoteEditorController.marker(for: block, number: number + 1),
                                                       attributes: NoteDocument.attributes(block: block)), replacementRange: selected)
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

    override func layout() { super.layout(); onLayout?() }

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
