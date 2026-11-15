import Foundation

// What an ask for a second opinion starts from, set on its own Settings tab. Tune can
// still change any of it for one ask, and that change stays with the ask.
struct SecondOpinionDefaults: Equatable {
    // A usual reviewer. One left unticked keeps its model and effort, so ticking it
    // again brings back the same seat.
    struct Seat: Equatable, Codable {
        var reviewer: SecondOpinion.Reviewer
        var on = true
    }

    var seats: [Seat] = []
    var chatFocus = Set(ChatSecondOpinion.Focus.standard)
    var changesFocus = Set(SecondOpinion.Focus.standard)
    var designFocus = Set(DesignSecondOpinion.Focus.standard)
    var chatReading = ChatSecondOpinion.Reading()
    var designReading = DesignSecondOpinion.Reading()
    // Off unless the person turns it on: a tool on an MCP server can act, not only read.
    var usesServers = false

    // The seats an ask opens with.
    var lineup: [SecondOpinion.Reviewer] { seats.filter(\.on).map(\.reviewer) }

    // These seats become the ones asked. A usual seat left out stays listed, unticked,
    // so its model and effort are still there to tick again.
    mutating func makeUsual(_ lineup: [SecondOpinion.Reviewer]) {
        let asked = SecondOpinionAsk.seated(lineup)
        let kept = seats.filter { !asked.contains($0.reviewer) }.map { Seat(reviewer: $0.reviewer, on: false) }
        seats = asked.map { Seat(reviewer: $0) }
            + kept.prefix(max(0, SecondOpinion.Reviewer.maxSeats - asked.count))
    }

    // Another seat for an agent, on a model no seat of it uses yet when there is one,
    // so two seats on one agent read the work twice rather than the same way twice.
    mutating func addSeat(_ agent: AgentKind, models: [String?], effort: String?) {
        guard seats.count < SecondOpinion.Reviewer.maxSeats else { return }
        let taken = Set(seats.filter { $0.reviewer.agent == agent }.map(\.reviewer.model))
        let model = models.first { !taken.contains($0) } ?? models.first ?? nil
        seats.append(Seat(reviewer: SecondOpinion.Reviewer(agent: agent, model: model, effort: effort)))
    }

    // Whether this seat is a second one for its agent, which can be removed. The first
    // seat of each agent stays and is only ticked or unticked.
    func isExtraSeat(at index: Int) -> Bool {
        seats.indices.contains(index)
            && seats[..<index].contains { $0.reviewer.agent == seats[index].reviewer.agent }
    }

    // Turning off the last thing to look for would leave an ask with nothing to do.
    static func toggled<Item: Hashable>(_ item: Item, in set: Set<Item>) -> Set<Item>? {
        guard set.contains(item) else { return set.union([item]) }
        guard set.count > 1 else { return nil }
        return set.subtracting([item])
    }
}

// Each list is read item by item, so an item a later version drops does not throw away
// the whole of the person's settings.
extension SecondOpinionDefaults: Codable {
    private enum CodingKeys: String, CodingKey {
        case seats, chatFocus, changesFocus, designFocus
        case chatFiles, chatConversation, designSource, designConversation, usesServers
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = SecondOpinionDefaults()
        seats = (try? values.decodeIfPresent([Seat].self, forKey: .seats)) ?? []
        func focus<Item: RawRepresentable>(_ key: CodingKeys, _ standard: Set<Item>) -> Set<Item>
            where Item.RawValue == String {
            guard let raw = try? values.decodeIfPresent([String].self, forKey: key) else { return standard }
            let items = Set(raw.compactMap(Item.init(rawValue:)))
            return items.isEmpty ? standard : items
        }
        chatFocus = focus(.chatFocus, fresh.chatFocus)
        changesFocus = focus(.changesFocus, fresh.changesFocus)
        designFocus = focus(.designFocus, fresh.designFocus)
        chatReading = ChatSecondOpinion.Reading(
            files: (try? values.decodeIfPresent(Bool.self, forKey: .chatFiles)) ?? fresh.chatReading.files,
            conversation: (try? values.decodeIfPresent(Bool.self, forKey: .chatConversation))
                ?? fresh.chatReading.conversation)
        designReading = DesignSecondOpinion.Reading(
            source: (try? values.decodeIfPresent(Bool.self, forKey: .designSource)) ?? fresh.designReading.source,
            conversation: (try? values.decodeIfPresent(Bool.self, forKey: .designConversation))
                ?? fresh.designReading.conversation)
        usesServers = (try? values.decodeIfPresent(Bool.self, forKey: .usesServers)) ?? fresh.usesServers
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(seats, forKey: .seats)
        try values.encode(ChatSecondOpinion.Focus.allCases.filter(chatFocus.contains).map(\.rawValue), forKey: .chatFocus)
        try values.encode(SecondOpinion.Focus.allCases.filter(changesFocus.contains).map(\.rawValue), forKey: .changesFocus)
        try values.encode(DesignSecondOpinion.Focus.allCases.filter(designFocus.contains).map(\.rawValue), forKey: .designFocus)
        try values.encode(chatReading.files, forKey: .chatFiles)
        try values.encode(chatReading.conversation, forKey: .chatConversation)
        try values.encode(designReading.source, forKey: .designSource)
        try values.encode(designReading.conversation, forKey: .designConversation)
        try values.encode(usesServers, forKey: .usesServers)
    }
}
