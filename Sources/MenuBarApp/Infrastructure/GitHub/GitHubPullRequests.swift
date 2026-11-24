import Foundation

// Talks to GitHub through the `gh` the person is already signed in to, so the app never
// holds a token of its own. The host comes off the pull request URL.
enum GitHubPullRequests {
    struct Fetched: Sendable, Equatable {
        var status: PullRequestStatus
        var reviews: [PullRequestReview]
    }

    enum Failure: Error, Equatable, Sendable {
        case noGH
        case notAPullRequest(String)
        case command(String)

        var message: String {
            switch self {
            case .noGH: "gh is not installed or not on PATH."
            case .notAPullRequest(let url): "Not a pull request URL: \(url)"
            case .command(let text): text
            }
        }
    }

    static func fetch(_ pullRequest: PullRequest) async throws -> Fetched {
        let endpoint = try Endpoint(pullRequest)
        async let statusData = api(endpoint.host, [endpoint.pulls])
        async let reviewsData = api(endpoint.host, ["\(endpoint.pulls)/reviews", "--paginate", "--slurp"])
        async let commentsData = api(endpoint.host, ["\(endpoint.pulls)/comments", "--paginate", "--slurp"])
        async let threadsData = threads(endpoint)
        guard var status = GitHubReviewParser.status(from: try await statusData) else {
            throw Failure.command("GitHub returned something that is not a pull request.")
        }
        // `--slurp` hands back one array per page, so the pages are flattened here.
        let reviewsJSON = joinPages(try await reviewsData)
        var reviews = GitHubReviewParser.reviews(reviews: reviewsJSON,
                                                 comments: joinPages(try await commentsData))
        let threadsJSON = try await threadsData
        status.reviewDecision = GitHubReviewParser.reviewDecision(from: threadsJSON)
            ?? GitHubReviewParser.reviewDecision(reviews: reviewsJSON)
        let states = GitHubReviewParser.threadStates(from: threadsJSON)
        for i in reviews.indices {
            for j in reviews[i].threads.indices {
                reviews[i].threads[j].isResolved = states[reviews[i].threads[j].id]?.isResolved ?? false
            }
        }
        return Fetched(status: status, reviews: reviews)
    }

    // Answers a line comment in its own thread, so the reply lands under the reviewer's words.
    static func reply(_ body: String, to thread: PullRequestReviewThread, on pullRequest: PullRequest) async throws {
        let endpoint = try Endpoint(pullRequest)
        // Raw, so a reply of `true` or one starting with `@someone` is sent as the words typed.
        _ = try await api(endpoint.host, ["\(endpoint.pulls)/comments/\(thread.id)/replies", "--method", "POST",
                                          "--raw-field", "body=\(body)"])
    }

    // Only GraphQL can resolve a thread, and it wants the thread's node id, which the REST
    // comments never carry, so the thread is found by its first comment's number.
    static func setResolved(_ resolved: Bool, _ thread: PullRequestReviewThread, on pullRequest: PullRequest) async throws {
        let endpoint = try Endpoint(pullRequest)
        guard let id = GitHubReviewParser.threadStates(from: try await threads(endpoint))[thread.id]?.nodeID else {
            throw Failure.command("GitHub could not find that thread.")
        }
        let mutation = resolved ? "resolveReviewThread" : "unresolveReviewThread"
        _ = try await graphql(endpoint.host, "mutation($id: ID!) { \(mutation)(input: {threadId: $id}) { thread { isResolved } } }",
                              fields: ["id=\(id)"], ints: [])
    }

    // The account gh is signed in as, whose replies count as answers.
    static func signedInLogin() async -> String? {
        guard let output = try? await run(["api", "user", "--jq", ".login"]), output.succeeded else { return nil }
        let login = output.output.trimmed
        return login.isEmpty ? nil : login
    }

    // The open pull request a checkout's branch is on, whoever opened it. Run inside the
    // checkout so gh reads the repository off its remote.
    @MainActor static func pullRequest(forBranchAt root: String) async -> PullRequest? {
        guard let branch = GitHead.branch(at: root) else { return nil }
        guard let output = try? await run(
            ["pr", "list", "--head", branch, "--state", "open", "--limit", "1", "--json", "number,url"],
            in: URL(fileURLWithPath: root)), output.succeeded else { return nil }
        return parseBranchPullRequest(Data(output.output.utf8))
    }

