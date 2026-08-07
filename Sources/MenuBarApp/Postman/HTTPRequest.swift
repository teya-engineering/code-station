import Foundation
import SwiftUI

enum HTTPMethod: String, CaseIterable, Identifiable, Codable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE", head = "HEAD"

    var id: String { rawValue }

    // Reading down a list of requests, the method is what you scan for, so each one is
    // tinted: green for the safe read, warmer colours the more the call changes.
    var tint: Color {
        switch self {
        case .get, .head: Theme.addition
        case .post, .put: Theme.secret
        case .patch: Color(red: 0.35, green: 0.40, blue: 0.51)
        case .delete: Theme.deletion
        }
    }
}

// What the body is sent as. The choice picks the Content-Type header, so a request with
// no body of its own does not need one at all.
enum BodyType: String, CaseIterable, Identifiable, Codable {
    case none, json, text, form

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .json: "JSON"
        case .text: "Text"
        case .form: "Form"
        }
    }

    var contentType: String? {
        switch self {
        case .none: nil
        case .json: "application/json"
        case .text: "text/plain"
        case .form: "application/x-www-form-urlencoded"
        }
    }
}

struct HeaderField: Identifiable, Codable, Equatable {
    var id = UUID()
    var key: String
    var value: String
    // Headers are switched off rather than deleted so a token can be parked between runs.
    var enabled = true
}

struct RequestFolder: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

struct SavedRequest: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    // A missing folder keeps a request at the top level. It is optional so saved
    // collections from before folders existed continue to load unchanged.
    var folderID: UUID?
    var method: HTTPMethod = .get
    var url: String = ""
    var headers: [HeaderField] = []
    // Query params are appended to the URL as ?key=value; path params fill the :name
    // segments typed into the URL. Both are rows so they can be parked with the toggle.
    var queryParams: [HeaderField] = []
    var pathParams: [HeaderField] = []
    var bodyType: BodyType = .none
    var body: String = ""
    // Whether the collection's token is attached when the request is sent.
    var useAuth = true

    // Written by hand so a file saved before a field existed still loads, with the new
    // field taking its default instead of the whole collection being thrown away.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        method = try container.decodeIfPresent(HTTPMethod.self, forKey: .method) ?? .get
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try container.decodeIfPresent([HeaderField].self, forKey: .headers) ?? []
        queryParams = try container.decodeIfPresent([HeaderField].self, forKey: .queryParams) ?? []
        pathParams = try container.decodeIfPresent([HeaderField].self, forKey: .pathParams) ?? []
        bodyType = try container.decodeIfPresent(BodyType.self, forKey: .bodyType) ?? .none
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        useAuth = try container.decodeIfPresent(Bool.self, forKey: .useAuth) ?? true
    }

    init(id: UUID = UUID(), name: String, folderID: UUID? = nil,
         method: HTTPMethod = .get, url: String = "",
         headers: [HeaderField] = [], queryParams: [HeaderField] = [],
         pathParams: [HeaderField] = [], bodyType: BodyType = .none, body: String = "",
         useAuth: Bool = true) {
        self.id = id
        self.name = name
        self.folderID = folderID
        self.method = method
        self.url = url
        self.headers = headers
        self.queryParams = queryParams
        self.pathParams = pathParams
        self.bodyType = bodyType
        self.body = body
        self.useAuth = useAuth
    }

    // The URL with the params folded in. {{env}} is left alone, so the result is still
    // a template for the environment to resolve on send.
    var expandedURL: String {
        var expanded = url
        // Longer names go first, so :id cannot eat the front of :idType. A param with
        // no value is skipped, which leaves the placeholder visible instead of a hole.
        let paths = pathParams
            .filter { $0.enabled && !$0.key.isEmpty && !$0.value.isEmpty }
            .sorted { $0.key.count > $1.key.count }
        for param in paths {
            expanded = expanded.replacingOccurrences(of: ":" + param.key, with: param.value)
        }
        let query = queryParams
            .filter { $0.enabled && !$0.key.isEmpty }
            .map { "\(Self.queryEncoded($0.key))=\(Self.queryEncoded($0.value))" }
            .joined(separator: "&")
        guard !query.isEmpty else { return expanded }
        return expanded + (expanded.contains("?") ? "&" : "?") + query
    }

    // A space or & in a value must not change the URL's shape. Braces stay as typed so
    // {{env}} still resolves inside a param.
    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#")
        set.insert(charactersIn: "{}")
        return set
    }()

    private static func queryEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? text
    }
}

// Folders and requests are saved together so moving a request only changes one local
// collection. The custom decoder accepts a missing folders key for early collection
// files that only introduced the enclosing object.
struct SavedRequestCollection: Codable, Equatable {
    var folders: [RequestFolder]
    var requests: [SavedRequest]

    init(folders: [RequestFolder] = [], requests: [SavedRequest] = []) {
        self.folders = folders
        self.requests = requests
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folders = try container.decodeIfPresent([RequestFolder].self, forKey: .folders) ?? []
        requests = try container.decodeIfPresent([SavedRequest].self, forKey: .requests) ?? []
    }
}

// One run of a request. The failure case still carries the elapsed time, since a call
// that hangs until it times out is itself the useful part of the answer.
struct HTTPResult: Equatable {
    var status: Int
    var headers: [HeaderField]
    var body: String
    var duration: TimeInterval
    var byteCount: Int
    var failure: String?

    var statusText: String {
        guard failure == nil else { return "Failed" }
        return "\(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)"
    }

    var tint: Color {
        if failure != nil { return Theme.deletion }
        switch status {
        case 200..<300: return Theme.addition
        case 300..<400: return Theme.secret
        default: return Theme.deletion
        }
    }
}
