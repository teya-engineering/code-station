import Foundation
import Testing
@testable import MenuBarApp

// Every git the app starts reads back what git printed, and none of them has a terminal.
// Without the pinned locale, git's messages come back translated and nothing can
// recognise them.
struct GitEnvironmentTests {

    @Test func pinsEverythingANonInteractiveGitNeeds() {
        let environment = GitEnvironment.nonInteractive(
            searchPath: "/opt/homebrew/bin:/usr/bin",
            base: ["HOME": "/Users/someone", "LANG": "pt_PT.UTF-8", "LC_ALL": "pt_PT.UTF-8"])
        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(environment["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(environment["GIT_PAGER"] == "cat")
        #expect(environment["LC_ALL"] == "C")
        // The rest of the user's environment, such as where their git config lives, stays.
        #expect(environment["HOME"] == "/Users/someone")
    }
}
