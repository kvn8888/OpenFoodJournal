// OpenFoodJournal — AI Provider Settings
// Runtime configuration for choosing the AI backend used by scans and searches.
// AGPL-3.0 License

import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case gemini
    case openRouter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: "Gemini"
        case .openRouter: "OpenRouter"
        }
    }

    var keychainAccount: String {
        switch self {
        case .gemini: KeychainService.geminiAPIKeyAccount
        case .openRouter: KeychainService.openRouterAPIKeyAccount
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AIProvider {
        guard let rawValue = defaults.string(forKey: AIProviderSettings.providerKey),
              let provider = AIProvider(rawValue: rawValue)
        else {
            return .gemini
        }
        return provider
    }
}

enum OpenRouterRoutingMode: String, CaseIterable, Identifiable {
    case automatic
    case preferGoogleVertex
    case requireGoogleVertex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .preferGoogleVertex: "Prefer Google Vertex"
        case .requireGoogleVertex: "Require Google Vertex"
        }
    }

    var description: String {
        switch self {
        case .automatic:
            return "OpenRouter chooses the provider route."
        case .preferGoogleVertex:
            return "OpenRouter tries Google Vertex first, then may fall back."
        case .requireGoogleVertex:
            return "OpenRouter uses only Google Vertex routes."
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> OpenRouterRoutingMode {
        guard let rawValue = defaults.string(forKey: AIProviderSettings.openRouterRoutingModeKey),
              let mode = OpenRouterRoutingMode(rawValue: rawValue)
        else {
            return .automatic
        }
        return mode
    }
}

enum AIProviderSettings {
    static let providerKey = "ai.provider"
    static let openRouterLiteModelKey = "ai.openRouter.liteModel"
    static let openRouterProModelKey = "ai.openRouter.proModel"
    static let openRouterEmojiModelKey = "ai.openRouter.emojiModel"
    static let openRouterRoutingModeKey = "ai.openRouter.routingMode"

    static let defaultProvider = AIProvider.gemini
    static let defaultOpenRouterLiteModel = "google/gemini-flash-latest"
    static let defaultOpenRouterProModel = "google/gemini-pro-latest"
    static let defaultOpenRouterEmojiModel = "google/gemini-flash-latest"
    static let googleVertexProviderSlug = "google-vertex"

    static func openRouterLiteModel(in defaults: UserDefaults = .standard) -> String {
        trimmed(defaults.string(forKey: openRouterLiteModelKey), fallback: defaultOpenRouterLiteModel)
    }

    static func openRouterProModel(in defaults: UserDefaults = .standard) -> String {
        trimmed(defaults.string(forKey: openRouterProModelKey), fallback: defaultOpenRouterProModel)
    }

    static func openRouterEmojiModel(in defaults: UserDefaults = .standard) -> String {
        trimmed(defaults.string(forKey: openRouterEmojiModelKey), fallback: defaultOpenRouterEmojiModel)
    }

    private static func trimmed(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}
