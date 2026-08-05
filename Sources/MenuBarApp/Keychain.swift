import Foundation
import Security

// Client secrets and access tokens, kept where macOS keeps secrets. A file with tight
// permissions is better than nothing, but it still ends up in backups and in anything
// that reads the app's directory.
enum Keychain {
    enum Account: String {
        case oauthClientSecret = "postman.oauth.client-secret"
        case oauthToken = "postman.oauth.token"
    }

    static func string(_ account: Account) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // An empty value removes the item, so clearing a secret does not leave one behind.
    static func set(_ value: String?, for account: Account) {
        let query = base(account)
        guard let value, !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }

        var insert = query
        insert[kSecValueData as String] = data
        // Readable once the Mac has been unlocked after a restart, which is what a
        // background refresh of a token needs.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    private static func base(_ account: Account) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AppPaths.bundleID,
         kSecAttrAccount as String: account.rawValue]
    }
}