    private static func parseBranchPullRequest(_ data: Data) -> PullRequest? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = list.first, let number = first["number"] as? Int, let url = first["url"] as? String
        else { return nil }
        return PullRequest(number: number, url: url)
    }

    // MARK: - Running gh

    // The URL pieces `gh api` wants, checked once per call.
    private struct Endpoint {
        let host: String
        let owner: String
        let name: String
        let number: Int

        init(_ pullRequest: PullRequest) throws {
            guard let host = pullRequest.host, let owner = pullRequest.owner, let name = pullRequest.repository else {
                throw Failure.notAPullRequest(pullRequest.url)
            }
            self.host = host
            self.owner = owner
            self.name = name
            number = pullRequest.number
        }

        var pulls: String { "repos/\(owner)/\(name)/pulls/\(number)" }
    }

    // The review decision rides along, since REST has no word for it and this query is
    // already on its way.
    private static func threads(_ endpoint: Endpoint) async throws -> Data {
        try await graphql(endpoint.host, """
        query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              reviewDecision
              reviewThreads(first: 100, after: $endCursor) {
                nodes { id isResolved comments(first: 1) { nodes { databaseId } } }
                pageInfo { hasNextPage endCursor }
              }
            }
          }
        }
        """, fields: ["owner=\(endpoint.owner)", "repo=\(endpoint.name)"], ints: ["number=\(endpoint.number)"], paginate: true)
    }

    private static func graphql(_ host: String, _ query: String, fields: [String], ints: [String],
                                paginate: Bool = false) async throws -> Data {
        try await api(host, ["graphql", "--raw-field", "query=\(query)"]
                      + fields.flatMap { ["--raw-field", $0] } + ints.flatMap { ["--field", $0] }
                      + (paginate ? ["--paginate", "--slurp"] : []))
    }

    private static func api(_ host: String, _ arguments: [String]) async throws -> Data {
        let output = try await run(["api", "--hostname", host] + arguments)
        guard !output.outputTruncated else { throw Failure.command("GitHub's answer was too large to read.") }
        guard output.succeeded else {
            let message = output.errorOutput.trimmed.isEmpty ? output.output.trimmed : output.errorOutput.trimmed
            throw Failure.command(message.isEmpty ? "gh api exited with status \(output.status)." : message)
        }
        return Data(output.output.utf8)
    }

    // The full search path a Finder-launched app lacks, and never waiting on a prompt.
    private static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ProcessManager.searchPath
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        return environment
    }

    private static let outputByteLimit = 8 * 1_048_576

    private static func run(_ arguments: [String], in directory: URL? = nil) async throws -> CommandRunner.Output {
        guard let gh = ProcessManager.resolve("gh") else { throw Failure.noGH }
        do {
            return try await CommandRunner.run(executable: gh, arguments: arguments, currentDirectory: directory,
                                               environment: environment, timeout: .seconds(45),
                                               outputByteLimit: outputByteLimit)
        } catch {
            throw Failure.command(error.localizedDescription)
        }
    }

    // The same gh for a caller that is already on a git queue and cannot wait on a task.
    // Nil when gh is missing, fails, or answers with more than can be read.
    static func runBlocking(_ arguments: [String], in directory: URL, timeout: TimeInterval) -> String? {
        guard let gh = ProcessManager.resolve("gh"),
              let output = try? CommandRunner.runBlocking(
                executable: gh, arguments: arguments, currentDirectory: directory,
                environment: environment, timeout: .seconds(timeout), outputByteLimit: outputByteLimit),
              output.succeeded, !output.outputTruncated, !output.errorOutputTruncated
        else { return nil }
        return output.output
    }

    private static func joinPages(_ data: Data) -> Data {
        guard let pages = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return data }
        return (try? JSONSerialization.data(withJSONObject: pages.flatMap { $0 })) ?? data
    }
}
