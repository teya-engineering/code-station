import Foundation

public struct AgentMessageFramer {
    public enum Format { case jsonLines, contentLength }
    public enum Failure: Error { case invalidLength }

    public let format: Format
    private var buffer = Data()

    public init(format: Format) { self.format = format }

    public mutating func append(_ data: Data) { buffer.append(data) }

    public mutating func next() throws -> Data? {
        if format == .jsonLines {
            guard let end = buffer.firstIndex(of: 0x0A) else { return nil }
            let body = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            return body
        }
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        guard let line = header.components(separatedBy: "\r\n").first(where: {
            $0.lowercased().hasPrefix("content-length:")
        }), let length = Int(String(line.dropFirst("Content-Length:".count)).trimmed),
              (0...32 * 1024 * 1024).contains(length) else {
            buffer.removeAll()
            throw Failure.invalidLength
        }
        guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(end.upperBound, offsetBy: length)
        let body = Data(buffer[end.upperBound..<bodyEnd])
        buffer.removeSubrange(..<bodyEnd)
        return body
    }
}
