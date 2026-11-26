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

    static func roles(of files: [GitChange], at root: String) async -> [String: FileRole] {
        guard !files.isEmpty else { return [:] }
        let tool = Git.tool()
        let url = URL(fileURLWithPath: root)
        return await Git.offMain(lane: .interactive) {
            let marked = tool.map { markedGenerated(files.map(\.path), tool: $0, in: url) } ?? []
            var roles: [String: FileRole] = [:]
            for file in files {
                var role = marked.contains(file.path) ? .generated : FileRole(path: file.path)
                if role != .generated, !file.isBinary, file.kind != .deleted,
                   hasGeneratedHeader(url.appendingPathComponent(file.path)) {
                    role = .generated
                }
                roles[file.path] = role
            }

            return roles
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
            || Self.generatedEndings.contains(where: name.hasSuffix)
            || (name.hasPrefix("mock_") && name.hasSuffix(".go")) {
            self = .generated
        } else if !folders.isDisjoint(with: Self.testFolders)
            || Self.testEndings.contains(where: name.hasSuffix)
            || name == "conftest.py"
            || (name.hasPrefix("test_") && name.hasSuffix(".py")) {
            self = .test
        } else {
            self = .code
        }
    }

    private static let generatedFolders: Set = ["vendor", "mocks", "node_modules", "dist"]
    private static let generatedPaths = ["/build/generated/", "/target/generated-sources/", "/gradle/wrapper/"]
    private static let generatedNames: Set = [
        "go.sum", "gradle.lockfile", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock",
        "Package.resolved", "poetry.lock", "Pipfile.lock", "Gemfile.lock", "composer.lock",
    ]
    private static let generatedEndings = [".pb.go", ".pb.gw.go", "_mock.go", ".min.js", ".min.css"]
    private static let testFolders: Set = [
        "test", "tests", "Tests", "testdata", "integrationTest", "testFixtures", "__tests__", "__snapshots__", "fixtures",
    ]
    private static let testEndings = [
        "_test.go", "Test.java", "Tests.java", "IT.java", "Test.kt", "Tests.kt", "Spec.kt", "Tests.swift",
        "_test.py", ".snap", ".test.ts", ".test.tsx", ".test.js", ".test.jsx", ".spec.ts", ".spec.tsx", ".spec.js",
        ".spec.jsx",
    ]

    private static func isGeneratedHeader(_ text: String) -> Bool {
        [#"(?mi)^\W*@generated\b"#, #"annotation\.(processing\.)?Generated"#, #"Code generated .*DO NOT EDIT"#]
            .contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func hasGeneratedHeader(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512) else { return false }

        return isGeneratedHeader(String(decoding: data, as: UTF8.self))
    }

    private static func markedGenerated(_ paths: [String], tool: Git.Tool, in url: URL) -> Set<String> {
        let output = Git.run(tool, ["check-attr", "-z", "linguist-generated", "linguist-vendored", "--"] + paths, in: url)
        guard output.ok else { return [] }
        let fields = output.text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var marked = Set<String>()
        for start in stride(from: 0, to: fields.count - 2, by: 3) where ["set", "true"].contains(fields[start + 2]) {
            marked.insert(fields[start])
        }

        return marked
    }
}
