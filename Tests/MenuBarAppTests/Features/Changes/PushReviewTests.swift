import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct PushReviewTests {
    private let commit = GitRemoteCommit(id: "12345678", subject: "Keep local work")
    private let incomingCommit = GitRemoteCommit(id: "abcdef12", subject: "Work from origin")
    private let incomingCommit2 = GitRemoteCommit(id: "fedcba98", subject: "More work from origin")

    @Test func secondaryTextMeetsContrastOnReviewSurfaces() throws {
        for appearance in try appearances() {
            let ink = try swatch(Theme.secondaryText, in: appearance)
            for colour in [Theme.background, Theme.card, Theme.sidebar] {
                let surface = try swatch(colour, in: appearance)
                #expect(ink.over(surface).contrast(against: surface) >= 4.5)
            }
            let field = try swatch(Theme.field, in: appearance).over(swatch(Theme.card, in: appearance))
            #expect(ink.over(field).contrast(against: field) >= 4.5)
        }
    }

    @Test func dismissedPreviewCannotPublishItsResult() async {
        let reads = PushPreviewReads()
        let model = PushReviewModel(read: { await reads.read() }, pull: { .upToDate }, push: { _ in nil })
        let task = Task { await model.load() }
        #expect(await waitUntil { reads.pending.count == 1 })
        model.invalidate()
        reads.pending[0].resume(returning: .commits([commit]))
        await task.value
        #expect(model.phase == .loading)
        #expect(model.commits.isEmpty)
    }

    @Test func aNewPreviewWinsOverAnOlderRead() async {
        let reads = PushPreviewReads()
        let model = PushReviewModel(read: { await reads.read() }, pull: { .upToDate }, push: { _ in nil })
        let first = Task { await model.load() }
        #expect(await waitUntil { reads.pending.count == 1 })
        let second = Task { await model.load() }
        #expect(await waitUntil { reads.pending.count == 2 })
        reads.pending[1].resume(returning: .behindUpstream(incoming: [incomingCommit, incomingCommit2], outgoing: [commit]))
        await second.value
        reads.pending[0].resume(returning: .commits([]))
        await first.value
        #expect(model.phase == .ready)
        #expect(model.commits == [commit])
        #expect(model.behind == 2)
    }

    @Test func cancelledReadCannotEnablePush() async {
        let reads = PushPreviewReads()
        let model = PushReviewModel(read: { await reads.read() }, pull: { .upToDate }, push: { _ in nil })
        let task = Task { await model.load() }
        #expect(await waitUntil { reads.pending.count == 1 })
        task.cancel()
        reads.pending[0].resume(returning: .commits([commit]))
        await task.value
        #expect(await model.send() == false)
    }

    @Test func pushRequiresAReviewAndRejectsDuplicateSubmission() async {
        let writes = PushWrites()
        let model = PushReviewModel(read: { .commits([commit]) }, pull: { .upToDate },
                                    push: { _ in await writes.push() })
        #expect(await model.send() == false)
        await model.load()
        let first = Task { await model.send() }
        #expect(await waitUntil { writes.pending != nil })
        #expect(model.phase == .pushing)
        #expect(await model.send() == false)
        let dialogs = DialogPresenter()
        dialogs.show(Dialog(title: "Push", actions: [], canDismiss: { !model.isWorking }))
        let identity = dialogs.current?.id
        dialogs.dismiss()
        #expect(dialogs.current?.id == identity)
        writes.pending?.resume(returning: nil)
        #expect(await first.value)
        #expect(model.phase == .complete)
        #expect(dialogs.current?.id == identity)
        dialogs.dismiss()
        #expect(dialogs.current == nil)
        #expect(writes.count == 1)
    }

    @Test func replacingOriginsBranchPinsThePushToTheReviewedTip() async {
        var sent: [String?] = []
        var reads = 0
        let model = PushReviewModel(read: {
            reads += 1
            return reads == 1 ? .nameOnOrigin(outgoing: [commit], unrelated: [incomingCommit], tip: "0ld71p")
                : .nameOnOrigin(outgoing: [commit], unrelated: [], tip: "0ld71p")
        }, pull: { Issue.record("Replacing must not pull"); return .upToDate }, push: { sent.append($0); return nil })
        await model.load()
        #expect(model.nameOnOrigin)
        #expect(model.replaced == [incomingCommit])
        #expect(model.behind == 0)
        #expect(await model.send())
        #expect(sent == ["0ld71p"])

        await model.load()
        #expect(model.nameOnOrigin)
        #expect(model.replaced.isEmpty)
        #expect(await model.send())
        #expect(sent == ["0ld71p", nil])
    }

    @Test func replacingARewrittenUpstreamPinsThePushAndDoesNotPull() async {
        var sent: [String?] = []
        let model = PushReviewModel(read: {
            .rewroteUpstream(outgoing: [commit], replaced: [incomingCommit], tip: "0ld71p")
        }, pull: { Issue.record("Replacing must not pull"); return .upToDate }, push: { sent.append($0); return nil })
        await model.load()
        #expect(model.rewrote)
        #expect(model.replaced == [incomingCommit])
        #expect(model.behind == 0)
        #expect(await model.send())
        #expect(sent == ["0ld71p"])
    }

    @Test func pullFailureStopsPushAndRetryRequiresFreshReview() async {
        var attempts = 0
        var pushes = 0
        let model = PushReviewModel(read: { .behindUpstream(incoming: [incomingCommit], outgoing: [commit]) }, pull: {
            attempts += 1
            return attempts == 1 ? .failed("Origin is unavailable") : .updated([])
        }, push: { _ in pushes += 1; return nil })
        await model.load()
        #expect(await model.send())
        #expect(model.phase == .failed)
        #expect(model.errorTitle == "Could not pull")
        #expect(model.commits == [commit])
        #expect(pushes == 0)
        #expect(await model.send() == false)
        await model.load()
        #expect(model.phase == .ready)
        #expect(pushes == 0)
        #expect(await model.send())
        #expect(model.phase == .complete)
        #expect(pushes == 1)
    }

    @Test func stashConflictSurvivesPushFailureAndRetry() async {
        var reads = 0
        var pushes = 0
        let incoming = GitRemoteCommit(id: "87654321", subject: "Origin work")
        let model = PushReviewModel(read: {
            reads += 1
            return reads == 1 ? .behindUpstream(incoming: [incomingCommit], outgoing: [commit]) : .commits([commit])
        }, pull: { .updatedWithStashConflict([incoming]) }, push: { _ in
            pushes += 1
            return pushes == 1 ? "Connection timed out" : nil
        })
        await model.load()
        #expect(await model.send())
        #expect(model.phase == .failed)
        #expect(model.errorTitle == "Could not push")
        #expect(model.stashConflict)
        await model.load()
        #expect(await model.send())
        #expect(model.phase == .complete)
        #expect(model.stashConflict)
        #expect(model.pulled == [incoming])
    }

    @Test func previewFailureCanBeRetriedWithoutSendingAnything() async {
        var reads = 0
        let model = PushReviewModel(read: {
            reads += 1
            return reads == 1 ? .failed("Cannot read repository") : .commits([])
        }, pull: { .upToDate }, push: { _ in Issue.record("Preview must not push"); return nil })
        await model.load()
        #expect(model.phase == .failed)
        #expect(await model.send() == false)
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.commits.isEmpty)
    }
}

@MainActor
private final class PushPreviewReads {
    var pending: [CheckedContinuation<GitPushPreview, Never>] = []

    func read() async -> GitPushPreview {
        await withCheckedContinuation { pending.append($0) }
    }
}

@MainActor
private final class PushWrites {
    var count = 0
    var pending: CheckedContinuation<String?, Never>?

    func push() async -> String? {
        count += 1
        return await withCheckedContinuation { pending = $0 }
    }
}
