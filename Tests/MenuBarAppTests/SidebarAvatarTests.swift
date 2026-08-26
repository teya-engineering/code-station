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
        ] {
            #expect(animated.contains(timing))
        }
        #expect(!still.contains("data:image/svg+xml"))
        #expect(!animated.contains("data:image/svg+xml"))
    }

    @Test func offersEveryRequestedStyleAndKeepsStripesStill() {
        #expect(DiceBearAvatarStyle.allCases.map(\.rawValue) == [
            "squircles", "planets", "shapes", "blobs", "waves", "sprouts", "stripes",
            "landscape"
        ])
        #expect(DiceBearAvatarStyle.available(for: .still).contains(.stripes))
        #expect(!DiceBearAvatarStyle.available(for: .animated).contains(.stripes))
    }
}
