import Foundation
import Observation

@MainActor
@Observable
final class SessionComposerStore {
    private var drafts: [UUID: Draft] = [:]
    private var briefs: [UUID: TroubleshootBrief] = [:]
    @ObservationIgnored private var walks: [UUID: PromptWalk] = [:]

    // An unsent composer: what has been typed, and what has been dropped or pasted onto it.
    struct Draft: Equatable {
        var text: String = ""
        var attachments: [Attachment] = []
        var customInstructions: String?

        var isEmpty: Bool {
            text.isBlank && attachments.isEmpty && customInstructions?.isBlank != false
        }
    }

    func draft(_ sessionID: UUID) -> Draft { drafts[sessionID] ?? Draft() }

    func editDraft(_ sessionID: UUID, _ change: (inout Draft) -> Void) {
        var draft = drafts[sessionID] ?? Draft()
        change(&draft)
        drafts[sessionID] = draft.isEmpty ? nil : draft
    }

    func clearDraft(_ sessionID: UUID) {
        drafts[sessionID] = nil
        walks[sessionID] = nil
    }

    // An unsent troubleshoot brief: the problem, the evidence for it, and the two choices
    // the tab makes about how the diagnosis runs.
    struct TroubleshootBrief: Equatable {
        var problem: String = ""
        var incidentTime: String = ""
        var attachments: [Attachment] = []
        var environment = TroubleshootEnvironment.first()
        var mcpServersEnabled = true
        var serviceName: String? = nil
        var trace: TroubleshootTraceContext? = nil
    }

    func brief(_ sessionID: UUID) -> TroubleshootBrief {
        briefs[sessionID] ?? TroubleshootBrief()
    }

    func editBrief(_ sessionID: UUID, _ change: (inout TroubleshootBrief) -> Void) {
        var brief = briefs[sessionID] ?? TroubleshootBrief()
        change(&brief)
        briefs[sessionID] = brief
    }

    func clearBrief(_ sessionID: UUID) { briefs[sessionID] = nil }

    private struct PromptWalk {
        // The number of steps taken, where one is the most recent prompt.
        var position: Int
        // The text the walk last put in the composer. Once the box holds something else
        // the prompt has been edited, which ends the walk: the arrows belong to the text
        // being written rather than to the history behind it.
        var shown: String
    }

    func isWalking(_ sessionID: UUID) -> Bool {
        walks[sessionID].map { $0.shown == draft(sessionID).text } ?? false
    }

    func restore(_ draft: Draft, in sessionID: UUID) {
        walks[sessionID] = nil
        drafts[sessionID] = draft.isEmpty ? nil : draft
    }

    func remove(_ sessionID: UUID) {
        clearDraft(sessionID)
        clearBrief(sessionID)
    }

    @discardableResult
    func recallEarlier(_ sessionID: UUID, history: [String]) -> Bool {
        // A walk already under way carries on from where it reached, whatever is in the
        // box, because the box holds what the last step put there.
        if let walk = walks[sessionID], walk.shown == draft(sessionID).text {
            let next = walk.position + 1
            guard next <= history.count else { return false }
            return show(history[next - 1], at: next, sessionID: sessionID)
        }
        // Starting one is different: with anything written the key keeps moving the
        // cursor, so a prompt part way through being typed is never thrown away.
        guard draft(sessionID).text.isEmpty else { return false }
        // Files waiting to go with the next prompt are the start of one, so they hold the
        // box in the same way written words do.
        guard draft(sessionID).isEmpty, let recent = history.first else { return false }
        return show(recent, at: 1, sessionID: sessionID)
    }

    @discardableResult
    func recallLater(_ sessionID: UUID, history: [String]) -> Bool {
        guard let walk = walks[sessionID], walk.shown == draft(sessionID).text else { return false }
        let previous = walk.position - 1
        guard previous > 0 else {
            clearDraft(sessionID)
            return true
        }
        guard previous <= history.count else { return false }
        return show(history[previous - 1], at: previous, sessionID: sessionID)
    }

    private func show(_ text: String, at position: Int, sessionID: UUID) -> Bool {
        walks[sessionID] = PromptWalk(position: position, shown: text)
        drafts[sessionID] = Draft(text: text)
        return true
    }

    // Files joining the unsent prompt. The same file twice in one prompt says nothing
    // new, so one already waiting is skipped.
    func attach(_ found: [Attachment], to sessionID: UUID) {
        editDraft(sessionID) { draft in
            for item in found where !draft.attachments.contains(where: { $0.url == item.url }) {
                draft.attachments.append(item)
            }
        }
    }
}
