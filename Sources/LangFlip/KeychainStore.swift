import Foundation
import Security

/// Tiny wrapper over the macOS Keychain Services API for the few
/// secrets we need to persist (currently: OpenAI / OpenAI-compatible
/// API keys for the Sprint H BYOK backend).
///
/// Why not UserDefaults: defaults end up in a plist under
/// ~/Library/Preferences/<bundle>.plist which is world-readable on
/// the user's account. API keys belong in Keychain so they're encrypted
/// at rest with the user's login key and protected from casual
/// inspection by other tools.
///
/// Why not encryptedUserDefaults / iCloud Keychain: we don't need
/// sync, and keeping it local-account-only matches the rest of
/// LangFlip's posture ("nothing leaves the Mac unless you explicitly
/// turn on a cloud feature").
enum KeychainStore {

    /// Service name common to every LangFlip secret. Per-secret
    /// uniqueness comes from the `account` parameter.
    static let service = "com.antonpinkevych.lang-flip"

    /// Store (or replace) a string under (`service`, `account`).
    /// Passing nil deletes the entry. Returns true on success.
    @discardableResult
    static func setString(_ value: String?, account: String) -> Bool {
        guard let value, !value.isEmpty else {
            return delete(account: account)
        }
        let data = Data(value.utf8)

        let baseQuery: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]

        // Update if entry exists, otherwise add.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        // Restrict to this user's keychain — no iCloud sync.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    /// Read the stored string for `account`, or nil if missing.
    static func getString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the entry for `account` if any. Returns true on success
    /// or when the entry didn't exist.
    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Account name constants

    /// Account key used for the cloud-AI BYOK API token. Single key
    /// covers OpenAI direct, OpenRouter, Together, Groq, etc. — the
    /// user is expected to switch the base URL when they rotate keys.
    static let openAIAPIKey = "cloud-ai-api-key"
}
