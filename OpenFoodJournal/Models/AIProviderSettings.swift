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

/// The Assistant can evolve independently from the scan pipeline. Azure is
/// intentionally absent from `AIProvider` because scans still require the
/// Gemini/OpenRouter nutrition-specific adapters.
enum AssistantProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case gemini
    case openRouter
    case azureOpenAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: "Gemini"
        case .openRouter: "OpenRouter"
        case .azureOpenAI: "Azure OpenAI"
        }
    }

    var keychainAccount: String {
        switch self {
        case .gemini: KeychainService.geminiAPIKeyAccount
        case .openRouter: KeychainService.openRouterAPIKeyAccount
        case .azureOpenAI: KeychainService.azureOpenAIAPIKeyAccount
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AssistantProvider {
        if let rawValue = defaults.string(forKey: AIProviderSettings.assistantProviderKey),
           let provider = AssistantProvider(rawValue: rawValue) {
            return provider
        }

        // Existing installs used one provider for everything. Preserve that
        // choice until the user explicitly selects an Assistant provider.
        switch AIProvider.stored(in: defaults) {
        case .gemini: return .gemini
        case .openRouter: return .openRouter
        }
    }
}

/// Web research is selected independently from the conversation model so a
/// thread can use Tavily with Gemini, OpenRouter, or Azure without changing
/// the provider-neutral agent loop.
enum AssistantResearchProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case modelProvider
    case tavily
    case parallel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .modelProvider: "Model Provider"
        case .tavily: "Tavily"
        case .parallel: "Parallel"
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AssistantResearchProvider {
        guard let raw = defaults.string(forKey: AIProviderSettings.assistantResearchProviderKey),
              let provider = AssistantResearchProvider(rawValue: raw)
        else { return .modelProvider }
        return provider
    }
}

enum ParallelSearchMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case turbo
    case basic
    case advanced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .turbo: "Turbo"
        case .basic: "Basic"
        case .advanced: "Advanced"
        }
    }

    var description: String {
        switch self {
        case .turbo: "Lowest latency and cost for straightforward lookups."
        case .basic: "Fast retrieval with deeper excerpts for normal Assistant research."
        case .advanced: "Highest-quality retrieval for complex, multi-hop questions."
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> ParallelSearchMode {
        guard let raw = defaults.string(forKey: AIProviderSettings.parallelSearchModeKey),
              let mode = ParallelSearchMode(rawValue: raw)
        else { return .basic }
        return mode
    }
}

enum TavilySearchDepth: String, CaseIterable, Identifiable, Codable, Sendable {
    case fast
    case basic
    case advanced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: "Fast"
        case .basic: "Balanced"
        case .advanced: "Deep"
        }
    }

    var description: String {
        switch self {
        case .fast: "Lowest-latency search for normal Assistant research."
        case .basic: "Broader general search with standard latency."
        case .advanced: "Deeper relevance pass that uses more Tavily credits."
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> TavilySearchDepth {
        guard let raw = defaults.string(forKey: AIProviderSettings.tavilySearchDepthKey),
              let depth = TavilySearchDepth(rawValue: raw)
        else { return .fast }
        return depth
    }
}

enum AzureAssistantModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case sol = "gpt-5.6-sol"
    case terra = "gpt-5.6-terra"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sol: "GPT-5.6 Sol"
        case .terra: "GPT-5.6 Terra"
        }
    }
}

