import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct FocusBoundaryTests {
    @Test(arguments: [false, true])
    func tabStaysInsideTheOpenSurfaceAndReturnsToItsOpeningControl(scrolling: Bool) async throws {
        let model = FocusFixtureModel()
        let host = NSHostingController(rootView: FocusFixture(model: model, scrolling: scrolling))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(CGSize(width: 500, height: 400))
        host.view.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        window.center()
        defer { window.close() }
        await settle(host.view)
        model.requested = .outside
        await settle(host.view)
        model.open = true
        await settle(host.view)
        let boundary = try #require(boundary(in: host.view))
        model.requested = .first
        await settle(host.view)
        #expect(model.focused == .first)
        window.recalculateKeyViewLoop()
        #expect(boundary.move(backward: false))
        await settle(host.view)
        #expect(model.focused == .second)
        #expect(boundary.move(backward: false))
        await settle(host.view)
        #expect(model.focused == .first)
        #expect(boundary.move(backward: true))
        await settle(host.view)
        #expect(model.focused == .second)
        model.open = false
        await settle(host.view)
        #expect(model.focused == .outside)
    }

    private func boundary(in view: NSView) -> FocusBoundary.BoundaryView? {
        if let boundary = view as? FocusBoundary.BoundaryView { return boundary }
        return view.subviews.lazy.compactMap { boundary(in: $0) }.first
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(20))
            view.layoutSubtreeIfNeeded()
        }
    }
}

@MainActor
@Observable
private final class FocusFixtureModel {
    enum Field: Hashable { case outside, first, second }
    var open = false
    var focused: Field?
    var requested: Field?
}

private struct FocusFixture: View {
    let model: FocusFixtureModel
    let scrolling: Bool
    @FocusState private var focus: FocusFixtureModel.Field?

    var body: some View {
        VStack(spacing: 20) {
            TextField("Opening control", text: .constant("")).focused($focus, equals: .outside)
            if model.open {
                Group {
                    if scrolling {
                        ScrollView { fields }.frame(height: 24)
                    } else {
                        fields
                    }
                }
                .padding(20)
                .focusBoundary()
            }
        }
        .textFieldStyle(.plain)
        .padding(20)
        .onChange(of: model.requested) { _, requested in focus = requested }
        .onChange(of: focus) { _, value in model.focused = value }
    }

    private var fields: some View {
        VStack(spacing: scrolling ? 100 : 20) {
            TextField("First field", text: .constant("")).focused($focus, equals: .first)
            TextField("Second field", text: .constant("")).focused($focus, equals: .second)
        }
    }
}
