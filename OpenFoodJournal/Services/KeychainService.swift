// OpenFoodJournal — Keychain Service
// Provides secure storage for the user's Gemini API key using the iOS Keychain.
// The Keychain persists across app updates and is encrypted at rest by the OS.
// AGPL-3.0 License

import Foundation
import Security

// MARK: - KeychainService

/// A simple wrapper around the iOS Keychain for storing and retrieving string secrets.
/// Used primarily to store the user's Gemini API key securely — never in UserDefaults
/// or plain text, since API keys grant access to billable services.
enum KeychainService {

    // MARK: - Constants

    /// The Keychain service identifier — scoped to our app's bundle.
    /// All keys stored by this service share this identifier.
    private static let service = "k3vnc.OpenFoodJournal"

    /// The specific Keychain account name for the Gemini API key.
    /// Think of (service, account) as a composite key in a database.
    static let geminiAPIKeyAccount = "gemini-api-key"

    // MARK: - Public API

    /// Saves a string value to the Keychain under the given account name.
    /// If a value already exists for that account, it's updated in place.
    ///
    /// - Parameters:
    ///   - value: The secret string to store (e.g. an API key like "AIza...")
    ///   - account: The Keychain account identifier (use `geminiAPIKeyAccount`)
    /// - Returns: `true` if the save/update succeeded, `false` otherwise
    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        // Convert the string to raw bytes — Keychain stores Data, not String
        guard let data = value.data(using: .utf8) else { return false }

        // Build the query that identifies this specific Keychain item
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,       // Type: generic password
            kSecAttrService as String: service,                   // Our app's service ID
            kSecAttrAccount as String: account,                   // The specific key name
        ]

        // First, delete any existing value for this account.
        // SecItemUpdate is another option, but delete+add is simpler and handles
        // the "doesn't exist yet" case without branching.
        SecItemDelete(query as CFDictionary)

        // Now add the new value
        var addQuery = query
        addQuery[kSecValueData as String] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieves a string value from the Keychain for the given account.
    ///
    /// - Parameter account: The Keychain account identifier
    /// - Returns: The stored string, or `nil` if not found or on error
    static func load(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,           // We want the actual data back
            kSecMatchLimit as String: kSecMatchLimitOne, // Only one result
        ]

        // SecItemCopyMatching writes the result into `result` via pointer
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        // Convert the raw Data back to a String
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes a value from the Keychain for the given account.
    ///
    /// - Parameter account: The Keychain account identifier
    /// - Returns: `true` if deleted (or didn't exist), `false` on error
    @discardableResult
    static func delete(for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound is fine — treating "already gone" as success
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Convenience

    /// Quick check: does the user have a Gemini API key stored?
    static var hasGeminiAPIKey: Bool {
        load(for: geminiAPIKeyAccount) != nil
    }

    /// Retrieves the stored Gemini API key, if any.
    static var geminiAPIKey: String? {
        load(for: geminiAPIKeyAccount)
    }
}