nonisolated enum ChatContextBudget: String, CaseIterable, Identifiable, Codable, Sendable {
    case efficient
    case balanced
    case maximum

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .efficient: "Efficient · 50k"
        case .balanced: "Balanced · 200k"
        case .maximum: "Maximum"
        }
    }

    func inputLimit(for descriptor: ChatModelDescriptor) -> Int {
        switch self {
        case .efficient: min(50_000, descriptor.capabilities.maximumInputTokens)
        case .balanced: min(200_000, descriptor.capabilities.maximumInputTokens)
        case .maximum: descriptor.capabilities.maximumInputTokens
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> ChatContextBudget {
        guard let raw = defaults.string(forKey: AIProviderSettings.chatContextBudgetKey),
              let value = ChatContextBudget(rawValue: raw)
        else { return .balanced }
        return value
    }
}

nonisolated struct ChatModelCapabilities: Codable, Equatable, Sendable {
    let maximumInputTokens: Int
    let maximumOutputTokens: Int
    let supportsStreaming: Bool
    let supportsFunctions: Bool
    let supportsParallelCalls: Bool
    let supportsImages: Bool
    let supportsPDFs: Bool
    let supportsWebSearch: Bool
    let supportsNativeCompaction: Bool
}

nonisolated struct ChatModelDescriptor: Codable, Equatable, Sendable {
    let provider: AssistantProvider
    /// The provider's stable base-model identifier used for capability lookup.
    let baseModelID: String
    /// The value sent in the request. Azure deployment names are user-defined.
    let deploymentIdentifier: String
    let displayName: String
    let capabilities: ChatModelCapabilities
    let lastVerifiedAt: String
}

/// Non-secret, portable model selection. Provider credentials are injected by
/// the configured-proxy factory and never serialized with a conversation.
nonisolated struct AssistantModelSelection: Codable, Equatable, Sendable {
    let descriptor: ChatModelDescriptor
    let endpoint: URL?
    let routingMode: OpenRouterRoutingMode

    var provider: AssistantProvider { descriptor.provider }
}

enum ChatModelCatalog {
    static let conservativeCapabilities = ChatModelCapabilities(
        maximumInputTokens: 50_000,
        maximumOutputTokens: 8_192,
        supportsStreaming: true,
        supportsFunctions: true,
        supportsParallelCalls: true,
        supportsImages: true,
        supportsPDFs: true,
        supportsWebSearch: true,
        supportsNativeCompaction: false
    )

    static func descriptor(
        provider: AssistantProvider,
        model: String,
        baseModelID: String? = nil
    ) -> ChatModelDescriptor {
        let base = baseModelID ?? model
        if provider == .azureOpenAI,
           let azureModel = AzureAssistantModel(rawValue: base) {
            return azureDescriptor(model: azureModel, deployment: model)
        }
        return ChatModelDescriptor(
            provider: provider,
            baseModelID: base,
            deploymentIdentifier: model,
            displayName: model,
            capabilities: conservativeCapabilities,
            lastVerifiedAt: "2026-07-20"
        )
    }

    static func azureDescriptor(
        model: AzureAssistantModel,
        deployment: String
    ) -> ChatModelDescriptor {
        ChatModelDescriptor(
            provider: .azureOpenAI,
            baseModelID: model.rawValue,
            deploymentIdentifier: deployment,
            displayName: model.displayName,
            capabilities: ChatModelCapabilities(
                maximumInputTokens: 922_000,
                maximumOutputTokens: 128_000,
                supportsStreaming: true,
                supportsFunctions: true,
                supportsParallelCalls: true,
                supportsImages: true,
                supportsPDFs: true,
                supportsWebSearch: true,
                supportsNativeCompaction: true
            ),
            lastVerifiedAt: "2026-07-20"
        )
    }
}

nonisolated struct ChatModelPricing: Equatable, Sendable {
    let inputPerMillionUSD: Double
    let cachedInputPerMillionUSD: Double
    let outputPerMillionUSD: Double
    let longContextThreshold: Int?
    let longContextInputMultiplier: Double
    let longContextCachedInputMultiplier: Double
    let longContextOutputMultiplier: Double
    /// Azure Responses `output_tokens` already includes reasoning tokens;
    /// Gemini reports them separately from candidate output.
    let outputIncludesThinking: Bool
    let source: String

    func estimatedCost(for usage: ChatTokenUsage) -> Double {
        let cached = min(max(0, usage.cachedInput), max(0, usage.input))
        let uncached = max(0, usage.input - cached)
        let isLongContext = longContextThreshold.map { usage.input > $0 } ?? false
        let inputMultiplier = isLongContext ? longContextInputMultiplier : 1
        let cachedInputMultiplier = isLongContext ? longContextCachedInputMultiplier : 1
        let outputMultiplier = isLongContext ? longContextOutputMultiplier : 1
        let billableOutput = usage.output + (outputIncludesThinking ? 0 : usage.thinking)
        return (
            Double(uncached) * inputPerMillionUSD * inputMultiplier
                + Double(cached) * cachedInputPerMillionUSD * cachedInputMultiplier
                + Double(billableOutput) * outputPerMillionUSD * outputMultiplier
        ) / 1_000_000
    }
}

nonisolated enum ChatPricingCatalog {
    static let version = "2026-07-24-v2"
    static let lastVerifiedAt = "2026-07-24"

    static func pricing(for selection: AssistantModelSelection) -> ChatModelPricing? {
        if selection.provider == .azureOpenAI,
           let model = AzureAssistantModel(rawValue: selection.descriptor.baseModelID) {
            let rates: (input: Double, cached: Double, output: Double) = switch model {
            case .sol: (5.00, 0.50, 30.00)
            case .terra: (2.50, 0.25, 15.00)
            }
            return ChatModelPricing(
                inputPerMillionUSD: rates.input,
                cachedInputPerMillionUSD: rates.cached,
                outputPerMillionUSD: rates.output,
                longContextThreshold: 272_000,
                longContextInputMultiplier: 2,
                longContextCachedInputMultiplier: 2,
                longContextOutputMultiplier: 1.5,
                outputIncludesThinking: true,
                source: "GPT-5.6 public standard token rates checked \(lastVerifiedAt); Azure agreement and deployment type may differ"
            )
        }

        guard selection.provider == .gemini else { return nil }
        let isPro = selection.descriptor.deploymentIdentifier
            .localizedCaseInsensitiveContains("pro")
        return ChatModelPricing(
            inputPerMillionUSD: isPro ? 2.00 : 1.50,
            cachedInputPerMillionUSD: isPro ? 0.20 : 0.15,
            outputPerMillionUSD: isPro ? 12.00 : 7.50,
            longContextThreshold: isPro ? 200_000 : nil,
            longContextInputMultiplier: isPro ? 2 : 1,
            longContextCachedInputMultiplier: isPro ? 2 : 1,
            longContextOutputMultiplier: isPro ? 1.5 : 1,
            outputIncludesThinking: false,
            source: "Gemini standard token-rate fallback checked \(lastVerifiedAt)"
        )
    }
}

enum AzureOpenAIEndpoint {
    enum ValidationError: LocalizedError {
        case invalidURL
        case insecureURL
        case credentialsInURL
        case unsupportedHost
        case unsupportedPort
        case unsupportedPath
        case privateDestination
        case dnsLookupFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Enter a valid Azure OpenAI resource URL."
            case .insecureURL: "Azure OpenAI endpoints must use HTTPS."
            case .credentialsInURL: "Do not include credentials in the endpoint URL."
            case .unsupportedHost: "Use an official Azure OpenAI resource host."
            case .unsupportedPort: "Azure OpenAI endpoints must use the standard HTTPS port."
            case .unsupportedPath: "Enter only the Azure resource URL; remove query parameters, fragments, and unrelated paths."
            case .privateDestination: "The Azure endpoint must resolve only to public internet addresses."
            case .dnsLookupFailed: "The Azure endpoint could not be resolved safely. Check the resource name and network connection."
            }
        }
    }

    private static let allowedSuffixes = [
        ".openai.azure.com",
        ".openai.azure.us",
        ".openai.azure.cn",
    ]

    static func normalizedBaseURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(), !host.isEmpty
        else { throw ValidationError.invalidURL }
        guard components.scheme?.lowercased() == "https" else {
            throw ValidationError.insecureURL
        }
        guard components.user == nil, components.password == nil else {
            throw ValidationError.credentialsInURL
        }
        guard allowedSuffixes.contains(where: { host.hasSuffix($0) }) else {
            throw ValidationError.unsupportedHost
        }
        guard components.port == nil || components.port == 443 else {
            throw ValidationError.unsupportedPort
        }
        let acceptedPaths = ["", "/", "/openai", "/openai/", "/openai/v1", "/openai/v1/"]
        guard acceptedPaths.contains(components.percentEncodedPath),
              components.query == nil,
              components.fragment == nil else {
            throw ValidationError.unsupportedPath
        }

        components.scheme = "https"
        components.host = host
        components.port = nil
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = "/openai/v1"
        guard let url = components.url else { throw ValidationError.invalidURL }
        return url
    }

    /// DNS validation happens before an API key is attached to a request. An
    /// official-looking hostname that resolves to a private/link-local target
    /// is rejected just like fetch_url destinations.
    static func validatePublicDestination(
        _ normalizedURL: URL,
        resolver: any ChatHostResolving = SystemChatHostResolver()
    ) throws {
        do {
            _ = try ChatURLSecurityPolicy.validatedAddresses(
                for: normalizedURL,
                resolver: resolver
            )
        } catch ChatURLSecurityError.privateAddress {
            throw ValidationError.privateDestination
        } catch ChatURLSecurityError.dnsLookupFailed {
            throw ValidationError.dnsLookupFailed
        } catch {
            throw ValidationError.invalidURL
        }
    }
}

