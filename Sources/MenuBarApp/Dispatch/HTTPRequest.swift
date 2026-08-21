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

// How a request fills in its Authorization header. Most services here take the
// environment's token, but some only ever had a username and password, so the request
// picks which one it sends.
enum AuthMode: String, CaseIterable, Identifiable, Codable {
    case none, environmentToken, basic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "No auth"
        case .environmentToken: "Environment token"
        case .basic: "Basic auth"
        }
    }
}

struct HeaderField: Identifiable, Codable, Equatable {
    var id = UUID()
    var key: String
    var value: String
    // Headers are switched off rather than deleted so a token can be parked between runs.
    var enabled = true

    // A header is written and copied as one "Name: value" line, so pasting the whole
    // line into the name box is the natural move. The colon splits it instead of
    // becoming part of the name. Whatever follows takes over the value, since a pasted
    // line is the whole header; a name ending in a bare colon leaves the value alone,
    // which is what typing the colon by hand should do.
    mutating func splitPastedName() {
        guard let colon = key.firstIndex(of: ":") else { return }
        let rest = key[key.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        key = key[..<colon].trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { value = rest }
    }

    // A field name is a token: letters, digits and a few marks, nothing else. Foundation
    // does not check, so a name with a space or a colon in it goes on the wire as typed.
    // An HTTP/1.1 server treats that as a header nobody reads, but an HTTP/2 server
    // cannot encode it at all and drops the stream, which surfaces as a lost connection
    // rather than as anything naming the header. Catching it here is the only place the
    // real reason is still known.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy(nameCharacters.contains)
    }

    private static let nameCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~")
}

struct RequestFolder: Identifiable, Codable, Equatable {
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let `default` = RequestFolder(id: defaultID, name: "Default")

    var id = UUID()
    var name: String

    var isDefault: Bool { id == Self.defaultID }

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

struct SavedRequest: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    // This stays optional so collections saved before folders existed still decode.
    // The store assigns missing and unknown folders to Default as it loads them.
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
    // What is attached as the Authorization header when the request is sent.
    var authMode: AuthMode = .environmentToken
    // The password that goes with it is held in the Keychain under this request's id, so
    // the collection file never carries one.
    var basicUsername: String = ""

    // Before the mode was a choice, a request either sent the environment's token or
    // nothing at all.
    private enum LegacyKeys: String, CodingKey { case useAuth }

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
        authMode = try container.decodeIfPresent(AuthMode.self, forKey: .authMode)
            ?? Self.legacyAuthMode(from: decoder)
        basicUsername = try container.decodeIfPresent(String.self, forKey: .basicUsername) ?? ""
    }

    private static func legacyAuthMode(from decoder: Decoder) -> AuthMode {
        guard let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
              let useAuth = try? legacy.decode(Bool.self, forKey: .useAuth) else {
            return .environmentToken
        }
        return useAuth ? .environmentToken : .none
    }

    init(id: UUID = UUID(), name: String, folderID: UUID? = nil,
         method: HTTPMethod = .get, url: String = "",
         headers: [HeaderField] = [], queryParams: [HeaderField] = [],
         pathParams: [HeaderField] = [], bodyType: BodyType = .none, body: String = "",
         authMode: AuthMode = .environmentToken, basicUsername: String = "") {
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
        self.authMode = authMode
        self.basicUsername = basicUsername
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
    // A starter request is marked when first offered, even if an identical request was
    // already saved. Deleting it later is then a lasting choice rather than a reason for
    // the site file to put it back on every launch.
    var importedSiteRequestIDs: [UUID]
    // The folders the user has opened. A folder starts closed, so one that is missing
    // here stays closed the next time the tool opens.
    var expandedFolderIDs: [UUID]

    init(folders: [RequestFolder] = [],
         requests: [SavedRequest] = [],
         importedSiteRequestIDs: [UUID] = [],
         expandedFolderIDs: [UUID] = []) {
        self.folders = folders
        self.requests = requests
        self.importedSiteRequestIDs = importedSiteRequestIDs
        self.expandedFolderIDs = expandedFolderIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folders = try container.decodeIfPresent([RequestFolder].self, forKey: .folders) ?? []
        requests = try container.decodeIfPresent([SavedRequest].self, forKey: .requests) ?? []
        importedSiteRequestIDs = try container.decodeIfPresent(
            [UUID].self, forKey: .importedSiteRequestIDs) ?? []
        expandedFolderIDs = try container.decodeIfPresent([UUID].self,
                                                          forKey: .expandedFolderIDs) ?? []
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
    var isTruncated = false

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
