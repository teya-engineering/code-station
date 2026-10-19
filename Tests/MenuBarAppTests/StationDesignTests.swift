import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): a session's Design
// conversation as the GUI's Design tab drives it, for a client that cannot draw the
// canvas. Starting one, the screens it drew as files to open in a browser, its ambition,
// approving the canvas, and handing it to the Build.
@MainActor
struct StationDesignTests {

    private static let silent = """
    IFS= read -r input
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
    printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}'
    """

    private func draw(_ html: String, for conversationID: String, in store: ProjectStore) throws {
        let conversation = try #require(UUID(uuidString: conversationID).flatMap(store.session))
        let artifact = try #require(store.designArtifactURL(for: conversation))
        try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(html.utf8).write(to: artifact)
    }

    // A session with no Design offers to start one. Starting it opens a conversation
    // behind the session, which a client opens as the session's Design conversation;
    // the canvas has nothing on it until the agent draws.
    @Test(arguments: StationImplementation.allCases)
    func startingADesignOpensAConversationBehindTheSession(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.silent, host: RecordingHost())
        defer { fixture.tearDown() }
        let commands = kind.connect(to: StationCommands(store: fixture.store, runner: fixture.runner))
        let id = fixture.session.id.uuidString

        let before = try await commands.readDesign(id)
        #expect(before.stage == .none)
        #expect(before.conversationID == nil)

        let started = try await commands.startDesign(id)
        #expect(started.stage == .designing)
        let conversationID = try #require(started.conversationID)
        #expect(conversationID != id)
        #expect(started.conversationIsSession == false)
        #expect(started.screens.isEmpty)
        #expect(started.canImplement == false)
        #expect(fixture.store.designSession(for: fixture.session.id)?.id.uuidString == conversationID)

        let opened = try await commands.openSession(id, conversation: .design)
        #expect(opened?.snapshot.sessionID == conversationID)

        // Starting again finds the same conversation, and naming the conversation reads
        // the session it belongs to.
        #expect(try await commands.startDesign(id).conversationID == conversationID)
        #expect(try await commands.readDesign(conversationID).sessionID == id)
        await #expect(throws: StationRefusal.self) { try await commands.readDesign(UUID().uuidString) }
    }

    // What the agent drew shows as its screens, each a file on the host to open in a
    // browser. The ambition is the conversation's own run setting.
    @Test(arguments: StationImplementation.allCases)
    func theCanvasIsListedAsFilesAndTheAmbitionFollowsTheRunSetting(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.silent, host: RecordingHost())
        defer { fixture.tearDown() }
        let commands = kind.connect(to: StationCommands(store: fixture.store, runner: fixture.runner))
        let id = fixture.session.id.uuidString
        let conversationID = try #require(try await commands.startDesign(id).conversationID)

        try draw("<html>Checkout</html>", for: conversationID, in: fixture.store)
        let drawn = try await commands.readDesign(id)

        let screen = try #require(drawn.screens.first)
        #expect(drawn.screens.count == 1)
        #expect(screen.title == "Canvas")
        #expect(screen.path == "index.html")
        let url = try #require(URL(string: screen.url))
        #expect(url.isFileURL)
        #expect(try String(contentsOf: url, encoding: .utf8) == "<html>Checkout</html>")
        #expect(drawn.canImplement)

        _ = try await commands.changeRunSetting(conversationID, "designAmbition", to: "all-out")
        #expect(try await commands.readDesign(id).ambition == "All out")
        _ = try await commands.changeRunSetting(conversationID, "designAmbition", to: "restrained")
        #expect(try await commands.readDesign(id).ambition == "Restrained")
    }

    // Approving saves the canvas as an approved version. Approving the same files again
    // approves that version rather than saving another; an empty canvas is refused.
    @Test(arguments: StationImplementation.allCases)
    func approvingSavesTheCanvasOnce(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.silent, host: RecordingHost())
        defer { fixture.tearDown() }
        let commands = kind.connect(to: StationCommands(store: fixture.store, runner: fixture.runner))
        let id = fixture.session.id.uuidString
        let conversationID = try #require(try await commands.startDesign(id).conversationID)

        await #expect(throws: StationRefusal.self) { try await commands.approveDesign(id) }

        try draw("<html>One</html>", for: conversationID, in: fixture.store)
        let approved = try await commands.approveDesign(id)
        #expect(approved.revisions.map(\.title) == ["Design v1"])
        #expect(approved.revisions.map(\.approved) == [true])

        let again = try await commands.approveDesign(id)
        #expect(again.revisions.map(\.title) == ["Design v1"])

        try draw("<html>Two</html>", for: conversationID, in: fixture.store)
        let second = try await commands.approveDesign(id)
        #expect(second.revisions.map(\.title) == ["Design v2", "Design v1"])
        #expect(second.revisions.map(\.approved) == [true, false])
    }

    // Implementing approves the canvas and hands it to the session it was started from,
    // which becomes the Build and is told to implement it with the guidance given. A
    // later change on the canvas puts the Build behind, and implementing again sends it
    // the newer version.
    @Test(arguments: StationImplementation.allCases)
    func implementingHandsTheDesignToTheBuild(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.silent, host: RecordingHost())
        defer { fixture.tearDown() }
        let commands = kind.connect(to: StationCommands(store: fixture.store, runner: fixture.runner))
        let id = fixture.session.id.uuidString
        let conversationID = try #require(try await commands.startDesign(id).conversationID)
        try draw("<html>One</html>", for: conversationID, in: fixture.store)

        let buildID = try await commands.implementDesign(id, additionalContext: "Keep the header.")

        #expect(buildID == id)
        #expect(fixture.store.transcript(of: fixture.session.id).contains {
            $0.text.contains("Implementation started from Design v1")
                && $0.text.contains("Additional context:\nKeep the header.")
        })
        #expect(await waitUntil { !fixture.runner.state(fixture.session.id).isBusy })
        let handed = try await commands.readDesign(id)
        #expect(handed.buildID == id)
        #expect(handed.buildIsCurrent)
        #expect(handed.revisions.first?.handedOff == true)

        try draw("<html>Two</html>", for: conversationID, in: fixture.store)
        #expect(try await commands.readDesign(id).buildIsCurrent == false)

        #expect(try await commands.implementDesign(id, additionalContext: nil) == id)
        #expect(await waitUntil { !fixture.runner.state(fixture.session.id).isBusy })
        let updated = try await commands.readDesign(id)
        #expect(updated.buildIsCurrent)
        #expect(updated.revisions.first?.title == "Design v2")
        #expect(fixture.store.transcript(of: fixture.session.id).contains {
            $0.text == "The implementation reference was updated to Design v2."
        })
    }
}
