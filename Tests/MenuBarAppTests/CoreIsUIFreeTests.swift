import Foundation
import Testing
@testable import CodeStationCore

// The core is shared by the menu bar app and the terminal front end. A terminal binary
// cannot link AppKit's window server or SwiftUI's view graph, so one stray UI import in
// `Sources/CodeStationCore` would tie the engine back to the GUI. This scans the core's
// sources and fails on any import of a UI framework, however it is spelled.
struct CoreIsUIFreeTests {

    static let uiFrameworks: Set<String> = [
        "AppKit", "Cocoa", "SwiftUI", "UIKit", "WatchKit", "Carbon", "WebKit",
        "QuartzCore", "Quartz", "SpriteKit", "SceneKit", "MetalKit", "RealityKit",
        "AVKit", "MapKit", "PDFKit", "Charts", "SwiftTerm",
    ]

    // The module each import line names, for every form Swift accepts:
    // `import AppKit`, `@preconcurrency import AppKit`, `import class AppKit.NSImage`,
    // `import AppKit.NSImage`.
    static func importedModules(in source: String) -> [String] {
        let pattern = #/^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][A-Za-z0-9_]*)/#
        return source.split(whereSeparator: \.isNewline).compactMap { line in
            (try? pattern.firstMatch(in: String(line))).map { String($0.output.1) }
        }
    }

    static var coreSources: URL { sources("CodeStationCore") }

    static func sources(_ target: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/\(target)")
    }

    // Every UI import in a target's sources, as "file imports Module".
    static func uiImports(in root: URL) throws -> (files: Int, offenders: [String]) {
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for module in importedModules(in: source) where uiFrameworks.contains(module) {
                offenders.append("\(file.path.replacingOccurrences(of: root.path + "/", with: "")) imports \(module)")
            }
        }
        return (files.count, offenders.sorted())
    }

    @Test func everySpellingOfAUIImportIsCaught() {
        let source = """
        import Foundation
        @preconcurrency import AppKit
        import struct SwiftUI.Color
        import WebKit.WKWebView
          @_exported import UIKit
        // import Cocoa is only a comment
        """
        let caught = Self.importedModules(in: source).filter(Self.uiFrameworks.contains)
        #expect(caught == ["AppKit", "SwiftUI", "WebKit", "UIKit"])
    }

    @Test func noCoreFileImportsAUIFramework() throws {
        let root = Self.coreSources
        let (files, offenders) = try Self.uiImports(in: root)
        #expect(files > 50, "the core's sources were not found at \(root.path)")
        #expect(offenders.isEmpty, "CodeStationCore must stay free of UI frameworks:\n\(offenders.joined(separator: "\n"))")
    }

    // The terminal front end runs over SSH and in plain terminals, where there is no
    // window server to link against. Its terminal layer and its own sources must stay as
    // free of UI frameworks as the core. (The package graph backs this up: the TUI
    // target depends only on the core, TerminalKit, TerminalTranscript and TerminalServices.)
    @Test(arguments: ["TerminalKit", "TerminalTranscript", "TerminalServices", "CodeStationTUI"])
    func noTerminalFileImportsAUIFramework(_ target: String) throws {
        let root = Self.sources(target)
        let (files, offenders) = try Self.uiImports(in: root)
        #expect(files > 0, "the \(target) sources were not found at \(root.path)")
        #expect(offenders.isEmpty, "\(target) must stay free of UI frameworks:\n\(offenders.joined(separator: "\n"))")
    }
}
