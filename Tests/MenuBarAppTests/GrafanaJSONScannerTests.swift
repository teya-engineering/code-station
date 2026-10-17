import Foundation
import Testing
@testable import MenuBarApp

struct GrafanaJSONScannerTests {
    @Test func keepsOnlyTheObjectsThatFinishedBeforeTheCut() throws {
        let text = #"{"data":[{"line":"a"},{"line":"b"},{"line":"c"#
        let objects = try #require(GrafanaJSONScanner.completeObjects(inArrayNamed: "data", of: text))
        #expect(objects.compactMap { $0["line"] as? String } == ["a", "b"])
    }

    @Test func isNotFooledByBracketsAndQuotesInsideStrings() throws {
        let text = #"{"data":[{"line":"x={\"a\":[1,2]} }]"},{"line":"y \\\"z"},{"line":"cut {"#
        let objects = try #require(GrafanaJSONScanner.completeObjects(inArrayNamed: "data", of: text))
        #expect(objects.compactMap { $0["line"] as? String } == [#"x={"a":[1,2]} }]"#, #"y \"z"#])
    }

    @Test func handlesNestedArraysInsideEntries() throws {
        let text = #"{"data":[{"metric":{"a":"b"},"values":[[1,"2"],[3,"4"]]},{"metric":{"#
        let objects = try #require(GrafanaJSONScanner.completeObjects(inArrayNamed: "data", of: text))
        #expect(objects.count == 1)
    }

    @Test func returnsNilWhenTheArrayIsMissing() {
        #expect(GrafanaJSONScanner.completeObjects(inArrayNamed: "data", of: #"{"rows":[{"a":1}"#) == nil)
    }

    @Test func ignoresAKeyThatOnlyAppearsInsideAString() throws {
        let text = #"{"note":"\"data\":[","data":[{"line":"real"},{"line":"#
        let objects = try #require(GrafanaJSONScanner.completeObjects(inArrayNamed: "data", of: text))
        #expect(objects.compactMap { $0["line"] as? String } == ["real"])
    }
}
