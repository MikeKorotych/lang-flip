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

    /// Service name common to every stored secret. Per-secret uniqueness comes
    /// from the `account` parameter. Intentionally kept as the original
    /// `com.antonpinkevych.lang-flip` string across the Sayful rename: it's an
    /// opaque Keychain service id, not the app's bundle id, so leaving it
    /// unchanged means existing API keys are still found (no Keychain migration).
    static let service = "com.antonpinkevych.lang-flip"

    /// Secrets should stay on this Mac and should not be readable while the
    /// user session is locked. This matches the app's interactive use: dictation,
    /// text fixes, and account refreshes happen only after the user is present.
    static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    /// Store (or replace) a string under (`service`, `account`).
    /// Passing nil deletes the entry. Returns true on success.
    @discardableResult
    static func setString(_ value: String?, account: String) -> Bool {
        guard let value, !value.isEmpty else {
            return delete(account: account)
        }
        let data = Data(value.utf8)

        let baseQuery = baseQuery(account: account)

        // Update if entry exists, otherwise add.
        let updateAttrs = storageAttributes(data: data)
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        let addQuery = addQuery(account: account, data: data)
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    /// Read the stored string for `account`, or nil if missing.
    static func getString(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the entry for `account` if any. Returns true on success
    /// or when the entry didn't exist.
    @discardableResult
    static func delete(account: String) -> Bool {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func storageAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func addQuery(account: String, data: Data) -> [String: Any] {
        var query = baseQuery(account: account)
        for (key, value) in storageAttributes(data: data) {
            query[key] = value
        }
        return query
    }

    // MARK: - Account name constants

    /// Account key used for the cloud-AI BYOK API token. Single key
    /// covers OpenAI direct, OpenRouter, Together, Groq, etc. — the
    /// user is expected to switch the base URL when they rotate keys.
    static let openAIAPIKey = "cloud-ai-api-key"

    /// Backend session tokens (WS1 `.backend` mode) — never a provider key.
    static let backendAccessToken = "backend-access-token"
    static let backendRefreshToken = "backend-refresh-token"

}
