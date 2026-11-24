import Foundation

// Why a call the agent has made a hundred times suddenly stops and asks. Claude Code's
// auto mode reads a call that reaches outside the folders the session was started with as
// a step up in scope and puts it to the person, so the answer is rarely about the command
// itself - it is about a folder the session cannot see. Finding that folder is what lets
// the card offer to open it up instead of asking again for every call that touches it.
extension PermissionRequest {
    // The folder this call reaches into that the session has no view of, or nil when
    // everything it names is already reachable. Only one is offered: a call that wanders
    // into several places is not a folder to add, it is a call to read before allowing.
    func directoryOutside(_ workingDirectories: [String]) -> String? {
        guard !workingDirectories.isEmpty else { return nil }
        let roots = workingDirectories.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        for candidate in namedPaths() {
            guard let directory = Self.offerable(candidate.path,
                                                orItsParent: candidate.namesAFile) else {
                continue
            }
            guard !roots.contains(where: { directory.pathRelative(to: $0) != nil }) else {
                continue
            }
            return directory
        }
        return nil
    }

    // A path a call spells out in full, and whether it is meant to be a file. A tool that
    // names a file may be about to write one that is not there yet, and the folder around
    // it is still the folder to open up. A path picked out of a shell line gets no such
    // benefit: guessing at one that is not there would offer a folder on the strength of
    // a typo.
    private struct NamedPath {
        let path: String
        let namesAFile: Bool
    }

    // Every path the call spells out in full. A relative path resolves against the folder
    // the agent already runs in, so it says nothing about what is missing.
    private func namedPaths() -> [NamedPath] {
        guard let raw = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
            return []
        }
        if let command = raw["command"] as? String {
            return Self.pathsIn(command).map { NamedPath(path: $0, namesAFile: false) }
        }
        return ["file_path", "path", "notebook_path"]
            .compactMap { raw[$0] as? String }
            .map { NamedPath(path: $0, namesAFile: true) }
    }

    // `cd` targets come first: in a compound command the folder it moves into is the one
    // the rest of the command works in, which makes it the folder worth adding.
    private static func pathsIn(_ command: String) -> [String] {
        let tokens = command
            .split(whereSeparator: { $0.isWhitespace || "|;&()".contains($0) })
            .map { token -> String in
                // A redirect keeps its target in the same token as the operator, so
                // "2>/dev/null" would otherwise read as a path of its own.
                var text = String(token)
                if let operatorIndex = text.lastIndex(where: { $0 == ">" || $0 == "<" }) {
                    text = String(text[text.index(after: operatorIndex)...])
                }
                return text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            }

        var moves: [String] = []
        var others: [String] = []
        for (position, token) in tokens.enumerated() {
            if token == "cd" {
                if position + 1 < tokens.count { moves.append(tokens[position + 1]) }
            } else if token.hasPrefix("/") || token.hasPrefix("~") || token.hasPrefix("$HOME") {
                others.append(token)
            }
        }
        return moves + others
    }

    // The folder to put on the button, or nil when this path is not one to open up. A
    // path that is not there yet says nothing, and the folders the sandbox exists to keep
    // out - the home folder itself, anything hidden, the system - are never on offer:
    // a one-click way into ~/.ssh would give away more than the prompt it saves.
    private static func offerable(_ path: String, orItsParent: Bool) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var expanded = path
        if expanded == "~" || expanded.hasPrefix("~/") { expanded = home + expanded.dropFirst() }
        if expanded.hasPrefix("$HOME") { expanded = home + expanded.dropFirst(5) }
        guard expanded.hasPrefix("/") else { return nil }

        var isDirectory: ObjCBool = false
        var url = URL(fileURLWithPath: expanded).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue { url = url.deletingLastPathComponent() }
        } else if orItsParent {
            url = url.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
        } else {
            return nil
        }
        url = url.resolvingSymlinksInPath()
        // A hidden folder is never the thing to open up; the project it sits in is.
        while url.lastPathComponent.hasPrefix("."), url.path != home, url.path != "/" {
            url = url.deletingLastPathComponent()
        }

        let directory = url.path
        guard directory != "/", directory != home else { return nil }
        guard !url.pathComponents.dropFirst().contains(where: { $0.hasPrefix(".") }) else {
            return nil
        }
        let closed = ["/bin", "/cores", "/dev", "/etc", "/net", "/opt", "/private", "/proc",
                      "/sbin", "/sys", "/tmp", "/usr", "/var", "/Applications", "/Library",
                      "/System", home + "/Library"]
        guard !closed.contains(where: { directory == $0 || directory.hasPrefix($0 + "/") }) else {
            return nil
        }
        return directory
    }
}
