// Draws Resources/AppIcon.icns from the app mark. Run with `swift make-icon.swift`
// after changing the art. The mark itself lives with the package resources so the
// window and the Dock icon are never drawn from two different files.
import AppKit

let artPath = "Sources/MenuBarApp/Resources/AppIcon.png"
guard let art = NSImage(contentsOfFile: artPath) else {
    print("Cannot read \(artPath)")
    exit(1)
}

// The art already carries its own margin, so it is drawn edge to edge rather than
// inset again, which would leave the Dock icon looking small next to system ones.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    art.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
             from: .zero,
             operation: .sourceOver,
             fraction: 1)
    image.unlockFocus()
    return image
}

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let image = drawIcon(size: pixels)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { continue }
        let suffix = scale == 1 ? "" : "@2x"
        try png.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}

try? FileManager.default.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(convert.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
