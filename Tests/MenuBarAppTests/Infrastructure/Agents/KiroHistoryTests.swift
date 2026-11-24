import Foundation
import Testing
@testable import MenuBarApp

// Importing past Kiro sessions. The fake answers the way kiro-cli 3.5.0 did: a list of the
// folder's sessions, a fork with a new id, and a load that replays the conversation.
struct KiroHistoryTests {
    private static let folder = "/tmp/kiro-history-project"

    private static func fakeKiro(in scratch: ScratchDirectory) throws -> URL {
        let executable = scratch.path("kiro-cli")
        let replay = { (update: String) in
            "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess_fork\",\"update\":\(update)}}'"
        }
        try FixtureCLI.write("""
            while IFS= read -r line; do
                id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
                case "$line" in
                    *'"initialize"'*)
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\\n' "$id" ;;
                    *'/list"'*)
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"sessions":[{"sessionId":"sess_old","cwd":"\(folder)","title":"Fix the login retry","updatedAt":"2026-11-19T23:42:46.054Z","_meta":{"kiro":{"createdAt":"2026-11-19T11:31:03.387Z","source":"local"}}},{"sessionId":"sess_cloud","cwd":"\(folder)","title":"In the cloud","_meta":{"kiro":{"source":"remote"}}},{"sessionId":"sess_other","cwd":"/elsewhere","title":"Other folder"},{"sessionId":"sess_blank","cwd":"\(folder)","title":"New Session"}]}}\\n' "$id" ;;
                    *'/fork"'*)
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"sess_fork"}}\\n' "$id" ;;
                    *'/load"'*)
                        \(replay(#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Fix the "},"_meta":{"kiro":{"messageId":"m1","timestamp":"2026-11-19T11:31:03.423Z","replay":true}}}"#))
                        \(replay(#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"login retry"},"_meta":{"kiro":{"messageId":"m1","timestamp":"2026-11-19T11:31:03.423Z","replay":true}}}"#))
                        \(replay(#"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Look first"},"_meta":{"kiro":{"timestamp":"2026-11-19T11:31:04.000Z","replay":true}}}"#))
                        \(replay(#"{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Read File","kind":"read","status":"pending","rawInput":{"path":"login.swift"},"_meta":{"kiro":{"replay":true}}}"#))
                        \(replay(#"{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","rawOutput":"retry()","_meta":{"kiro":{"replay":true}}}"#))
                        \(replay(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Fixed "},"_meta":{"kiro":{"replay":true}}}"#))
                        \(replay(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"it."},"_meta":{"kiro":{"replay":true}}}"#))
                        \(replay(#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Thanks"},"_meta":{"kiro":{"messageId":"m2","replay":true}}}"#))
                        \(replay(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Any time."},"_meta":{"kiro":{"replay":true}}}"#))
                        printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id" ;;
                esac
            done
            """, to: executable)
        return executable
    }

    @Test func listsOnlyThisFoldersSessionsOnThisMac() async throws {
        let scratch = ScratchDirectory(prefix: "kiro-history")
        let found = try await KiroHistoryReader.list(folder: Self.folder, root: scratch.url,
                                                     executable: try Self.fakeKiro(in: scratch).path)
        #expect(found.map(\.sessionID) == ["sess_old"])
        #expect(found.first?.agent == .kiro)
        #expect(found.first?.displayTitle == "Fix the login retry")
        #expect(found.first?.lastActivity == ClaudeTranscriptImport.date("2026-11-19T23:42:46.054Z"))
    }

    @Test func importsAForkSoTheOriginalStaysUntouched() async throws {
        let scratch = ScratchDirectory(prefix: "kiro-history")
        let executable = try Self.fakeKiro(in: scratch).path
        let candidate = try #require(try await KiroHistoryReader.list(folder: Self.folder, root: scratch.url,
                                                                      executable: executable).first)
        let reading = try await KiroHistoryReader.prepare(candidate, executable: executable)
        #expect(reading.resumeID == "sess_fork")
        #expect(reading.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(reading.messages.map(\.text) == ["Fix the login retry", "Fixed it.", "Thanks", "Any time."])
        #expect(reading.messages[0].date == ClaudeTranscriptImport.date("2026-11-19T11:31:03.423Z"))
        #expect(reading.messages[1].thinking?.map(\.text) == ["Look first"])
        #expect(reading.messages[1].tools.map(\.name) == ["Read"])
        #expect(reading.messages[1].tools.first?.result == "retry()")
    }

    // Runs against the real kiro-cli and a signed-in account; it forks a session to read it.
    @Test func readsARealKiroSession() async throws {
        guard ProcessInfo.processInfo.environment["CODE_STATION_LIVE_AGENT_TESTS"] == "1",
              let folder = ProcessInfo.processInfo.environment["CODE_STATION_LIVE_KIRO_FOLDER"] else { return }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro")
        let found = try await KiroHistoryReader.list(folder: ClaudeSessionCatalog.standardized(folder), root: root)
        let candidate = try #require(found.first)
        let reading = try await KiroHistoryReader.prepare(candidate)
        #expect(!reading.messages.isEmpty)
        #expect(reading.resumeID != candidate.sessionID)
        print("live kiro import:", candidate.displayTitle, reading.messages.map(\.role))
    }
}
