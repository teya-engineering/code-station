import Foundation

// Tool output is cut at a fixed length, which leaves a large Grafana result as JSON that
// stops mid-entry. The entries before the cut are whole, so this walks the text to find
// the named array and hands back each object in it that closed before the text ran out.
enum GrafanaJSONScanner {
    static func completeObjects(inArrayNamed name: String, of text: String) -> [[String: Any]]? {
        let bytes = Array(text.utf8)
        guard let arrayStart = arrayStart(named: name, in: bytes) else { return nil }

        var objects: [[String: Any]] = []
        var depth = 0
        var inString = false
        var escaped = false
        var objectStart: Int?
        var index = arrayStart
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    if depth == 0, byte == UInt8(ascii: "{") { objectStart = index }
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    if depth == 0 { return objects }
                    depth -= 1
                    if depth == 0, let start = objectStart {
                        let slice = Data(bytes[start...index])
                        if let object = (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any] {
                            objects.append(object)
                        }
                        objectStart = nil
                    }
                default:
                    break
                }
            }
            index += 1
        }
        return objects
    }

    // The index just after the "[" that opens `"<name>": [` at the top level of the document,
    // skipping any occurrence of the key inside a string value.
    private static func arrayStart(named name: String, in bytes: [UInt8]) -> Int? {
        let key = Array("\"\(name)\"".utf8)
        var depth = 0
        var inString = false
        var escaped = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                index += 1
                continue
            }
            if depth == 1, byte == UInt8(ascii: "\""),
               index + key.count <= bytes.count, Array(bytes[index..<index + key.count]) == key {
                var cursor = index + key.count
                while cursor < bytes.count, bytes[cursor] == UInt8(ascii: " ") || bytes[cursor] == UInt8(ascii: "\n") {
                    cursor += 1
                }
                if cursor < bytes.count, bytes[cursor] == UInt8(ascii: ":") {
                    cursor += 1
                    while cursor < bytes.count, bytes[cursor] == UInt8(ascii: " ") || bytes[cursor] == UInt8(ascii: "\n") {
                        cursor += 1
                    }
                    if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "[") { return cursor + 1 }
                }
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
            default: break
            }
            index += 1
        }
        return nil
    }
}
