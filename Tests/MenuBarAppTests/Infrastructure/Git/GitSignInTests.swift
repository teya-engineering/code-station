import Foundation
import Testing
@testable import MenuBarApp

// A clone the app runs has no terminal, so an HTTPS address that needs a login, or an SSH
// server never seen before, fails. These pin down which failures read as a sign-in
// problem, what the user is told, and which SSH address is offered.
struct GitSignInTests {

    private let github = "https://github.com/example/marketplace.git"

    // What a user saw when the app let git try to open a terminal.
    @Test func recognisesTheMissingTerminalFailure() {
        let output = """
            Cloning into '/Users/someone/Library/Application Support/com.teya.code-station/marketplaces/.marketplace-1'...
            fatal: could not read Username for 'https://github.com': Device not configured
            """
        let problem = GitSignIn.problem(in: output, address: github)
        #expect(problem?.sshAddress == "git@github.com:example/marketplace.git")
        #expect(problem?.errorDescription == problem?.message)
    }

    @Test func recognisesTheFailureWithPromptsTurnedOff() {
        #expect(GitSignIn.problem(in:
            "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
            address: github) != nil)
        #expect(GitSignIn.problem(in:
            "remote: Invalid username or token.\nfatal: Authentication failed for 'https://github.com/org/repo.git/'",
            address: github) != nil)
    }

    @Test func leavesOtherFailuresAlone() {
        #expect(GitSignIn.problem(in: "fatal: repository 'https://example.com/x.git/' not found",
                                  address: "https://example.com/x.git") == nil)
        #expect(GitSignIn.problem(in: "fatal: unable to access 'https://github.com/': Could not resolve host",
                                  address: github) == nil)
    }

    // GitHub asks for a login for a repository that does not exist too, so a typo cannot
    // be ruled out and the message has to say so.
    @Test func keepsATypoOnTheTable() {
        let message = GitSignIn.problem(in: "terminal prompts disabled", address: github)?.message ?? ""
        #expect(message.hasPrefix("GitHub asked for a sign-in"))
        #expect(message.contains("Check the address first"))
        #expect(message.contains("git@github.com:example/marketplace.git"))
        #expect(message.contains("gh auth setup-git"))
    }

    @Test func explainsOtherServersWithoutGuessing() {
        let message = GitSignIn.problem(in: "terminal prompts disabled",
                                        address: "https://git.example.com/org/repo.git")
        #expect(message?.sshAddress == nil)
        #expect(message?.message.hasPrefix("git.example.com asked for a sign-in") == true)
        #expect(message?.message.contains("many servers answer the same way") == true)
        #expect(message?.message.contains("gh auth") == false)
    }

    // ssh cannot ask to trust a new host without a terminal. It fails at once rather
    // than hanging, so what is left is saying what to do about it.
    @Test func explainsAnUntrustedHost() {
        let output = "Host key verification failed.\nfatal: Could not read from remote repository."
        let scp = GitSignIn.problem(in: output, address: "git@gitlab.com:group/repo.git")
        #expect(scp?.sshAddress == nil)
        #expect(scp?.message.hasPrefix("SSH has not been told to trust GitLab yet") == true)
        #expect(scp?.message.contains("ssh -T git@gitlab.com") == true)

        let url = GitSignIn.problem(in: output, address: "ssh://git@git.example.com/org/repo.git")
        #expect(url?.message.contains("ssh -T git@git.example.com") == true)

        let port = GitSignIn.problem(in: output, address: "ssh://git@git.example.com:2222/org/repo.git")
        #expect(port?.message.contains("Connect to it once with ssh in Terminal") == true)
    }

    @Test func explainsARejectedKey() {
        let problem = GitSignIn.problem(in: "git@github.com: Permission denied (publickey).",
                                        address: "git@github.com:org/repo.git")
        #expect(problem?.sshAddress == nil)
        #expect(problem?.message.hasPrefix("GitHub turned down your SSH key") == true)
        #expect(problem?.message.contains("ssh-add -l") == true)
    }

    @Test func offersTheSSHAddressForGitHub() {
        #expect(GitSignIn.sshAddress(for: github) == "git@github.com:example/marketplace.git")
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

    // A pasted browser address points at a page inside the repository. Turning that into
    // an SSH address would offer one that cannot work.
    @Test func ignoresBrowserPages() {
        #expect(GitSignIn.sshAddress(for: "https://github.com/org/repo/tree/main") == nil)
        #expect(GitSignIn.sshAddress(for: "https://bitbucket.org/team/repo/src/main") == nil)
        #expect(GitSignIn.sshAddress(for: "https://gitlab.com/group/repo/-/tree/main") == nil)
    }

    // Other servers choose their own SSH user and port, so no address is guessed.
    @Test func offersNothingItCannotBeSureOf() {
        #expect(GitSignIn.sshAddress(for: "https://git.example.com/org/repo.git") == nil)
        #expect(GitSignIn.sshAddress(for: "git@github.com:org/repo.git") == nil)
        #expect(GitSignIn.sshAddress(for: "https://github.com/org") == nil)
        #expect(GitSignIn.sshAddress(for: "https://github.com:8443/org/repo.git") == nil)
        #expect(GitSignIn.sshAddress(for: "https://github.com/org/repo?tab=readme") == nil)
    }
}
