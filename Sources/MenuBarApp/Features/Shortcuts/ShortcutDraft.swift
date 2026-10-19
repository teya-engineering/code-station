import Foundation
import Observation
import CodeStationCore

@MainActor
@Observable
final class ShortcutDraft {
    var value: Shortcut
    private(set) var original: Shortcut
    private(set) var isNew: Bool
    let projectIDWhenPrivate: UUID?
    let projectName: String?

    init(request: ShortcutEditorRequest) {
        let value = request.shortcut ?? Shortcut(name: request.name ?? "", text: request.text ?? "",
                                                projectID: request.projectID)
        self.value = value
        original = value
        isNew = request.shortcut == nil
        projectIDWhenPrivate = value.projectID ?? request.projectID
        projectName = request.projectName
    }

    var isDirty: Bool { value != original }
    var canSave: Bool { !value.name.isBlank && !value.text.isBlank }

    var shortcut: Shortcut {
        var saved = value
        saved.name = saved.name.trimmed
        saved.text = saved.text.trimmed
        saved.projectID = saved.availableInAllProjects ? nil : projectIDWhenPrivate
        return saved
    }

    func accept(_ saved: Shortcut) {
        value = saved
        original = saved
        isNew = false
    }

    func reset() { value = original }
}
