import Foundation

extension Data {
    // git only looks for a NUL byte, but anything that is not valid UTF-8 would render as
    // a wall of replacement characters, so treat that as binary too.
    var looksBinary: Bool {
        let head = prefix(8000)
        if head.contains(0) { return true }
        // Complete a character cut by the sample without hiding invalid trailing bytes.
        for end in head.count...Swift.min(count, head.count + 3) {
            if String(data: prefix(end), encoding: .utf8) != nil { return false }
        }
        return true
    }
}
