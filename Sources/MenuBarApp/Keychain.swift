import Foundation
import Security

// Client secrets and access tokens, kept where macOS keeps secrets. Everything sits in
// one keychain item as a JSON dictionary: each item carries its own access prompt, so
// one item means at most one prompt instead of one per secret.
enum Keychain {
    enum Account: String, CaseIterable {
        case stagingClientSecret = "postman.staging.client-secret"
        case stagingToken = "postman.staging.token"
        case productionClientSecret = "postman.production.client-secret"
        case productionToken = "postman.production.token"
    }

    private static let store = "postman.secrets"

    static func string(_ account: Account) -> String? {
        values()[account.rawValue]
    }

    // An empty value removes the entry, so clearing a secret does not leave one behind.
    static func set(_ value: String?, for account: Account) {
        var all = values()
        if let value, !value.isEmpty {
            all[account.rawValue] = value
        } else {
            all.removeValue(forKey: account.rawValue)
        }
        write(all)
    }

    private static func values() -> [String: String] {
        if let data = read(store),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            return stored
        }
        return migrateLegacyItems()
    }

    // The secrets used to live in one keychain item each. Gather them into the combined
    // item and delete the originals, so an old install carries over without leftovers.
    private static func migrateLegacyItems() -> [String: String] {
        var gathered: [String: String] = [:]
        for account in Account.allCases {
            if let data = read(account.rawValue),
               let value = String(data: data, encoding: .utf8), !value.isEmpty {
                gathered[account.rawValue] = value
            }
        }
        guard !gathered.isEmpty, write(gathered) else { return gathered }
        for account in Account.allCases {
            SecItemDelete(query(account.rawValue) as CFDictionary)
        }
        return gathered
    }

    private static func read(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    private static func write(_ values: [String: String]) -> Bool {
        let query = query(store)
        guard !values.isEmpty, let data = try? JSONEncoder().encode(values) else {
            SecItemDelete(query as CFDictionary)
            return true
        }

        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }

        var insert = query
        insert[kSecValueData as String] = data
        // Readable once the Mac has been unlocked after a restart, which is what a
        // background refresh of a token needs.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AppPaths.bundleID,
         kSecAttrAccount as String: account]
    }
}
