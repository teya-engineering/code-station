import Foundation
import CodeStationCore

// Old files can contain prompts. Drop them before decoding commands so their text
// can never be handed to a shell. Unknown kinds still fail instead of being guessed.
public struct CommandShortcutRecord<Value: Decodable>: Decodable {
    public let value: Value?

    private enum CodingKeys: String, CodingKey { case kind }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind)
        if kind == "prompt" {
            value = nil
            return
        }
        guard kind == nil || kind == "command" else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                   debugDescription: "Unknown shortcut kind.")
        }
        value = try Value(from: decoder)
    }
}
