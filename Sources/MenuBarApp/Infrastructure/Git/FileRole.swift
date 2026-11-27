import Foundation

enum FileRole: Sendable, CaseIterable {
    case code, test, generated

    var title: String {
        switch self {
        case .code: "Code"
        case .test: "Tests"
        case .generated: "Generated"
        }
    }

    // A refresh runs for every open project, so a file's opening bytes are only read again
    // when its size or modified time moves. `.gitattributes` is asked every time, since one
    // edit there can change any file.
    static func roles(of files: [GitChange], at root: String, reusing previous: FileRoles = FileRoles()) async -> FileRoles {
        guard !files.isEmpty else { return FileRoles() }
        let tool = Git.tool()
        let url = URL(fileURLWithPath: root)
        return await Git.offMain(lane: .interactive) {
            let marked = tool.map { markedGenerated(files.map(\.path), tool: $0, in: url) } ?? []
            var result = FileRoles()
            for file in files {
                var role = marked.contains(file.path) ? .generated : FileRole(path: file.path)
                if role != .generated, !file.isBinary, file.kind != .deleted {
                    let path = url.appendingPathComponent(file.path).path
                    if let stamp = FileStamp(path: path) {
                        let read = previous.headers[file.path].flatMap { $0.stamp == stamp ? $0 : nil }
                            ?? HeaderRead(stamp: stamp, generated: hasGeneratedHeader(path))
                        result.headers[file.path] = read
                        if read.generated { role = .generated }
                    }
                }
                result.roles[file.path] = role
            }

            return result
        }
    }

    init(path: String) {
        let parts = path.split(separator: "/").map(String.init)
        let name = parts.last ?? path
        let folders = Set(parts.dropLast())
        let slashed = "/" + path
        if !folders.isDisjoint(with: Self.generatedFolders)
            || Self.generatedPaths.contains(where: slashed.contains)
            || Self.generatedNames.contains(name)
            || Self.generatedEndings.contains(where: name.hasSuffix) {
            self = .generated
        } else if !folders.isDisjoint(with: Self.testFolders)
            || Self.testEndings.contains(where: name.hasSuffix)
            || name == "conftest.py"
            || (name.hasPrefix("test_") && name.hasSuffix(".py"))
            || (name.hasPrefix("mock_") && name.hasSuffix(".go")) {
            self = .test
        } else {
            self = .code
        }
    }

    private static let generatedFolders: Set = ["vendor", "node_modules", "dist"]
    private static let generatedPaths = ["/build/generated/", "/target/generated-sources/", "/gradle/wrapper/"]
    private static let generatedNames: Set = [
        "go.sum", "gradle.lockfile", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock",
        "Package.resolved", "poetry.lock", "Pipfile.lock", "Gemfile.lock", "composer.lock",
    ]
    private static let generatedEndings = [".pb.go", ".pb.gw.go", ".min.js", ".min.css"]
    // Mocks are often written by hand. Tools such as mockery mark their output with a
    // generated header, which still puts those files under Generated.
    private static let testFolders: Set = [
        "test", "tests", "Tests", "testdata", "integrationTest", "testFixtures", "__tests__", "__snapshots__",
        "__mocks__", "mocks", "fixtures",
    ]
    private static let testEndings = [
        "_test.go", "_mock.go", "Test.java", "Tests.java", "IT.java", "Test.kt", "Tests.kt", "IT.kt", "Spec.kt",
        "Test.groovy", "Spec.groovy", "Test.swift", "Tests.swift", "_test.py", "_spec.rb", "_test.rb", ".snap",
        ".test.ts", ".test.tsx", ".test.js", ".test.jsx", ".spec.ts", ".spec.tsx", ".spec.js", ".spec.jsx",
    ]

    private static let generatedHeaders = [
        #"(?mi)^\W*@generated\b"#, #"annotation\.(processing\.)?Generated"#, #"Code generated .*DO NOT EDIT"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static func hasGeneratedHeader(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)

        return generatedHeaders.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    // Each git call costs tens of milliseconds, so paths go in as few calls as fit under
    // the system's limit on the length of one command.
    private static func markedGenerated(_ paths: [String], tool: Git.Tool, in url: URL) -> Set<String> {
        var batches: [[String]] = [[]]
        var length = 0
        for path in paths {
            if length + path.utf8.count > 200_000, !batches[batches.count - 1].isEmpty {
                batches.append([])
                length = 0
            }
            batches[batches.count - 1].append(path)
            length += path.utf8.count + 1
        }
        var marked = Set<String>()
        for batch in batches {
            let output = Git.run(tool, ["check-attr", "-z", "linguist-generated", "linguist-vendored", "--"] + batch, in: url)
            guard output.ok else { continue }
            let fields = output.text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            for field in stride(from: 0, to: fields.count - 2, by: 3) where ["set", "true"].contains(fields[field + 2]) {
                marked.insert(fields[field])
            }
        }

        return marked
    }
}

struct FileRoles: Sendable {
    fileprivate(set) var roles: [String: FileRole] = [:]
    fileprivate var headers: [String: HeaderRead] = [:]

    subscript(path: String) -> FileRole? { roles[path] }
}

private struct HeaderRead: Sendable {
    let stamp: FileStamp
    let generated: Bool
}

private struct FileStamp: Sendable, Equatable {
    let size: Int64
    let seconds: Int
    let nanoseconds: Int

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        size = info.st_size
        seconds = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
    }
}