enum AzureConnectionStatus {
    static func failureMessage(for error: Error) -> String {
        if let validation = error as? AzureOpenAIEndpoint.ValidationError {
            return validation.localizedDescription
        }
        if let chat = error as? ChatError {
            switch chat {
            case .noAPIKey:
                return "Authentication setup is incomplete: save an Azure API key."
            case .networkError(let underlying):
                return "Network error: \(underlying.localizedDescription)"
            case .serverError(let code, let detail):
                let suffix = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                switch code {
                case 401, 403:
                    return "Authentication failed: check the resource endpoint and API key."
                case 404:
                    return "Deployment not found: check this deployment name in the selected Azure resource."
                case 429:
                    return "Quota or rate limit reached: check the deployment quota and try again."
                case 400, 409, 422:
                    return "Deployment or region capability error\(suffix.isEmpty ? "." : ": \(suffix)")"
                default:
                    return "Azure service error (HTTP \(code))\(suffix.isEmpty ? "." : ": \(suffix)")"
                }
            case .cancelled:
                return "Cancelled"
            case .emptyResponse:
                return "The deployment responded without text. Verify that it supports the Responses API."
            case .invalidResponse:
                return "Azure returned an unexpected response. Verify Responses API support for this deployment and region."
            case .contextLimit(let detail):
                return detail
            case .timeout(let step, _):
                return "Azure timed out during \(step.replacingOccurrences(of: "_", with: " "))."
            case .rateLimited(_, let message):
                return message
            }
        }
        return error.localizedDescription
    }
}

