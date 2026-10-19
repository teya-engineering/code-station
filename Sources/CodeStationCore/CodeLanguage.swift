// The grammar family a piece of code is read as. It comes from a fence tag in chat or
// from a file extension elsewhere. A fence tag we do not know still gets the generic
// C-like reading, because most languages people paste look enough like C for comments,
// strings and numbers to land right. An unknown file extension gets nothing: a random
// text file coloured as code looks broken.
public enum CodeLanguage: Sendable, Equatable {
    case swift, json, yaml, shell, python, javascript, java, kotlin, go, rust, markup, sql, cLike

    public init?(tag: String?) {
        guard let tag, !tag.isEmpty else { return nil }
        self = CodeLanguage(name: tag.lowercased()) ?? .cLike
    }

    public init?(fileExtension: String) {
        guard let language = CodeLanguage(name: fileExtension.lowercased()) else { return nil }
        self = language
    }

    private init?(name: String) {
        switch name {
        case "swift": self = .swift
        case "json", "jsonc", "json5": self = .json
        case "yaml", "yml": self = .yaml
        case "bash", "sh", "zsh", "shell", "fish", "shellscript": self = .shell
        case "python", "py", "python3": self = .python
        case "javascript", "js", "mjs", "cjs", "typescript", "ts", "jsx", "tsx": self = .javascript
        case "java": self = .java
        case "kotlin", "kt", "kts": self = .kotlin
        case "go", "golang": self = .go
        case "rust", "rs": self = .rust
        case "html", "htm", "xml", "svg", "xhtml", "plist", "xib", "storyboard": self = .markup
        case "sql", "postgres", "postgresql", "mysql", "sqlite", "psql": self = .sql
        case "c", "h", "cpp", "hpp", "cc", "hh", "cxx", "m", "mm", "cs", "scala",
             "groovy", "gradle", "php", "dart", "proto": self = .cLike
        default: return nil
        }
    }
}
