import Foundation
import Testing
@testable import MenuBarApp

struct EnvironmentPropertyTests {
    private let environment = ApiEnvironment(name: "uat", label: "UAT")

    @Test func resolvesBeforeEncodingWithoutExpandingValuesAgain() {
        let properties = [
            EnvironmentProperty(name: "base", value: "https://example.test"),
            EnvironmentProperty(name: "value", value: "a/b &+?#"),
            EnvironmentProperty(name: "literal", value: "{{env}}")
        ]
        let request = SavedRequest(name: "test", url: "{{base}}/:id",
                                   headers: [HeaderField(key: "X-Literal", value: "{{literal}}")],
                                   queryParams: [HeaderField(key: "q", value: "{{value}}")],
                                   pathParams: [HeaderField(key: "id", value: "{{value}}")])
        let resolved = DispatchRunner.resolve(request, environment: environment, authorization: nil, properties: properties)
        #expect(resolved.problems.isEmpty)
        #expect(resolved.url == "https://example.test/a%2Fb%20%26%2B%3F%23?q=a/b%20%26%2B?%23")
        #expect(resolved.headers.first?.value == "{{env}}")
    }

    @Test func escapesJSONStringValuesAndRejectsInvalidJSON() throws {
        let value = "a\"b\\c\nline"
        let properties = [EnvironmentProperty(name: "value", value: value)]
        var request = SavedRequest(name: "json", method: .post, url: "https://example.test",
                                   bodyType: .json, body: #"{"value":"{{value}}"}"#)
        let resolved = DispatchRunner.resolve(request, environment: environment, authorization: nil, properties: properties)
        let json = try JSONSerialization.jsonObject(with: Data(try #require(resolved.body).utf8)) as? [String: String]
        #expect(json?["value"] == value)
        #expect(resolved.problems.isEmpty)
        request.body = #"{"value":{{value}}}"#
        #expect(!DispatchRunner.resolve(request, environment: environment, authorization: nil, properties: properties).problems.isEmpty)
    }

    @Test func reportsMissingEmptyAndCaseSensitivePropertiesByField() {
        let request = SavedRequest(name: "missing", url: "https://{{host}}/",
                                   headers: [HeaderField(key: "X-ID", value: "{{id}}")])
        let resolved = DispatchRunner.resolve(request, environment: environment, authorization: nil,
                                              properties: [EnvironmentProperty(name: "Host", value: "example.test"),
                                                           EnvironmentProperty(name: "id", value: "")])
        #expect(resolved.problems.count == 2)
        #expect(resolved.problems[0].contains("UAT (uat): URL"))
        #expect(resolved.problems[1].contains("Header X-ID"))
    }

    @Test func masksSecretPropertiesEverywhereInExports() {
        let request = SavedRequest(name: "secret", method: .post, url: "https://example.test/{{key}}",
                                   headers: [HeaderField(key: "Authorization", value: "{{key}}")],
                                   bodyType: .json, body: #"{"key":"{{key}}"}"#)
        let properties = [EnvironmentProperty(name: "key", value: "do-not-export", isSecret: true)]
        let resolved = DispatchRunner.resolve(request, environment: environment, authorization: "Bearer ignored", properties: properties)
        #expect(resolved.headers.first?.value == "do-not-export")
        let curl = CurlCommand.text(for: request, environment: environment, authorization: nil, properties: properties)
        #expect(!curl.contains("do-not-export"))
        #expect(curl.contains("REDACTED"))
    }

    @Test func formValuesCannotInjectPairs() {
        let request = SavedRequest(name: "form", method: .post, url: "https://example.test",
                                   bodyType: .form, body: "name={{value}}\nother={{env}}")
        let resolved = DispatchRunner.resolve(request, environment: environment, authorization: nil,
                                              properties: [EnvironmentProperty(name: "value", value: "a&admin=true+\n")])
        #expect(resolved.body == "name=a%26admin%3Dtrue%2B%0A&other=uat")
    }

    @Test func ignoresFieldsThatAreNotSent() {
        let request = SavedRequest(name: "unused", url: "https://example.test",
                                   headers: [HeaderField(key: "X-ID", value: "{{missing}}", enabled: false),
                                             HeaderField(key: "", value: "{{missing}}")],
                                   queryParams: [HeaderField(key: "", value: "{{missing}}")],
                                   pathParams: [HeaderField(key: "unused", value: "{{missing}}")],
                                   bodyType: .json, body: #"{"id":"{{missing}}"}"#)
        #expect(DispatchRunner.resolve(request, environment: environment, authorization: nil).problems.isEmpty)
    }

    @Test func masksRawJSONSecretsWithoutReportingAFalseValidationError() throws {
        let request = SavedRequest(name: "json", method: .post, url: "https://example.test",
                                   bodyType: .json, body: #"{"id":{{id}}}"#)
        let properties = [EnvironmentProperty(name: "id", value: "123456", isSecret: true)]
        let resolved = DispatchRunner.resolve(request, environment: environment, authorization: nil,
                                              properties: properties, masked: true)
        #expect(resolved.problems.isEmpty)
        #expect(resolved.body == #"{"id":"REDACTED"}"#)
    }

    @Test func preservesAlreadyEncodedFormText() {
        let request = SavedRequest(name: "form", method: .post, url: "https://example.test",
                                   bodyType: .form, body: "name=a%2Fb&other={{value}}")
        let resolved = DispatchRunner.resolve(request, environment: environment, authorization: nil,
                                              properties: [EnvironmentProperty(name: "value", value: "%2F")])
        #expect(resolved.body == "name=a%2Fb&other=%252F")
    }

    @Test func validatesNamesButAllowsEmptyValues() {
        #expect(EnvironmentProperty.validation([EnvironmentProperty(name: "valid_1")]) == nil)
        for name in ["", "1name", "a-b", "env", "naïve", "name\n"] {
            #expect(EnvironmentProperty.validation([EnvironmentProperty(name: name)]) != nil)
        }
        #expect(EnvironmentProperty.validation([EnvironmentProperty(name: "id"), EnvironmentProperty(name: "id")]) != nil)
    }

    @MainActor @Test func savesIndependentValuesAndKeepsSecretsOutOfTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("auth.json")
        let secrets = PropertyTestKeychain()
        let store = DispatchAuthStore(storeURL: url, keychain: secrets.client)
        let first = store.environments[0]
        let second = store.environments[1]
        let active = store.active
        let secret = EnvironmentProperty(name: "key", value: "private-property-value", isSecret: true)
        #expect(store.setProperties([first: [secret], second: [EnvironmentProperty(name: "key", value: "other")]]))
        #expect(store.active == active)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains(secret.value))
        let reloaded = DispatchAuthStore(storeURL: url, keychain: secrets.client)
        #expect(reloaded.properties(for: first) == [secret])
        #expect(reloaded.properties(for: second).first?.value == "other")
        #expect(reloaded.setProperties([first: []]))
        #expect(secrets.read()[.dispatchProperty(secret.id, environment: first.name)] == nil)
        #expect(reloaded.properties(for: second).first?.value == "other")
    }

    @MainActor @Test func failedKeychainSaveKeepsPreviousValues() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DispatchAuthStore(storeURL: url, keychain: KeychainClient(read: { [:] }, write: { _ in throw CocoaError(.fileWriteNoPermission) }))
        let env = store.environments[0]
        #expect(!store.setProperties([env: [EnvironmentProperty(name: "key", value: "secret", isSecret: true)]]))
        #expect(store.properties(for: env).isEmpty)
        #expect(store.saveError != nil)
    }
}

private final class PropertyTestKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Keychain.Account: String] = [:]
    func read() -> [Keychain.Account: String] { lock.withLock { values } }
    var client: KeychainClient {
        KeychainClient(read: { self.read() }, write: { values in self.lock.withLock { self.values = values } })
    }
}
