import Foundation
import Observation

@MainActor
@Observable
public final class SessionAttention {
    public var finished: Set<UUID> = []
    public var markedUnread: Set<UUID> = []
    @ObservationIgnored public var applicationIsActive = true

    public init() {}

    @discardableResult
    public func noteTurnEnded(_ sessionID: UUID, isVisible: Bool, isRemote: Bool) -> Bool {
        guard !isRemote, !(applicationIsActive && isVisible) else { return false }
        finished.insert(sessionID)
        return true
    }
}
