import CodeStationCore
import Foundation
import Testing

// The few helpers the TUI tests share with the app's suite. They are copied rather than
// shared because the app's test target links AppKit, which a TUI test must never need.

// Polls until the condition holds or the timeout passes. Returns whether it held. The
// timeout is measured on the suspending clock, so time the Mac spends asleep is not counted.
func waitUntil(timeout: Duration = .seconds(30),
               isolation: isolated (any Actor)? = #isolation,
               _ condition: () -> Bool) async -> Bool {
    let deadline = SuspendingClock.now + timeout
    while SuspendingClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

// Lets a test's own preferences suite go, file and all. Removing the domain alone
// leaves an empty plist behind in ~/Library/Preferences, one per test run.
func removeScratchDefaults(_ suite: String) {
    UserDefaults.standard.removePersistentDomain(forName: suite)
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(suite).plist")
    try? FileManager.default.removeItem(at: file)
}

// A throwaway folder under the temp directory, removed when the value goes away.
final class ScratchDirectory: @unchecked Sendable {
    let url: URL

    init(prefix: String = "code-station-tui-test") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }
}

// The fake agents are shell scripts. `wait_for` gives up once the script's folder is gone,
// so a test that fails part way never leaves one spinning.
enum FixtureCLI {
    private static let preamble = """
    #!/bin/sh
    folder=$(dirname "$0")
    wait_for() {
        waited=0
        while [ ! -f "$1" ]; do
            [ -d "$folder" ] || exit 1
            [ "$waited" -ge 1500 ] && exit 1
            waited=$((waited + 1))
            sleep 0.02
        done
    }
    """

    static func write(_ script: String, to url: URL) throws {
        try Data((preamble + "\n" + script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
