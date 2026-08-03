// Draws Resources/AppIcon.icns. Run with `swift make-icon.swift` after changing the art.
// The icon is generated rather than checked in as opaque binary art so the palette can
// stay in step with Theme.swift.
import AppKit

let accent = NSColor(srgbRed: 0.20, green: 0.34, blue: 0.24, alpha: 1)
let cream = NSColor(srgbRed: 0.965, green: 0.961, blue: 0.945, alpha: 1)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS art sits inside the canvas rather than filling it, so the Dock's own
    // shadow and spacing look right next to system icons.
    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    accent.setFill()
    squircle.fill()

    // A split panel: the sidebar and detail layout the app is built around.
    let panel = rect.insetBy(dx: rect.width * 0.20, dy: rect.height * 0.24)
    let panelRadius = panel.width * 0.10
    let stroke = max(size * 0.028, 1)
    let outline = NSBezierPath(roundedRect: panel, xRadius: panelRadius, yRadius: panelRadius)
    outline.lineWidth = stroke
    cream.setStroke()
    outline.stroke()

    // The divider sits a third in, matching the real sidebar's proportion.
    let x = panel.minX + panel.width * 0.36
    let divider = NSBezierPath()
    divider.move(to: NSPoint(x: x, y: panel.minY))
    divider.line(to: NSPoint(x: x, y: panel.maxY))
    divider.lineWidth = stroke
    divider.stroke()

    // Fill the sidebar side so the glyph reads as a layout, not an empty box.
    let sidebar = NSRect(x: panel.minX, y: panel.minY, width: x - panel.minX, height: panel.height)
    let clip = NSBezierPath(roundedRect: panel, xRadius: panelRadius, yRadius: panelRadius)
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    cream.withAlphaComponent(0.30).setFill()
    sidebar.fill()
    NSGraphicsContext.restoreGraphicsState()

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