enum OpenRouterRoutingMode: String, CaseIterable, Identifiable, Codable, Sendable {
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
    static let assistantProviderKey = "assistant.provider"
    static let assistantResearchProviderKey = "assistant.researchProvider"
    static let tavilySearchDepthKey = "assistant.tavily.searchDepth"
    static let parallelSearchModeKey = "assistant.parallel.searchMode"
    static let openRouterLiteModelKey = "ai.openRouter.liteModel"
    static let openRouterProModelKey = "ai.openRouter.proModel"
    static let openRouterEmojiModelKey = "ai.openRouter.emojiModel"
    static let openRouterRoutingModeKey = "ai.openRouter.routingMode"
    static let azureEndpointKey = "assistant.azure.endpoint"
    static let azureSolDeploymentKey = "assistant.azure.solDeployment"
    static let azureTerraDeploymentKey = "assistant.azure.terraDeployment"
    static let azureDefaultModelKey = "assistant.azure.defaultModel"
    nonisolated static let chatContextBudgetKey = "assistant.contextBudget"

    static let defaultProvider = AIProvider.gemini
    static let defaultOpenRouterLiteModel = "google/gemini-flash-latest"
    static let defaultOpenRouterProModel = "google/gemini-pro-latest"
    static let defaultOpenRouterEmojiModel = "google/gemini-flash-latest"
    static let defaultAzureModel = AzureAssistantModel.terra
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

    static func azureEndpoint(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: azureEndpointKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func azureDeployment(
        for model: AzureAssistantModel,
        in defaults: UserDefaults = .standard
    ) -> String {
        let key = model == .sol ? azureSolDeploymentKey : azureTerraDeploymentKey
        return defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func azureDefaultModel(in defaults: UserDefaults = .standard) -> AzureAssistantModel {
        guard let raw = defaults.string(forKey: azureDefaultModelKey),
              let model = AzureAssistantModel(rawValue: raw)
        else { return defaultAzureModel }
        return model
    }

    private static func trimmed(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}
