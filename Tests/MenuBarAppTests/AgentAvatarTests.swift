import AppKit
import Foundation
import ImageIO
import Testing
@testable import MenuBarApp

struct AgentAvatarTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-avatar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
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
    }

    @Test @MainActor func rejectsANonImageWithoutRemovingCurrentImages() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
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

    @Test @MainActor func storesTheDefaultAndAllowsNonBot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
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

        #expect(settings.defaultAgentAvatarName == AgentAvatarSelection.nonBotName)

        try settings.importAgentAvatars(from: sources)
        let secondName = try #require(settings.agentAvatars.last?.url.lastPathComponent)
        #expect(settings.defaultAgentAvatarName == "agent-avatar.png")
        #expect(AgentAvatarSelection.avatar(
            named: AgentAvatarSelection.nonBotName,
            forTurn: 0,
            from: settings.agentAvatars) == nil)
        #expect(AgentAvatarSelection.avatar(
            named: nil,
            forTurn: 1,
            from: settings.agentAvatars)?.url.lastPathComponent == secondName)

        settings.setDefaultAgentAvatarName(secondName)
        #expect(AppSettings(agentAvatarURL: destination, preferences: defaults)
            .defaultAgentAvatarName == secondName)

        settings.setDefaultAgentAvatarName(AgentAvatarSelection.nonBotName)
        #expect(AppSettings(agentAvatarURL: destination, preferences: defaults)
            .defaultAgentAvatarName == AgentAvatarSelection.nonBotName)
    }

    @Test @MainActor func removingTheDefaultChoosesTheNextBot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
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

        #expect(settings.defaultAgentAvatarName == "agent-avatar-2.png")
        #expect(AppSettings(agentAvatarURL: destination, preferences: defaults)
            .defaultAgentAvatarName == "agent-avatar-2.png")
    }

    @Test @MainActor func storesAndChangesThePersonalityWithTheImage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
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

    @Test func legacySessionsCycleAcrossBotsWhenNothingWasSelected() {
        #expect(AgentAvatarSelection.index(forTurn: 0, count: 3) == 0)
        #expect(AgentAvatarSelection.index(forTurn: 1, count: 3) == 1)
        #expect(AgentAvatarSelection.index(forTurn: 2, count: 3) == 2)
        #expect(AgentAvatarSelection.index(forTurn: 3, count: 3) == 0)
        #expect(AgentAvatarSelection.index(forTurn: -1, count: 3) == 0)
        #expect(AgentAvatarSelection.index(forTurn: 3, count: 0) == nil)
    }

    @Test func resolvesSavedDefaultsAndKeepsNonBotExplicit() {
        let names = ["agent-avatar.png", "agent-avatar-2.png"]

        #expect(AgentAvatarSelection.defaultName(
            preferredName: nil, availableNames: names) == "agent-avatar.png")
        #expect(AgentAvatarSelection.defaultName(
            preferredName: "agent-avatar-2.png", availableNames: names) == "agent-avatar-2.png")
        #expect(AgentAvatarSelection.defaultName(
            preferredName: "missing.png", availableNames: names) == "agent-avatar.png")
        #expect(AgentAvatarSelection.defaultName(
            preferredName: AgentAvatarSelection.nonBotName,
            availableNames: names) == AgentAvatarSelection.nonBotName)
    }

    @Test @MainActor func storesTheNonBotChoiceWithTheSession() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("projects.json")
        let store = ProjectStore(storeURL: index)
        let project = try #require(store.addProject(at: root.appendingPathComponent("project")))

        _ = store.newSession(in: project.id,
                             agentAvatarName: AgentAvatarSelection.nonBotName)
        #expect(store.save())

        let restored = try #require(ProjectStore(storeURL: index).sessions.first)
        #expect(restored.agentAvatarName == AgentAvatarSelection.nonBotName)
    }
}
