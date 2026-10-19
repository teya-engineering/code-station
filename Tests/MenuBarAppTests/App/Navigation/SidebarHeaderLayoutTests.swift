import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

@MainActor
struct SidebarHeaderLayoutTests {
    private let testPreferences = TestPreferences()
    @Test(arguments: [0, 2, 120], [CGFloat(1), 1.3])
    func headerFitsTheSidebar(running: Int, scale: CGFloat) {
        let (store, _) = TestStore.make()
        let mobile = MobileAccessController(store: store, runner: SessionRunner(preferences: testPreferences.store, paths: [:]),
                                            gitStats: GitStatsCache())
        let host = NSHostingController(rootView: SidebarHeaderProbe(running: running)
            .environment(mobile)
            .environment(GlobalCommandPaletteController())
            .environment(\.textScale, scale)
            .appOverlays())
        let size = host.sizeThatFits(in: CGSize(width: 318, height: CGFloat.infinity))

        #expect(size.width <= 318)
        #expect(size.height >= 149)
        #expect(size.height < 210)
        if scale == 1, running < 10 {
            #expect(abs(size.height - 149) < 1)
        }
    }

    @Test func rendersHeaderStatesForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["SIDEBAR_HEADER_PREVIEWS"] else { return }
        let destination = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let (store, _) = TestStore.make()
        let mobile = MobileAccessController(store: store, runner: SessionRunner(preferences: testPreferences.store, paths: [:]),
                                            gitStats: GitStatsCache())
        for dark in [false, true] {
            for state in ["default", "idle", "large", "filter", "name"] {
                let content = SidebarHeaderProbe(running: state == "idle" ? 0 : 2,
                                                 filtering: state == "filter",
                                                 alphabetical: state == "name")
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Theme.sidebar)
                    .environment(mobile)
                    .environment(GlobalCommandPaletteController())
                    .environment(\.textScale, state == "large" ? 1.3 : 1)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .appOverlays()
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 318, height: 210)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let url = destination.appendingPathComponent("\(state)-\(dark ? "dark" : "light").png")
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
            }
        }
    }
}

private struct SidebarHeaderProbe: View {
    let running: Int
    var filtering = false
    var alphabetical = false

    @State private var box = SidebarFilterBox()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SidebarBrandBar(runningCount: running, isHome: false, selectHome: {})
            SidebarFilterBar(box: $box, focused: $focused,
                             openCommandPalette: {}, showsShortcutHint: true)
            SidebarArrangementBar(sort: .constant(alphabetical ? .name : .lastUsed),
                                  grouping: .constant(alphabetical ? .kind : .flat))
        }
        .background(Theme.sidebar)
        .onAppear {
            if filtering { box.openField() }
        }
    }
}
