import AppKit
import Foundation
import Testing
@testable import MenuBarApp

struct SidebarAvatarTests {
    @Test func createsStableDistinctSeedsForEachSidebarSubject() {
        let id = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!

        #expect(SidebarAvatar(subject: .project, id: id).seed
            == "project-deadbeef-dead-beef-dead-beefdeadbeef")
        #expect(SidebarAvatar(subject: .task, id: id).seed
            != SidebarAvatar(subject: .project, id: id).seed)
        #expect(SidebarAvatar(subject: .workspace, id: id).seed
            != SidebarAvatar(subject: .project, id: id).seed)
    }

    @Test func assignsStableBundledArtwork() {
        let avatar = SidebarAvatar(subject: .project, id: UUID())

        #expect(avatar.artworkIndex() == avatar.artworkIndex())
        #expect((1...SidebarAvatar.artworkCount).contains(avatar.artworkIndex()!))
        #expect(avatar.artworkURL(style: .planets)?.isFileURL == true)
    }

    @Test func usesAChosenArtworkAndAlwaysChoosesADifferentReplacement() {
        let avatar = SidebarAvatar(subject: .project, id: UUID(), artworkIndex: 3)

        #expect(avatar.artworkIndex(count: 4) == 3)
        for _ in 0..<100 {
            let replacement = avatar.randomArtworkIndex(count: 4)
            #expect(replacement != 3)
            #expect(replacement.map { (1...4).contains($0) } == true)
        }
    }

    @MainActor
    @Test func persistsChangedProjectTaskAndWorkspaceArtwork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-sidebar-avatar-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("projects.json")
        let store = ProjectStore(storeURL: storeURL)
        let first = try #require(store.addProject(at: root.appendingPathComponent("api")))
        let second = try #require(store.addProject(at: root.appendingPathComponent("web")))
        let task = try store.addTask(
            named: "Release",
            prompt: "Ship it.",
            in: root.appendingPathComponent("tasks"))
            .get()
        let workspace = try #require(store.addWorkspace(
            name: "Checkout",
            projectIDs: [first.id, second.id],
            leadProjectID: first.id))
        let originalProjectIndex = first.sidebarAvatar.artworkIndex()
        let originalTaskIndex = task.sidebarAvatar.artworkIndex()
        let originalWorkspaceIndex = workspace.sidebarAvatar.artworkIndex()

        store.changeSidebarAvatar(forProject: first.id)
        store.changeSidebarAvatar(forProject: task.id)
        store.changeSidebarAvatar(forWorkspace: workspace.id)

        let changedProjectIndex = try #require(store.project(first.id)?.sidebarAvatarIndex)
        let changedTaskIndex = try #require(store.project(task.id)?.sidebarAvatarIndex)
        let changedWorkspaceIndex = try #require(store.workspace(workspace.id)?.sidebarAvatarIndex)
        #expect(changedProjectIndex != originalProjectIndex)
        #expect(changedTaskIndex != originalTaskIndex)
        #expect(changedWorkspaceIndex != originalWorkspaceIndex)

        let restored = ProjectStore(storeURL: storeURL)
        #expect(restored.project(first.id)?.sidebarAvatarIndex == changedProjectIndex)
        #expect(restored.project(task.id)?.sidebarAvatarIndex == changedTaskIndex)
        #expect(restored.workspace(workspace.id)?.sidebarAvatarIndex == changedWorkspaceIndex)
    }

    @MainActor
    @Test func providesAStillPreviewForEveryArtworkStyle() {
        for style in DiceBearAvatarStyle.allCases {
            #expect(SidebarAvatar.preview.artworkImage(style: style) != nil)
        }
    }

    @MainActor
    @Test func resolvesTheSameIdentityTintAsTheSidebarRail() throws {
        let avatar = SidebarAvatar(subject: .project, id: UUID(), artworkIndex: 1)
        let monogramTint = Theme.projectTint(for: "Payments")
        let artworkColour = try #require(avatar.primaryColour(style: .blobs))

        let monogram = avatar.identityTint(
            iconSet: .monograms,
            style: .blobs,
            name: "Payments",
            monogramTint: monogramTint)
        let multiColourArtwork = avatar.identityTint(
            iconSet: .diceBear,
            style: .shapes,
            name: "Payments",
            monogramTint: Theme.workspaceTint)
        let singleColourArtwork = avatar.identityTint(
            iconSet: .diceBear,
            style: .blobs,
            name: "Payments",
            monogramTint: monogramTint)

        #expect(monogram.colour == monogramTint.colour)
        #expect(multiColourArtwork.colour == monogramTint.colour)
        #expect(singleColourArtwork.colour == artworkColour)
    }

    @Test func derivesMotionFromActiveSessionsInTheSameContainer() {
        let projectID = UUID()
        let workspaceID = UUID()
        let projectSession = ChatSession(projectID: projectID, agent: .codex)
        var workspaceSession = ChatSession(projectID: projectID, agent: .codex)
        workspaceSession.workspaceID = workspaceID
        let busy = Set([projectSession.id, workspaceSession.id])

        let project = SidebarAvatar(subject: .project, id: projectID)
        let task = SidebarAvatar(subject: .task, id: projectID)
        let workspace = SidebarAvatar(subject: .workspace, id: workspaceID)

        #expect(project.motion(sessions: [projectSession], isBusy: busy.contains) == .animated)
        #expect(task.motion(sessions: [projectSession], isBusy: busy.contains) == .animated)
        #expect(project.motion(sessions: [workspaceSession], isBusy: busy.contains) == .still)
        #expect(workspace.motion(sessions: [workspaceSession], isBusy: busy.contains) == .animated)
        #expect(workspace.motion(sessions: [projectSession], isBusy: busy.contains) == .still)
        #expect(project.motion(sessions: [projectSession], isBusy: { _ in false }) == .still)
    }

    @Test func findsEveryOfflineAvatar() throws {
        for style in DiceBearAvatarStyle.allCases {
            for index in 1...SidebarAvatar.artworkCount {
                let url = SidebarAvatar.artworkURL(style: style, index: index)
                #expect(url?.isFileURL == true)
                if let url {
                    let svg = try String(contentsOf: url, encoding: .utf8)
                    #expect(svg.hasPrefix("<svg"))
                    #expect((style.primaryColour(in: svg) != nil)
                        == style.usesArtworkPrimaryColour)
                }
            }
        }
    }

    @Test func readsTheArtworkBackgroundAsItsPrimaryColour() throws {
        let url = try #require(SidebarAvatar.artworkURL(style: .blobs, index: 1))
        let svg = try String(contentsOf: url, encoding: .utf8)

        #expect(DiceBearAvatarStyle.blobs.primaryColour(in: svg)?.rgb == 0xbe185d)
        #expect(DiceBearAvatarStyle.shapes.primaryColour(in: svg) == nil)
        #expect(DiceBearAvatarStyle.landscape.primaryColour(in: svg) == nil)

        let wider = try #require(SidebarAvatar.artworkURL(style: .botttsNeutral, index: 1))
        let widerSVG = try String(contentsOf: wider, encoding: .utf8)

        #expect(DiceBearAvatarStyle.botttsNeutral.primaryColour(in: widerSVG)?.rgb == 0x7681f5)
    }

    @Test func bundlesAnimationAndReducedMotionInTheSVG() throws {
        for style in DiceBearAvatarStyle.allCases {
            for index in 1...SidebarAvatar.artworkCount {
                let url = try #require(SidebarAvatar.artworkURL(style: style, index: index))
                let svg = try String(contentsOf: url, encoding: .utf8)
                #expect(svg.contains("@keyframes") == style.supportsAnimation)
                #expect(svg.contains("prefers-reduced-motion") == style.supportsAnimation)
            }
        }
    }

    @Test func usesWebKitOnlyForActiveAnimatedArtwork() {
        #expect(DiceBearAvatarStyle.squircles.usesWebAnimation(for: .animated))
        #expect(!DiceBearAvatarStyle.squircles.usesWebAnimation(for: .still))
        #expect(!DiceBearAvatarStyle.stripes.usesWebAnimation(for: .animated))
        #expect(!DiceBearAvatarStyle.weave.usesWebAnimation(for: .animated))
        #expect(!DiceBearAvatarStyle.botttsNeutral.usesWebAnimation(for: .animated))
    }

    @Test func rendersEveryStaticAvatarWithItsReferencedLayers() throws {
        for style in DiceBearAvatarStyle.allCases {
            for index in 1...SidebarAvatar.artworkCount {
                let url = try #require(SidebarAvatar.artworkURL(style: style, index: index))
                let source = try String(contentsOf: url, encoding: .utf8)
                let image = try #require(DiceBearAvatarDocument.stillImage(source: source))
                #expect(try renderedColourCount(image) > 1)
            }
        }
    }

    @Test func rendersReferencedLayersForStillAndAnimatedAvatars() throws {
        let url = try #require(SidebarAvatar.artworkURL(style: .waves, index: 1))
        let svg = try String(contentsOf: url, encoding: .utf8)
        let still = DiceBearAvatarDocument.html(source: svg, motion: .still)
        let animated = DiceBearAvatarDocument.html(source: svg, motion: .animated)

        #expect(still.contains("<body><svg"))
        #expect(still.contains("* { animation: none !important; }"))
        #expect(animated.contains("<body><svg"))
        for timing in [
            "--dbsq-t: 0.3 !important;",
            "--dbpa-t: 0.2 !important;",
            "--dbsh-t: 0.25 !important;",
            "--dbba-t: 0.3 !important;",
            "--dbwa-t: 0.25 !important;",
            "--dbsp-t: 0.55 !important;",
            "--dbla-t: 0.2 !important;",
            "--dbcr-t: 0.55 !important;",
            "--dbmo-t: 0.55 !important;",
        ] {
            #expect(animated.contains(timing))
        }
        #expect(!still.contains("data:image/svg+xml"))
        #expect(!animated.contains("data:image/svg+xml"))
    }

    @Test func offersEveryRequestedStyle() {
        #expect(DiceBearAvatarStyle.allCases.map(\.rawValue) == [
            "squircles", "planets", "shapes", "blobs", "waves", "sprouts", "stripes",
            "landscape", "weave", "critters", "moods", "bottts-neutral"
        ])
    }
}

private func renderedColourCount(_ image: NSImage) throws -> Int {
    let side = 64
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: side,
        pixelsHigh: side,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()

    var colours = Set<UInt32>()
    for y in 0..<side {
        for x in 0..<side {
            guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            let red = UInt32((colour.redComponent * 255).rounded())
            let green = UInt32((colour.greenComponent * 255).rounded())
            let blue = UInt32((colour.blueComponent * 255).rounded())
            colours.insert((red << 16) | (green << 8) | blue)
        }
    }
    return colours.count
}
