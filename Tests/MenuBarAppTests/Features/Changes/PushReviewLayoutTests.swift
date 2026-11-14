import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct PushReviewLayoutTests {
    @Test func longCommitErrorsKeepTheirActionsInsideTheWindow() async throws {
        let presenter = DialogPresenter()
        presenter.show(Dialog(title: "Could not create the commit",
            message: "Your message and selected files have been kept.\n\n"
                + String(repeating: "error: gpg failed to sign the data\n", count: 40),
            actions: [.init(label: "Try again", kind: .primary), .init(label: "Back to changes", kind: .cancel)],
            width: 500, isModal: true, fitsWindow: true))
        let host = NSHostingController(rootView: Theme.background.overlay { DialogHost() }.environment(presenter))
        host.sizingOptions = []
        let size = CGSize(width: 640, height: 360)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = host
        window.setContentSize(size)
        window.center()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.view.layoutSubtreeIfNeeded()
        #expect(host.view.bounds.size == size)
        #expect(host.sizeThatFits(in: size).height <= size.height)
        if let folder = ProcessInfo.processInfo.environment["WORKSPACE_REVIEW_DIRECTORY"] {
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("commit-error-short.png"))
        }
        presenter.dismiss()
        window.contentViewController = nil
    }

    @Test func reviewKeepsItsIdentityAndFitsShortWindowsAcrossAllStates() async throws {
        for dark in [false, true] {
            let scenario = PushLayoutScenario()
            let model = PushReviewModel(read: { await scenario.read() }, pull: { .upToDate },
                                        push: { _ in await scenario.push() })
            let presenter = DialogPresenter()
            presenter.show(Dialog(title: "Review your push", content: AnyView(
                PushReviewView(model: model, repository: "code-station", branch: "refine-commit-flow",
                               upstream: "origin/refine-commit-flow", changed: {})),
                actions: [], width: 560, isModal: true, framesItself: true, fitsWindow: true, hugsContent: true,
                maximumHeight: 480, canDismiss: { !model.isWorking }))
            let identity = presenter.current?.id
            let host = NSHostingController(rootView: Theme.background.overlay { DialogHost() }
                .environment(presenter).environment(TooltipPresenter())
                .environment(\.colorScheme, dark ? .dark : .light)
                .transaction { $0.disablesAnimations = true })
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.center()
            window.layoutIfNeeded()
            #expect(await waitUntil { scenario.reading != nil })
            for phase in [PushReviewModel.Phase.loading, .ready, .pushing, .failed, .complete] {
                #expect(model.phase == phase)
                for size in [CGSize(width: 1000, height: 760), CGSize(width: 640, height: 440)] {
                    window.setContentSize(size)
                    try await Task.sleep(for: .milliseconds(180))
                    host.view.layoutSubtreeIfNeeded()
                    let measured = host.sizeThatFits(in: size)
                    #expect(measured.width <= size.width)
                    #expect(measured.height <= size.height)
                    #expect(presenter.current?.id == identity)
                    if let folder = ProcessInfo.processInfo.environment["WORKSPACE_REVIEW_DIRECTORY"] {
                        let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                        try #require(bitmap.representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: folder)
                                .appendingPathComponent("push-\(phase)-\(dark ? "dark" : "light")-\(Int(size.height)).png"))
                    }
                }
                switch phase {
                case .loading:
                    scenario.reading?.resume(returning: .commits(scenario.commits))
                    scenario.reading = nil
                    #expect(await waitUntil { model.phase == .ready })
                case .ready:
                    Task { await model.send() }
                    #expect(await waitUntil { scenario.writing != nil })
                case .pushing:
                    presenter.dismiss()
                    #expect(presenter.current?.id == identity)
                    scenario.writing?.resume(returning: "ssh: connect to host github.com port 22: Operation timed out")
                    scenario.writing = nil
                    #expect(await waitUntil { model.phase == .failed })
                case .failed:
                    Task { await model.load() }
                    #expect(await waitUntil { scenario.reading != nil })
                    scenario.reading?.resume(returning: .commits(scenario.commits))
                    scenario.reading = nil
                    #expect(await waitUntil { model.phase == .ready })
                    Task { await model.send() }
                    #expect(await waitUntil { scenario.writing != nil })
                    scenario.writing?.resume(returning: nil)
                    scenario.writing = nil
                    #expect(await waitUntil { model.phase == .complete })
                default: break
                }
            }
            presenter.dismiss()
            window.contentViewController = nil
        }
    }

    // Five commits show whole at the dialog's width, a long list stops at its cap and
    // scrolls inside, and the dialog stands only as tall as what it holds.
    @Test func commitListShowsFiveRowsWholeAndCapsLongerLists() async throws {
        let commits = (0..<12).map { GitRemoteCommit(id: String(format: "%08x", $0), subject: "Commit number \($0)") }
        func height(_ count: Int) -> CGFloat {
            let host = NSHostingController(rootView: RemoteCommitList(commits: Array(commits.prefix(count)),
                                                                      emptyMessage: "").frame(width: 520))
            return host.sizeThatFits(in: CGSize(width: 520, height: 2000)).height
        }
        #expect(height(5) > 5 * 26)
        #expect(height(5) < 222)
        #expect(height(12) == 222)

        for (upstream, preview) in [("origin/main", GitPushPreview.commits(Array(commits.prefix(5)))),
                                    (nil, .commits(Array(commits.prefix(3)))),
                                    ("origin/main", .behindUpstream(incoming: Array(commits.prefix(2)),
                                                                    outgoing: Array(commits.prefix(5)))),
                                    (nil, .nameOnOrigin(outgoing: Array(commits.prefix(2)),
                                                        unrelated: Array(commits.prefix(3)), tip: "0ld71p"))] {
            let model = PushReviewModel(read: { preview }, pull: { .upToDate }, push: { _ in nil })
            await model.load()
            let presenter = DialogPresenter()
            let view = PushReviewView(model: model, repository: "code-station",
                                      branch: "feature/slide-map-and-night-scene-with-a-long-name",
                                      upstream: upstream, changed: {})
                .environment(presenter).environment(TooltipPresenter())
            let host = NSHostingController(rootView: HuggingHeight(limit: 480) { view }.frame(width: 560))
            let measured = host.sizeThatFits(in: CGSize(width: 560, height: 480))
            #expect(measured.width == 560)
            #expect(model.phase == .ready)
            // Two lists outgrow the cap, and the body scrolls instead of the dialog growing.
            if case .nameOnOrigin = preview { #expect(measured.height <= 480) }
            else if case .behindUpstream = preview { #expect(measured.height == 480) }
            else { #expect(measured.height < 480) }
        }
    }
}

@MainActor
private final class PushLayoutScenario {
    let commits = [GitRemoteCommit(id: "a1b2c3d4", subject: "Keep repository drafts when switching projects"),
                   GitRemoteCommit(id: "e5f6a7b8", subject: "Restore focus after closing a dialog")]
    var reading: CheckedContinuation<GitPushPreview, Never>?
    var writing: CheckedContinuation<String?, Never>?

    func read() async -> GitPushPreview {
        await withCheckedContinuation { reading = $0 }
    }

    func push() async -> String? {
        await withCheckedContinuation { writing = $0 }
    }
}
