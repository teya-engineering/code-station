import Foundation
import Security

// Client secrets and access tokens, kept where macOS keeps secrets. Everything sits in
// one keychain item as a JSON dictionary: each item carries its own access prompt, so
// one item means at most one prompt instead of one per secret.
enum Keychain {
    enum Account: String, CaseIterable, Sendable {
        case stagingClientSecret = "dispatch.staging.client-secret"
        case stagingToken = "dispatch.staging.token"
        case productionClientSecret = "dispatch.production.client-secret"
        case productionToken = "dispatch.production.token"
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
        return Account.allCases.reduce(into: [:]) { values, account in
            values[account] = rawValues[account.rawValue]
        }
    }

    static func replace(with values: [Account: String]) throws {
        let rawValues = values.reduce(into: [String: String]()) { result, entry in
            if !entry.value.isEmpty { result[entry.key.rawValue] = entry.value }
        }
        try write(rawValues)
    }

    // Earlier releases used a different feature name, and older ones kept each value in
    // its own item. Gather every shape into the current combined item before cleanup.
    private static func migrateLegacyItems() throws -> [String: String] {
        var gathered = try read(legacyStore).map {
            normalizedValues(try JSONDecoder().decode([String: String].self, from: $0))
        } ?? [:]
        for account in Account.allCases {
            let names = [account.rawValue, legacyName(for: account)]
            for name in names where gathered[account.rawValue] == nil {
                if let data = try read(name),
                   let value = String(data: data, encoding: .utf8), !value.isEmpty {
                    gathered[account.rawValue] = value
                }
            }
        }
        guard !gathered.isEmpty else { return gathered }
        try write(gathered)
        let oldItems = [legacyStore] + Account.allCases.flatMap {
            [$0.rawValue, legacyName(for: $0)]
        }
        for item in oldItems {
            try delete(item)
        }
        return gathered
    }

    static func normalizedValues(_ values: [String: String]) -> [String: String] {
        Account.allCases.reduce(into: [:]) { result, account in
            result[account.rawValue] = values[account.rawValue]
                ?? values[legacyName(for: account)]
        }
    }

    private static func legacyName(for account: Account) -> String {
        switch account {
        case .stagingClientSecret: "postman.staging.client-secret"
        case .stagingToken: "postman.staging.token"
        case .productionClientSecret: "postman.production.client-secret"
        case .productionToken: "postman.production.token"
        }
    }

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
