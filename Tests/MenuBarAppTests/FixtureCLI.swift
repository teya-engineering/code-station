import Foundation

// The fake CLIs that the runner tests spawn are shell scripts, and most of them have to sit
// and wait for the test to let them through. Nothing outside the test stops them, so a run
// that is killed part way leaves a script spinning on a marker file that can never arrive.
// Every script is therefore given `wait_for`, which gives up once its own folder is gone or
// once it has waited far longer than any test does. Leftovers then die on their own instead
// of piling up as orphans.
enum FixtureCLI {
    // 1500 turns of the loop is about a minute, since each turn costs the fork for `sleep` on
    // top of the sleep itself. That is far longer than any test waits, so a slow machine is
    // never cut off, and it is still a firm bound on how long a leftover can sit there.
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

    // Writes `script` as an executable fake CLI at `url`, with the preamble in front of it.
    static func write(_ script: String, to url: URL) throws {
        try Data((preamble + "\n" + script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: url.path)
    }
}
