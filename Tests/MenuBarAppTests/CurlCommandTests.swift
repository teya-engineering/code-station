import Foundation
import Testing
@testable import MenuBarApp

struct CurlCommandTests {
    @Test func writesMethodHeadersAndBody() {
        let request = SavedRequest(
            name: "create",
            method: .post,
            url: "https://example.test/things",
            headers: [HeaderField(key: "X-Trace", value: "abc")],
            bodyType: .json,
            body: #"{"name":"thing"}"#)

        let command = CurlCommand.text(for: request, environment: .staging,
                                       authorization: "Bearer token")

        #expect(command == """
        curl \\
          -X POST \\
          'https://example.test/things' \\
          -H 'Authorization: Bearer token' \\
          -H 'X-Trace: abc' \\
          -H 'Content-Type: application/json' \\
          --data-raw '{"name":"thing"}'
        """)
    }

    @Test func leavesGetImplicitAndSendsNoBody() {
        let request = SavedRequest(name: "read", method: .get, url: "https://example.test/things")

        let command = CurlCommand.text(for: request, environment: .staging, authorization: nil)

        #expect(command == "curl \\\n  'https://example.test/things'")
    }

    @Test func foldsInTheParamsAndTheEnvironment() {
        let request = SavedRequest(
            name: "read",
            url: "https://host.{{env}}.test/things/:id",
            queryParams: [HeaderField(key: "q", value: "a b")],
            pathParams: [HeaderField(key: "id", value: "42")])

        let command = CurlCommand.text(for: request, environment: .staging, authorization: nil)

        let expected = "https://host.\(ApiEnvironment.staging.envValue).test/things/42?q=a%20b"
        #expect(command.contains("'\(expected)'"))
    }

    @Test func keepsTheShellOutOfAQuotedBody() {
        let request = SavedRequest(name: "quote", method: .post, url: "https://example.test",
                                   bodyType: .text, body: "it's $HOME")

        let command = CurlCommand.text(for: request, environment: .staging, authorization: nil)

        #expect(command.contains(#"--data-raw 'it'\''s $HOME'"#))
    }

    @Test func skipsTheTokenWhenTheRequestDoesNotUseAuth() {
        let request = SavedRequest(name: "open", url: "https://example.test", useAuth: false)

        let command = CurlCommand.text(for: request, environment: .staging,
                                       authorization: "Bearer token")

        #expect(!command.contains("Authorization"))
    }

    @Test func aTypedContentTypeWinsOverTheOneTheBodyImplies() {
        let request = SavedRequest(
            name: "custom",
            method: .post,
            url: "https://example.test",
            headers: [HeaderField(key: "content-type", value: "application/vnd.api+json")],
            bodyType: .json,
            body: "{}")

        let command = CurlCommand.text(for: request, environment: .staging, authorization: nil)

        #expect(command.contains("-H 'content-type: application/vnd.api+json'"))
        #expect(!command.contains("application/json'"))
    }

    @Test func aTypedAuthorizationHeaderWinsOverTheCollectionToken() {
        let request = SavedRequest(
            name: "override",
            url: "https://example.test",
            headers: [HeaderField(key: "Authorization", value: "Bearer typed")])

        let command = CurlCommand.text(for: request, environment: .staging,
                                       authorization: "Bearer collection")

        #expect(command.contains("-H 'Authorization: Bearer typed'"))
        #expect(!command.contains("Bearer collection"))
    }

    @Test func skipsAHeaderThatIsSwitchedOff() {
        let request = SavedRequest(
            name: "parked",
            url: "https://example.test",
            headers: [HeaderField(key: "X-Parked", value: "no", enabled: false)])

        let command = CurlCommand.text(for: request, environment: .staging, authorization: nil)

        #expect(!command.contains("X-Parked"))
    }
}
