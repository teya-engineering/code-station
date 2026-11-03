import Foundation

// Git run by the app has no terminal to ask for a username or password in. When an HTTPS
// address needs a sign-in and no credential helper holds one, git gives up with a line
// that reads like a device fault ("could not read Username ... Device not configured").
// People who push over SSH rarely have an HTTPS login stored, so the same repository
// that clones fine for them by hand fails here. This turns that failure into what it
// means and, for the common hosts, offers the SSH address that uses the key they have.
enum GitSignIn {
    // The lines git prints when it needed credentials it could not get, whether prompts
    // were turned off or it tried a terminal the app does not have. The last is a stored
    // login the server turned down.
    private static let signals = [
        "could not read username",
        "could not read password",
        "terminal prompts disabled",
        "authentication failed for",
    ]

    static func isRequired(by gitOutput: String) -> Bool {
        let text = gitOutput.lowercased()
        return signals.contains { text.contains($0) }
    }

    // Hosts whose SSH address is `git@<host>:<path>.git` for every HTTPS repository
    // address. Other servers set their own SSH user, port or path, so guessing would
    // offer an address that fails in a new way.
    private static let sshHosts: [String: String] = [
        "github.com": "GitHub",
        "gitlab.com": "GitLab",
        "bitbucket.org": "Bitbucket",
    ]

    static func sshAddress(for address: String) -> String? {
        guard let components = URLComponents(string: address.trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), sshHosts[host] != nil,
              components.port == nil, components.query == nil, components.fragment == nil
        else { return nil }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        // An owner and a repository at least. GitLab groups nest, so more is fine.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts.contains("") else { return nil }
        return "git@\(host):\(path).git"
    }

    static func explanation(for address: String) -> String {
        let host = URLComponents(string: address.trimmed)?.host?.lowercased() ?? ""
        let server = sshHosts[host] ?? "The server"
        var message = "\(server) needs you to sign in to read this repository, "
            + "and git cannot ask for a password from here."
        if let ssh = sshAddress(for: address) {
            message += " Use the SSH address \(ssh) to sign in with your SSH key."
        }
        message += host == "github.com"
            ? " To keep the HTTPS address, run gh auth setup-git in Terminal first."
            : " To keep the HTTPS address, set up a git credential helper for it first."
        return message
    }
}

// Thrown when a clone stopped at a sign-in. The screen that started it can offer the SSH
// address as a one-click retry instead of leaving the user to work it out.
struct GitSignInRequired: LocalizedError, Sendable {
    let address: String

    var sshAddress: String? { GitSignIn.sshAddress(for: address) }
    var errorDescription: String? { GitSignIn.explanation(for: address) }
}
