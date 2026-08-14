import Foundation

// The request written out as a curl command, so a call that works here can be pasted
// into a terminal or handed to someone else without being rebuilt by hand. It is built
// from the same resolved request that a send uses, token and all, so the two agree.
enum CurlCommand {
    static func text(for request: SavedRequest, environment: ApiEnvironment,
                     authorization: String?) -> String {
        let resolved = DispatchRunner.resolve(request, environment: environment,
                                              authorization: authorization)
        var parts = ["curl"]
        // curl sends GET on its own, so naming it is only noise.
        if request.method != .get {
            parts.append("-X \(request.method.rawValue)")
        }
        parts.append(quoted(resolved.url))
        for header in resolved.headers {
            parts.append("-H \(quoted("\(header.key): \(header.value)"))")
        }
        if let body = resolved.body {
            // --data-raw rather than --data, so a body starting with @ is sent as text
            // instead of being read as a file name.
            parts.append("--data-raw \(quoted(body))")
        }
        // One argument per line, since these commands are long enough to need scrolling
        // otherwise, and the shape of the request is easier to read down a column.
        return parts.joined(separator: " \\\n  ")
    }

    // Single quotes keep the shell out of the value: nothing inside them is expanded. A
    // quote in the value itself has to close the run, escape itself and open a new one.
    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
