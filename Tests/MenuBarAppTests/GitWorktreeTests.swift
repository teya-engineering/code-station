import Foundation
import Testing
@testable import MenuBarApp

// Naming a worktree. The new session sheet shows the branch and folder before either
// exists, so what it shows has to be exactly what gets created.
struct GitWorktreeTests {

    private let sessionID = UUID(uuidString: "4F2AB8C1-0000-0000-0000-000000000000")!

    @Test func namesTheBranchAfterTheSession() {
        let plan = GitWorktree.plan(projectName: "Project A", sessionID: sessionID)
        #expect(plan.branch == "conductor/4f2ab8c1")
    }

    // The folder sits next to other worktrees in one directory, so it carries the project
    // name to stay recognisable and the session id to stay unique.
    @Test func keepsTheProjectRecognisableInTheFolderName() {
        let plan = GitWorktree.plan(projectName: "Project A", sessionID: sessionID)
        #expect(plan.path.hasSuffix("/Project-A-4f2ab8c1"))
        #expect(plan.path.hasPrefix(GitWorktree.baseDirectory.path))
    }

    // A name is a folder name here, so anything that is not a letter or a number becomes
    // a dash rather than a slash or a space in a path.
    @Test func replacesAnythingThatWouldUpsetAPath() {
        let plan = GitWorktree.plan(projectName: "api/v2 (old)", sessionID: sessionID)
        #expect(plan.path.hasSuffix("/api-v2--old--4f2ab8c1"))
    }

    @Test func groupsWorkspaceCheckoutsUnderTheSession() {
        let projectID = UUID(uuidString: "AABBCCDD-0000-0000-0000-000000000000")!
        let plan = GitWorktree.plan(projectName: "Project A", projectID: projectID,
                                    sessionID: sessionID)

        #expect(plan.path.hasSuffix("/4f2ab8c1/Project-A-aabbccdd"))
        #expect(plan.branch == "conductor/4f2ab8c1")
    }
}
