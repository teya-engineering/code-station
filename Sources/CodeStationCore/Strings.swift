import Foundation

extension String {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isBlank: Bool { trimmed.isEmpty }

    // For a field that is optional in meaning but arrives as an empty string.
    public var nilIfBlank: String? { isBlank ? nil : self }
}

// "1 file", "3 files". A noun with an irregular plural passes it in.
public func counted(_ count: Int, _ noun: String, plural: String? = nil) -> String {
    let word = count == 1 ? noun : plural ?? noun + "s"
    return "\(count) \(word)"
}

extension Data {
    // Base64 with the URL-safe alphabet and no padding, the form OAuth and pairing
    // secrets need.
    public var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    public func pathRelative(to directory: String) -> String? {
        let path = URL(fileURLWithPath: self).standardizedFileURL.path
        let directory = URL(fileURLWithPath: directory).standardizedFileURL.path
        guard path != directory else { return "" }

        let prefix = directory == "/" ? "/" : directory + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    public var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let relativePath = pathRelative(to: home) else { return self }
        return relativePath.isEmpty ? "~" : "~/\(relativePath)"
    }
}
