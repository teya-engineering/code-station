import Foundation
import Observation

@MainActor
@Observable
final class ShortcutDraft {
    var value: Shortcut
    private(set) var original: Shortcut
    private(set) var isNew: Bool
    let projectIDWhenPrivate: UUID?
    let projectName: String?
    private var textByKind: [ShortcutKind: String] = [:]

    init(request: ShortcutEditorRequest) {
        let value = request.shortcut ?? Shortcut(name: request.name ?? "", text: request.text ?? "",
                                                kind: request.kind,
                                                icon: request.kind.icon,
                                                projectID: request.projectID)
        self.value = value
        original = value
        isNew = request.shortcut == nil
        projectIDWhenPrivate = value.projectID ?? request.projectID
        projectName = request.projectName
    }

    var isDirty: Bool { value != original }
    var canSave: Bool { !value.name.isBlank && !value.text.isBlank && (isNew || isDirty) }

    func selectKind(_ kind: ShortcutKind) {
        guard kind != value.kind else { return }
        textByKind[value.kind] = value.text
        if value.icon == value.kind.icon { value.icon = kind.icon }
        value.kind = kind
        value.text = textByKind[kind] ?? ""
    }

    var shortcut: Shortcut {
        var saved = value
        saved.name = saved.name.trimmed
        if saved.kind == .command { saved.text = saved.text.trimmed }
        saved.projectID = saved.availableInAllProjects ? nil : projectIDWhenPrivate
        return saved
    }

    func accept(_ saved: Shortcut) {
        value = saved
        original = saved
        isNew = false
        textByKind = [:]
    }

    func reset() {
        value = original
        textByKind = [:]
    }
}
