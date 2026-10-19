import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

private let testEnvironment = ApiEnvironment(name: "test")

struct SavedRequestFormBodyTests {

    @Test func joinsOnePairPerLineWithAmpersands() {
        let body = SavedRequest.formEncoded("grant_type=client_credentials\nscope=terminal\n")
        #expect(body == "grant_type=client_credentials&scope=terminal")
    }

    @Test func keepsABodyTypedOnOneLine() {
        let body = SavedRequest.formEncoded("grant_type=client_credentials&scope=terminal")
        #expect(body == "grant_type=client_credentials&scope=terminal")
    }

    @Test func skipsBlankLinesAndTrimsLineEnds() {
        let body = SavedRequest.formEncoded("  a=1  \r\n\n\tb=2\n")
        #expect(body == "a=1&b=2")
    }

    @Test func encodesCharactersThatWouldChangeTheValue() {
        let body = SavedRequest.formEncoded("client_secret=ab+c/d=\nscope=read write\nname=café")
        #expect(body == "client_secret=ab%2Bc%2Fd%3D&scope=read%20write&name=caf%C3%A9")
    }

    @Test func keepsEscapesThatAreAlreadyThere() {
        let body = SavedRequest.formEncoded("redirect=https%3A%2F%2Fhost\nratio=50%")
        #expect(body == "redirect=https%3A%2F%2Fhost&ratio=50%25")
    }

    @Test func onlyFormBodiesAreRewrittenWhenSent() {
        let form = SavedRequest(name: "r", method: .post, url: "https://host", bodyType: .form, body: "a=1\nb=2")
        let text = SavedRequest(name: "r", method: .post, url: "https://host", bodyType: .text, body: "a=1\nb=2")
        let formResolved = DispatchRunner.resolve(form, environment: testEnvironment, authorization: nil)
        let textResolved = DispatchRunner.resolve(text, environment: testEnvironment, authorization: nil)
        #expect(formResolved.body == "a=1&b=2")
        #expect(formResolved.headers.contains { $0.key == "Content-Type"
            && $0.value == "application/x-www-form-urlencoded" })
        #expect(textResolved.body == "a=1\nb=2")
    }
}
