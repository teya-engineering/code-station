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
        #expect(settings.agentAvatar == nil)

        try settings.importAgentAvatar(from: source)
        try FileManager.default.removeItem(at: source)

        #expect(settings.agentAvatar != nil)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let imageSource = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(
            imageSource, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(max(width, height) <= AgentAvatarFile.maxPixelSize)
        #expect(AppSettings(agentAvatarURL: destination).agentAvatar != nil)
    }

    @Test @MainActor func rejectsANonImageWithoutReplacingTheCurrentImage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let invalid = root.appendingPathComponent("notes.txt")
        let destination = root.appendingPathComponent("agent-avatar.png")
        try pngData(width: 4, height: 4).write(to: source)
        try Data("not an image".utf8).write(to: invalid)
        let settings = AppSettings(agentAvatarURL: destination)
        try settings.importAgentAvatar(from: source)
        let original = try Data(contentsOf: destination)

        #expect(throws: AgentAvatarError.self) {
            try settings.importAgentAvatar(from: invalid)
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(settings.agentAvatar != nil)
    }

    @Test @MainActor func removesTheStoredImageAndReturnsToTheFallback() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let destination = root.appendingPathComponent("agent-avatar.png")
        try pngData(width: 4, height: 4).write(to: source)
        let settings = AppSettings(agentAvatarURL: destination)
        try settings.importAgentAvatar(from: source)

        try settings.removeAgentAvatar()

        #expect(settings.agentAvatar == nil)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }
}
