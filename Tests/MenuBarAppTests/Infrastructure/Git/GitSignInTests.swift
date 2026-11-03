import Foundation
import Testing
@testable import MenuBarApp

// A clone the app runs has no terminal, so an HTTPS address that needs a login fails.
// These pin down which failures read as a sign-in and which SSH address is offered.
struct GitSignInTests {

    // What a user saw when the app let git try to open a terminal.
    @Test func recognisesTheMissingTerminalFailure() {
        let output = """
            Cloning into '/Users/someone/Library/Application Support/com.teya.code-station/marketplaces/.marketplace-1'...
            fatal: could not read Username for 'https://github.com': Device not configured
            """
        #expect(GitSignIn.isRequired(by: output))
    }

    @Test func recognisesTheFailureWithPromptsTurnedOff() {
        #expect(GitSignIn.isRequired(by:
            "fatal: could not read Username for 'https://github.com': terminal prompts disabled"))
        #expect(GitSignIn.isRequired(by:
            "remote: Invalid username or token.\nfatal: Authentication failed for 'https://github.com/org/repo.git/'"))
    }

    @Test func leavesOtherFailuresAlone() {
        #expect(!GitSignIn.isRequired(by: "fatal: repository 'https://example.com/x.git/' not found"))
        #expect(!GitSignIn.isRequired(by: "fatal: unable to access 'https://github.com/': Could not resolve host"))
    }

    @Test func offersTheSSHAddressForGitHub() {
        #expect(GitSignIn.sshAddress(for: "https://github.com/example/marketplace.git")
                == "git@github.com:example/marketplace.git")
        #expect(GitSignIn.sshAddress(for: "https://github.com/example/marketplace/")
                == "git@github.com:example/marketplace.git")
        #expect(GitSignIn.sshAddress(for: "  https://user@GitHub.com/org/repo  ")
                == "git@github.com:org/repo.git")
    }

    // GitLab groups nest, so the whole path carries over.
    @Test func keepsNestedGitLabGroups() {
        #expect(GitSignIn.sshAddress(for: "https://gitlab.com/group/sub/repo.git")
                == "git@gitlab.com:group/sub/repo.git")
    }

    // Other servers choose their own SSH user and port, so no address is guessed.
    @Test func offersNothingItCannotBeSureOf() {
        #expect(GitSignIn.sshAddress(for: "https://git.example.com/org/repo.git") == nil)
        #expect(GitSignIn.sshAddress(for: "git@github.com:org/repo.git") == nil)
        #expect(GitSignIn.sshAddress(for: "https://github.com/org") == nil)
        #expect(GitSignIn.sshAddress(for: "https://github.com:8443/org/repo.git") == nil)
        #expect(GitSignIn.sshAddress(for: "https://github.com/org/repo?tab=readme") == nil)
    }

    @Test func explainsTheFixInPlainWords() {
        let github = GitSignIn.explanation(for: "https://github.com/org/repo.git")
        #expect(github.hasPrefix("GitHub needs you to sign in"))
        #expect(github.contains("git@github.com:org/repo.git"))
        #expect(github.contains("gh auth setup-git"))

        let other = GitSignIn.explanation(for: "https://git.example.com/org/repo.git")
        #expect(other.hasPrefix("The server needs you to sign in"))
        #expect(!other.contains("git@"))
        #expect(!other.contains("gh auth"))
    }
}
