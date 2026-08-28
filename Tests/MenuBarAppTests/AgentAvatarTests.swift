import AppKit
import Foundation
import ImageIO
import Testing
@testable import MenuBarApp

struct AgentAvatarTests {
    private let scratch = ScratchDirectory(prefix: "agent-avatar-tests")
    private var root: URL { scratch.url }

    private func pngData(width: Int = 800, height: Int = 400) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: width, height: height))
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test @MainActor func keepsAPrivateDownscaledCopyAndRestoresIt() throws {
        let source = root.appendingPathComponent("source.png")
        let destination = root.appendingPathComponent("support/agent-avatar.png")
        try pngData().write(to: source)

        let settings = AppSettings(agentAvatarURL: destination)
        #expect(settings.agentAvatars.isEmpty)

        try settings.importAgentAvatars(from: [source])
        try FileManager.default.removeItem(at: source)

        #expect(settings.agentAvatars.count == 1)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let imageSource = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(
            imageSource, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(max(width, height) <= AgentAvatarFile.maxPixelSize)
        let restored = AppSettings(agentAvatarURL: destination).agentAvatars
        #expect(restored.count == 1)
        #expect(restored.first?.personality == .standard)
        #expect(restored.first?.usesStockArtwork == false)
    }

    @Test @MainActor func rejectsANonImageWithoutRemovingCurrentImages() throws {
        let source = root.appendingPathComponent("source.png")
        let invalid = root.appendingPathComponent("notes.txt")
        let destination = root.appendingPathComponent("agent-avatar.png")
        try pngData(width: 4, height: 4).write(to: source)
        try Data("not an image".utf8).write(to: invalid)
        let settings = AppSettings(agentAvatarURL: destination)
        try settings.importAgentAvatars(from: [source])
        let original = try Data(contentsOf: destination)

        #expect(throws: AgentAvatarError.self) {
            try settings.importAgentAvatars(from: [invalid])
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(settings.agentAvatars.count == 1)
    }

    @Test @MainActor func removesTheStoredImageAndReturnsToTheFallback() throws {
        let source = root.appendingPathComponent("source.png")
        let destination = root.appendingPathComponent("agent-avatar.png")
        try pngData(width: 4, height: 4).write(to: source)
        let settings = AppSettings(agentAvatarURL: destination)
        try settings.importAgentAvatars(from: [source])

        try settings.removeAgentAvatars()

        #expect(settings.agentAvatars.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test @MainActor func importsSeveralImagesAndRestoresTheirOrder() throws {
        let sources = try (1...3).map { index in
            let url = root.appendingPathComponent("source-\(index).png")
            try pngData(width: index * 10, height: index * 10).write(to: url)
            return url
        }
        let destination = root.appendingPathComponent("support/agent-avatar.png")
        let settings = AppSettings(agentAvatarURL: destination)

        try settings.importAgentAvatars(from: sources)

        #expect(settings.agentAvatars.map(\.url.lastPathComponent) == [
            "agent-avatar.png",
            "agent-avatar-2.png",
            "agent-avatar-3.png",
        ])
        #expect(AppSettings(agentAvatarURL: destination).agentAvatars.map(\.url.lastPathComponent) == [
            "agent-avatar.png",
            "agent-avatar-2.png",
            "agent-avatar-3.png",
        ])
    }

    @Test @MainActor func refusesToImportBeyondTheMaximumNumberOfBots() throws {
        let sources = try (1...AgentAvatarFile.maxCount + 1).map { index in
            let url = root.appendingPathComponent("source-\(index).png")
            try pngData(width: 4, height: 4).write(to: url)
            return url
        }
        let destination = root.appendingPathComponent("agent-avatar.png")
        let settings = AppSettings(agentAvatarURL: destination)
        try settings.importAgentAvatars(from: Array(sources.dropLast()))

        #expect(throws: AgentAvatarError.self) {
            try settings.importAgentAvatars(from: [sources[AgentAvatarFile.maxCount]])
        }

        #expect(settings.agentAvatars.count == AgentAvatarFile.maxCount)
        #expect(AppSettings(agentAvatarURL: destination)
            .agentAvatars.count == AgentAvatarFile.maxCount)
    }

    @Test @MainActor func rejectsABatchThatWouldExceedTheMaximumWithoutImportingAnyOfIt() throws {
        let sources = try (1...AgentAvatarFile.maxCount + 1).map { index in
            let url = root.appendingPathComponent("source-\(index).png")
            try pngData(width: 4, height: 4).write(to: url)
            return url
        }
        let destination = root.appendingPathComponent("agent-avatar.png")
        let settings = AppSettings(agentAvatarURL: destination)

        #expect(throws: AgentAvatarError.self) {
            try settings.importAgentAvatars(from: sources)
        }

        #expect(settings.agentAvatars.isEmpty)
    }

    @Test @MainActor func removesOneImageWithoutChangingTheOthers() throws {
        let sources = try (1...3).map { index in
            let url = root.appendingPathComponent("source-\(index).png")
            try pngData(width: index * 10, height: index * 10).write(to: url)
            return url
        }
        let destination = root.appendingPathComponent("agent-avatar.png")
        let settings = AppSettings(agentAvatarURL: destination)
        try settings.importAgentAvatars(from: sources)
        let second = try #require(settings.agentAvatars.dropFirst().first)

        try settings.removeAgentAvatar(second)

        #expect(settings.agentAvatars.map(\.url.lastPathComponent) == [
            "agent-avatar.png",
            "agent-avatar-3.png",
        ])
        #expect(FileManager.default.fileExists(atPath: second.url.path) == false)
    }

    @Test @MainActor func usesTheBuiltInDefaultUntilAnotherBotIsChosen() throws {
        let suite = "agent-avatar-default-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources = try (1...2).map { index in
            let url = root.appendingPathComponent("source-\(index).png")
            try pngData(width: index * 10, height: index * 10).write(to: url)
            return url
        }
        let destination = root.appendingPathComponent("agent-avatar.png")
        let settings = AppSettings(agentAvatarURL: destination, preferences: defaults)

        #expect(settings.defaultAgentAvatarName == AgentAvatarSelection.defaultName)

        try settings.importAgentAvatars(from: sources)
        let secondName = try #require(settings.agentAvatars.last?.url.lastPathComponent)
        #expect(settings.defaultAgentAvatarName == AgentAvatarSelection.defaultName)
        #expect(AgentAvatarSelection.avatar(named: nil, from: settings.agentAvatars)
            .url.lastPathComponent == AgentAvatarSelection.defaultName)
        #expect(AgentAvatarSelection.avatar(named: nil, from: settings.agentAvatars)
            .personality == .standard)

        settings.setDefaultAgentAvatarName(secondName)
        #expect(AppSettings(agentAvatarURL: destination, preferences: defaults)
            .defaultAgentAvatarName == secondName)

        settings.setDefaultAgentAvatarName(AgentAvatarSelection.defaultName)
        #expect(AppSettings(agentAvatarURL: destination, preferences: defaults)
            .defaultAgentAvatarName == AgentAvatarSelection.defaultName)
    }

    @Test @MainActor func removingTheChosenDefaultUsesTheBuiltInBot() throws {
        let suite = "agent-avatar-removal-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources = try (1...2).map { index in
            let url = root.appendingPathComponent("source-\(index).png")
            try pngData(width: index * 10, height: index * 10).write(to: url)
            return url
        }
        let destination = root.appendingPathComponent("agent-avatar.png")
        let settings = AppSettings(agentAvatarURL: destination, preferences: defaults)
        try settings.importAgentAvatars(from: sources)
        let first = try #require(settings.agentAvatars.first)

        settings.setDefaultAgentAvatarName(first.url.lastPathComponent)
        try settings.removeAgentAvatar(first)

        #expect(settings.defaultAgentAvatarName == AgentAvatarSelection.defaultName)
        #expect(AppSettings(agentAvatarURL: destination, preferences: defaults)
            .defaultAgentAvatarName == AgentAvatarSelection.defaultName)
    }

    @Test @MainActor func storesAndChangesThePersonalityWithTheImage() throws {
        let source = root.appendingPathComponent("source.png")
        let destination = root.appendingPathComponent("support/agent-avatar.png")
        try pngData(width: 4, height: 4).write(to: source)
        let settings = AppSettings(agentAvatarURL: destination)

        try settings.importAgentAvatars(from: [source], personality: .sarcastic)

        let sarcastic = try #require(settings.agentAvatars.first)
        #expect(sarcastic.personality == .sarcastic)
        #expect(AppSettings(agentAvatarURL: destination).agentAvatars.first?.personality == .sarcastic)

        try settings.setPersonality(.cat, for: sarcastic)

        #expect(settings.agentAvatars.first?.personality == .cat)
        #expect(AppSettings(agentAvatarURL: destination).agentAvatars.first?.personality == .cat)
    }

    @Test @MainActor func rejectsAnInvalidBatchWithoutImportingItsValidImages() throws {
        let source = root.appendingPathComponent("source.png")
        let invalid = root.appendingPathComponent("notes.txt")
        let destination = root.appendingPathComponent("agent-avatar.png")
        try pngData(width: 4, height: 4).write(to: source)
        try Data("not an image".utf8).write(to: invalid)
        let settings = AppSettings(agentAvatarURL: destination)

        #expect(throws: AgentAvatarError.self) {
            try settings.importAgentAvatars(from: [source, invalid])
        }

        #expect(settings.agentAvatars.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test @MainActor func addsABotWithoutAPhotoAndGivesItThePersonalitysPicture() throws {
        let destination = root.appendingPathComponent("support/agent-avatar.png")
        let settings = AppSettings(agentAvatarURL: destination)

        try settings.addStockAgentAvatar(personality: .cat)

        #expect(settings.agentAvatars.first?.personality == .cat)
        #expect(settings.agentAvatars.first?.usesStockArtwork == true)
        #expect(try Data(contentsOf: destination) == AgentAvatarArt.pngData(for: .cat))
        let restored = try #require(AppSettings(agentAvatarURL: destination).agentAvatars.first)
        #expect(restored.personality == .cat)
        #expect(restored.usesStockArtwork)
    }

    @Test @MainActor func usesSessionMoodsOnlyForPhotoLessBots() throws {
        let source = root.appendingPathComponent("source.png")
        let destination = root.appendingPathComponent("agent-avatar.png")
        try pngData(width: 4, height: 4).write(to: source)
        let settings = AppSettings(agentAvatarURL: destination)
        try settings.addStockAgentAvatar(personality: .standard)
        try settings.importAgentAvatars(from: [source], personality: .standard)
        let stock = try #require(settings.agentAvatars.first)
        let photo = try #require(settings.agentAvatars.last)
        let sessionID = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"))

        #expect(stock.displayImage(for: nil) !== stock.image)
        #expect(stock.displayImage(for: sessionID) !== stock.image)
        #expect(photo.displayImage(for: sessionID) === photo.image)
    }

    @Test func derivesAStableMoodFromTheSessionAndBot() throws {
        let firstSession = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondSession = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"))

        #expect(AgentAvatarArt.sessionArtworkIndex(
            sessionID: firstSession, avatarName: "agent-avatar.png") == 10)
        #expect(AgentAvatarArt.sessionArtworkIndex(
            sessionID: secondSession, avatarName: "agent-avatar.png") == 53)
        #expect(AgentAvatarArt.sessionArtworkIndex(
            sessionID: firstSession, avatarName: "agent-avatar-2.png") == 37)
        #expect(AgentAvatarArt.sessionArtworkIndex(
            sessionID: firstSession, avatarName: "agent-avatar.png", count: 0) == nil)
    }

    @Test @MainActor func recognizesArtworkSavedByOlderBuildsAsPhotoLess() throws {
        let destination = root.appendingPathComponent("agent-avatar.png")
        let legacyURL = try #require(AppResources.bundle.url(
            forResource: "avatar-cat", withExtension: "png"))
        try Data(contentsOf: legacyURL).write(to: destination)

        let avatar = try #require(AppSettings(
            agentAvatarURL: destination).agentAvatars.first)

        #expect(avatar.usesStockArtwork)
    }

    // The picture follows the personality, but only for the ones the app supplied: a photo is
    // the user's and has to survive the same change.
    @Test @MainActor func swapsAStockPictureWhenThePersonalityChangesAndLeavesPhotosAlone() throws {
        let source = root.appendingPathComponent("source.png")
        let destination = root.appendingPathComponent("agent-avatar.png")
        try pngData(width: 4, height: 4).write(to: source)
        let settings = AppSettings(agentAvatarURL: destination)
        try settings.addStockAgentAvatar(personality: .cat)
        try settings.importAgentAvatars(from: [source], personality: .cat)
        let photo = try #require(settings.agentAvatars.last)
        let photoBytes = try Data(contentsOf: photo.url)

        try settings.setPersonality(.manager, for: try #require(settings.agentAvatars.first))
        try settings.setPersonality(.manager, for: photo)

        #expect(try Data(contentsOf: destination) == AgentAvatarArt.pngData(for: .manager))
        #expect(try Data(contentsOf: photo.url) == photoBytes)
    }

    // A personality shipped without a picture of its own would leave a bot with no face.
    @Test func shipsADifferentPictureForEveryPersonality() throws {
        let pictures = try AgentPersonality.allCases.map { try AgentAvatarArt.pngData(for: $0) }
        #expect(Set(pictures).count == AgentPersonality.allCases.count)
    }

    @Test @MainActor func missingAndLegacySelectionsUseTheBuiltInDefault() throws {
        let sessionID = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"))
        let builtIn = AgentAvatarSelection.avatar(named: nil, from: [])

        #expect(builtIn.url.lastPathComponent == AgentAvatarSelection.defaultName)
        #expect(builtIn.usesStockArtwork)
        #expect(builtIn.displayImage(for: sessionID) === AgentAvatarArt.sessionImage(
            for: sessionID,
            avatarName: AgentAvatarSelection.defaultName))
        #expect(AgentAvatarSelection.avatar(named: "non-bot", from: [])
            .url.lastPathComponent == AgentAvatarSelection.defaultName)
        #expect(AgentAvatarSelection.avatar(named: "missing.png", from: [])
            .personality == .standard)
    }

    @Test func resolvesMissingAndLegacyDefaultsToTheBuiltInBot() {
        let names = ["agent-avatar.png", "agent-avatar-2.png"]

        #expect(AgentAvatarSelection.resolvedName(
            nil, availableNames: names) == AgentAvatarSelection.defaultName)
        #expect(AgentAvatarSelection.resolvedName(
            "agent-avatar-2.png", availableNames: names) == "agent-avatar-2.png")
        #expect(AgentAvatarSelection.resolvedName(
            "missing.png", availableNames: names) == AgentAvatarSelection.defaultName)
        #expect(AgentAvatarSelection.resolvedName(
            "non-bot", availableNames: names) == AgentAvatarSelection.defaultName)
    }

    @Test @MainActor func readsALegacyNonBotSessionAsTheBuiltInDefault() throws {
        let index = root.appendingPathComponent("projects.json")
        let store = ProjectStore(storeURL: index)
        let project = try #require(store.addProject(at: root.appendingPathComponent("project")))

        _ = store.newSession(in: project.id, seed: .init(agentAvatarName: "non-bot"))
        #expect(store.save())

        let restored = try #require(ProjectStore(storeURL: index).sessions.first)
        #expect(AgentAvatarSelection.avatar(named: restored.agentAvatarName, from: [])
            .url.lastPathComponent == AgentAvatarSelection.defaultName)
    }

    @Test @MainActor func changesTheBotUsedByAnExistingSession() throws {
        let index = root.appendingPathComponent("projects.json")
        let store = ProjectStore(storeURL: index)
        let project = try #require(store.addProject(at: root.appendingPathComponent("project")))
        let session = store.newSession(in: project.id,
                                       seed: .init(agentAvatarName: AgentAvatarSelection.defaultName))

        store.setAgentAvatarName("agent-avatar-2.png", for: session.id)

        #expect(store.session(session.id)?.agentAvatarName == "agent-avatar-2.png")
        let restored = try #require(ProjectStore(storeURL: index).session(session.id))
        #expect(restored.agentAvatarName == "agent-avatar-2.png")
    }
}
