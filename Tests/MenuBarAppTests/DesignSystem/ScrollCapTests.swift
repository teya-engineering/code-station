import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// A capped scroll block sits inside the transcript, which is one long stack in a scroll
// view. If the block gives up height when offered less, the stack measures shorter than it
// draws and the end of the conversation can no longer be scrolled into view.
@MainActor
struct ScrollCapTests {
    private func lines(_ count: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    Text("line \(index)").frame(height: 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func height(of view: some View, offered: CGFloat) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 400, height: offered)).height
    }

    @Test func longContentStopsAtTheCapAndKeepsItWhenOfferedLess() {
        let block = lines(100).scrollCap(ScrollCap.short)

        #expect(height(of: block, offered: 4000) == ScrollCap.short)
        #expect(height(of: block, offered: 50) == ScrollCap.short)
    }

    @Test func shortContentTakesOnlyItsOwnHeight() {
        let block = lines(3).scrollCap(ScrollCap.short)

        #expect(height(of: block, offered: 4000) == 60)
        #expect(height(of: block, offered: 30) == 60)
    }

    @Test func theCapGrowsWithTheText() {
        let block = lines(100).scrollCap(ScrollCap.short).environment(\.textScale, 1.5)

        #expect(height(of: block, offered: 4000) == ScrollCap.short * 1.5)
    }

    @Test func toolOutputKeepsItsHeightWhenOfferedLess() {
        let text = (0..<200).map { "output line \($0)" }.joined(separator: "\n")
        let card = ToolOutputCard(label: "OUTPUT", text: text, isFailure: false, runInShell: nil)

        let roomy = height(of: card, offered: 4000)
        let tight = height(of: card, offered: 80)

        #expect(tight == roomy)
        #expect(roomy < 400)
    }

    @Test func grafanaSamplesKeepTheirHeightWhenOfferedLess() throws {
        let samples = (0..<60).map {
            GrafanaToolResult.Sample(id: $0, labels: ["pod": "ledger-\($0)"], date: nil, value: "\($0)")
        }
        guard case .success(let spec) = TranscriptLogsSpec.parse(#"{"title":"ledger","lines":[{"message":"up"}]}"#) else {
            Issue.record("not read"); return
        }
        let card = GrafanaResultView(source: .init(logs: spec), result: .samples(samples, truncated: false))
            .environment(TooltipPresenter())
            .environment(DialogPresenter())
            .environment(MenuPresenter())

        let roomy = height(of: card, offered: 4000)
        let tight = height(of: card, offered: 80)

        #expect(tight == roomy)
        #expect(roomy < 600)
    }
}
