import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The band at the top of the window stands in for its title bar, but only where nothing
// else on the band wants the click, and only for the band that runs along the top edge.
@MainActor
struct TitleBarAreaTests {
    @Test func followsTheDoubleClickSetting() {
        #expect(TitleBarDoubleClick.reading(action: "Maximize", minimizes: false) == .zoom)
        #expect(TitleBarDoubleClick.reading(action: "Fill", minimizes: false) == .zoom)
        #expect(TitleBarDoubleClick.reading(action: "Minimize", minimizes: false) == .minimize)
        #expect(TitleBarDoubleClick.reading(action: "None", minimizes: true) == .nothing)
        #expect(TitleBarDoubleClick.reading(action: nil, minimizes: false) == .zoom)
        #expect(TitleBarDoubleClick.reading(action: nil, minimizes: true) == .minimize)
    }

    @Test func onlyTheEmptyPartOfTheTopBandActsAsTheTitleBar() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSHostingView(rootView: VStack(spacing: 0) {
            HStack {
                Button(action: {}) {
                    Text("Go").frame(width: 60, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.leading, 20)
            .headerBand()
            Text("Below").headerBand()
            Color.clear
        })
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        // Points are from the top left of the content, the way the view lays itself out.
        func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? {
            let local = NSPoint(x: x, y: content.isFlipped ? y : content.bounds.height - y)
            return content.hitTest(content.convert(local, to: content.superview))
        }

        #expect(hit(400, 30) is TitleBarAreaView)
        #expect(!(hit(50, 30) is TitleBarAreaView), "the button lost its click to the title bar")
        #expect(!(hit(400, 90) is TitleBarAreaView), "a band lower down acted as the title bar")
    }
}
