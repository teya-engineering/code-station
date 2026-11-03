import Foundation

// Git run by the app has no terminal, so it cannot ask for a username or a password, and
// ssh cannot ask whether to trust a server it has never seen. Each of those fails with a
// line that reads like a fault ("could not read Username ... Device not configured",
// "Host key verification failed"). People who push over SSH rarely have an HTTPS login
// stored, so a repository that clones fine for them by hand fails here.
//
// This turns those failures into what they mean and, for an HTTPS address on a common
// host, offers the SSH address that signs in with the key the user already has. It
// matches git's English messages, which GitEnvironment pins with LC_ALL=C.
struct GitSignInRequired: LocalizedError, Sendable, Equatable {
    let message: String
    // Only set for an HTTPS address whose SSH address can be worked out with certainty.
    let sshAddress: String?

    var errorDescription: String? { message }
}

enum GitSignIn {
    // What git prints when it needed an HTTPS login it could not get, whether prompts
    // were off or it tried a terminal the app does not have. The last is a stored login
    // the server turned down.
    private static let httpsSignals = [
        "could not read username",
        "could not read password",
        "terminal prompts disabled",
        "authentication failed for",
    ]

    // Nil when the failure has nothing to do with signing in.
    static func problem(in gitOutput: String, address: String) -> GitSignInRequired? {
        let text = gitOutput.lowercased()
        if text.contains("host key verification failed") {
            return GitSignInRequired(message: unknownHostMessage(for: address), sshAddress: nil)
        }
        if text.contains("permission denied (publickey") {
            return GitSignInRequired(message: rejectedKeyMessage(for: address), sshAddress: nil)
        }
        guard httpsSignals.contains(where: text.contains) else { return nil }
        return GitSignInRequired(message: httpsMessage(for: address),
                                 sshAddress: sshAddress(for: address))
    }

    // Hosts whose SSH address is `git@<host>:<path>.git` for every HTTPS repository
    // address. Other servers set their own SSH user, port or path, so guessing would
    // offer an address that fails in a new way.
    private struct KnownHost {
        let name: String
        // GitLab groups nest, so a repository path can be longer than owner/name. On the
        // others anything past the second part is a page, such as /tree/main.
        let nests: Bool
    }

    private static let knownHosts: [String: KnownHost] = [
        "github.com": KnownHost(name: "GitHub", nests: false),
        "gitlab.com": KnownHost(name: "GitLab", nests: true),
        "bitbucket.org": KnownHost(name: "Bitbucket", nests: false),
    ]

    static func sshAddress(for address: String) -> String? {
        guard let components = URLComponents(string: address.trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), let known = knownHosts[host],
              components.port == nil, components.query == nil, components.fragment == nil
        else { return nil }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts.contains("") else { return nil }
        if known.nests {
            // GitLab puts every page of a repository behind a `-` part: /group/repo/-/tree.
            guard !parts.contains("-") else { return nil }
        } else {
            guard parts.count == 2 else { return nil }
        }
        return "git@\(host):\(path).git"
    }

    // MARK: - Messages

    private static func httpsMessage(for address: String) -> String {
        let host = self.host(of: address)
        let server = serverName(host)
        var message = "\(server) asked for a sign-in to read this repository, "
            + "and git cannot ask you for one from here."
        // GitHub and the others answer a missing repository with the same request for a
        // login, so they cannot be told apart from here. A typo has to stay on the table.
        message += host.flatMap { knownHosts[$0] } == nil
            ? " Check the address first: many servers answer the same way when a repository does not exist."
            : " Check the address first: \(server) answers the same way when a repository does not exist."
        if let ssh = sshAddress(for: address) {
            message += " If it is private, use the SSH address \(ssh) to sign in with your SSH key."
        }
        message += host == "github.com"
            ? " To keep the HTTPS address, run gh auth setup-git in Terminal first."
            : " To keep the HTTPS address, set up a git credential helper for it first."
        return message
    }

    private static func unknownHostMessage(for address: String) -> String {
        let server = serverName(host(of: address))
        let first = "SSH has not been told to trust \(server) yet, and cannot ask you from here."
        guard let target = sshTarget(of: address) else {
            return first + " Connect to it once with ssh in Terminal, accept its key, then try again."
        }
        return first + " Run ssh -T \(target) in Terminal once, accept the key, then try again."
    }

    private static func rejectedKeyMessage(for address: String) -> String {
        "\(serverName(host(of: address))) turned down your SSH key for this repository. "
            + "Check that the key is added to your account there and loaded in ssh-agent: "
            + "ssh-add -l in Terminal lists the keys that are loaded."
    }

    private static func serverName(_ host: String?) -> String {
        guard let host else { return "The server" }
        return knownHosts[host]?.name ?? host
    }

    // MARK: - Reading addresses

    // The host of an HTTPS or ssh:// URL, or of an scp-like `user@host:path` address.
    private static func host(of address: String) -> String? {
        let address = address.trimmed
        if address.contains("://") {
            return URLComponents(string: address)?.host?.lowercased()
        }
        guard let colon = address.firstIndex(of: ":") else { return nil }
        var host = address[..<colon]
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        return host.isEmpty || host.contains("/") ? nil : host.lowercased()
    }

    // What to pass to `ssh -T` to meet the server once: `git@github.com` for either kind
    // of SSH address. Nil when a port is involved, since spelling that out reads worse
    // than the general advice.
    private static func sshTarget(of address: String) -> String? {
        let address = address.trimmed
        if address.contains("://") {
            guard let components = URLComponents(string: address),
                  components.scheme?.lowercased() == "ssh", components.port == nil,
                  let host = components.host else { return nil }
            return components.user.map { "\($0)@\(host)" } ?? host
        }
        guard let colon = address.firstIndex(of: ":"), host(of: address) != nil else { return nil }
        return String(address[..<colon])
    }
}
