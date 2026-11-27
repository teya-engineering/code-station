import Foundation
import Testing
@testable import MenuBarApp

struct DispatchAddressTests {
    private let staging = ApiEnvironment(name: "staging")
    private let properties = [EnvironmentProperty(name: "base_url", value: "https://api.staging.test"),
                              EnvironmentProperty(name: "key", value: "s3cret", isSecret: true)]

    @Test func cutsTheTemplateIntoTextPropertiesAndPathNames() {
        let tokens = DispatchAddress.tokens(in: "{{base_url}}/v2/merchants/:merchant_id/settlements?from=:later")
        #expect(tokens == [.property(name: "base_url", text: "{{base_url}}"),
                           .text("/v2/merchants/"),
                           .path(name: "merchant_id"),
                           .text("/settlements?from=:later")])
        #expect(tokens.map(\.text).joined() == "{{base_url}}/v2/merchants/:merchant_id/settlements?from=:later")
    }

    @Test func leavesTheHostAndPortAlone() {
        #expect(DispatchAddress.tokens(in: "https://ledger.{{env}}.test:8080/health") == [
            .text("https://ledger."), .property(name: "env", text: "{{env}}"), .text(".test:8080/health")
        ])
        #expect(DispatchAddress.tokens(in: "") == [])
    }

    @Test func marksWhatWasFilledInAndMatchesWhatIsSent() {
        var request = SavedRequest(name: "Settlements",
                                   url: "{{base_url}}/v2/merchants/:merchant_id/settlements",
                                   queryParams: [HeaderField(key: "from", value: "2026-11-01"),
                                                 HeaderField(key: "status", value: "paid", enabled: false)])
        request.setPathValue("mrc 1", for: "merchant_id")
        let resolved = DispatchAddress.resolve(request, environment: staging, properties: properties)
        #expect(resolved.parts == [
            .init(text: "https://api.staging.test", substituted: true),
            .init(text: "/v2/merchants/"),
            .init(text: "mrc%201", substituted: true),
            .init(text: "/settlements"),
            .init(text: "?from=2026-11-01")
        ])
        #expect(resolved.problem == nil)
        #expect(resolved.text == DispatchRunner.resolve(request, environment: staging, authorization: nil,
                                                       properties: properties, masked: true).url)
    }

    @Test func masksSecretsInWhatIsShown() {
        let request = SavedRequest(name: "Keyed", url: "https://example.test/{{key}}/:id",
                                   pathParams: [HeaderField(key: "id", value: "{{key}}")])
        let resolved = DispatchAddress.resolve(request, environment: staging, properties: properties)
        #expect(resolved.text == "https://example.test/REDACTED/REDACTED")
        #expect(resolved.problem == nil)
    }

    @Test func showsTheRunnersAddressWholeWhenThePartsDoNotAddUp() {
        let request = SavedRequest(name: "Fragment", url: "https://example.test/a#top",
                                   queryParams: [HeaderField(key: "q", value: "1")])
        let resolved = DispatchAddress.resolve(request, environment: staging, properties: [])
        #expect(resolved.parts == [.init(text: "https://example.test/a?q=1#top")])
    }

    @Test func saysTheOneThingToFix() {
        func problem(_ url: String, path: [HeaderField] = []) -> String? {
            DispatchAddress.resolve(SavedRequest(name: "R", url: url, pathParams: path),
                                    environment: staging, properties: properties).problem
        }
        #expect(problem("  ") == "Type an address to send to.")
        #expect(problem("https://example.test/{{nope}}")?.contains("{{nope}}") == true)
        #expect(problem("https://example.test/:id") == "Give :id a value in Parameters.")
        #expect(problem("https://example.test/:id", path: [HeaderField(key: "id", value: "7", enabled: false)])
                == "Give :id a value in Parameters.")
        #expect(problem("example.test/a") == "The address needs to start with http:// or https://.")
        #expect(problem("https://bad host.test") == "The address is not one that can be sent to.")
        #expect(problem("https://example.test/:id", path: [HeaderField(key: "id", value: "7")]) == nil)
    }

    @Test func pathValuesFollowTheNamesInTheAddress() {
        var request = SavedRequest(name: "R", url: "https://example.test/:b/:a/:b",
                                   pathParams: [HeaderField(key: "a", value: "old", enabled: false)])
        #expect(request.pathNames == ["b", "a"])
        #expect(request.pathValue(for: "a") == "")
        request.setPathValue("1", for: "a")
        request.setPathValue("2", for: "b")
        #expect(request.pathParams.map(\.key) == ["a", "b"])
        #expect(request.pathParams.map(\.enabled) == [true, true])
        #expect(request.expandedURL == "https://example.test/2/1/2")
    }

    @Test func foldKeepsTheBodyWholeAndCountsItsItems() throws {
        let body = #"{"data":[{"id":1,"tags":["a","b"]},{"id":2},{"id":"3,4"}],"next":null}"#
        let fold = try #require(DispatchResponseDocument(body: body).fold)
        #expect(fold.head + fold.inner + fold.tail == body)
        #expect(fold.head == #"{"data":["#)
        #expect(fold.count == 3)
        #expect(DispatchResponseDocument(body: "[1]").fold?.count == 1)
    }

    @Test @MainActor func aSendUnderWayKnowsWhenItStartedAndCancellingIsNotAFailureToReach() async {
        let runner = DispatchRunner()
        let request = SavedRequest(name: "Slow", url: "https://example.test")
        runner.start(request, environment: staging) {
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        #expect(runner.startedAt(request.id, in: staging) != nil)
        runner.cancel(request.id, in: staging)
        #expect(runner.startedAt(request.id, in: staging) == nil)
        #expect(runner.result(request.id, in: staging)?.wasCancelled == true)
    }
}
