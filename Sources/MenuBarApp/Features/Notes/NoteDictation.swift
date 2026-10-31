import AppKit
import SwiftUI

@MainActor
final class NoteDictation {
    let noteID: UUID
    let caret: Int
    private let original: NoteDocument
    private let attributes: [NSAttributedString.Key: Any]
    private let store: NotebookStore
    private weak var view: NoteTextView?
    private var draft: SessionComposerStore.Draft
    private var committed = false

    init(note: QuickNote, store: NotebookStore, view: NoteTextView?) {
        noteID = note.id
        original = note.body
        self.store = store
        self.view = view
        caret = min(view?.selectedRange().location ?? note.body.text.utf16.count, note.body.text.utf16.count)
        attributes = view?.typingAttributes ?? NoteDocument.attributes()
        draft = .init(text: note.body.text)
        view?.breakUndoCoalescing()
    }

    var binding: Binding<SessionComposerStore.Draft> {
        Binding(get: { self.draft }, set: { self.receive($0) })
    }

    func placeCaret(_ location: Int) {
        guard store.selectedID == noteID, let view, let window = view.window else { return }
        view.setSelectedRange(NSRange(location: min(location, view.string.utf16.count), length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        window.makeFirstResponder(view)
    }

    private func receive(_ value: SessionComposerStore.Draft) {
        guard let current = store.note(noteID)?.body else { return }
        let document: NoteDocument
        if committed {
            document = Self.replacingText(in: current, with: value.text, attributes: attributes)
        } else {
            let text = original.text as NSString
            let prefix = text.substring(to: caret)
            let suffix = text.substring(from: caret)
            let length = value.text.utf16.count - text.length
            guard length >= 0, value.text.hasPrefix(prefix), value.text.hasSuffix(suffix) else { return }
            let inserted = (value.text as NSString).substring(with: NSRange(location: caret, length: length))
            let result = NSMutableAttributedString(attributedString: original.attributed)
            result.insert(NSAttributedString(string: inserted, attributes: attributes), at: caret)
            document = inserted.isEmpty ? original : NoteDocument(result)
        }
        let undoing = committed ? (document != current ? current : nil)
            : value.dictated && document != original ? original : nil
        draft = value
        committed = value.dictated
        if document != current { store.update(noteID) { $0.body = document } }
        // The request keeps its original editor and note even if the library selection changes.
        view?.replaceDictation(document, undoing: undoing)
        if value.dictated { _ = store.flush() }
    }

    private static func replacingText(in document: NoteDocument, with text: String,
                                      attributes: [NSAttributedString.Key: Any]) -> NoteDocument {
        let old = Array(document.text)
        let new = Array(text)
        let prefix = zip(old, new).prefix(while: { $0 == $1 }).count
        let suffix = zip(old.dropFirst(prefix).reversed(), new.dropFirst(prefix).reversed())
            .prefix(while: { $0 == $1 }).count
        let range = NSRange(location: String(old.prefix(prefix)).utf16.count,
                            length: String(old.dropFirst(prefix).dropLast(suffix)).utf16.count)
        let result = NSMutableAttributedString(attributedString: document.attributed)
        result.replaceCharacters(in: range, with: NSAttributedString(
            string: String(new.dropFirst(prefix).dropLast(suffix)), attributes: attributes))
        return NoteDocument(result)
    }
}

extension NoteTextView {
    func replaceDictation(_ document: NoteDocument, undoing previous: NoteDocument? = nil) {
        if let previous {
            breakUndoCoalescing()
            undoManager?.registerUndo(withTarget: self) { $0.replaceDictation(previous, undoing: document) }
            undoManager?.setActionName("Dictation")
        }
        guard NoteDocument(attributedString()) != document else { return }
        let selection = selectedRange()
        textStorage?.setAttributedString(document.attributed)
        setSelectedRange(NSRange(location: min(selection.location, document.text.utf16.count), length: 0))
        didChangeText()
    }
}
