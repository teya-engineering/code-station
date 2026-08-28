import Foundation

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var isBlank: Bool { trimmed.isEmpty }
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
