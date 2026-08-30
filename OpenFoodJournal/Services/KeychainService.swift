// OpenFoodJournal — Keychain Service
// Provides secure storage for user-owned API keys using the iOS Keychain.
// The Keychain persists across app updates and is encrypted at rest by the OS.
// AGPL-3.0 License

import Foundation
import Security

// MARK: - KeychainService

/// A simple wrapper around the iOS Keychain for storing and retrieving string secrets.
/// Used primarily to store user AI provider keys securely — never in UserDefaults
/// or plain text, since API keys grant access to billable services.
enum KeychainService {

    // MARK: - Constants

    /// The Keychain service identifier — scoped to our app's bundle.
    /// All keys stored by this service share this identifier.
    private static let service = "k3vnc.OpenFoodJournal"

    /// The specific Keychain account name for the Gemini API key.
    /// Think of (service, account) as a composite key in a database.
    static let geminiAPIKeyAccount = "gemini-api-key"

    /// OpenRouter API key for model-router access. This is separate from the
    /// Gemini key so users can switch providers without overwriting secrets.
    static let openRouterAPIKeyAccount = "openrouter-api-key"

    /// Azure OpenAI uses its own resource-scoped key. Keeping it in a distinct
    /// account prevents provider switching or backups from exposing it.
    static let azureOpenAIAPIKeyAccount = "azure-openai-api-key"

    static let openAIAPIKeyAccount = "openai-api-key"
    static let anthropicAPIKeyAccount = "anthropic-api-key"
    static let museSparkAPIKeyAccount = "muse-spark-api-key"

    /// Tavily is an independent Assistant research provider. Its credential
    /// is never shared with the selected conversation model or exported.
    static let tavilyAPIKeyAccount = "tavily-api-key"

    /// Parallel Search is independent from the conversation model and Tavily,
    /// so it receives its own non-exportable Keychain account.
    static let parallelAPIKeyAccount = "parallel-api-key"
    static let exaAPIKeyAccount = "exa-api-key"

    /// Optional Turso mirror credentials. These are user-owned debugging
    /// database secrets and must never be copied into UserDefaults or logs.
    static let tursoDatabaseURLAccount = "turso-database-url"
    static let tursoAuthTokenAccount = "turso-auth-token"

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

    /// Quick check: does the user have an OpenRouter API key stored?
    static var hasOpenRouterAPIKey: Bool {
        load(for: openRouterAPIKeyAccount) != nil
    }

    /// Retrieves the stored OpenRouter API key, if any.
    static var openRouterAPIKey: String? {
        load(for: openRouterAPIKeyAccount)
    }

    /// Quick check: does the user have an Azure OpenAI API key stored?
    static var hasAzureOpenAIAPIKey: Bool {
        load(for: azureOpenAIAPIKeyAccount) != nil
    }

    /// Retrieves the stored Azure OpenAI API key, if any.
    static var azureOpenAIAPIKey: String? {
        load(for: azureOpenAIAPIKeyAccount)
    }

    static var hasOpenAIAPIKey: Bool { load(for: openAIAPIKeyAccount) != nil }
    static var openAIAPIKey: String? { load(for: openAIAPIKeyAccount) }
    static var hasAnthropicAPIKey: Bool { load(for: anthropicAPIKeyAccount) != nil }
    static var anthropicAPIKey: String? { load(for: anthropicAPIKeyAccount) }
    static var hasMuseSparkAPIKey: Bool { load(for: museSparkAPIKeyAccount) != nil }
    static var museSparkAPIKey: String? { load(for: museSparkAPIKeyAccount) }

    static var hasTavilyAPIKey: Bool {
        load(for: tavilyAPIKeyAccount) != nil
    }

    static var tavilyAPIKey: String? {
        load(for: tavilyAPIKeyAccount)
    }

    static var hasParallelAPIKey: Bool {
        load(for: parallelAPIKeyAccount) != nil
    }

    static var parallelAPIKey: String? {
        load(for: parallelAPIKeyAccount)
    }

    static var hasExaAPIKey: Bool { load(for: exaAPIKeyAccount) != nil }
    static var exaAPIKey: String? { load(for: exaAPIKeyAccount) }

    /// Retrieves the API key for whichever provider is currently selected.
    static func apiKey(for provider: AIProvider) -> String? {
        load(for: provider.keychainAccount)
    }

    /// Retrieves the API key for the independently selected Assistant provider.
    static func apiKey(for provider: AssistantProvider) -> String? {
        load(for: provider.keychainAccount)
    }

    /// Quick check: does the user have both Turso mirror credential fields saved?
    static var hasTursoCredentials: Bool {
        tursoDatabaseURL != nil && tursoAuthToken != nil
    }

    /// Retrieves the stored Turso database URL, if any.
    static var tursoDatabaseURL: String? {
        load(for: tursoDatabaseURLAccount)
    }

    /// Retrieves the stored Turso database token, if any.
    static var tursoAuthToken: String? {
        load(for: tursoAuthTokenAccount)
    }
}
