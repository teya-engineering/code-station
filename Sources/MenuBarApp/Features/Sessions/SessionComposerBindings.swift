import SwiftUI
import CodeStationCore

// The composer drafts live in the core, which has no SwiftUI, so the bindings the
// composer fields edit them through are made here.
extension SessionComposerStore {
    func draftBinding(_ sessionID: UUID) -> Binding<Draft> {
        Binding(get: { self.draft(sessionID) },
                set: { value in self.editDraft(sessionID) { $0 = value } })
    }

    func problemBinding(_ sessionID: UUID) -> Binding<Draft> {
        Binding(get: {
            let brief = self.brief(sessionID)
            return Draft(text: brief.problem, dictated: brief.dictated)
        }, set: { value in
            self.editBrief(sessionID) {
                $0.problem = value.text
                $0.dictated = value.dictated
            }
        })
    }
}
