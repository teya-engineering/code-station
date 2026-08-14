import Foundation
import Security

// Client secrets, access tokens and request passwords, kept where macOS keeps secrets.
// Everything sits in one keychain item as a JSON dictionary: each item carries its own
// access prompt, so one item means at most one prompt instead of one per secret.
enum Keychain {
    // What a secret is filed under. The OAuth ones are fixed, but a request that signs in
    // with a password needs a name of its own, so the set is open rather than a list.
    struct Account: Hashable, Sendable {
        let name: String

        static let stagingClientSecret = Account(name: "dispatch.staging.client-secret")
        static let stagingToken = Account(name: "dispatch.staging.token")
        static let productionClientSecret = Account(name: "dispatch.production.client-secret")
        static let productionToken = Account(name: "dispatch.production.token")

        private static let requestPrefix = "dispatch.request."
        private static let passwordSuffix = ".basic-password"

        static func basicPassword(for requestID: UUID) -> Account {
            Account(name: requestPrefix + requestID.uuidString + passwordSuffix)
        }

        // The request a stored password belongs to, and nil for every other kind of
        // secret. This is how a load sorts the request passwords out of the one item.
        var basicPasswordRequestID: UUID? {
            guard name.hasPrefix(Self.requestPrefix), name.hasSuffix(Self.passwordSuffix) else {
                return nil
            }
            return UUID(uuidString: String(name.dropFirst(Self.requestPrefix.count)
                                               .dropLast(Self.passwordSuffix.count)))
        }
    }

    private static let store = "dispatch.secrets"
    private static let legacyStore = "postman.secrets"

    struct Failure: LocalizedError {
        let operation: String
        let status: OSStatus

        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return "The Keychain could not \(operation): \(detail ?? "status \(status)")"
        }
    }

    static func values() throws -> [Account: String] {
        let rawValues: [String: String]
        if let data = try read(store) {
            rawValues = normalizedValues(
                try JSONDecoder().decode([String: String].self, from: data))
        } else {
            rawValues = try migrateLegacyItems()
        }
        return rawValues.reduce(into: [:]) { values, entry in
            values[Account(name: entry.key)] = entry.value
        }
    }

    static func replace(with values: [Account: String]) throws {
        let rawValues = values.reduce(into: [String: String]()) { result, entry in
            if !entry.value.isEmpty { result[entry.key.name] = entry.value }
        }
        try write(rawValues)
    }

    // Earlier releases used a different feature name, and older ones kept each value in
    // its own item. Gather every shape into the current combined item before cleanup.
    private static func migrateLegacyItems() throws -> [String: String] {
        var gathered = try read(legacyStore).map {
            normalizedValues(try JSONDecoder().decode([String: String].self, from: $0))
        } ?? [:]
        for (legacy, current) in legacyNames {
            for name in [current, legacy] where gathered[current] == nil {
                if let data = try read(name),
                   let value = String(data: data, encoding: .utf8), !value.isEmpty {
                    gathered[current] = value
                }
            }
        }
        guard !gathered.isEmpty else { return gathered }
        try write(gathered)
        let oldItems = [legacyStore] + legacyNames.flatMap { [$0.key, $0.value] }
        for item in oldItems {
            try delete(item)
        }
        return gathered
    }

    // A value stored by an earlier release is folded onto the name used now. Anything
    // else is kept as it is, since the store also holds a name per request.
    static func normalizedValues(_ values: [String: String]) -> [String: String] {
        var normalized = values
        for (legacy, current) in legacyNames {
            guard let value = normalized.removeValue(forKey: legacy) else { continue }
            if normalized[current] == nil { normalized[current] = value }
        }
        return normalized
    }

    private static let legacyNames = [
        "postman.staging.client-secret": Account.stagingClientSecret.name,
        "postman.staging.token": Account.stagingToken.name,
        "postman.production.client-secret": Account.productionClientSecret.name,
        "postman.production.token": Account.productionToken.name
    ]

    private static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(operation: "remove an old item", status: status)
        }
    }

    private static func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw Failure(operation: "read an item", status: status)
        }
        return item as? Data
    }

    private static func write(_ values: [String: String]) throws {
        let query = query(store)
        guard !values.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure(operation: "remove an item", status: status)
            }
            return
        }
        let data = try JSONEncoder().encode(values)

        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw Failure(operation: "update an item", status: status)
        }

        var insert = query
        insert[kSecValueData as String] = data
        // Readable once the Mac has been unlocked after a restart, which is what a
        // background refresh of a token needs.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw Failure(operation: "add an item", status: insertStatus)
        }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AppPaths.bundleID,
         kSecAttrAccount as String: account]
    }
}

struct KeychainClient: Sendable {
    var read: @Sendable () throws -> [Keychain.Account: String]
    var write: @Sendable ([Keychain.Account: String]) throws -> Void

    static let live = KeychainClient(
        read: { try Keychain.values() },
        write: { try Keychain.replace(with: $0) }
    )
}
