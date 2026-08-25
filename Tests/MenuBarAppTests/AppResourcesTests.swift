import Foundation
import Testing
@testable import MenuBarApp

// The fonts and artwork are read through one bundle, so a build that cannot find it looks
// like an app with no type and no avatars rather than a missing file.
struct AppResourcesTests {

    @Test func findsTheFont() {
        #expect(AppResources.bundle.url(forResource: "Sora-Variable", withExtension: "ttf") != nil)
    }

    @Test func findsEveryAvatar() {
        for personality in AgentPersonality.allCases {
            #expect(AppResources.bundle.url(forResource: "avatar-\(personality.rawValue)",
                                            withExtension: "png") != nil)
        }

        for index in 1...AgentAvatarArt.sessionArtworkCount {
            #expect(AppResources.bundle.url(
                forResource: String(format: "avatar-moods-%02d", index),
                withExtension: "png") != nil)
        }
    }
}
