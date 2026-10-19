import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers
import CodeStationCore

enum BotPhoto {
    static let maxBytes = 10 * 1024 * 1024

    static func read(from url: URL) throws -> CGImage {
        guard url.isFileURL else { throw ImportError.unsupported }
        guard let file = try? FileHandle(forReadingFrom: url) else { throw ImportError.unreadable }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maxBytes + 1) else { throw ImportError.unreadable }
        guard data.count <= maxBytes else { throw ImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String) else {
            throw ImportError.unreadable
        }
        guard [UTType.png, .jpeg, .webP].contains(type) else { throw ImportError.unsupported }
        // Bound decoded memory while retaining enough detail for a 512-pixel crop.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ] as CFDictionary) else { throw ImportError.unreadable }
        return image
    }

    enum ImportError: LocalizedError {
        case unsupported, unreadable, tooLarge

        var errorDescription: String? {
            switch self {
            case .unsupported: "Choose a JPG, PNG, or WebP picture. Other file types aren't supported."
            case .unreadable: "This picture couldn't be opened. Try another JPG, PNG, or WebP file."
            case .tooLarge: "This picture is too large. Choose one no larger than 10 MB."
            }
        }
    }
}

@MainActor
@Observable
final class BotPhotoCrop {
    let image: CGImage
    var zoom: Double = 1
    var across: Double = 0
    var down: Double = 0

    init(image: CGImage) { self.image = image }

    static func sourceRect(size: CGSize, zoom: Double, across: Double, down: Double) -> CGRect {
        let side = min(size.width, size.height) / min(2.5, max(1, zoom))
        return CGRect(x: (size.width - side) * (1 - min(1, max(-1, across))) / 2,
                      y: (size.height - side) * (1 - min(1, max(-1, down))) / 2,
                      width: side, height: side)
    }

    func pngData() throws -> Data {
        let rect = Self.sourceRect(size: CGSize(width: image.width, height: image.height),
                                   zoom: zoom, across: across, down: down)
        let side = AgentAvatarFile.maxPixelSize
        guard let cropped = image.cropping(to: rect),
              let context = CGContext(data: nil, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AgentAvatarError.couldNotEncodeImage
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let output = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else {
            throw AgentAvatarError.couldNotEncodeImage
        }
        return data
    }
}
