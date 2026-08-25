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

    @Test func findsEveryOfflineAvatar() {
        for style in DiceBearAvatarStyle.allCases {
            for index in 1...SidebarAvatar.artworkCount {
                let url = SidebarAvatar.artworkURL(style: style, index: index)
                #expect(url?.isFileURL == true)
                if let url {
                    #expect(NSImage(contentsOf: url) != nil)
                }
            }
        }
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

    @Test func offersEveryRequestedStyleAndKeepsStripesStill() {
        #expect(DiceBearAvatarStyle.allCases.map(\.rawValue) == [
            "squircles", "planets", "shapes", "blobs", "waves", "sprouts", "stripes",
            "landscape"
        ])
        #expect(DiceBearAvatarStyle.available(for: .still).contains(.stripes))
        #expect(!DiceBearAvatarStyle.available(for: .animated).contains(.stripes))
    }
}
