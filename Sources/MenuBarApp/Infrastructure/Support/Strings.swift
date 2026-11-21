import Foundation

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    // The same as `components(separatedBy: "\n")`, a "\r" before a break included, but
    // split on the bytes instead of with Foundation's general search, which is slow.
    var lines: [String] {
        utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(Substring($0)) }
    }

    // `trimmingCharacters(in: .whitespaces)`, without the Foundation call for the usual
    // line that starts and ends in printable ASCII and so has nothing to trim.
    var trimmedSpaces: String {
        let printable: ClosedRange<UInt8> = 0x21...0x7E
        if let first = utf8.first, let last = utf8.last,
           printable.contains(first), printable.contains(last) { return self }
        return trimmingCharacters(in: .whitespaces)
    }

    var isBlank: Bool { trimmed.isEmpty }

    // For a field that is optional in meaning but arrives as an empty string.
    var nilIfBlank: String? { isBlank ? nil : self }
}

// "1 file", "3 files". A noun with an irregular plural passes it in.
func counted(_ count: Int, _ noun: String, plural: String? = nil) -> String {
    let word = count == 1 ? noun : plural ?? noun + "s"
    return "\(count) \(word)"
}

extension Data {
    // Base64 with the URL-safe alphabet and no padding, the form OAuth and pairing
    // secrets need.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
