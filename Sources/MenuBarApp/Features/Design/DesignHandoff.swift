import Foundation
import CodeStationCore

// The GUI's side of handing a Design over: the work is the core's (`DesignHandoff`), and
// the GUI then puts the Build on screen.
@MainActor
enum DesignHandoffLifecycle {
    typealias Failure = DesignHandoff.Failure

    static func sourceRevisions(for session: ChatSession,
                                store: ProjectStore) async -> [String: String] {
        await DesignHandoff.sourceRevisions(for: session, store: store)
    }

    static func startImplementation(_ designSessionID: UUID, revision: DesignRevision,
                                    additionalContext: String? = nil,
                                    store: ProjectStore, runner: SessionRunner)
        -> Result<Void, Failure> {
        DesignHandoff.startImplementation(designSessionID, revision: revision,
                                          additionalContext: additionalContext,
                                          store: store, runner: runner)
            .map { store.selectSession($0) }
    }

    static func sendLatestDesign(to implementationID: UUID,
                                 store: ProjectStore, runner: SessionRunner)
        -> Result<DesignRevision, Failure> {
        DesignHandoff.sendLatestDesign(to: implementationID, store: store, runner: runner)
    }

    static func implementationPrompt(_ revision: DesignRevision,
                                     additionalContext: String? = nil) -> String {
        DesignHandoff.implementationPrompt(revision, additionalContext: additionalContext)
    }
}
