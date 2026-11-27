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

    // A fake `kiro-cli acp`: one JSON-RPC request per line on stdin, each answered on
    // stdout. Opening a session answers by itself; `onPrompt` runs for every prompt with
    // the request in `$line` and its id in `$id`, says things with `kiro_say` (one chunk
    // each), thinks with `kiro_think`, calls a tool with `kiro_tool <id>`, reports what
    // the turn cost with `kiro_credits <amount>`, and ends the turn with `kiro_end`. JSONSerialization writes "/" as "\\/", so methods are
    // matched by the part after the slash.
    static func kiroServer(onPrompt: String) -> String {
        """
        kiro_say() {
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"kiro-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"'"$1"'"}}}}'
        }
        kiro_think() {
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"kiro-1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"'"$1"'"}}}}'
        }
        kiro_tool() {
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"kiro-1","update":{"sessionUpdate":"tool_call","toolCallId":"'"$1"'","title":"Read File","kind":"read","status":"completed","rawInput":{"path":"notes.txt"},"rawOutput":{"message":"hello"}}}}'
        }
        kiro_credits() {
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"kiro-1","update":{"sessionUpdate":"session_info_update","_meta":{"kiro":{"kind":"turn_completion","promptTurnSummaries":[{"unit":"credit","unitPlural":"credits","usage":'"$1"'}]}}}}}'
        }
        kiro_end() {
            printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\\n' "$id"
        }
        while IFS= read -r line; do
            id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
            case "$line" in
                *'"initialize"'*)
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\\n' "$id" ;;
                *'/new"'*|*'/load"'*)
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"kiro-1"}}\\n' "$id" ;;
                *'set_config_option'*)
                    printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id" ;;
                *'/prompt"'*)
        \(onPrompt)
                    ;;
            esac
        done
        """
    }

    // Writes `script` as an executable fake CLI at `url`, with the preamble in front of it.
    static func write(_ script: String, to url: URL) throws {
        try Data((preamble + "\n" + script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: url.path)
    }
}
