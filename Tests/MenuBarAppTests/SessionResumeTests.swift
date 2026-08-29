import Foundation
import Testing
@testable import MenuBarApp

struct SessionResumeTests {
    private let projectPath = "/tmp/resume-project"

    @Test func summarizesEvidenceSinceTheLastVisit() throws {
        let seenAt = Date(timeIntervalSince1970: 1_800_000_000)
        let request = ChatMessage(role: .user, text: "Fix the retry order")
        let initialReply = ChatMessage(role: .assistant, text: "I will inspect it.")
        let boundary = SessionResumeBoundary(
            messages: [request, initialReply], seenAt: seenAt)
        let editInput = #"{"file_path":"/tmp/resume-project/Sources/App.swift","old_string":"old","new_string":"new"}"#
        let completed = [
            ToolUse(id: "edit-\(UUID())", name: "Edit", input: editInput, result: "ok"),
            ToolUse(id: "test-\(UUID())", name: "Bash", input: "swift test", result: "ok"),
            ToolUse(id: "lint-\(UUID())", name: "Bash", input: "swift lint",
                    result: "lint failed", isError: true)
        ]
        let finalReply = ChatMessage(
            role: .assistant,
            text: "I am applying the change.\n\n# Implemented the retry change.\nThe focused tests pass.",
            tools: completed)

        let brief = try #require(SessionResumeBrief.make(
            messages: [request, initialReply, finalReply],
            boundary: boundary,
            projectPath: projectPath))

        #expect(brief.seenAt == seenAt)
        #expect(brief.lastRequest == "Fix the retry order")
        #expect(brief.agentReport == "Implemented the retry change.")
        #expect(brief.completedCalls == 3)
        #expect(brief.failedCalls == 1)
        #expect(brief.runningCalls == 0)
        #expect(brief.changedFiles == 1)
        #expect(brief.added == 1)
        #expect(brief.removed == 1)
    }

    @Test func noticesACallThatFinishedInsideTheExistingReply() throws {
        let request = ChatMessage(role: .user, text: "Run the tests")
        var reply = ChatMessage(
            role: .assistant,
            tools: [ToolUse(id: "running-\(UUID())", name: "Bash", input: "swift test")])
        let boundary = SessionResumeBoundary(messages: [request, reply])

        reply.text = "All tests passed."
        reply.tools[0].result = "ok"
        let brief = try #require(SessionResumeBrief.make(
            messages: [request, reply], boundary: boundary, projectPath: projectPath))

        #expect(brief.agentReport == "All tests passed.")
        #expect(brief.completedCalls == 1)
        #expect(brief.failedCalls == 0)
        #expect(brief.runningCalls == 0)
    }

    @Test func quotesOnlyTextThatArrivedAfterTheBoundary() throws {
        let request = ChatMessage(role: .user, text: "Explain the result")
        var reply = ChatMessage(role: .assistant, text: "Already read.\n")
        let boundary = SessionResumeBoundary(messages: [request, reply])

        reply.text += "New result is ready."
        let brief = try #require(SessionResumeBrief.make(
            messages: [request, reply], boundary: boundary, projectPath: projectPath))

        #expect(brief.agentReport == "New result is ready.")
    }

    @Test func makesNoBriefWhenTheTranscriptHasNotChanged() {
        let messages = [ChatMessage(role: .user, text: "Nothing new")]
        let boundary = SessionResumeBoundary(messages: messages)

        #expect(SessionResumeBrief.make(
            messages: messages, boundary: boundary, projectPath: projectPath) == nil)
    }
}

@MainActor
struct SessionResumeStoreTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let project: Project

    init() throws {
        (store, scratch) = TestStore.make()
        project = try TestStore.project(in: store)
    }

    @Test func persistsTheBoundaryWhenLeavingASession() throws {
        let session = store.newSession(in: project.id)
        let request = ChatMessage(role: .user, text: "Keep my place")
        let reply = ChatMessage(role: .assistant, text: "This is where you stopped.")
        store.append(request, to: session.id)
        store.append(reply, to: session.id)

        store.selectHome()
        #expect(store.save())

        let boundary = try #require(store.session(session.id)?.resumeBoundary)
        #expect(boundary.messageID == reply.id)
        #expect(boundary.textLength == reply.text.count)

        let reloaded = try #require(ProjectStore(storeURL: store.storeURL).session(session.id))
        let reloadedBoundary = try #require(reloaded.resumeBoundary)
        #expect(reloadedBoundary.messageID == boundary.messageID)
        #expect(reloadedBoundary.textLength == boundary.textLength)
        #expect(reloadedBoundary.toolCount == boundary.toolCount)
        #expect(reloadedBoundary.pendingToolIDs == boundary.pendingToolIDs)
        #expect(abs(reloadedBoundary.seenAt.timeIntervalSince(boundary.seenAt)) < 1)
    }
}
