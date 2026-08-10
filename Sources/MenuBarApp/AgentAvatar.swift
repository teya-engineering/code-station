import AppKit
import ImageIO
import SwiftUI

enum AgentAvatarFile {
    static let maxPixelSize = 512

    static func load(from url: URL) -> NSImage? {
        NSImage(contentsOf: url)
    }

    static func importImage(from sourceURL: URL, to destinationURL: URL) throws -> NSImage {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else {
            throw AgentAvatarError.couldNotReadImage
        }

        let bitmap = NSBitmapImageRep(cgImage: thumbnail)
        guard let data = bitmap.representation(using: .png, properties: [:]),
              let image = NSImage(data: data) else {
            throw AgentAvatarError.couldNotEncodeImage
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: destinationURL, options: .atomic)
        return image
    }

    static func remove(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

enum AgentAvatarError: LocalizedError {
    case couldNotReadImage
    case couldNotEncodeImage

    var errorDescription: String? {
        switch self {
        case .couldNotReadImage:
            "The selected file is not an image the app can read."
        case .couldNotEncodeImage:
            "The selected image could not be prepared for use."
        }
    }
}

struct AgentAvatarView: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.border))
            .accessibilityLabel("Bot image")
    }
}
