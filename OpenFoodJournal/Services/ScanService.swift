// OpenFoodJournal — Scan Service (BYOK AI Providers)
// Calls the selected AI provider directly from the device using the user's own API key.
// Gemini remains the default; OpenRouter can route requests to Google Vertex or other models.
// AGPL-3.0 License

import Foundation
import UIKit
import Observation
import SwiftData

// MARK: - Scan Errors

enum ScanError: LocalizedError {
    case imageEncodingFailed
    case noImages
    case tooManyImages(Int)
    case emptySearchQuery
    case networkError(Error)
    case invalidResponse
    case invalidEmojiResponse(String)
    case invalidGeneratedImageResponse(String)
    case serverError(Int, String)
    case decodingError(Error)
    case noAPIKey
    case noProviderAPIKey(String)

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed: "Failed to encode image for upload."
        case .noImages: "Add at least one photo before analyzing."
        case .tooManyImages(let maximum): "Choose up to \(maximum) photos for one scan."
        case .emptySearchQuery: "Enter a food or product to search for."
        case .networkError(let e): "Network error: \(e.localizedDescription)"
        case .invalidResponse: "Received an invalid response from the server."
        case .invalidEmojiResponse(let text): "Gemini did not return a usable food emoji: \(text)"
        case .invalidGeneratedImageResponse(let text): "Gemini did not return a usable food icon image: \(text)"
        case .serverError(let code, let msg): "Server error \(code): \(msg)"
        case .decodingError(let e): "Failed to parse nutrition data: \(e.localizedDescription)"
        case .noAPIKey: "No Gemini API key configured. Add your key in Settings."
        case .noProviderAPIKey(let provider): "No \(provider) API key configured. Add your key in Settings."
        }
    }
}

struct CalculatorPortionDraft: Codable, Sendable {
    var label: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var micronutrients: [String: MicronutrientValue]

    init(
        label: String,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        micronutrients: [String: MicronutrientValue] = [:]
    ) {
        self.label = label
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.micronutrients = micronutrients
    }

    enum CodingKeys: String, CodingKey {
        case label
        case calories
        case protein
        case carbs
        case fat
        case micronutrients
    }
}

struct CalculatorIngredientDraft: Codable, Sendable {
    var name: String
    var portions: [CalculatorPortionDraft]
}

private struct GeminiFoodEmojiResponse: Codable {
    let emoji: String
}

private struct FoodIconImagePrompt: Encodable {
    let brand: String?
    let item: String

    enum CodingKeys: String, CodingKey {
        case brand = "Brand"
        case item
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(item, forKey: .item)
        try container.encodeIfPresent(brand, forKey: .brand)
    }
}

// MARK: - Gemini Interactions API Types

/// App-level request payload before the model is injected for a specific attempt.
/// The wire body is `GeminiInteractionRequest`, built by `interactionBody(model:)`.
private struct GeminiRequest: Encodable {
    let input: [GeminiContent]
    let tools: [GeminiTool]?
    let responseFormat: GeminiResponseFormat
    let generationConfig: GeminiGenerationConfig
    let stream: Bool
    let store: Bool

    init(
        input: [GeminiContent],
        generationConfig: GeminiGenerationConfig,
        tools: [GeminiTool]? = nil,
        responseFormat: GeminiResponseFormat = .jsonText,
        stream: Bool = true,
        store: Bool = false
    ) {
        self.input = input
        self.tools = tools?.isEmpty == true ? nil : tools
        self.responseFormat = responseFormat
        self.generationConfig = generationConfig
        self.stream = stream
        self.store = store
    }

    func interactionBody(model: String) -> GeminiInteractionRequest {
        GeminiInteractionRequest(
            model: model,
            input: input,
            tools: tools,
            responseFormat: responseFormat,
            generationConfig: generationConfig,
            stream: stream,
            store: store
        )
    }
}

/// The top-level Interactions request body sent over the wire.
private struct GeminiInteractionRequest: Encodable {
    let model: String
    let input: [GeminiContent]
    let tools: [GeminiTool]?
    let responseFormat: GeminiResponseFormat
    let generationConfig: GeminiGenerationConfig
    let stream: Bool
    let store: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case tools
        case responseFormat = "response_format"
        case generationConfig = "generation_config"
        case stream
        case store
    }
}

/// A single Interactions content block. Unlike generateContent parts, each block
/// is first-class and typed (`text`, `image`, etc.).
private enum GeminiContent: Codable {
    case text(String)
    case image(mimeType: String, data: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case data
        case mimeType = "mime_type"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let mimeType, let data):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            self = .image(
                mimeType: try container.decode(String.self, forKey: .mimeType),
                data: try container.decode(String.self, forKey: .data)
            )
        default:
            self = .text("")
        }
    }
}

/// Built-in Gemini tools. Interactions represents tools by a `type` discriminator.
private struct GeminiTool: Codable {
    let type: String

    static let googleSearch = GeminiTool(type: "google_search")
}

private struct GeminiResponseFormat: Encodable {
    let type: String
    let mimeType: String

    static let jsonText = GeminiResponseFormat(type: "text", mimeType: "application/json")

    enum CodingKeys: String, CodingKey {
        case type
        case mimeType = "mime_type"
    }
}

/// Controls response shape and thought-summary streaming for Interactions.
private struct GeminiGenerationConfig: Codable {
    let thinkingLevel: String
    let thinkingSummaries: String

    enum CodingKeys: String, CodingKey {
        case thinkingLevel = "thinking_level"
        case thinkingSummaries = "thinking_summaries"
    }

    init(thinkingLevel: String, thinkingSummaries: String = "auto") {
        self.thinkingLevel = thinkingLevel
        self.thinkingSummaries = thinkingSummaries
    }
}

private struct GeminiImageGenerationRequest: Encodable {
    let model: String
    let input: String
    let systemInstruction: String
    let generationConfig: GeminiImageGenerationConfig
    let responseModalities: [String]

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case systemInstruction = "system_instruction"
        case generationConfig = "generation_config"
        case responseModalities = "response_modalities"
    }
}

private struct GeminiImageGenerationConfig: Encodable {
    let temperature: Double
    let maxOutputTokens: Int
    let topP: Double
    let thinkingLevel: String
    let imageConfig: GeminiImageConfig

    enum CodingKeys: String, CodingKey {
        case temperature
        case maxOutputTokens = "max_output_tokens"
        case topP = "top_p"
        case thinkingLevel = "thinking_level"
        case imageConfig = "image_config"
    }
}

private struct GeminiImageConfig: Encodable {
    let aspectRatio: String
    let imageSize: String

    enum CodingKeys: String, CodingKey {
        case aspectRatio = "aspect_ratio"
        case imageSize = "image_size"
    }
}

private struct GeneratedFoodIconImage: Sendable {
    let data: Data
    let mimeType: String
}

private struct GeminiInteractionResponseEnvelope: Decodable {
    let interaction: GeminiInteractionResource?
    let usage: GeminiInteractionUsage?
    let metadata: GeminiStreamMetadata?
}

private struct GeminiInteractionSSEEvent: Decodable {
    let eventType: String?
    let interaction: GeminiInteractionResource?
    let step: GeminiInteractionStep?
    let delta: GeminiInteractionDelta?
    let usage: GeminiInteractionUsage?
    let metadata: GeminiStreamMetadata?
    let error: GeminiAPIError?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case interaction
        case step
        case delta
        case usage
        case metadata
        case error
    }
}

private struct GeminiInteractionResource: Decodable {
    let id: String?
    let model: String?
    let status: String?
    let usage: GeminiInteractionUsage?
}

private struct GeminiInteractionStep: Decodable {
    let type: String?
}

private struct GeminiInteractionDelta: Decodable {
    let type: String?
    let text: String?
    let signature: String?
    let content: GeminiInteractionContentBlock?
}

private struct GeminiInteractionContentBlock: Decodable {
    let type: String?
    let text: String?
}

private struct GeminiStreamMetadata: Decodable {
    let totalUsage: GeminiInteractionUsage?

    enum CodingKeys: String, CodingKey {
        case totalUsage = "total_usage"
    }
}

private struct GeminiInteractionUsage: Codable {
    let totalInputTokens: Int?
    let totalOutputTokens: Int?
    let totalThoughtTokens: Int?
    let totalTokens: Int?
    let totalToolUseTokens: Int?
    let groundingToolCount: [GeminiGroundingToolCount]?

    enum CodingKeys: String, CodingKey {
        case totalInputTokens = "total_input_tokens"
        case totalOutputTokens = "total_output_tokens"
        case totalThoughtTokens = "total_thought_tokens"
        case totalTokens = "total_tokens"
        case totalToolUseTokens = "total_tool_use_tokens"
        case groundingToolCount = "grounding_tool_count"
    }
}

private struct GeminiGroundingToolCount: Codable {
    let type: String?
    let count: Int?
}

/// Error response from the Gemini API (e.g. invalid key, quota exceeded).
private struct GeminiAPIError: Codable {
    let code: Int?
    let message: String?
    let status: String?
}

private struct GeminiAPIErrorEnvelope: Decodable {
    let error: GeminiAPIError?
}

// MARK: - Nutrition Response Shape

/// The JSON structure we ask Gemini to return in its response.
/// Core macros are required; micronutrients is a flexible dictionary.
private struct GeminiNutritionResponse: Codable {
    let name: String
    let brand: String?
    let confidence: Double?
    let servingSize: String?
    let servingQuantity: Double?
    let servingUnit: String?
    let servingWeightGrams: Double?
    let servingsPerContainer: Double?
    // Structured serving fields — populated by Gemini prompt
    let servingType: String?   // "mass" | "volume" | "both"
    let servingGrams: Double?  // gram weight of one serving
    let servingMl: Double?     // mL of one serving (nil for solid foods)

    // Core macros — always present
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double

    // Dynamic micronutrients — Gemini returns whatever it finds on the label/food.
    let micronutrients: [String: MicronutrientValue]?

    let scanMode: String?

    enum CodingKeys: String, CodingKey {
        case name, brand, confidence, calories, protein, carbs, fat
        case micronutrients
        case servingSize = "serving_size"
        case servingQuantity = "serving_quantity"
        case servingUnit = "serving_unit"
        case servingWeightGrams = "serving_weight_grams"
        case servingsPerContainer = "servings_per_container"
        case servingType = "serving_type"
        case servingGrams = "serving_grams"
        case servingMl = "serving_ml"
        case scanMode = "scan_mode"
    }
}

// MARK: - Model Configuration

/// Defines which Gemini model to use for each scan mode.
/// Label scans use a fast, lightweight model; food photo scans use a reasoning model.
private struct ModelConfig {
    let primary: String       // Primary model name
    let fallback: String      // Fallback if primary returns 500/503
    let thinkingLevel: String // "low" for speed, "high" for accuracy

    var expectsThinkingTrace: Bool {
        thinkingLevel != "none"
    }

    // Keep these on Google's latest aliases. Do not replace them with concrete
    // dated, preview, or versioned Gemini model slugs unless Google removes the
    // latest endpoints entirely.
    private static let flashLatest = "gemini-flash-latest"
    private static let proLatest = "gemini-pro-latest"

    /// Label scans: latest Flash with low thinking.
    /// Optimized for OCR — reads text accurately with low latency (~2-4s).
    static let label = ModelConfig(
        primary: flashLatest,
        fallback: flashLatest,
        thinkingLevel: "low"
    )

    /// Food photo scans (Pro): latest Pro with high thinking.
    /// Needs reasoning to estimate portion sizes and nutrient content (~4-8s).
    static let foodPhoto = ModelConfig(
        primary: proLatest,
        fallback: flashLatest,
        thinkingLevel: "high"
    )

    /// Food photo scans (Lite): uses latest Flash for faster, cheaper estimates.
    /// Less accurate than Pro but still reasonable for common foods (~2-4s).
    static let foodPhotoLite = ModelConfig(
        primary: flashLatest,
        fallback: flashLatest,
        thinkingLevel: "low"
    )

    /// AI Search uses the same user-facing model preference as food photos:
    /// Flash for speed/quota, Pro when the Settings toggle is enabled.
    static func aiSearch(useProModel: Bool) -> ModelConfig {
        useProModel ? foodPhoto : foodPhotoLite
    }

    /// Food Bank emoji assignment uses the lightweight latest Flash alias.
    /// Never replace this with a concrete Flash-Lite preview/versioned slug.
    /// If Google exposes a stable Flash-Lite latest alias, add that alias here
    /// rather than pinning to a dated model.
    static let foodEmoji = ModelConfig(
        primary: flashLatest,
        fallback: flashLatest,
        thinkingLevel: "low"
    )
}

struct ScanRedoRequest {
    let images: [UIImage]
    let mode: ScanMode
    let prompt: String?
    let useProModel: Bool
    let submittedAt: Date

    var photoCount: Int { images.count }
}

private struct PreparedGeminiImage {
    let data: Data
    let metadata: GeminiImageLogMetadata
}

private struct GeminiImageLogMetadata: Codable {
    let index: Int
    let originalWidthPx: Int
    let originalHeightPx: Int
    let resizedWidthPx: Int
    let resizedHeightPx: Int
    let jpegBytes: Int
    let jpegQuality: Double
}

private struct GeminiGeneratedFoodIconLogMetadata: Codable {
    let originalGeneratedImageBytes: Int
    let storedImageBytes: Int
    let storedImageMimeType: String
    let storageMaxPixelDimension: Int
    let storageJPEGQuality: Double
    let promptJSON: String
    let reportedInputTokens: Int
    let reportedOutputTokens: Int
    let reportedTotalTokens: Int
    let billableImageOutputTokens: Int
    let estimatedImageOutputCostUSD: Double
    let estimatedTotalCostUSD: Double
    let pricingModel: String
}

private struct GeminiRequestLogMetadata: Codable {
    let apiMethod: String
    let aiProvider: String?
    let responseMimeType: String
    let thinkingLevel: String
    let includeThoughts: Bool
    let tools: [String]
    let imageCount: Int
    let maxImageDimension: Int?
    let jpegQuality: Double?
    let providerRouting: String?

    init(
        apiMethod: String,
        aiProvider: String? = nil,
        responseMimeType: String,
        thinkingLevel: String,
        includeThoughts: Bool,
        tools: [String],
        imageCount: Int,
        maxImageDimension: Int?,
        jpegQuality: Double?,
        providerRouting: String? = nil
    ) {
        self.apiMethod = apiMethod
        self.aiProvider = aiProvider
        self.responseMimeType = responseMimeType
        self.thinkingLevel = thinkingLevel
        self.includeThoughts = includeThoughts
        self.tools = tools
        self.imageCount = imageCount
        self.maxImageDimension = maxImageDimension
        self.jpegQuality = jpegQuality
        self.providerRouting = providerRouting
    }
}

private struct GeminiModelAttemptLog: Codable {
    var model: String
    var modelVersion: String?
    var endpoint: String
    var durationMs: Int?
    var httpStatus: Int?
    var succeeded: Bool = false
    var inputTokenCount: Int = 0
    var outputTokenCount: Int = 0
    var thinkingTokenCount: Int = 0
    var totalTokenCount: Int = 0
    var estimatedCostUSD: Double = 0
    var pricingModel: String?
    var inputRatePerMillionTokens: Double = 0
    var outputRatePerMillionTokens: Double = 0
    var errorCode: Int?
    var errorMessage: String?
    var parseStage: String?
    var responseText: String?
    var responseTextCharacters: Int = 0
    var rawResponseJSON: String?
    var rawErrorBody: String?
    var streamEventCount: Int = 0
    var thoughtPartCount: Int = 0
    var nonThoughtPartCount: Int = 0
    var firstThoughtSummaryMs: Int?
    var lastThoughtSummaryMs: Int?
    var firstTextDeltaMs: Int?
    var lastTextDeltaMs: Int?
    var searchGroundingUsed: Bool = false
    var webSearchQueries: [String] = []
    var groundingSourceURLs: [String] = []
    var groundingSourceTitles: [String] = []
    var groundingMetadataJSON: String?
}

private final class GeminiCallTrace {
    let requestPrompt: String?
    let requestMetadataJSON: String?
    let imageMetadataJSON: String?
    let searchGroundingRequested: Bool
    var requestPayloadBytes: Int?
    var resolvedModel: String?
    var resolvedModelVersion: String?
    var usedFallback = false
    var responseHTTPStatus: Int?
    var parseStage: String?
    var responseText: String?
    var responseTextCharacterCount: Int = 0
    var rawResponseJSON: String?
    var estimatedCostUSD: Double = 0
    var inputTokenCount: Int = 0
    var outputTokenCount: Int = 0
    var thinkingTokenCount: Int = 0
    var totalTokenCount: Int = 0
    var pricingModel: String?
    var streamEventCount: Int = 0
    var thoughtPartCount: Int = 0
    var nonThoughtPartCount: Int = 0
    var searchGroundingUsed: Bool = false
    var webSearchQueries: [String] = []
    var groundingSourceURLs: [String] = []
    var groundingSourceTitles: [String] = []
    var groundingMetadataJSON: String?
    var attempts: [GeminiModelAttemptLog] = []

    init(
        requestPrompt: String?,
        requestMetadataJSON: String?,
        imageMetadataJSON: String?,
        searchGroundingRequested: Bool
    ) {
        self.requestPrompt = requestPrompt
        self.requestMetadataJSON = requestMetadataJSON
        self.imageMetadataJSON = imageMetadataJSON
        self.searchGroundingRequested = searchGroundingRequested
    }

    var requestPromptCharacterCount: Int {
        requestPrompt?.count ?? 0
    }

    func absorb(_ attempt: GeminiModelAttemptLog) {
        attempts.append(attempt)
        responseHTTPStatus = attempt.httpStatus
        parseStage = attempt.parseStage
        responseText = attempt.responseText
        responseTextCharacterCount = attempt.responseTextCharacters
        rawResponseJSON = attempt.rawResponseJSON
        estimatedCostUSD = attempts.reduce(0) { $0 + $1.estimatedCostUSD }
        inputTokenCount = attempts.reduce(0) { $0 + $1.inputTokenCount }
        outputTokenCount = attempts.reduce(0) { $0 + $1.outputTokenCount }
        thinkingTokenCount = attempts.reduce(0) { $0 + $1.thinkingTokenCount }
        totalTokenCount = attempts.reduce(0) { $0 + $1.totalTokenCount }
        pricingModel = attempt.pricingModel ?? pricingModel
        streamEventCount = attempt.streamEventCount
        thoughtPartCount = attempt.thoughtPartCount
        nonThoughtPartCount = attempt.nonThoughtPartCount
        searchGroundingUsed = attempt.searchGroundingUsed
        webSearchQueries = attempt.webSearchQueries
        groundingSourceURLs = attempt.groundingSourceURLs
        groundingSourceTitles = attempt.groundingSourceTitles
        groundingMetadataJSON = attempt.groundingMetadataJSON
        resolvedModel = attempt.model
        if let modelVersion = attempt.modelVersion {
            resolvedModelVersion = modelVersion
        }

        if attempt.succeeded {
            resolvedModelVersion = attempt.modelVersion
        }
    }
}

private struct AISearchValidationResult {
    let reasons: [String]
    let retryNutrientIDs: [String]

    var requiresRetry: Bool {
        !reasons.isEmpty
    }

    var reasonSummary: String {
        reasons.joined(separator: "; ")
    }
}

private struct GeminiPricingEstimate {
    let pricingModel: String
    let inputRatePerMillionTokens: Double
    let outputRatePerMillionTokens: Double
    let estimatedCostUSD: Double
}

private struct GeminiCallFailure: Error {
    let underlying: Error
    let trace: GeminiCallTrace
}

private enum AIRequestPurpose {
    case labelScan
    case foodPhoto(useProModel: Bool)
    case aiSearch(useProModel: Bool)
    case calculatorOCR(useProModel: Bool)
    case foodEmoji
}

private struct AIRequestConfig {
    let provider: AIProvider
    let primary: String
    let fallback: String
    let thinkingLevel: String
    let openRouterRoutingMode: OpenRouterRoutingMode

    var expectsThinkingTrace: Bool {
        provider == .gemini && thinkingLevel != "none"
    }

    var providerRoutingDescription: String? {
        guard provider == .openRouter else { return nil }
        return openRouterRoutingMode.displayName
    }
}

// MARK: - OpenRouter Chat Completions Types

private struct OpenRouterChatRequest: Encodable {
    let model: String
    let messages: [OpenRouterMessage]
    let stream: Bool
    let temperature: Double
    let responseFormat: OpenRouterResponseFormat
    let provider: OpenRouterProviderPreferences?
    let plugins: [OpenRouterPlugin]?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case responseFormat = "response_format"
        case provider
        case plugins
    }
}

private struct OpenRouterMessage: Encodable {
    let role: String
    let text: String?
    let parts: [OpenRouterContentPart]?

    static func user(text: String, images: [PreparedGeminiImage] = []) -> OpenRouterMessage {
        guard !images.isEmpty else {
            return OpenRouterMessage(role: "user", text: text, parts: nil)
        }

        var parts: [OpenRouterContentPart] = [.text(text)]
        parts += images.map {
            .imageURL("data:image/jpeg;base64,\($0.data.base64EncodedString())")
        }
        return OpenRouterMessage(role: "user", text: nil, parts: parts)
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let parts {
            try container.encode(parts, forKey: .content)
        } else {
            try container.encode(text ?? "", forKey: .content)
        }
    }
}

private enum OpenRouterContentPart: Encodable {
    case text(String)
    case imageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    private enum ImageURLKeys: String, CodingKey {
        case url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            var nested = container.nestedContainer(keyedBy: ImageURLKeys.self, forKey: .imageURL)
            try nested.encode(url, forKey: .url)
        }
    }
}

private struct OpenRouterResponseFormat: Encodable {
    let type: String

    static let jsonObject = OpenRouterResponseFormat(type: "json_object")
}

private struct OpenRouterProviderPreferences: Encodable {
    let order: [String]?
    let only: [String]?
    let allowFallbacks: Bool?

    enum CodingKeys: String, CodingKey {
        case order
        case only
        case allowFallbacks = "allow_fallbacks"
    }

    static func from(_ mode: OpenRouterRoutingMode) -> OpenRouterProviderPreferences? {
        switch mode {
        case .automatic:
            return nil
        case .preferGoogleVertex:
            return OpenRouterProviderPreferences(
                order: [AIProviderSettings.googleVertexProviderSlug],
                only: nil,
                allowFallbacks: true
            )
        case .requireGoogleVertex:
            return OpenRouterProviderPreferences(
                order: nil,
                only: [AIProviderSettings.googleVertexProviderSlug],
                allowFallbacks: false
            )
        }
    }
}

private struct OpenRouterPlugin: Encodable {
    let id: String

    static let web = OpenRouterPlugin(id: "web")
}

private struct OpenRouterStreamChunk: Decodable {
    let id: String?
    let model: String?
    let choices: [Choice]?
    let usage: OpenRouterUsage?
    let error: OpenRouterError?

    struct Choice: Decodable {
        let delta: Delta?
        let message: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let content: String?
        let reasoning: String?
        let annotations: [OpenRouterAnnotation]?
    }
}

private struct OpenRouterAnnotation: Decodable {
    let type: String?
    let urlCitation: OpenRouterURLCitation?

    enum CodingKeys: String, CodingKey {
        case type
        case urlCitation = "url_citation"
    }
}

private struct OpenRouterURLCitation: Decodable {
    let url: String?
    let title: String?
}

private struct OpenRouterUsage: Codable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let reasoningTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case reasoningTokens = "reasoning_tokens"
    }
}

private struct OpenRouterErrorEnvelope: Decodable {
    let error: OpenRouterError?
}

private struct OpenRouterError: Codable {
    let code: Int?
    let message: String?
    let type: String?
}

// MARK: - ScanService

@Observable
@MainActor
final class ScanService {
    static let maxImagesPerScan = 4
    private static let foodEmojiPersistenceBatchSize = 10
    // Image generation currently uses this concrete Gemini image endpoint; the
    // "latest alias only" rule above still applies to text scan/emoji models.
    private static let foodIconImageModel = "models/gemini-3.1-flash-lite-image"
    private static let foodIconImageSystemInstruction = "Pure White background. 3d emoji. Simple. Center the food object. No text on the food items"
    // Public Gemini API Standard paid-tier pricing checked 2026-06-30. AI Studio
    // may show a lower studio/free estimate; persisted app estimates use the
    // documented paid API rates so the Settings total stays auditable.
    private static let foodIconImagePricingModel = "Gemini 3.1 Flash Lite Image Standard image output, checked 2026-06-30"
    private static let foodIconImageFallbackOutputTokens1K = 1_120
    private static let foodIconImageInputRatePerMillionTokens = 0.25
    private static let foodIconImageTextOutputRatePerMillionTokens = 1.50
    private static let foodIconImageOutputRatePerMillionTokens = 30.00
    private static let foodIconStoredMaxPixelDimension: CGFloat = 160
    private static let foodIconStoredJPEGQuality = 0.82
    private static let foodIconStoredMimeType = "image/jpeg"
    private static let foodIconTransparentMimeType = "image/png"
    // Gemini Interactions currently rejects the older "minimal" value for
    // thinking_level, including for the image model.
    private static let foodIconImageThinkingLevel = "low"
    private static let generationFailureRetryInterval: TimeInterval = 60 * 60
    private static let foodEmojiFailureCacheStorageKey = "foodBank.foodEmojiGenerationFailures"
    private static let foodIconImageFailureCacheStorageKey = "foodBank.foodIconImageGenerationFailures"
    private static let foodEmojiGenerationCacheVersion = "food-emoji-v1"
    private static let foodIconImageGenerationCacheVersion = "food-icon-image-v2-low-160"

    // MARK: State

    var isScanning = false
    var error: ScanError?
    /// Holds the result of a background scan until the user confirms/dismisses it
    var pendingResult: NutritionEntry?
    /// Duration of the last completed scan in milliseconds
    var lastScanDurationMs: Int?
    /// High-level status displayed while a scan is in flight.
    var scanProgressMessage = "Preparing scan..."
    /// Gemini thought summaries streamed back during the current scan.
    var thinkingTrace: [String] = []
    /// Total distinct thought-summary chunks received during the current scan.
    var thinkingTraceUpdateCount = 0
    /// True while the current request asks Gemini for high-thinking summaries.
    var expectsThinkingTrace = false
    /// Last image set and scan settings submitted to Gemini, used for redo.
    var lastSubmittedScan: ScanRedoRequest?
    /// Sequential Food Bank emoji assignment state shown in Settings.
    var isAssigningFoodEmojis = false
    var foodEmojiProgressMessage = ""
    var foodEmojiCompletedCount = 0
    var foodEmojiTotalCount = 0

    @ObservationIgnored private let modelContext: ModelContext?
    @ObservationIgnored private let tursoMirror: TursoMirrorService?
    @ObservationIgnored private let diagnosticSink: (any AIDiagnosticWriting)?
    @ObservationIgnored private let modelCatalog: RuntimeModelCatalog?

    init(
        modelContext: ModelContext? = nil,
        tursoMirror: TursoMirrorService? = nil,
        diagnosticSink: (any AIDiagnosticWriting)? = nil,
        modelCatalog: RuntimeModelCatalog? = nil
    ) {
        self.modelContext = modelContext
        self.tursoMirror = tursoMirror
        self.diagnosticSink = diagnosticSink ?? tursoMirror
        self.modelCatalog = modelCatalog
    }

    // MARK: Configuration

    /// Gemini Interactions endpoint. The model is supplied in the JSON body.
    private static let geminiInteractionsURL = "https://generativelanguage.googleapis.com/v1beta/interactions"
    /// OpenRouter's OpenAI-compatible chat completions endpoint.
    private static let openRouterChatCompletionsURL = "https://openrouter.ai/api/v1/chat/completions"

    @ObservationIgnored
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60   // Gemini Pro with thinking can take ~10-15s
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

    private var selectedAIProvider: AIProvider {
        AIProvider.stored()
    }

    private func aiRequestConfig(for purpose: AIRequestPurpose) -> AIRequestConfig {
        let provider = selectedAIProvider
        let geminiConfig: ModelConfig

        switch purpose {
        case .labelScan:
            geminiConfig = .label
        case .foodPhoto(let useProModel), .aiSearch(let useProModel), .calculatorOCR(let useProModel):
            geminiConfig = ModelConfig.aiSearch(useProModel: useProModel)
        case .foodEmoji:
            geminiConfig = .foodEmoji
        }

        guard provider == .openRouter else {
            return AIRequestConfig(
                provider: .gemini,
                primary: geminiConfig.primary,
                fallback: geminiConfig.fallback,
                thinkingLevel: geminiConfig.thinkingLevel,
                openRouterRoutingMode: .automatic
            )
        }

        let defaults = UserDefaults.standard
        let liteModel = AIProviderSettings.openRouterLiteModel(in: defaults)
        let proModel = AIProviderSettings.openRouterProModel(in: defaults)
        let emojiModel = AIProviderSettings.openRouterEmojiModel(in: defaults)
        let routingMode = OpenRouterRoutingMode.stored(in: defaults)
        let primaryModel: String
        let fallbackModel: String

        switch purpose {
        case .labelScan:
            primaryModel = liteModel
            fallbackModel = liteModel
        case .foodPhoto(let useProModel), .aiSearch(let useProModel), .calculatorOCR(let useProModel):
            primaryModel = useProModel ? proModel : liteModel
            fallbackModel = liteModel
        case .foodEmoji:
            primaryModel = emojiModel
            fallbackModel = liteModel
        }

        return AIRequestConfig(
            provider: .openRouter,
            primary: primaryModel,
            fallback: fallbackModel,
            thinkingLevel: geminiConfig.thinkingLevel,
            openRouterRoutingMode: routingMode
        )
    }

    private func apiKey(for config: AIRequestConfig) -> String? {
        KeychainService.apiKey(for: config.provider)
    }

    // MARK: - Scan

    /// Kicks off a single-image scan in the background. Kept for callers that
    /// do not need multi-angle analysis.
    func scanInBackground(image: UIImage, mode: ScanMode, prompt: String? = nil, useProModel: Bool = false) {
        scanInBackground(images: [image], mode: mode, prompt: prompt, useProModel: useProModel)
    }

    /// Kicks off a scan in the background. The caller can dismiss immediately.
    /// Result lands in `pendingResult`; errors land in `error`.
    func scanInBackground(images: [UIImage], mode: ScanMode, prompt: String? = nil, useProModel: Bool = false) {
        lastSubmittedScan = ScanRedoRequest(
            images: images,
            mode: mode,
            prompt: prompt,
            useProModel: useProModel,
            submittedAt: .now
        )

        Task { @MainActor in
            do {
                let entry = try await scan(images: images, mode: mode, prompt: prompt, useProModel: useProModel)
                pendingResult = entry
            } catch {
                // error is already set via the scan() method
            }
        }
    }

    func redoLastScanInBackground() {
        guard let request = lastSubmittedScan else { return }
        pendingResult = nil
        scanInBackground(
            images: request.images,
            mode: request.mode,
            prompt: request.prompt,
            useProModel: request.useProModel
        )
    }

    /// Sends a single captured image directly to the selected AI provider.
    func scan(image: UIImage, mode: ScanMode, prompt: String? = nil, useProModel: Bool = false) async throws -> NutritionEntry {
        try await scan(images: [image], mode: mode, prompt: prompt, useProModel: useProModel)
    }

    /// Sends captured images directly to the selected AI provider and returns a NutritionEntry.
    /// Requires the selected provider's API key stored in Keychain.
    /// The entry is NOT inserted into SwiftData — caller should review and confirm.
    func scan(images: [UIImage], mode: ScanMode, prompt: String? = nil, useProModel: Bool = false) async throws -> NutritionEntry {
        isScanning = true
        error = nil
        thinkingTrace = []
        thinkingTraceUpdateCount = 0
        expectsThinkingTrace = false
        scanProgressMessage = "Preparing photos..."
        defer {
            isScanning = false
            expectsThinkingTrace = false
        }
        let scanStart = ContinuousClock.now

        guard !images.isEmpty else {
            let err = ScanError.noImages
            self.error = err
            recordGeminiScanLog(
                operation: .scan,
                status: .failure,
                scanMode: mode,
                photoCount: images.count,
                userPrompt: prompt,
                durationMs: msFrom(ContinuousClock.now.duration(to: scanStart)),
                error: err
            )
            throw err
        }
        guard images.count <= Self.maxImagesPerScan else {
            let err = ScanError.tooManyImages(Self.maxImagesPerScan)
            self.error = err
            recordGeminiScanLog(
                operation: .scan,
                status: .failure,
                scanMode: mode,
                photoCount: images.count,
                userPrompt: prompt,
                durationMs: msFrom(ContinuousClock.now.duration(to: scanStart)),
                error: err
            )
            throw err
        }

        // Pick provider/model config based on scan mode.
        // Food photos default to lite unless the user enables Pro in Settings.
        let aiConfig: AIRequestConfig = mode == .label
            ? aiRequestConfig(for: .labelScan)
            : aiRequestConfig(for: .foodPhoto(useProModel: useProModel))

        // Retrieve the selected provider's API key from Keychain.
        guard let apiKey = apiKey(for: aiConfig) else {
            let err = ScanError.noProviderAPIKey(aiConfig.provider.displayName)
            self.error = err
            recordGeminiScanLog(
                operation: .scan,
                status: .failure,
                scanMode: mode,
                primaryModel: aiConfig.primary,
                fallbackModel: aiConfig.fallback,
                photoCount: images.count,
                userPrompt: prompt,
                durationMs: msFrom(ContinuousClock.now.duration(to: scanStart)),
                error: err
            )
            throw err
        }

        // Resize each photo to max 1200px on longest edge before JPEG encoding.
        // OCR doesn't need high resolution — 1200px captures all text on a
        // nutrition label clearly while keeping JPEG size under ~200KB.
        // Label scans only need readable text → aggressive 50% JPEG quality (~100-200KB)
        // Food photos need visual detail for portion estimation → 80% quality (~300-600KB)
        let maxImageDimension: CGFloat = 1200
        let jpegQuality: CGFloat = mode == .label ? 0.50 : 0.80
        let preparedImages: [PreparedGeminiImage] = try images.enumerated().map { index, image in
            let resized = image.resizedForOCR(maxDimension: maxImageDimension)
            guard let data = resized.jpegData(compressionQuality: jpegQuality) else {
                let err = ScanError.imageEncodingFailed
                self.error = err
                recordGeminiScanLog(
                    operation: .scan,
                    status: .failure,
                    scanMode: mode,
                    photoCount: images.count,
                    userPrompt: prompt,
                    durationMs: msFrom(ContinuousClock.now.duration(to: scanStart)),
                    error: err
                )
                throw err
            }

            #if DEBUG
            print("📐 Image \(index + 1)/\(images.count): \(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale))px → \(Int(resized.size.width * resized.scale))×\(Int(resized.size.height * resized.scale))px, JPEG: \(data.count / 1024)KB")
            #endif
            let metadata = GeminiImageLogMetadata(
                index: index + 1,
                originalWidthPx: Int(image.size.width * image.scale),
                originalHeightPx: Int(image.size.height * image.scale),
                resizedWidthPx: Int(resized.size.width * resized.scale),
                resizedHeightPx: Int(resized.size.height * resized.scale),
                jpegBytes: data.count,
                jpegQuality: Double(jpegQuality)
            )
            return PreparedGeminiImage(data: data, metadata: metadata)
        }
        let jpegData = preparedImages.map(\.data)
        let prepEnd = ContinuousClock.now
        let prepMs = msFrom(prepEnd.duration(to: scanStart))

        let systemPrompt = mode == .label ? Self.labelPrompt : Self.foodPhotoPrompt

        var finalPrompt = systemPrompt
        if images.count > 1 {
            finalPrompt += "\n\nYou are receiving \(images.count) photos of the same food item or product. Use all photos together as supporting evidence. Do not treat different angles as separate servings or duplicate any food."
        }

        // If user provided additional context (e.g. "this is walnut shrimp"),
        // append it to the system prompt.
        if let prompt, !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            finalPrompt += "\n\nAdditional context from user: \(prompt)"
        }

        // Encode each photo as its own Interactions image block. Gemini can
        // reason over multiple image blocks in one user input.
        let imageParts = jpegData.map {
            GeminiContent.image(mimeType: "image/jpeg", data: $0.base64EncodedString())
        }

        // Build the Gemini Interactions request payload.
        let request = GeminiRequest(
            input: [.text(finalPrompt)] + imageParts,
            generationConfig: GeminiGenerationConfig(thinkingLevel: aiConfig.thinkingLevel)
        )
        let requestMetadata = GeminiRequestLogMetadata(
            apiMethod: aiConfig.provider == .gemini ? "interactions.create.stream" : "chat.completions.stream",
            aiProvider: aiConfig.provider.rawValue,
            responseMimeType: "application/json",
            thinkingLevel: aiConfig.thinkingLevel,
            includeThoughts: aiConfig.expectsThinkingTrace,
            tools: [],
            imageCount: images.count,
            maxImageDimension: Int(maxImageDimension),
            jpegQuality: Double(jpegQuality),
            providerRouting: aiConfig.providerRoutingDescription
        )
        let trace = GeminiCallTrace(
            requestPrompt: finalPrompt,
            requestMetadataJSON: encodedJSONString(requestMetadata),
            imageMetadataJSON: encodedJSONString(preparedImages.map(\.metadata)),
            searchGroundingRequested: false
        )

        // Try primary model, fall back on 500/503
        prepareAIWait(for: aiConfig)
        let nutritionData: GeminiNutritionResponse
        do {
            nutritionData = try await callAI(
                request: request,
                prompt: finalPrompt,
                images: preparedImages,
                useWebSearch: false,
                apiKey: apiKey,
                config: aiConfig,
                trace: trace
            )
        } catch {
            let visibleError = visibleError(from: error)
            recordGeminiScanLog(
                operation: .scan,
                status: .failure,
                scanMode: mode,
                primaryModel: aiConfig.primary,
                fallbackModel: aiConfig.fallback,
                resolvedModel: trace.resolvedModel ?? aiConfig.primary,
                usedFallback: trace.usedFallback,
                photoCount: images.count,
                userPrompt: prompt,
                durationMs: msFrom(ContinuousClock.now.duration(to: scanStart)),
                debugTrace: trace,
                error: visibleError
            )
            throw visibleError
        }

        let networkEnd = ContinuousClock.now
        let networkMs = msFrom(networkEnd.duration(to: prepEnd))
        scanProgressMessage = "Building nutrition entry..."

        // Measure and log the full scan duration
        let totalMs = msFrom(ContinuousClock.now.duration(to: scanStart))
        let decodeMs = totalMs - abs(prepMs) - abs(networkMs)
        lastScanDurationMs = totalMs
        #if DEBUG
        let usedFallback = trace.usedFallback
        print("📸 Scan completed in \(totalMs)ms (mode: \(mode.rawValue), photos: \(images.count), provider: \(aiConfig.provider.rawValue), model: \(usedFallback ? aiConfig.fallback : aiConfig.primary))")
        print("   ├─ Image prep (resize + JPEG): \(abs(prepMs))ms")
        print("   ├─ AI API round-trip: \(abs(networkMs))ms")
        print("   └─ Client decode: \(abs(decodeMs))ms")
        #endif

        let entry = nutritionData.toNutritionEntry(mode: mode)
        entry.scanDurationMs = totalMs
        recordGeminiScanLog(
            operation: .scan,
            status: .success,
            scanMode: mode,
            primaryModel: aiConfig.primary,
            fallbackModel: aiConfig.fallback,
            resolvedModel: trace.resolvedModel ?? aiConfig.primary,
            usedFallback: trace.usedFallback,
            photoCount: images.count,
            userPrompt: prompt,
            durationMs: totalMs,
            debugTrace: trace,
            response: nutritionData
        )
        return entry
    }

    /// Uses the selected AI provider with web grounding/search to look up
    /// nutrition data from current public web sources. The result is returned
    /// for manual review.
    func searchNutrition(query: String, useProModel: Bool = false) async throws -> NutritionEntry {
        isScanning = true
        error = nil
        thinkingTrace = []
        thinkingTraceUpdateCount = 0
        expectsThinkingTrace = false
        scanProgressMessage = "Searching nutrition sources..."
        defer {
            isScanning = false
            expectsThinkingTrace = false
        }
        let searchStart = ContinuousClock.now

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let err = ScanError.emptySearchQuery
            self.error = err
            recordGeminiScanLog(
                operation: .aiSearch,
                status: .failure,
                userPrompt: query,
                durationMs: msFrom(ContinuousClock.now.duration(to: searchStart)),
                error: err
            )
            throw err
        }

        let aiConfig = aiRequestConfig(for: .aiSearch(useProModel: useProModel))

        guard let apiKey = apiKey(for: aiConfig) else {
            let err = ScanError.noProviderAPIKey(aiConfig.provider.displayName)
            self.error = err
            recordGeminiScanLog(
                operation: .aiSearch,
                status: .failure,
                primaryModel: aiConfig.primary,
                fallbackModel: aiConfig.fallback,
                userPrompt: trimmed,
                durationMs: msFrom(ContinuousClock.now.duration(to: searchStart)),
                error: err
            )
            throw err
        }

        let finalPrompt = Self.aiSearchPrompt + "\n\nUser search prompt: \(trimmed)"

        let request = GeminiRequest(
            input: [.text(finalPrompt)],
            generationConfig: GeminiGenerationConfig(thinkingLevel: aiConfig.thinkingLevel),
            tools: [.googleSearch]
        )
        let searchTools = aiConfig.provider == .gemini ? ["google_search"] : ["openrouter_web"]
        let requestMetadata = GeminiRequestLogMetadata(
            apiMethod: aiConfig.provider == .gemini ? "interactions.create.stream" : "chat.completions.stream",
            aiProvider: aiConfig.provider.rawValue,
            responseMimeType: "application/json",
            thinkingLevel: aiConfig.thinkingLevel,
            includeThoughts: aiConfig.expectsThinkingTrace,
            tools: searchTools,
            imageCount: 0,
            maxImageDimension: nil,
            jpegQuality: nil,
            providerRouting: aiConfig.providerRoutingDescription
        )
        let trace = GeminiCallTrace(
            requestPrompt: finalPrompt,
            requestMetadataJSON: encodedJSONString(requestMetadata),
            imageMetadataJSON: nil,
            searchGroundingRequested: true
        )

        prepareAIWait(for: aiConfig)
        var nutritionData: GeminiNutritionResponse
        do {
            nutritionData = try await callAI(
                request: request,
                prompt: finalPrompt,
                images: [],
                useWebSearch: true,
                apiKey: apiKey,
                config: aiConfig,
                trace: trace
            )
        } catch {
            let visibleError = visibleError(from: error)
            recordGeminiScanLog(
                operation: .aiSearch,
                status: .failure,
                primaryModel: aiConfig.primary,
                fallbackModel: aiConfig.fallback,
                resolvedModel: trace.resolvedModel ?? aiConfig.primary,
                usedFallback: trace.usedFallback,
                userPrompt: trimmed,
                durationMs: msFrom(ContinuousClock.now.duration(to: searchStart)),
                debugTrace: trace,
                error: visibleError
            )
            throw visibleError
        }

        scanProgressMessage = "Validating nutrition data..."
        let validation = validateAISearchResponse(nutritionData, query: trimmed, trace: trace)
        #if DEBUG
        if validation.requiresRetry {
            print("⚠️ AI nutrition search suspicious first pass: \(validation.reasonSummary)")
        } else {
            print("✅ AI nutrition search validation passed")
        }
        #endif

        if validation.requiresRetry {
            recordGeminiScanLog(
                operation: .aiSearch,
                status: .success,
                primaryModel: aiConfig.primary,
                fallbackModel: aiConfig.fallback,
                resolvedModel: trace.resolvedModel ?? aiConfig.primary,
                usedFallback: trace.usedFallback,
                userPrompt: "\(trimmed) [first pass; validation retry: \(validation.reasonSummary)]",
                durationMs: msFrom(ContinuousClock.now.duration(to: searchStart)),
                debugTrace: trace,
                response: nutritionData
            )

            scanProgressMessage = "Checking missing nutrients..."
            let retryPrompt = Self.aiSearchValidationRetryPrompt(
                query: trimmed,
                firstPass: nutritionData,
                validation: validation
            )
            let retryRequest = GeminiRequest(
                input: [.text(retryPrompt)],
                generationConfig: GeminiGenerationConfig(thinkingLevel: aiConfig.thinkingLevel),
                tools: [.googleSearch]
            )
            let retryMetadata = GeminiRequestLogMetadata(
                apiMethod: aiConfig.provider == .gemini ? "interactions.create.stream" : "chat.completions.stream",
                aiProvider: aiConfig.provider.rawValue,
                responseMimeType: "application/json",
                thinkingLevel: aiConfig.thinkingLevel,
                includeThoughts: aiConfig.expectsThinkingTrace,
                tools: searchTools,
                imageCount: 0,
                maxImageDimension: nil,
                jpegQuality: nil,
                providerRouting: aiConfig.providerRoutingDescription
            )
            let retryTrace = GeminiCallTrace(
                requestPrompt: retryPrompt,
                requestMetadataJSON: encodedJSONString(retryMetadata),
                imageMetadataJSON: nil,
                searchGroundingRequested: true
            )

            do {
                let retryData = try await callAI(
                    request: retryRequest,
                    prompt: retryPrompt,
                    images: [],
                    useWebSearch: true,
                    apiKey: apiKey,
                    config: aiConfig,
                    trace: retryTrace
                )
                let merge = mergeAISearchRetry(
                    firstPass: nutritionData,
                    retry: retryData,
                    validation: validation,
                    retryTrace: retryTrace
                )
                nutritionData = merge.response
                let mergeSummary = merge.mergedNutrientIDs.isEmpty
                    ? "no better sourced non-zero nutrients"
                    : "merged \(merge.mergedNutrientIDs.sorted().joined(separator: ", "))"
                recordGeminiScanLog(
                    operation: .aiSearch,
                    status: .success,
                    primaryModel: aiConfig.primary,
                    fallbackModel: aiConfig.fallback,
                    resolvedModel: retryTrace.resolvedModel ?? aiConfig.primary,
                    usedFallback: retryTrace.usedFallback,
                    userPrompt: "\(trimmed) [validation retry: \(validation.reasonSummary); \(mergeSummary)]",
                    durationMs: msFrom(ContinuousClock.now.duration(to: searchStart)),
                    debugTrace: retryTrace,
                    response: retryData
                )
            } catch {
                let visibleError = visibleError(from: error)
                recordGeminiScanLog(
                    operation: .aiSearch,
                    status: .failure,
                    primaryModel: aiConfig.primary,
                    fallbackModel: aiConfig.fallback,
                    resolvedModel: retryTrace.resolvedModel ?? aiConfig.primary,
                    usedFallback: retryTrace.usedFallback,
                    userPrompt: "\(trimmed) [validation retry failed: \(validation.reasonSummary)]",
                    durationMs: msFrom(ContinuousClock.now.duration(to: searchStart)),
                    debugTrace: retryTrace,
                    error: visibleError
                )
                #if DEBUG
                print("⚠️ AI nutrition validation retry failed; using first pass: \(visibleError.localizedDescription)")
                #endif
            }
        }

        let totalMs = msFrom(ContinuousClock.now.duration(to: searchStart))
        scanProgressMessage = "Building nutrition entry..."
        lastScanDurationMs = totalMs
        #if DEBUG
        let usedFallback = trace.usedFallback
        print("🔎 AI nutrition search completed in \(totalMs)ms (provider: \(aiConfig.provider.rawValue), model: \(usedFallback ? aiConfig.fallback : aiConfig.primary))")
        #endif

        let entry = nutritionData.toNutritionEntry(mode: .manual)
        entry.scanDurationMs = totalMs
        recordGeminiScanLog(
            operation: .aiSearch,
            status: .success,
            primaryModel: aiConfig.primary,
            fallbackModel: aiConfig.fallback,
            resolvedModel: trace.resolvedModel ?? aiConfig.primary,
            usedFallback: trace.usedFallback,
            userPrompt: validation.requiresRetry
                ? "\(trimmed) [merged result after validation: \(validation.reasonSummary)]"
                : "\(trimmed) [validation passed]",
            durationMs: totalMs,
            debugTrace: validation.requiresRetry ? nil : trace,
            response: nutritionData
        )
        return entry
    }

    // MARK: - Food Bank Emoji Assignment

    /// Assigns missing Food Bank emojis one at a time. This intentionally avoids
    /// parallel Gemini calls so a large Food Bank cannot burst through the user's
    /// BYOK quota or obscure which food caused a bad response.
    func backfillMissingFoodEmojis() async {
        guard !isAssigningFoodEmojis else { return }
        guard let modelContext else { return }

        let aiConfig = aiRequestConfig(for: .foodEmoji)
        guard let apiKey = apiKey(for: aiConfig) else {
            foodEmojiProgressMessage = "Add a \(aiConfig.provider.displayName) API key to generate food emojis."
            foodEmojiCompletedCount = 0
            foodEmojiTotalCount = 0
            return
        }

        let descriptor = FetchDescriptor<SavedFood>(
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
        )
        let foods = (try? modelContext.fetch(descriptor)) ?? []
        let missingFoods = foods.filter(\.needsFoodBankEmoji)
        let targets = missingFoods.filter { food in
            !hasRecentGenerationFailure(
                storageKey: Self.foodEmojiFailureCacheStorageKey,
                cacheKey: foodEmojiFailureCacheKey(for: food, config: aiConfig)
            )
        }
        let skippedRecentlyFailedCount = missingFoods.count - targets.count

        guard !targets.isEmpty else {
            if skippedRecentlyFailedCount > 0 {
                foodEmojiProgressMessage = Self.skippedRecentFailuresMessage(skippedRecentlyFailedCount, noun: "emoji")
            } else {
                foodEmojiProgressMessage = "All saved foods have emojis."
            }
            foodEmojiCompletedCount = 0
            foodEmojiTotalCount = 0
            return
        }

        isAssigningFoodEmojis = true
        foodEmojiCompletedCount = 0
        foodEmojiTotalCount = targets.count
        foodEmojiProgressMessage = "Preparing food emoji assignment..."
        var pendingPersistenceCount = 0

        func savePendingEmojiBackfillChanges(reason: String) {
            guard pendingPersistenceCount > 0 else { return }
            do {
                try modelContext.save()
                tursoMirror?.scheduleMirror(reason: reason)
                pendingPersistenceCount = 0
            } catch {
                #if DEBUG
                print("⚠️ Food emoji persistence failed: \(error.localizedDescription)")
                #endif
            }
        }

        defer {
            savePendingEmojiBackfillChanges(reason: "food_emoji_backfill_finished")
            isAssigningFoodEmojis = false
        }

        for (index, food) in targets.enumerated() {
            if !food.needsFoodBankEmoji {
                foodEmojiCompletedCount = index + 1
                continue
            }

            let displayName = food.name.trimmingCharacters(in: .whitespacesAndNewlines)
            foodEmojiProgressMessage = "Assigning \(index + 1) of \(targets.count): \(displayName.isEmpty ? "Saved food" : displayName)"
            let cacheKey = foodEmojiFailureCacheKey(for: food, config: aiConfig)

            do {
                let emoji = try await generateFoodEmoji(for: food, apiKey: apiKey, config: aiConfig)
                pendingPersistenceCount += 1
                if food.needsFoodBankEmoji {
                    food.emoji = emoji
                }
                clearGenerationFailure(storageKey: Self.foodEmojiFailureCacheStorageKey, cacheKey: cacheKey)
            } catch {
                rememberGenerationFailure(storageKey: Self.foodEmojiFailureCacheStorageKey, cacheKey: cacheKey)
                pendingPersistenceCount += 1
                #if DEBUG
                print("⚠️ Food emoji assignment failed for \(food.name): \(error.localizedDescription)")
                #endif
            }

            if pendingPersistenceCount >= Self.foodEmojiPersistenceBatchSize {
                savePendingEmojiBackfillChanges(reason: "food_emoji_backfill_batch")
            }
            foodEmojiCompletedCount = index + 1
        }

        savePendingEmojiBackfillChanges(reason: "food_emoji_backfill_complete")
        if skippedRecentlyFailedCount > 0 {
            foodEmojiProgressMessage = "Food emoji assignment complete. \(Self.skippedRecentFailuresMessage(skippedRecentlyFailedCount, noun: "emoji"))"
        } else {
            foodEmojiProgressMessage = "Food emoji assignment complete."
        }
    }

    func backfillMissingFoodIconImages() async {
        guard !isAssigningFoodEmojis else { return }
        guard let modelContext else { return }

        guard let apiKey = KeychainService.geminiAPIKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            foodEmojiProgressMessage = "Add a Gemini API key to generate food images."
            foodEmojiCompletedCount = 0
            foodEmojiTotalCount = 0
            return
        }

        let descriptor = FetchDescriptor<SavedFood>(
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
        )
        let foods = (try? modelContext.fetch(descriptor)) ?? []
        let optimizedExistingCount = optimizeStoredFoodIconImages(in: foods)
        if optimizedExistingCount > 0 {
            do {
                try modelContext.save()
                tursoMirror?.scheduleMirror(reason: "food_icon_image_optimized")
            } catch {
                #if DEBUG
                print("⚠️ Food image optimization failed: \(error.localizedDescription)")
                #endif
            }
        }
        let missingFoods = foods.filter(\.needsFoodBankGeneratedIconImage)
        let targets = missingFoods.filter { food in
            !hasRecentGenerationFailure(
                storageKey: Self.foodIconImageFailureCacheStorageKey,
                cacheKey: foodIconImageFailureCacheKey(for: food)
            )
        }
        let skippedRecentlyFailedCount = missingFoods.count - targets.count

        guard !targets.isEmpty else {
            if skippedRecentlyFailedCount > 0 {
                foodEmojiProgressMessage = Self.skippedRecentFailuresMessage(skippedRecentlyFailedCount, noun: "food image")
            } else if optimizedExistingCount > 0 {
                foodEmojiProgressMessage = "All saved foods have generated images. Optimized \(optimizedExistingCount) stored image\(optimizedExistingCount == 1 ? "" : "s")."
            } else {
                foodEmojiProgressMessage = "All saved foods have generated images."
            }
            foodEmojiCompletedCount = 0
            foodEmojiTotalCount = 0
            return
        }

        isAssigningFoodEmojis = true
        foodEmojiCompletedCount = 0
        foodEmojiTotalCount = targets.count
        foodEmojiProgressMessage = "Preparing food image generation..."
        var pendingPersistenceCount = 0

        func savePendingFoodIconChanges(reason: String) {
            guard pendingPersistenceCount > 0 else { return }
            do {
                try modelContext.save()
                tursoMirror?.scheduleMirror(reason: reason)
                pendingPersistenceCount = 0
            } catch {
                #if DEBUG
                print("⚠️ Food image persistence failed: \(error.localizedDescription)")
                #endif
            }
        }

        defer {
            savePendingFoodIconChanges(reason: "food_icon_image_backfill_finished")
            isAssigningFoodEmojis = false
        }

        for (index, food) in targets.enumerated() {
            if !food.needsFoodBankGeneratedIconImage {
                foodEmojiCompletedCount = index + 1
                continue
            }

            let displayName = food.name.trimmingCharacters(in: .whitespacesAndNewlines)
            foodEmojiProgressMessage = "Generating \(index + 1) of \(targets.count): \(displayName.isEmpty ? "Saved food" : displayName)"
            let cacheKey = foodIconImageFailureCacheKey(for: food)

            do {
                let icon = try await generateFoodIconImagePayload(for: food, apiKey: apiKey)
                apply(icon, to: food)
                clearGenerationFailure(storageKey: Self.foodIconImageFailureCacheStorageKey, cacheKey: cacheKey)
                pendingPersistenceCount += 1
            } catch {
                rememberGenerationFailure(storageKey: Self.foodIconImageFailureCacheStorageKey, cacheKey: cacheKey)
                pendingPersistenceCount += 1
                #if DEBUG
                print("⚠️ Food image generation failed for \(food.name): \(error.localizedDescription)")
                #endif
            }

            if pendingPersistenceCount >= Self.foodEmojiPersistenceBatchSize {
                savePendingFoodIconChanges(reason: "food_icon_image_backfill_batch")
            }
            foodEmojiCompletedCount = index + 1
        }

        savePendingFoodIconChanges(reason: "food_icon_image_backfill_complete")
        if skippedRecentlyFailedCount > 0 {
            foodEmojiProgressMessage = "Food image generation complete. \(Self.skippedRecentFailuresMessage(skippedRecentlyFailedCount, noun: "food image"))"
        } else {
            foodEmojiProgressMessage = "Food image generation complete."
        }
    }

    func refreshFoodEmoji(for food: SavedFood) async {
        guard !isAssigningFoodEmojis else { return }
        guard let modelContext else { return }

        let aiConfig = aiRequestConfig(for: .foodEmoji)
        guard let apiKey = apiKey(for: aiConfig) else {
            foodEmojiProgressMessage = "Add a \(aiConfig.provider.displayName) API key to regenerate food emojis."
            return
        }

        isAssigningFoodEmojis = true
        foodEmojiCompletedCount = 0
        foodEmojiTotalCount = 1
        foodEmojiProgressMessage = "Regenerating emoji for \(food.name)"
        defer { isAssigningFoodEmojis = false }
        let cacheKey = foodEmojiFailureCacheKey(for: food, config: aiConfig)

        do {
            let emoji = try await generateFoodEmoji(for: food, apiKey: apiKey, config: aiConfig)
            food.emoji = emoji
            clearGenerationFailure(storageKey: Self.foodEmojiFailureCacheStorageKey, cacheKey: cacheKey)
            try modelContext.save()
            tursoMirror?.scheduleMirror(reason: "food_emoji_regenerated")
            foodEmojiCompletedCount = 1
            foodEmojiProgressMessage = "Food emoji regenerated."
        } catch {
            rememberGenerationFailure(storageKey: Self.foodEmojiFailureCacheStorageKey, cacheKey: cacheKey)
            try? modelContext.save()
            foodEmojiCompletedCount = 1
            foodEmojiProgressMessage = "Food emoji regeneration failed."
        }
    }

    func generateFoodIconImage(for food: SavedFood, force: Bool = false) async {
        guard !isAssigningFoodEmojis else { return }
        guard let modelContext else { return }
        guard force || food.needsFoodBankGeneratedIconImage else { return }

        guard let apiKey = KeychainService.geminiAPIKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            foodEmojiProgressMessage = "Add a Gemini API key to generate food images."
            return
        }
        let cacheKey = foodIconImageFailureCacheKey(for: food)
        if !force,
           hasRecentGenerationFailure(storageKey: Self.foodIconImageFailureCacheStorageKey, cacheKey: cacheKey) {
            foodEmojiProgressMessage = Self.skippedRecentFailuresMessage(1, noun: "food image")
            return
        }

        isAssigningFoodEmojis = true
        foodEmojiCompletedCount = 0
        foodEmojiTotalCount = 1
        foodEmojiProgressMessage = "\(force ? "Regenerating" : "Generating") image for \(food.name)"
        defer { isAssigningFoodEmojis = false }

        do {
            let icon = try await generateFoodIconImagePayload(for: food, apiKey: apiKey)
            apply(icon, to: food)
            clearGenerationFailure(storageKey: Self.foodIconImageFailureCacheStorageKey, cacheKey: cacheKey)
            try modelContext.save()
            tursoMirror?.scheduleMirror(reason: "food_icon_image_generated")
            foodEmojiCompletedCount = 1
            foodEmojiProgressMessage = "Food image generated."
        } catch {
            rememberGenerationFailure(storageKey: Self.foodIconImageFailureCacheStorageKey, cacheKey: cacheKey)
            try? modelContext.save()
            foodEmojiCompletedCount = 1
            foodEmojiProgressMessage = "Food image generation failed."
        }
    }

    func pixelPassFoodIconImage(for food: SavedFood) async {
        guard let modelContext else { return }
        guard let data = food.generatedIconImageData, !data.isEmpty else {
            foodEmojiProgressMessage = "Generate a food image before running Pixel Pass."
            return
        }

        let currentIcon = GeneratedFoodIconImage(
            data: data,
            mimeType: food.generatedIconImageMimeType ?? "image/*"
        )
        guard let pixelPassedIcon = Self.pixelPassedTransparentFoodIconImage(from: currentIcon) else {
            foodEmojiProgressMessage = "Pixel Pass could not process this image."
            return
        }

        food.generatedIconImageData = pixelPassedIcon.data
        food.generatedIconImageMimeType = pixelPassedIcon.mimeType
        food.generatedIconImageUpdatedAt = .now

        do {
            try modelContext.save()
            tursoMirror?.scheduleMirror(reason: "food_icon_image_pixel_pass")
            foodEmojiProgressMessage = "Pixel Pass applied."
        } catch {
            foodEmojiProgressMessage = "Pixel Pass failed to save."
        }
    }

    private func apply(_ icon: GeneratedFoodIconImage, to food: SavedFood) {
        food.generatedIconImageData = icon.data
        food.generatedIconImageMimeType = icon.mimeType
        food.generatedIconImageUpdatedAt = .now
        food.generatedIconImagePrompt = Self.foodIconImagePrompt(name: food.name, brand: food.brand)
    }

    private func foodEmojiFailureCacheKey(for food: SavedFood, config: AIRequestConfig) -> String {
        let prompt = Self.foodEmojiPrompt(
            name: food.name,
            brand: food.brand,
            servingSize: food.servingSize
        )
        return generationFailureCacheKey(
            version: Self.foodEmojiGenerationCacheVersion,
            model: "\(config.provider.rawValue):\(config.primary)",
            foodID: food.id,
            prompt: prompt
        )
    }

    private func foodIconImageFailureCacheKey(for food: SavedFood) -> String {
        let prompt = Self.foodIconImagePrompt(name: food.name, brand: food.brand)
        return generationFailureCacheKey(
            version: Self.foodIconImageGenerationCacheVersion,
            model: Self.foodIconImageModel,
            foodID: food.id,
            prompt: prompt
        )
    }

    private func generationFailureCacheKey(
        version: String,
        model: String,
        foodID: UUID,
        prompt: String
    ) -> String {
        "\(version)|\(model)|\(foodID.uuidString)|\(prompt)"
    }

    private func hasRecentGenerationFailure(storageKey: String, cacheKey: String, now: Date = .now) -> Bool {
        var cache = generationFailureCache(storageKey: storageKey)
        let cutoff = now.timeIntervalSince1970 - Self.generationFailureRetryInterval
        let originalCount = cache.count
        cache = cache.filter { $0.value >= cutoff }
        if cache.count != originalCount {
            saveGenerationFailureCache(cache, storageKey: storageKey)
        }
        guard let failedAt = cache[cacheKey] else { return false }
        return failedAt >= cutoff
    }

    private func rememberGenerationFailure(storageKey: String, cacheKey: String, now: Date = .now) {
        var cache = generationFailureCache(storageKey: storageKey)
        cache[cacheKey] = now.timeIntervalSince1970
        saveGenerationFailureCache(cache, storageKey: storageKey)
    }

    private func clearGenerationFailure(storageKey: String, cacheKey: String) {
        var cache = generationFailureCache(storageKey: storageKey)
        guard cache.removeValue(forKey: cacheKey) != nil else { return }
        saveGenerationFailureCache(cache, storageKey: storageKey)
    }

    private func generationFailureCache(storageKey: String) -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: storageKey)?.compactMapValues { value in
            if let double = value as? Double { return double }
            if let number = value as? NSNumber { return number.doubleValue }
            return nil
        } ?? [:]
    }

    private func saveGenerationFailureCache(_ cache: [String: Double], storageKey: String) {
        UserDefaults.standard.set(cache, forKey: storageKey)
    }

    private static func skippedRecentFailuresMessage(_ count: Int, noun: String) -> String {
        let item = count == 1 ? noun : "\(noun)s"
        return "Skipped \(count.formatted()) \(item) that failed recently. Use a row's regenerate action to retry now."
    }

    @discardableResult
    private func optimizeStoredFoodIconImages(in foods: [SavedFood]) -> Int {
        var optimizedCount = 0
        for food in foods {
            guard let data = food.generatedIconImageData,
                  !data.isEmpty,
                  let optimized = Self.optimizedStoredFoodIconImage(
                      from: GeneratedFoodIconImage(
                          data: data,
                          mimeType: food.generatedIconImageMimeType ?? "image/*"
                      )
                  ),
                  optimized.data.count < data.count else {
                continue
            }

            apply(optimized, to: food)
            optimizedCount += 1
        }
        return optimizedCount
    }

    private func generateFoodEmoji(for food: SavedFood, apiKey: String, config: AIRequestConfig) async throws -> String {
        let start = ContinuousClock.now
        let prompt = Self.foodEmojiPrompt(
            name: food.name,
            brand: food.brand,
            servingSize: food.servingSize
        )
        let request = GeminiRequest(
            input: [.text(prompt)],
            generationConfig: GeminiGenerationConfig(thinkingLevel: config.thinkingLevel)
        )
        let requestMetadata = GeminiRequestLogMetadata(
            apiMethod: config.provider == .gemini ? "interactions.create.stream" : "chat.completions.stream",
            aiProvider: config.provider.rawValue,
            responseMimeType: "application/json",
            thinkingLevel: config.thinkingLevel,
            includeThoughts: config.expectsThinkingTrace,
            tools: [],
            imageCount: 0,
            maxImageDimension: nil,
            jpegQuality: nil,
            providerRouting: config.providerRoutingDescription
        )
        let trace = GeminiCallTrace(
            requestPrompt: prompt,
            requestMetadataJSON: encodedJSONString(requestMetadata),
            imageMetadataJSON: nil,
            searchGroundingRequested: false
        )
        let userPrompt = [food.brand, food.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        thinkingTrace = []
        thinkingTraceUpdateCount = 0

        let text: String
        do {
            text = try await callAIText(
                request: request,
                prompt: prompt,
                images: [],
                useWebSearch: false,
                apiKey: apiKey,
                config: config,
                trace: trace
            )
        } catch {
            let visibleError = visibleError(from: error)
            recordGeminiScanLog(
                operation: .foodEmoji,
                status: .failure,
                primaryModel: config.primary,
                fallbackModel: config.fallback,
                resolvedModel: trace.resolvedModel ?? config.primary,
                usedFallback: trace.usedFallback,
                userPrompt: userPrompt,
                durationMs: msFrom(ContinuousClock.now.duration(to: start)),
                debugTrace: trace,
                error: visibleError,
                persistImmediately: false
            )
            throw visibleError
        }

        let decoded: GeminiFoodEmojiResponse
        do {
            decoded = try JSONDecoder().decode(GeminiFoodEmojiResponse.self, from: Data(extractJSONObjectText(from: text).utf8))
        } catch {
            let err = ScanError.decodingError(error)
            trace.parseStage = "food_emoji_json_decode"
            recordGeminiScanLog(
                operation: .foodEmoji,
                status: .failure,
                primaryModel: config.primary,
                fallbackModel: config.fallback,
                resolvedModel: trace.resolvedModel ?? config.primary,
                usedFallback: trace.usedFallback,
                userPrompt: userPrompt,
                durationMs: msFrom(ContinuousClock.now.duration(to: start)),
                debugTrace: trace,
                error: err,
                persistImmediately: false
            )
            throw err
        }

        guard let emoji = Self.extractFoodEmoji(from: decoded.emoji) else {
            let err = ScanError.invalidEmojiResponse(Self.clippedForLog(text))
            trace.parseStage = "food_emoji_parse"
            recordGeminiScanLog(
                operation: .foodEmoji,
                status: .failure,
                primaryModel: config.primary,
                fallbackModel: config.fallback,
                resolvedModel: trace.resolvedModel ?? config.primary,
                usedFallback: trace.usedFallback,
                userPrompt: userPrompt,
                durationMs: msFrom(ContinuousClock.now.duration(to: start)),
                debugTrace: trace,
                error: err,
                persistImmediately: false
            )
            throw err
        }

        recordGeminiScanLog(
            operation: .foodEmoji,
            status: .success,
            primaryModel: config.primary,
            fallbackModel: config.fallback,
            resolvedModel: trace.resolvedModel ?? config.primary,
            usedFallback: trace.usedFallback,
            userPrompt: userPrompt,
            durationMs: msFrom(ContinuousClock.now.duration(to: start)),
            debugTrace: trace,
            persistImmediately: false
        )
        return emoji
    }

    private func generateFoodIconImagePayload(for food: SavedFood, apiKey: String) async throws -> GeneratedFoodIconImage {
        let start = ContinuousClock.now
        let prompt = Self.foodIconImagePrompt(name: food.name, brand: food.brand)
        let requestMetadata = GeminiRequestLogMetadata(
            apiMethod: "interactions.create",
            aiProvider: AIProvider.gemini.rawValue,
            responseMimeType: "image/*",
            thinkingLevel: Self.foodIconImageThinkingLevel,
            includeThoughts: false,
            tools: [],
            imageCount: 0,
            maxImageDimension: nil,
            jpegQuality: nil,
            providerRouting: nil
        )
        let trace = GeminiCallTrace(
            requestPrompt: prompt,
            requestMetadataJSON: encodedJSONString(requestMetadata),
            imageMetadataJSON: nil,
            searchGroundingRequested: false
        )
        let userPrompt = [food.brand, food.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let icon = try await callGeminiFoodIconImage(prompt: prompt, apiKey: apiKey, trace: trace)
            recordGeminiScanLog(
                operation: .foodIconImage,
                status: .success,
                primaryModel: Self.foodIconImageModel,
                fallbackModel: nil,
                resolvedModel: trace.resolvedModel ?? Self.foodIconImageModel,
                usedFallback: false,
                userPrompt: userPrompt,
                durationMs: msFrom(ContinuousClock.now.duration(to: start)),
                debugTrace: trace,
                persistImmediately: false
            )
            return icon
        } catch {
            let visibleError = visibleError(from: error)
            recordGeminiScanLog(
                operation: .foodIconImage,
                status: .failure,
                primaryModel: Self.foodIconImageModel,
                fallbackModel: nil,
                resolvedModel: trace.resolvedModel ?? Self.foodIconImageModel,
                usedFallback: false,
                userPrompt: userPrompt,
                durationMs: msFrom(ContinuousClock.now.duration(to: start)),
                debugTrace: trace,
                error: visibleError,
                persistImmediately: false
            )
            throw visibleError
        }
    }

    private func callGeminiFoodIconImage(
        prompt: String,
        apiKey: String,
        trace: GeminiCallTrace
    ) async throws -> GeneratedFoodIconImage {
        let redactedEndpoint = Self.geminiInteractionsURL
        let attemptStart = ContinuousClock.now
        var attempt = GeminiModelAttemptLog(model: Self.foodIconImageModel, endpoint: redactedEndpoint)

        func fail(_ error: Error, stage: String? = nil) throws -> Never {
            let visible = visibleError(from: error)
            attempt.durationMs = msFrom(ContinuousClock.now.duration(to: attemptStart))
            attempt.errorCode = errorCode(from: visible)
            attempt.errorMessage = errorMessage(from: visible)
            if let stage {
                attempt.parseStage = stage
            }
            trace.absorb(attempt)
            self.error = visible as? ScanError
            throw GeminiCallFailure(underlying: visible, trace: trace)
        }

        guard let url = URL(string: Self.geminiInteractionsURL) else {
            try fail(ScanError.invalidResponse, stage: "build_url")
        }

        let requestBody = GeminiImageGenerationRequest(
            model: Self.foodIconImageModel,
            input: prompt,
            systemInstruction: Self.foodIconImageSystemInstruction,
            generationConfig: GeminiImageGenerationConfig(
                temperature: 1,
                maxOutputTokens: 65_536,
                topP: 0.95,
                thinkingLevel: Self.foodIconImageThinkingLevel,
                imageConfig: GeminiImageConfig(
                    aspectRatio: "1:1",
                    imageSize: "1K"
                )
            ),
            responseModalities: ["image"]
        )

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        httpRequest.httpBody = try JSONEncoder().encode(requestBody)
        trace.requestPayloadBytes = httpRequest.httpBody?.count

        #if DEBUG
        print("🧠 Gemini food icon image start model=\(Self.foodIconImageModel) payloadBytes=\(trace.requestPayloadBytes ?? 0)")
        #endif

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: httpRequest)
        } catch {
            try fail(ScanError.networkError(error), stage: "network")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            try fail(ScanError.invalidResponse, stage: "http_response")
        }
        attempt.httpStatus = httpResponse.statusCode

        #if DEBUG
        print("🧠 Gemini food icon image HTTP \(httpResponse.statusCode) model=\(Self.foodIconImageModel) +\(msFrom(attemptStart.duration(to: ContinuousClock.now)))ms")
        #endif

        guard (200..<300).contains(httpResponse.statusCode) else {
            attempt.rawErrorBody = String(data: data, encoding: .utf8)
            let apiResponse = try? JSONDecoder().decode(GeminiAPIErrorEnvelope.self, from: data)
            let message = apiResponse?.error?.message ?? "HTTP \(httpResponse.statusCode)"
            #if DEBUG
            if let rawErrorBody = attempt.rawErrorBody {
                print("🧠 Gemini food icon image HTTP error \(httpResponse.statusCode): \(rawErrorBody)")
            }
            #endif
            try fail(ScanError.serverError(httpResponse.statusCode, message), stage: "http_error")
        }

        guard let generatedIcon = Self.extractGeneratedFoodIconImage(from: data) else {
            let rawText = String(data: data, encoding: .utf8) ?? "<binary response>"
            try fail(ScanError.invalidGeneratedImageResponse(Self.clippedForLog(rawText)), stage: "image_parse")
        }
        let icon = Self.optimizedStoredFoodIconImage(from: generatedIcon) ?? generatedIcon

        let imagePricing = applyFoodIconImagePricing(from: data, to: &attempt)
        attempt.rawResponseJSON = encodedJSONString(
            GeminiGeneratedFoodIconLogMetadata(
                originalGeneratedImageBytes: generatedIcon.data.count,
                storedImageBytes: icon.data.count,
                storedImageMimeType: icon.mimeType,
                storageMaxPixelDimension: Int(Self.foodIconStoredMaxPixelDimension),
                storageJPEGQuality: Self.foodIconStoredJPEGQuality,
                promptJSON: prompt,
                reportedInputTokens: imagePricing.reportedInputTokens,
                reportedOutputTokens: imagePricing.reportedOutputTokens,
                reportedTotalTokens: imagePricing.reportedTotalTokens,
                billableImageOutputTokens: imagePricing.billableImageOutputTokens,
                estimatedImageOutputCostUSD: imagePricing.estimatedImageOutputCostUSD,
                estimatedTotalCostUSD: imagePricing.estimatedTotalCostUSD,
                pricingModel: imagePricing.pricingModel
            )
        )
        attempt.succeeded = true
        attempt.parseStage = "complete"
        attempt.durationMs = msFrom(ContinuousClock.now.duration(to: attemptStart))
        trace.absorb(attempt)

        #if DEBUG
        print("🧠 Gemini food icon image complete bytes=\(icon.data.count) mime=\(icon.mimeType) duration=\(attempt.durationMs ?? 0)ms \(Self.debugFoodIconImageCostSummary(imagePricing, attempt: attempt))")
        #endif

        return icon
    }

    private static func optimizedStoredFoodIconImage(from icon: GeneratedFoodIconImage) -> GeneratedFoodIconImage? {
        guard let image = UIImage(data: icon.data) else { return nil }
        guard let resized = resizedFoodIconImage(from: image, opaque: true, fillColor: .white) else {
            return nil
        }

        guard let data = resized.jpegData(compressionQuality: foodIconStoredJPEGQuality) else {
            return nil
        }
        return GeneratedFoodIconImage(data: data, mimeType: foodIconStoredMimeType)
    }

    private static func pixelPassedTransparentFoodIconImage(from icon: GeneratedFoodIconImage) -> GeneratedFoodIconImage? {
        guard let image = UIImage(data: icon.data),
              let resized = resizedFoodIconImage(from: image, opaque: false, fillColor: nil),
              let cgImage = resized.cgImage else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let didDrawImage = pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo.rawValue
                  ) else {
                return false
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDrawImage else {
            return nil
        }

        var visited = [Bool](repeating: false, count: width * height)
        var queue: [Int] = []
        queue.reserveCapacity(width * height)

        func enqueue(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let pixelIndex = y * width + x
            guard !visited[pixelIndex] else { return }

            if pixelPassBackgroundAlpha(pixels, byteIndex: pixelIndex * bytesPerPixel) != nil {
                visited[pixelIndex] = true
                queue.append(pixelIndex)
            }
        }

        for x in 0..<width {
            enqueue(x, 0)
            enqueue(x, height - 1)
        }
        for y in 0..<height {
            enqueue(0, y)
            enqueue(width - 1, y)
        }

        var head = 0
        while head < queue.count {
            let pixelIndex = queue[head]
            head += 1

            let x = pixelIndex % width
            let y = pixelIndex / width
            enqueue(x + 1, y)
            enqueue(x - 1, y)
            enqueue(x, y + 1)
            enqueue(x, y - 1)
        }

        var softShadowPixelCount = 0
        for pixelIndex in queue {
            let byteIndex = pixelIndex * bytesPerPixel
            let outputAlpha = pixelPassBackgroundAlpha(pixels, byteIndex: byteIndex) ?? 0
            if outputAlpha > 0 {
                softShadowPixelCount += 1
            }

            pixels[byteIndex] = 0
            pixels[byteIndex + 1] = 0
            pixels[byteIndex + 2] = 0
            pixels[byteIndex + 3] = outputAlpha
        }

        let outputData = Data(pixels)
        guard let provider = CGDataProvider(data: outputData as CFData),
              let outputImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ),
              let pngData = UIImage(cgImage: outputImage, scale: 1, orientation: .up).pngData() else {
            return nil
        }

        #if DEBUG
        print("🧪 Food icon Pixel Pass backgroundPixels=\(queue.count)/\(width * height) softShadowPixels=\(softShadowPixelCount) bytes=\(icon.data.count)->\(pngData.count)")
        #endif

        return GeneratedFoodIconImage(data: pngData, mimeType: foodIconTransparentMimeType)
    }

    private static func resizedFoodIconImage(from image: UIImage, opaque: Bool, fillColor: UIColor?) -> UIImage? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > 0 else { return nil }

        let ratio = min(1, foodIconStoredMaxPixelDimension / longest)
        let targetSize = CGSize(
            width: max(1, (pixelWidth * ratio).rounded()),
            height: max(1, (pixelHeight * ratio).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { context in
            if let fillColor {
                fillColor.setFill()
                context.fill(CGRect(origin: .zero, size: targetSize))
            }
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func pixelPassBackgroundAlpha(_ pixels: [UInt8], byteIndex: Int) -> UInt8? {
        let alpha = Int(pixels[byteIndex + 3])
        guard alpha >= 12 else { return 0 }

        let red = Int(pixels[byteIndex])
        let green = Int(pixels[byteIndex + 1])
        let blue = Int(pixels[byteIndex + 2])
        let darkestChannel = min(red, green, blue)
        let brightestChannel = max(red, green, blue)
        let distanceFromWhite = max(255 - red, 255 - green, 255 - blue)

        guard darkestChannel >= 185,
              brightestChannel - darkestChannel <= 44 else {
            return nil
        }

        let transparentDistance = 5
        guard distanceFromWhite > transparentDistance else { return 0 }

        let rampDistance = 82.0
        let ramp = min(1, Double(distanceFromWhite - transparentDistance) / rampDistance)
        let eased = ramp * ramp * (3 - 2 * ramp)
        return UInt8((eased * 96).rounded())
    }

    nonisolated static func extractFoodEmoji(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for character in trimmed where character.isFoodBankEmojiCandidate {
            return String(character)
        }

        return nil
    }

    nonisolated private static func extractGeneratedFoodIconImage(from data: Data) -> GeneratedFoodIconImage? {
        if let mimeType = imageMimeType(for: data, declaredMimeType: nil) {
            return GeneratedFoodIconImage(data: data, mimeType: mimeType)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findGeneratedFoodIconImage(in: object, inheritedMimeType: nil)
    }

    nonisolated private static func findGeneratedFoodIconImage(
        in object: Any,
        inheritedMimeType: String?
    ) -> GeneratedFoodIconImage? {
        if let dictionary = object as? [String: Any] {
            let declaredMimeType = firstString(
                in: dictionary,
                keys: ["mime_type", "mimeType", "mime", "content_type", "contentType"]
            ) ?? inheritedMimeType

            for key in ["data", "base64", "bytes_base64_encoded", "bytesBase64Encoded"] {
                if let rawBase64 = dictionary[key] as? String,
                   let decoded = decodeImageBase64(rawBase64, declaredMimeType: declaredMimeType) {
                    return decoded
                }
            }

            for key in ["inline_data", "inlineData", "image", "content", "part"] {
                if let nested = dictionary[key],
                   let decoded = findGeneratedFoodIconImage(in: nested, inheritedMimeType: declaredMimeType) {
                    return decoded
                }
            }

            for value in dictionary.values {
                if let decoded = findGeneratedFoodIconImage(in: value, inheritedMimeType: declaredMimeType) {
                    return decoded
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let decoded = findGeneratedFoodIconImage(in: value, inheritedMimeType: inheritedMimeType) {
                    return decoded
                }
            }
        }

        return nil
    }

    nonisolated private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    nonisolated private static func decodeImageBase64(
        _ raw: String,
        declaredMimeType: String?
    ) -> GeneratedFoodIconImage? {
        let base64: String
        if let commaIndex = raw.firstIndex(of: ",") {
            base64 = String(raw[raw.index(after: commaIndex)...])
        } else {
            base64 = raw
        }

        let cleaned = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]),
              let mimeType = imageMimeType(for: decoded, declaredMimeType: declaredMimeType) else {
            return nil
        }
        return GeneratedFoodIconImage(data: decoded, mimeType: mimeType)
    }

    nonisolated private static func imageMimeType(for data: Data, declaredMimeType: String?) -> String? {
        if Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47] {
            return declaredMimeType?.hasPrefix("image/") == true ? declaredMimeType : "image/png"
        }
        if Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF] {
            return declaredMimeType?.hasPrefix("image/") == true ? declaredMimeType : "image/jpeg"
        }
        if Array(data.prefix(4)) == [0x47, 0x49, 0x46, 0x38] {
            return declaredMimeType?.hasPrefix("image/") == true ? declaredMimeType : "image/gif"
        }
        if data.count >= 12,
           String(data: Data(data.prefix(4)), encoding: .ascii) == "RIFF",
           String(data: Data(data.dropFirst(8).prefix(4)), encoding: .ascii) == "WEBP" {
            return declaredMimeType?.hasPrefix("image/") == true ? declaredMimeType : "image/webp"
        }
        if let declaredMimeType, declaredMimeType.hasPrefix("image/"), !data.isEmpty {
            return declaredMimeType
        }
        return nil
    }

    /// Extracts portions for one named calculator ingredient from restaurant
    /// nutrition images. The typed name anchors extraction; callers keep
    /// that name authoritative when mapping the id-less draft into local values.
    func extractCalculatorIngredient(
        named name: String,
        from images: [UIImage],
        useProModel: Bool = false
    ) async throws -> CalculatorIngredientDraft {
        isScanning = true
        error = nil
        thinkingTrace = []
        thinkingTraceUpdateCount = 0
        expectsThinkingTrace = false
        scanProgressMessage = "Reading ingredient image..."
        defer {
            isScanning = false
            expectsThinkingTrace = false
        }
        let start = ContinuousClock.now
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            let err = ScanError.emptySearchQuery
            self.error = err
            throw err
        }

        guard !images.isEmpty else {
            let err = ScanError.noImages
            self.error = err
            throw err
        }
        guard images.count <= Self.maxImagesPerScan else {
            let err = ScanError.tooManyImages(Self.maxImagesPerScan)
            self.error = err
            throw err
        }
        let aiConfig = aiRequestConfig(for: .calculatorOCR(useProModel: useProModel))

        guard let apiKey = apiKey(for: aiConfig) else {
            let err = ScanError.noProviderAPIKey(aiConfig.provider.displayName)
            self.error = err
            throw err
        }

        let maxImageDimension: CGFloat = 1600
        let jpegQuality: CGFloat = 0.72
        let preparedImages: [PreparedGeminiImage] = try images.enumerated().map { index, image in
            let resized = image.resizedForOCR(maxDimension: maxImageDimension)
            guard let data = resized.jpegData(compressionQuality: jpegQuality) else {
                let err = ScanError.imageEncodingFailed
                self.error = err
                throw err
            }

            let metadata = GeminiImageLogMetadata(
                index: index + 1,
                originalWidthPx: Int(image.size.width * image.scale),
                originalHeightPx: Int(image.size.height * image.scale),
                resizedWidthPx: Int(resized.size.width * resized.scale),
                resizedHeightPx: Int(resized.size.height * resized.scale),
                jpegBytes: data.count,
                jpegQuality: Double(jpegQuality)
            )
            return PreparedGeminiImage(data: data, metadata: metadata)
        }

        let prompt = Self.calculatorIngredientPrompt(name: trimmedName)
        let imageParts = preparedImages.map {
            GeminiContent.image(mimeType: "image/jpeg", data: $0.data.base64EncodedString())
        }
        let request = GeminiRequest(
            input: [.text(prompt)] + imageParts,
            generationConfig: GeminiGenerationConfig(thinkingLevel: aiConfig.thinkingLevel)
        )
        let requestMetadata = GeminiRequestLogMetadata(
            apiMethod: aiConfig.provider == .gemini ? "interactions.create.stream" : "chat.completions.stream",
            aiProvider: aiConfig.provider.rawValue,
            responseMimeType: "application/json",
            thinkingLevel: aiConfig.thinkingLevel,
            includeThoughts: aiConfig.expectsThinkingTrace,
            tools: [],
            imageCount: images.count,
            maxImageDimension: Int(maxImageDimension),
            jpegQuality: Double(jpegQuality),
            providerRouting: aiConfig.providerRoutingDescription
        )
        let trace = GeminiCallTrace(
            requestPrompt: prompt,
            requestMetadataJSON: encodedJSONString(requestMetadata),
            imageMetadataJSON: encodedJSONString(preparedImages.map(\.metadata)),
            searchGroundingRequested: false
        )

        prepareAIWait(for: aiConfig)
        let text: String
        do {
            text = try await callAIText(
                request: request,
                prompt: prompt,
                images: preparedImages,
                useWebSearch: false,
                apiKey: apiKey,
                config: aiConfig,
                trace: trace
            )
        } catch {
            let visibleError = visibleError(from: error)
            recordGeminiScanLog(
                operation: .scan,
                status: .failure,
                primaryModel: aiConfig.primary,
                fallbackModel: aiConfig.fallback,
                resolvedModel: trace.resolvedModel ?? aiConfig.primary,
                usedFallback: trace.usedFallback,
                photoCount: images.count,
                userPrompt: "Nutrition calculator ingredient OCR: \(trimmedName)",
                durationMs: msFrom(ContinuousClock.now.duration(to: start)),
                debugTrace: trace,
                error: visibleError
            )
            throw visibleError
        }

        do {
            let response = try JSONDecoder().decode(CalculatorIngredientDraft.self, from: Data(extractJSONObjectText(from: text).utf8))
            let filteredPortions = response.portions.filter {
                !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            recordGeminiScanLog(
                operation: .scan,
                status: .success,
                primaryModel: aiConfig.primary,
                fallbackModel: aiConfig.fallback,
                resolvedModel: trace.resolvedModel ?? aiConfig.primary,
                usedFallback: trace.usedFallback,
                photoCount: images.count,
                userPrompt: "Nutrition calculator ingredient OCR: \(trimmedName)",
                durationMs: msFrom(ContinuousClock.now.duration(to: start)),
                debugTrace: trace
            )
            return CalculatorIngredientDraft(
                name: response.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? trimmedName
                    : response.name.trimmingCharacters(in: .whitespacesAndNewlines),
                portions: filteredPortions
            )
        } catch {
            let err = ScanError.decodingError(error)
            self.error = err
            recordGeminiScanLog(
                operation: .scan,
                status: .failure,
                primaryModel: aiConfig.primary,
                fallbackModel: aiConfig.fallback,
                resolvedModel: trace.resolvedModel ?? aiConfig.primary,
                usedFallback: trace.usedFallback,
                photoCount: images.count,
                userPrompt: "Nutrition calculator ingredient OCR: \(trimmedName)",
                durationMs: msFrom(ContinuousClock.now.duration(to: start)),
                debugTrace: trace,
                error: err
            )
            throw err
        }
    }

    // MARK: - Gemini API Call

    private func callAI(
        request: GeminiRequest,
        prompt: String,
        images: [PreparedGeminiImage],
        useWebSearch: Bool,
        apiKey: String,
        config: AIRequestConfig,
        trace: GeminiCallTrace
    ) async throws -> GeminiNutritionResponse {
        let text = try await callAIText(
            request: request,
            prompt: prompt,
            images: images,
            useWebSearch: useWebSearch,
            apiKey: apiKey,
            config: config,
            trace: trace
        )
        do {
            return try JSONDecoder().decode(GeminiNutritionResponse.self, from: Data(extractJSONObjectText(from: text).utf8))
        } catch {
            let err = ScanError.decodingError(error)
            trace.parseStage = "nutrition_json_decode"
            self.error = err
            throw GeminiCallFailure(underlying: err, trace: trace)
        }
    }

    private func callAIText(
        request: GeminiRequest,
        prompt: String,
        images: [PreparedGeminiImage],
        useWebSearch: Bool,
        apiKey: String,
        config: AIRequestConfig,
        trace: GeminiCallTrace
    ) async throws -> String {
        switch config.provider {
        case .gemini:
            return try await callGeminiText(
                request: request,
                apiKey: apiKey,
                primaryModel: config.primary,
                fallbackModel: config.fallback,
                trace: trace
            )
        case .openRouter:
            return try await callOpenRouterText(
                prompt: prompt,
                images: images,
                useWebSearch: useWebSearch,
                apiKey: apiKey,
                config: config,
                trace: trace
            )
        }
    }

    /// Calls Gemini Interactions. If the primary model fails with 500/503,
    /// automatically retries with the fallback model.
    private func callGemini(
        request: GeminiRequest,
        apiKey: String,
        primaryModel: String,
        fallbackModel: String,
        trace: GeminiCallTrace
    ) async throws -> GeminiNutritionResponse {
        do {
            return try await callGeminiModel(request: request, apiKey: apiKey, model: primaryModel, trace: trace)
        } catch {
            let visible = visibleError(from: error)
            if let code = retryableFallbackStatusCode(visible) {
                scanProgressMessage = "Retrying with Gemini Flash..."
                print("⚠️ Primary model failed (\(code)), falling back to \(fallbackModel)...")
                trace.usedFallback = true
                do {
                    return try await callGeminiModel(request: request, apiKey: apiKey, model: fallbackModel, trace: trace)
                } catch {
                    let fallbackError = visibleError(from: error)
                    self.error = fallbackError as? ScanError
                    throw GeminiCallFailure(underlying: fallbackError, trace: trace)
                }
            }
            self.error = visible as? ScanError
            throw GeminiCallFailure(underlying: visible, trace: trace)
        }
    }

    private func callGeminiText(
        request: GeminiRequest,
        apiKey: String,
        primaryModel: String,
        fallbackModel: String,
        trace: GeminiCallTrace
    ) async throws -> String {
        do {
            return try await callGeminiTextModel(request: request, apiKey: apiKey, model: primaryModel, trace: trace)
        } catch {
            let visible = visibleError(from: error)
            if retryableFallbackStatusCode(visible) != nil {
                scanProgressMessage = "Retrying with Gemini Flash..."
                trace.usedFallback = true
                do {
                    return try await callGeminiTextModel(request: request, apiKey: apiKey, model: fallbackModel, trace: trace)
                } catch {
                    let fallbackError = visibleError(from: error)
                    self.error = fallbackError as? ScanError
                    throw GeminiCallFailure(underlying: fallbackError, trace: trace)
                }
            }
            self.error = visible as? ScanError
            throw GeminiCallFailure(underlying: visible, trace: trace)
        }
    }

    private func callGeminiModel(
        request: GeminiRequest,
        apiKey: String,
        model: String,
        trace: GeminiCallTrace
    ) async throws -> GeminiNutritionResponse {
        let text = try await callGeminiTextModel(request: request, apiKey: apiKey, model: model, trace: trace)
        do {
            return try JSONDecoder().decode(GeminiNutritionResponse.self, from: Data(extractJSONObjectText(from: text).utf8))
        } catch {
            let err = ScanError.decodingError(error)
            trace.parseStage = "nutrition_json_decode"
            self.error = err
            throw GeminiCallFailure(underlying: err, trace: trace)
        }
    }

    private func callGeminiTextModel(
        request: GeminiRequest,
        apiKey: String,
        model: String,
        trace: GeminiCallTrace
    ) async throws -> String {
        let redactedEndpoint = Self.geminiInteractionsURL
        let attemptStart = ContinuousClock.now
        var attempt = GeminiModelAttemptLog(model: model, endpoint: redactedEndpoint)

        func fail(_ error: Error, stage: String? = nil) throws -> Never {
            let visible = visibleError(from: error)
            attempt.durationMs = msFrom(ContinuousClock.now.duration(to: attemptStart))
            attempt.errorCode = errorCode(from: visible)
            attempt.errorMessage = errorMessage(from: visible)
            if let stage {
                attempt.parseStage = stage
            }
            trace.absorb(attempt)
            self.error = visible as? ScanError
            throw GeminiCallFailure(underlying: visible, trace: trace)
        }

        guard let url = URL(string: Self.geminiInteractionsURL) else {
            try fail(ScanError.invalidResponse, stage: "build_url")
        }

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        httpRequest.httpBody = try JSONEncoder().encode(request.interactionBody(model: model))
        trace.requestPayloadBytes = httpRequest.httpBody?.count
        #if DEBUG
        print("🧠 Gemini stream start model=\(model) payloadBytes=\(trace.requestPayloadBytes ?? 0)")
        #endif

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: httpRequest)
        } catch {
            try fail(ScanError.networkError(error), stage: "network")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            try fail(ScanError.invalidResponse, stage: "http_response")
        }
        attempt.httpStatus = httpResponse.statusCode
        #if DEBUG
        print("🧠 Gemini stream HTTP \(httpResponse.statusCode) model=\(model) +\(msFrom(attemptStart.duration(to: ContinuousClock.now)))ms")
        #endif

        guard (200..<300).contains(httpResponse.statusCode) else {
            let data = try await collectData(from: bytes)
            attempt.rawErrorBody = String(data: data, encoding: .utf8)
            let apiResponse = try? JSONDecoder().decode(GeminiAPIErrorEnvelope.self, from: data)
            let message = apiResponse?.error?.message ?? "HTTP \(httpResponse.statusCode)"
            #if DEBUG
            if let rawErrorBody = attempt.rawErrorBody {
                print("🧠 Gemini stream HTTP error \(httpResponse.statusCode) model=\(model): \(rawErrorBody)")
            }
            #endif
            try fail(ScanError.serverError(httpResponse.statusCode, message), stage: "http_error")
        }

        var jsonText = ""
        var currentEventName: String?
        var rawEventPayloads: [String] = []

        do {
            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty {
                    currentEventName = nil
                    continue
                }

                if line.hasPrefix("event:") {
                    currentEventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" {
                        #if DEBUG
                        print("🧠 Gemini stream done model=\(model) +\(msFrom(attemptStart.duration(to: ContinuousClock.now)))ms")
                        #endif
                        break
                    }
                    rawEventPayloads.append(payload)
                    try await consumeGeminiInteractionStreamEvent(
                        payload,
                        eventName: currentEventName,
                        attemptStartedAt: attemptStart,
                        jsonText: &jsonText,
                        attempt: &attempt
                    )
                    currentEventName = nil
                }
            }
        } catch let scanError as ScanError {
            attempt.rawResponseJSON = encodedJSONString(rawEventPayloads)
            attempt.responseText = jsonText
            attempt.responseTextCharacters = jsonText.count
            try fail(scanError, stage: attempt.parseStage ?? "stream")
        } catch {
            attempt.rawResponseJSON = encodedJSONString(rawEventPayloads)
            attempt.responseText = jsonText
            attempt.responseTextCharacters = jsonText.count
            try fail(ScanError.decodingError(error), stage: attempt.parseStage ?? "stream_decode")
        }

        attempt.rawResponseJSON = encodedJSONString(rawEventPayloads)
        attempt.responseText = jsonText
        attempt.responseTextCharacters = jsonText.count

        guard !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try fail(ScanError.invalidResponse, stage: "empty_response_text")
        }

        attempt.succeeded = true
        attempt.parseStage = "complete"
        attempt.durationMs = msFrom(ContinuousClock.now.duration(to: attemptStart))
        #if DEBUG
        print("🧠 Gemini stream complete model=\(model) duration=\(attempt.durationMs ?? 0)ms events=\(attempt.streamEventCount) thoughtSummaries=\(attempt.thoughtPartCount) textDeltas=\(attempt.nonThoughtPartCount) firstThoughtMs=\(attempt.firstThoughtSummaryMs.map(String.init) ?? "nil") firstTextMs=\(attempt.firstTextDeltaMs.map(String.init) ?? "nil") jsonChars=\(jsonText.count)")
        #endif
        trace.absorb(attempt)
        return jsonText
    }

    private func callOpenRouterText(
        prompt: String,
        images: [PreparedGeminiImage],
        useWebSearch: Bool,
        apiKey: String,
        config: AIRequestConfig,
        trace: GeminiCallTrace
    ) async throws -> String {
        do {
            return try await callOpenRouterTextModel(
                prompt: prompt,
                images: images,
                useWebSearch: useWebSearch,
                apiKey: apiKey,
                model: config.primary,
                routingMode: config.openRouterRoutingMode,
                trace: trace
            )
        } catch {
            let visible = visibleError(from: error)
            if retryableFallbackStatusCode(visible) != nil, config.fallback != config.primary {
                scanProgressMessage = "Retrying with OpenRouter fallback..."
                trace.usedFallback = true
                do {
                    return try await callOpenRouterTextModel(
                        prompt: prompt,
                        images: images,
                        useWebSearch: useWebSearch,
                        apiKey: apiKey,
                        model: config.fallback,
                        routingMode: config.openRouterRoutingMode,
                        trace: trace
                    )
                } catch {
                    let fallbackError = visibleError(from: error)
                    self.error = fallbackError as? ScanError
                    throw GeminiCallFailure(underlying: fallbackError, trace: trace)
                }
            }
            self.error = visible as? ScanError
            throw GeminiCallFailure(underlying: visible, trace: trace)
        }
    }

    private func callOpenRouterTextModel(
        prompt: String,
        images: [PreparedGeminiImage],
        useWebSearch: Bool,
        apiKey: String,
        model: String,
        routingMode: OpenRouterRoutingMode,
        trace: GeminiCallTrace
    ) async throws -> String {
        let redactedEndpoint = Self.openRouterChatCompletionsURL
        let attemptStart = ContinuousClock.now
        var attempt = GeminiModelAttemptLog(model: model, endpoint: redactedEndpoint)
        attempt.searchGroundingUsed = useWebSearch

        func fail(_ error: Error, stage: String? = nil) throws -> Never {
            let visible = visibleError(from: error)
            attempt.durationMs = msFrom(ContinuousClock.now.duration(to: attemptStart))
            attempt.errorCode = errorCode(from: visible)
            attempt.errorMessage = errorMessage(from: visible)
            if let stage {
                attempt.parseStage = stage
            }
            trace.absorb(attempt)
            self.error = visible as? ScanError
            throw GeminiCallFailure(underlying: visible, trace: trace)
        }

        guard let url = URL(string: Self.openRouterChatCompletionsURL) else {
            try fail(ScanError.invalidResponse, stage: "build_url")
        }

        let openRouterRequest = OpenRouterChatRequest(
            model: model,
            messages: [.user(text: prompt, images: images)],
            stream: true,
            temperature: 0,
            responseFormat: .jsonObject,
            provider: OpenRouterProviderPreferences.from(routingMode),
            plugins: useWebSearch ? [.web] : nil
        )

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("https://github.com/kvn8888/OpenFoodJournal", forHTTPHeaderField: "HTTP-Referer")
        httpRequest.setValue("OpenFoodJournal", forHTTPHeaderField: "X-Title")
        httpRequest.httpBody = try JSONEncoder().encode(openRouterRequest)
        trace.requestPayloadBytes = httpRequest.httpBody?.count

        #if DEBUG
        print("🧠 OpenRouter stream start model=\(model) route=\(routingMode.rawValue) payloadBytes=\(trace.requestPayloadBytes ?? 0)")
        #endif

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: httpRequest)
        } catch {
            try fail(ScanError.networkError(error), stage: "network")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            try fail(ScanError.invalidResponse, stage: "http_response")
        }
        attempt.httpStatus = httpResponse.statusCode
        #if DEBUG
        print("🧠 OpenRouter stream HTTP \(httpResponse.statusCode) model=\(model) +\(msFrom(attemptStart.duration(to: ContinuousClock.now)))ms")
        #endif

        guard (200..<300).contains(httpResponse.statusCode) else {
            let data = try await collectData(from: bytes)
            attempt.rawErrorBody = String(data: data, encoding: .utf8)
            let apiResponse = try? JSONDecoder().decode(OpenRouterErrorEnvelope.self, from: data)
            let message = apiResponse?.error?.message ?? "HTTP \(httpResponse.statusCode)"
            #if DEBUG
            if let rawErrorBody = attempt.rawErrorBody {
                print("🧠 OpenRouter HTTP error \(httpResponse.statusCode) model=\(model): \(rawErrorBody)")
            }
            #endif
            try fail(ScanError.serverError(httpResponse.statusCode, message), stage: "http_error")
        }

        var jsonText = ""
        var currentEventName: String?
        var rawEventPayloads: [String] = []

        do {
            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty {
                    currentEventName = nil
                    continue
                }
                if line.hasPrefix(":") {
                    continue
                }
                if line.hasPrefix("event:") {
                    currentEventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                guard line.hasPrefix("data:") else { continue }

                let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" {
                    #if DEBUG
                    print("🧠 OpenRouter stream done model=\(model) +\(msFrom(attemptStart.duration(to: ContinuousClock.now)))ms")
                    #endif
                    break
                }

                rawEventPayloads.append(payload)
                try consumeOpenRouterStreamPayload(
                    payload,
                    eventName: currentEventName,
                    elapsedMs: msFrom(attemptStart.duration(to: ContinuousClock.now)),
                    jsonText: &jsonText,
                    attempt: &attempt
                )
                currentEventName = nil
            }
        } catch let scanError as ScanError {
            attempt.rawResponseJSON = encodedJSONString(rawEventPayloads)
            attempt.responseText = jsonText
            attempt.responseTextCharacters = jsonText.count
            try fail(scanError, stage: attempt.parseStage ?? "stream")
        } catch {
            attempt.rawResponseJSON = encodedJSONString(rawEventPayloads)
            attempt.responseText = jsonText
            attempt.responseTextCharacters = jsonText.count
            try fail(ScanError.decodingError(error), stage: attempt.parseStage ?? "stream_decode")
        }

        attempt.rawResponseJSON = encodedJSONString(rawEventPayloads)
        attempt.responseText = jsonText
        attempt.responseTextCharacters = jsonText.count

        let extractedText = extractJSONObjectText(from: jsonText)
        guard !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try fail(ScanError.invalidResponse, stage: "empty_response_text")
        }

        attempt.responseText = extractedText
        attempt.responseTextCharacters = extractedText.count
        attempt.succeeded = true
        attempt.parseStage = "complete"
        attempt.durationMs = msFrom(ContinuousClock.now.duration(to: attemptStart))
        if useWebSearch {
            appendUnique("OpenRouter web plugin", to: &attempt.groundingSourceTitles)
        }
        #if DEBUG
        print("🧠 OpenRouter stream complete model=\(model) duration=\(attempt.durationMs ?? 0)ms events=\(attempt.streamEventCount) textDeltas=\(attempt.nonThoughtPartCount) jsonChars=\(extractedText.count)")
        #endif
        trace.absorb(attempt)
        return extractedText
    }

    private func consumeOpenRouterStreamPayload(
        _ payload: String,
        eventName: String?,
        elapsedMs: Int,
        jsonText: inout String,
        attempt: inout GeminiModelAttemptLog
    ) throws {
        guard let data = payload.data(using: .utf8) else { return }
        attempt.parseStage = eventName ?? "openrouter_stream_event"
        let chunk = try JSONDecoder().decode(OpenRouterStreamChunk.self, from: data)
        attempt.streamEventCount += 1

        if let model = chunk.model, model != attempt.model {
            attempt.modelVersion = model
            modelCatalog?.observeResolvedModel(
                provider: .openRouter,
                requestedModelID: attempt.model,
                resolvedModelID: model
            )
        }
        if let usage = chunk.usage {
            applyOpenRouterUsageMetadata(usage, to: &attempt)
        }
        if let apiError = chunk.error {
            throw ScanError.serverError(apiError.code ?? 500, apiError.message ?? "Unknown OpenRouter error")
        }

        for choice in chunk.choices ?? [] {
            let delta = choice.delta ?? choice.message
            if let content = delta?.content, !content.isEmpty {
                attempt.nonThoughtPartCount += 1
                attempt.firstTextDeltaMs = attempt.firstTextDeltaMs ?? elapsedMs
                attempt.lastTextDeltaMs = elapsedMs
                jsonText += content
            }
            if delta?.reasoning?.isEmpty == false {
                attempt.thoughtPartCount += 1
                attempt.firstThoughtSummaryMs = attempt.firstThoughtSummaryMs ?? elapsedMs
                attempt.lastThoughtSummaryMs = elapsedMs
            }
            for annotation in delta?.annotations ?? [] {
                if let url = annotation.urlCitation?.url, !url.isEmpty {
                    appendUnique(url, to: &attempt.groundingSourceURLs)
                }
                if let title = annotation.urlCitation?.title, !title.isEmpty {
                    appendUnique(title, to: &attempt.groundingSourceTitles)
                }
            }
        }
    }

    private func consumeGeminiInteractionStreamEvent(
        _ payload: String,
        eventName: String?,
        attemptStartedAt: ContinuousClock.Instant,
        jsonText: inout String,
        attempt: inout GeminiModelAttemptLog
    ) async throws {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let previousThinkingUpdateCount = thinkingTraceUpdateCount
        attempt.parseStage = "stream_event_decode"
        let eventFragments = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "[DONE]" }

        for fragment in eventFragments {
            guard let data = fragment.data(using: .utf8) else { continue }
            let event = try JSONDecoder().decode(GeminiInteractionSSEEvent.self, from: data)
            try consumeGeminiInteractionEvent(
                event,
                eventName: event.eventType ?? eventName,
                elapsedMs: msFrom(attemptStartedAt.duration(to: ContinuousClock.now)),
                jsonText: &jsonText,
                attempt: &attempt
            )
        }

        await yieldForThinkingTraceRenderIfNeeded(previousUpdateCount: previousThinkingUpdateCount)
    }

    private func consumeGeminiInteractionEvent(
        _ event: GeminiInteractionSSEEvent,
        eventName: String?,
        elapsedMs: Int,
        jsonText: inout String,
        attempt: inout GeminiModelAttemptLog
    ) throws {
        attempt.streamEventCount += 1

        if let model = event.interaction?.model, model != attempt.model {
            attempt.modelVersion = model
            modelCatalog?.observeResolvedModel(
                provider: .gemini,
                requestedModelID: attempt.model,
                resolvedModelID: model
            )
        }

        applyInteractionUsageMetadata(event.usage, to: &attempt)
        applyInteractionUsageMetadata(event.interaction?.usage, to: &attempt)
        applyInteractionUsageMetadata(event.metadata?.totalUsage, to: &attempt)

        if let apiError = event.error {
            attempt.parseStage = "interaction_stream_error"
            throw ScanError.serverError(apiError.code ?? 500, apiError.message ?? "Unknown Gemini error")
        }

        if let stepType = event.step?.type, stepType.contains("google_search") {
            attempt.searchGroundingUsed = true
            appendUnique("Google Search grounding", to: &attempt.groundingSourceTitles)
        }

        attempt.parseStage = eventName ?? "interaction_event"
        #if DEBUG
        if eventName != "step.delta" {
            let stepType = event.step?.type ?? "none"
            let usageTokens = event.usage?.totalTokens
                ?? event.interaction?.usage?.totalTokens
                ?? event.metadata?.totalUsage?.totalTokens
            print("🧠 Gemini stream event=\(eventName ?? "unknown") step=\(stepType) +\(elapsedMs)ms usageTotal=\(usageTokens.map(String.init) ?? "nil")")
        }
        #endif
        guard eventName == "step.delta", let delta = event.delta else { return }

        switch delta.type {
        case "thought_summary":
            if let text = delta.content?.text, !text.isEmpty {
                attempt.thoughtPartCount += 1
                attempt.firstThoughtSummaryMs = attempt.firstThoughtSummaryMs ?? elapsedMs
                attempt.lastThoughtSummaryMs = elapsedMs
                recordThinkingTrace(text)
                #if DEBUG
                print("🧠 Gemini stream thought_summary #\(attempt.thoughtPartCount) +\(elapsedMs)ms chars=\(text.count)")
                #endif
            }
        case "text":
            if let text = delta.text, !text.isEmpty {
                attempt.nonThoughtPartCount += 1
                attempt.firstTextDeltaMs = attempt.firstTextDeltaMs ?? elapsedMs
                attempt.lastTextDeltaMs = elapsedMs
                jsonText += text
                #if DEBUG
                print("🧠 Gemini stream text_delta #\(attempt.nonThoughtPartCount) +\(elapsedMs)ms chars=\(text.count) totalJSONChars=\(jsonText.count)")
                #endif
            }
        case "thought_signature":
            #if DEBUG
            print("🧠 Gemini stream thought_signature +\(elapsedMs)ms")
            #endif
            break
        default:
            #if DEBUG
            print("🧠 Gemini stream delta=\(delta.type ?? "unknown") event=\(eventName ?? "unknown") +\(elapsedMs)ms")
            #endif
            break
        }
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        guard !value.isEmpty, !values.contains(value) else { return }
        values.append(value)
    }

    private func applyInteractionUsageMetadata(
        _ usage: GeminiInteractionUsage?,
        to attempt: inout GeminiModelAttemptLog
    ) {
        guard let usage else { return }

        let inputTokens = usage.totalInputTokens ?? 0
        let thinkingTokens = usage.totalThoughtTokens ?? 0
        let responseTokens = usage.totalOutputTokens ?? 0
        let totalTokens = usage.totalTokens ?? inputTokens + responseTokens + thinkingTokens + (usage.totalToolUseTokens ?? 0)
        let outputTokens = max(responseTokens + thinkingTokens, totalTokens - inputTokens)
        let modelIdentifier = attempt.modelVersion ?? attempt.model
        let estimate = estimateGeminiTokenCost(
            modelIdentifier: modelIdentifier,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )

        attempt.inputTokenCount = inputTokens
        attempt.outputTokenCount = outputTokens
        attempt.thinkingTokenCount = thinkingTokens
        attempt.totalTokenCount = totalTokens
        attempt.estimatedCostUSD = estimate.estimatedCostUSD
        attempt.pricingModel = estimate.pricingModel
        attempt.inputRatePerMillionTokens = estimate.inputRatePerMillionTokens
        attempt.outputRatePerMillionTokens = estimate.outputRatePerMillionTokens

        let searchCount = usage.groundingToolCount?
            .filter { $0.type == "google_search" }
            .compactMap(\.count)
            .reduce(0, +) ?? 0
        if searchCount > 0 {
            attempt.searchGroundingUsed = true
            appendUnique("Google Search grounding (\(searchCount) call\(searchCount == 1 ? "" : "s"))", to: &attempt.groundingSourceTitles)
            attempt.groundingMetadataJSON = encodedJSONString(usage.groundingToolCount)
        }
    }

    private func applyOpenRouterUsageMetadata(
        _ usage: OpenRouterUsage,
        to attempt: inout GeminiModelAttemptLog
    ) {
        let inputTokens = usage.promptTokens ?? 0
        let thinkingTokens = usage.reasoningTokens ?? 0
        let completionTokens = usage.completionTokens ?? 0
        let totalTokens = usage.totalTokens ?? inputTokens + completionTokens + thinkingTokens
        let outputTokens = max(completionTokens, totalTokens - inputTokens)
        let modelIdentifier = attempt.modelVersion ?? attempt.model
        let estimate = estimateOpenRouterTokenCost(
            modelIdentifier: modelIdentifier,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )

        attempt.inputTokenCount = inputTokens
        attempt.outputTokenCount = outputTokens
        attempt.thinkingTokenCount = thinkingTokens
        attempt.totalTokenCount = totalTokens
        attempt.estimatedCostUSD = estimate.estimatedCostUSD
        attempt.pricingModel = estimate.pricingModel
        attempt.inputRatePerMillionTokens = estimate.inputRatePerMillionTokens
        attempt.outputRatePerMillionTokens = estimate.outputRatePerMillionTokens
    }

    private struct FoodIconImagePricingResult {
        let reportedInputTokens: Int
        let reportedOutputTokens: Int
        let reportedTotalTokens: Int
        let billableImageOutputTokens: Int
        let estimatedImageOutputCostUSD: Double
        let estimatedTotalCostUSD: Double
        let pricingModel: String
    }

    #if DEBUG
    private static func debugFoodIconImageCostSummary(
        _ pricing: FoodIconImagePricingResult,
        attempt: GeminiModelAttemptLog
    ) -> String {
        let cost = String(
            format: "$%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            pricing.estimatedTotalCostUSD
        )
        let outputTokenText = pricing.reportedOutputTokens > 0
            ? "outputTokens=\(pricing.reportedOutputTokens)"
            : "outputTokens=\(pricing.billableImageOutputTokens) fallbackOutputTokens=true"

        return "estimatedCost=\(cost) inputTokens=\(pricing.reportedInputTokens) \(outputTokenText) thinkingTokens=\(attempt.thinkingTokenCount) totalTokens=\(attempt.totalTokenCount)"
    }
    #endif

    private func applyFoodIconImagePricing(
        from responseData: Data,
        to attempt: inout GeminiModelAttemptLog
    ) -> FoodIconImagePricingResult {
        let usage = extractInteractionUsage(from: responseData)
        let inputTokens = usage?.totalInputTokens ?? 0
        let thinkingTokens = usage?.totalThoughtTokens ?? 0
        let reportedOutputTokens = usage?.totalOutputTokens ?? 0
        let reportedTotalTokens = usage?.totalTokens ?? inputTokens + reportedOutputTokens + thinkingTokens
        let billableImageOutputTokens = reportedOutputTokens > 0 ? reportedOutputTokens : Self.foodIconImageFallbackOutputTokens1K
        let inputCost = Double(inputTokens) / 1_000_000 * Self.foodIconImageInputRatePerMillionTokens
        let thinkingCost = Double(thinkingTokens) / 1_000_000 * Self.foodIconImageTextOutputRatePerMillionTokens
        let imageOutputCost = Double(billableImageOutputTokens) / 1_000_000 * Self.foodIconImageOutputRatePerMillionTokens
        let totalCost = inputCost + thinkingCost + imageOutputCost

        attempt.inputTokenCount = inputTokens
        attempt.outputTokenCount = billableImageOutputTokens
        attempt.thinkingTokenCount = thinkingTokens
        attempt.totalTokenCount = reportedTotalTokens > 0 ? reportedTotalTokens : inputTokens + billableImageOutputTokens + thinkingTokens
        attempt.estimatedCostUSD = totalCost
        attempt.pricingModel = Self.foodIconImagePricingModel
        attempt.inputRatePerMillionTokens = Self.foodIconImageInputRatePerMillionTokens
        attempt.outputRatePerMillionTokens = Self.foodIconImageOutputRatePerMillionTokens

        return FoodIconImagePricingResult(
            reportedInputTokens: inputTokens,
            reportedOutputTokens: reportedOutputTokens,
            reportedTotalTokens: reportedTotalTokens,
            billableImageOutputTokens: billableImageOutputTokens,
            estimatedImageOutputCostUSD: imageOutputCost,
            estimatedTotalCostUSD: totalCost,
            pricingModel: Self.foodIconImagePricingModel
        )
    }

    private func extractInteractionUsage(from responseData: Data) -> GeminiInteractionUsage? {
        guard let envelope = try? JSONDecoder().decode(GeminiInteractionResponseEnvelope.self, from: responseData) else {
            return nil
        }

        return envelope.usage
            ?? envelope.interaction?.usage
            ?? envelope.metadata?.totalUsage
    }

    private func retryableFallbackStatusCode(_ error: Error) -> Int? {
        guard let scanError = error as? ScanError else { return nil }
        if case .serverError(let code, _) = scanError {
            return code == 500 || code == 503 ? code : nil
        }
        return nil
    }

    private func estimateGeminiTokenCost(
        modelIdentifier: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> GeminiPricingEstimate {
        if let pricing = modelCatalog?.pricing(
            provider: .gemini,
            modelID: modelIdentifier
        ) {
            return pricingEstimate(
                pricing,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
        }
        let normalized = modelIdentifier.lowercased()
        let inputRate: Double
        let outputRate: Double
        let pricingModel: String

        if normalized.contains("3.1-pro") || normalized.contains("pro") {
            if inputTokens > 200_000 {
                inputRate = 4.00
                outputRate = 18.00
                pricingModel = "Gemini 3.1 Pro Preview Standard >200k"
            } else {
                inputRate = 2.00
                outputRate = 12.00
                pricingModel = "Gemini 3.1 Pro Preview Standard <=200k"
            }
        } else if normalized.contains("flash-lite") {
            inputRate = 0.25
            outputRate = 1.50
            pricingModel = "Gemini 3.1 Flash-Lite Standard"
        } else if normalized.contains("flash") {
            inputRate = 1.50
            outputRate = 9.00
            pricingModel = "Gemini 3.5 Flash Standard"
        } else {
            inputRate = 1.50
            outputRate = 9.00
            pricingModel = "Gemini Flash Standard fallback"
        }

        let inputCost = Double(inputTokens) / 1_000_000 * inputRate
        let outputCost = Double(outputTokens) / 1_000_000 * outputRate
        return GeminiPricingEstimate(
            pricingModel: pricingModel,
            inputRatePerMillionTokens: inputRate,
            outputRatePerMillionTokens: outputRate,
            estimatedCostUSD: inputCost + outputCost
        )
    }

    private func estimateOpenRouterTokenCost(
        modelIdentifier: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> GeminiPricingEstimate {
        if let pricing = modelCatalog?.pricing(
            provider: .openRouter,
            modelID: modelIdentifier
        ) {
            return pricingEstimate(
                pricing,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
        }
        let normalized = modelIdentifier.lowercased()
        guard normalized.contains("gemini") || normalized.contains("google/") else {
            return GeminiPricingEstimate(
                pricingModel: "OpenRouter model cost not estimated locally",
                inputRatePerMillionTokens: 0,
                outputRatePerMillionTokens: 0,
                estimatedCostUSD: 0
            )
        }

        var geminiEstimate = estimateGeminiTokenCost(
            modelIdentifier: modelIdentifier,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
        geminiEstimate = GeminiPricingEstimate(
            pricingModel: "OpenRouter routed \(geminiEstimate.pricingModel)",
            inputRatePerMillionTokens: geminiEstimate.inputRatePerMillionTokens,
            outputRatePerMillionTokens: geminiEstimate.outputRatePerMillionTokens,
            estimatedCostUSD: geminiEstimate.estimatedCostUSD
        )
        return geminiEstimate
    }

    private func pricingEstimate(
        _ pricing: ChatModelPricing,
        inputTokens: Int,
        outputTokens: Int
    ) -> GeminiPricingEstimate {
        let isLongContext = pricing.longContextThreshold
            .map { inputTokens > $0 } ?? false
        let inputRate = pricing.inputPerMillionUSD
            * (isLongContext ? pricing.longContextInputMultiplier : 1)
        let outputRate = pricing.outputPerMillionUSD
            * (isLongContext ? pricing.longContextOutputMultiplier : 1)
        return GeminiPricingEstimate(
            pricingModel: pricing.source,
            inputRatePerMillionTokens: inputRate,
            outputRatePerMillionTokens: outputRate,
            estimatedCostUSD: pricing.estimatedCost(for: ChatTokenUsage(
                input: inputTokens,
                output: outputTokens
            ))
        )
    }

    private func extractJSONObjectText(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            let body = lines
                .dropFirst()
                .dropLast(lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true ? 1 : 0)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("{"), body.hasSuffix("}") {
                return body
            }
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end
        else {
            return trimmed
        }

        return String(trimmed[start...end])
    }

    private func validateAISearchResponse(
        _ response: GeminiNutritionResponse,
        query: String,
        trace: GeminiCallTrace
    ) -> AISearchValidationResult {
        let micros = normalizedMicronutrients(response.micronutrients ?? [:])
        var reasons: [String] = []
        var retryNutrientIDs = Set<String>()
        let hasRealNutrition = response.calories > 20 && (response.protein + response.carbs + response.fat) > 0
        let labelLikely = hasRealNutrition && isLikelyBrandedOrRestaurantResult(response: response, query: query)

        if trace.searchGroundingRequested && !trace.searchGroundingUsed {
            reasons.append("no grounding metadata returned")
            retryNutrientIDs.formUnion(Self.aiSearchCoreLabelNutrientIDs)
        }

        if labelLikely && !hasPositiveMicronutrient("sodium", in: micros) {
            reasons.append("branded/restaurant-like result has missing or zero sodium")
            retryNutrientIDs.insert("sodium")
        }

        if labelLikely && response.carbs > 0 && !hasPositiveMicronutrient("fiber", in: micros) {
            reasons.append("branded/restaurant-like result has missing or zero fiber")
            retryNutrientIDs.insert("fiber")
        }

        if labelLikely && response.carbs > 0 && !hasPositiveSugar(in: micros) {
            reasons.append("branded/restaurant-like result has missing or zero sugar")
            retryNutrientIDs.formUnion(["sugar", "added_sugars"])
        }

        let criticalValues = Self.aiSearchCriticalMicronutrientIDs.compactMap { micros[$0]?.value }
        if hasRealNutrition && !criticalValues.isEmpty && criticalValues.allSatisfy({ $0 <= 0 }) {
            reasons.append("all critical micronutrients are zero")
            retryNutrientIDs.formUnion(Self.aiSearchCriticalMicronutrientIDs)
        }

        return AISearchValidationResult(
            reasons: reasons,
            retryNutrientIDs: Array(retryNutrientIDs).sorted()
        )
    }

    private func mergeAISearchRetry(
        firstPass: GeminiNutritionResponse,
        retry: GeminiNutritionResponse,
        validation: AISearchValidationResult,
        retryTrace: GeminiCallTrace
    ) -> (response: GeminiNutritionResponse, mergedNutrientIDs: [String]) {
        guard retryTrace.searchGroundingUsed else {
            return (firstPass, [])
        }

        var mergedMicros = normalizedMicronutrients(firstPass.micronutrients ?? [:])
        let retryMicros = normalizedMicronutrients(retry.micronutrients ?? [:])
        var mergedIDs: [String] = []

        for nutrientID in validation.retryNutrientIDs {
            guard let retryValue = retryMicros[nutrientID], retryValue.value > 0 else { continue }
            if (mergedMicros[nutrientID]?.value ?? 0) <= 0 {
                mergedMicros[nutrientID] = retryValue
                mergedIDs.append(nutrientID)
            }
        }

        guard !mergedIDs.isEmpty else {
            return (firstPass, [])
        }

        return (
            GeminiNutritionResponse(
                name: firstPass.name,
                brand: firstPass.brand,
                confidence: firstPass.confidence,
                servingSize: firstPass.servingSize,
                servingQuantity: firstPass.servingQuantity,
                servingUnit: firstPass.servingUnit,
                servingWeightGrams: firstPass.servingWeightGrams,
                servingsPerContainer: firstPass.servingsPerContainer,
                servingType: firstPass.servingType,
                servingGrams: firstPass.servingGrams,
                servingMl: firstPass.servingMl,
                calories: firstPass.calories,
                protein: firstPass.protein,
                carbs: firstPass.carbs,
                fat: firstPass.fat,
                micronutrients: mergedMicros,
                scanMode: firstPass.scanMode
            ),
            mergedIDs
        )
    }

    private func normalizedMicronutrients(
        _ micronutrients: [String: MicronutrientValue]
    ) -> [String: MicronutrientValue] {
        var normalized: [String: MicronutrientValue] = [:]
        for (key, value) in micronutrients {
            normalized[normalizedMicronutrientID(key)] = value
        }
        return normalized
    }

    private func normalizedMicronutrientID(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased().replacingOccurrences(of: " ", with: "_")
        switch lower {
        case "total_sugar", "total_sugars", "sugars":
            return "sugar"
        default:
            return KnownMicronutrients.normalize(trimmed)
        }
    }

    private func hasPositiveMicronutrient(
        _ id: String,
        in micronutrients: [String: MicronutrientValue]
    ) -> Bool {
        (micronutrients[id]?.value ?? 0) > 0
    }

    private func hasPositiveSugar(in micronutrients: [String: MicronutrientValue]) -> Bool {
        hasPositiveMicronutrient("sugar", in: micronutrients)
            || hasPositiveMicronutrient("added_sugars", in: micronutrients)
    }

    private func isLikelyBrandedOrRestaurantResult(
        response: GeminiNutritionResponse,
        query: String
    ) -> Bool {
        if response.brand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }

        let text = "\(query) \(response.name) \(response.servingSize ?? "")".lowercased()
        return Self.aiSearchBrandedRestaurantSignals.contains { text.contains($0) }
    }

    private func recordThinkingTrace(_ text: String) {
        let cleaned = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !cleaned.isEmpty else { return }

        let maxCharacters = 260
        let clipped = cleaned.count > maxCharacters
            ? String(cleaned.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
            : cleaned

        if thinkingTrace.last == clipped { return }

        var updatedTrace = thinkingTrace
        updatedTrace.append(clipped)
        if updatedTrace.count > 4 {
            updatedTrace.removeFirst(updatedTrace.count - 4)
        }
        thinkingTrace = updatedTrace
        thinkingTraceUpdateCount += 1
        scanProgressMessage = thinkingProgressMessage(updateCount: thinkingTraceUpdateCount)
    }

    private func yieldForThinkingTraceRenderIfNeeded(previousUpdateCount: Int) async {
        guard thinkingTraceUpdateCount > previousUpdateCount else { return }

        // URLSession can hand us several already-buffered SSE events in one
        // MainActor turn. Yield once so real early thought summaries can render
        // while the stream continues, without delaying the final result screen.
        await Task.yield()
    }

    private func prepareAIWait(for config: AIRequestConfig) {
        expectsThinkingTrace = config.expectsThinkingTrace
        if expectsThinkingTrace {
            scanProgressMessage = thinkingProgressMessage(updateCount: thinkingTraceUpdateCount)
        } else {
            scanProgressMessage = "Waiting for \(config.provider.displayName)..."
        }
    }

    private func thinkingProgressMessage(updateCount: Int) -> String {
        guard updateCount > 0 else { return "Gemini is thinking..." }
        let suffix = updateCount == 1 ? "summary" : "summaries"
        return "Gemini is thinking... \(updateCount) thought \(suffix)"
    }

    private func collectData(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private func recordGeminiScanLog(
        operation: GeminiScanLogOperation,
        status: GeminiScanLogStatus,
        scanMode: ScanMode? = nil,
        primaryModel: String? = nil,
        fallbackModel: String? = nil,
        resolvedModel: String? = nil,
        usedFallback: Bool = false,
        photoCount: Int = 0,
        userPrompt: String? = nil,
        durationMs: Int? = nil,
        debugTrace: GeminiCallTrace? = nil,
        response: GeminiNutritionResponse? = nil,
        error: Error? = nil,
        persistImmediately: Bool = true
    ) {
        let cleanedPrompt = userPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let log = GeminiScanLog(
            operation: operation,
            status: status,
            provider: loggedAIProvider(from: debugTrace),
            scanMode: scanMode?.rawValue,
            primaryModel: primaryModel,
            fallbackModel: fallbackModel,
            resolvedModel: debugTrace?.resolvedModel ?? resolvedModel,
            resolvedModelVersion: debugTrace?.resolvedModelVersion,
            usedFallback: debugTrace?.usedFallback ?? usedFallback,
            photoCount: photoCount,
            durationMs: durationMs,
            userPrompt: cleanedPrompt,
            requestPrompt: debugTrace?.requestPrompt,
            requestPromptCharacterCount: debugTrace?.requestPromptCharacterCount ?? 0,
            requestMetadataJSON: debugTrace?.requestMetadataJSON,
            requestImageMetadataJSON: debugTrace?.imageMetadataJSON,
            requestPayloadBytes: debugTrace?.requestPayloadBytes,
            responseHTTPStatus: debugTrace?.responseHTTPStatus,
            parseStage: debugTrace?.parseStage,
            responseText: debugTrace?.responseText,
            responseTextCharacterCount: debugTrace?.responseTextCharacterCount ?? 0,
            rawResponseJSON: debugTrace?.rawResponseJSON,
            modelAttemptsJSON: debugTrace.flatMap { encodedJSONString($0.attempts) },
            inputTokenCount: debugTrace?.inputTokenCount ?? 0,
            outputTokenCount: debugTrace?.outputTokenCount ?? 0,
            thinkingTokenCount: debugTrace?.thinkingTokenCount ?? 0,
            totalTokenCount: debugTrace?.totalTokenCount ?? 0,
            estimatedTokenCostUSD: debugTrace?.estimatedCostUSD ?? 0,
            pricingModel: debugTrace?.pricingModel,
            searchGroundingRequested: debugTrace?.searchGroundingRequested ?? false,
            searchGroundingUsed: debugTrace?.searchGroundingUsed ?? false,
            webSearchQueries: debugTrace?.webSearchQueries ?? [],
            groundingSourceURLs: debugTrace?.groundingSourceURLs ?? [],
            groundingSourceTitles: debugTrace?.groundingSourceTitles ?? [],
            groundingMetadataJSON: debugTrace?.groundingMetadataJSON,
            streamEventCount: debugTrace?.streamEventCount ?? 0,
            thoughtPartCount: debugTrace?.thoughtPartCount ?? 0,
            nonThoughtPartCount: debugTrace?.nonThoughtPartCount ?? 0,
            resultName: response?.name,
            calories: response?.calories,
            protein: response?.protein,
            carbs: response?.carbs,
            fat: response?.fat,
            errorCode: errorCode(from: error),
            errorMessage: errorMessage(from: error),
            responseJSON: response.flatMap(encodedResponseJSON),
            thinkingTrace: thinkingTrace,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            osVersion: UIDevice.current.systemVersion
        )

        diagnosticSink?.recordDiagnostic(AIDiagnosticEvent(scanLog: log))

        if let modelContext {
            recordGeminiCost(debugTrace, status: status, in: modelContext)
            guard persistImmediately else { return }
            do {
                try modelContext.save()
                // Usage aggregates remain part of the optional data mirror.
                tursoMirror?.scheduleMirror(reason: "ai_usage_saved")
            } catch {
                // Usage accounting is best-effort and must never break scanning.
            }
        }
    }

    /// Request metadata is already sanitized before persistence. Reading the
    /// provider from that payload keeps direct-Gemini image work accurate even
    /// when the user's general scan provider is OpenRouter.
    private func loggedAIProvider(from trace: GeminiCallTrace?) -> String? {
        guard
            let json = trace?.requestMetadataJSON,
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let provider = object["aiProvider"] as? String,
            !provider.isEmpty
        else {
            return selectedAIProvider.rawValue
        }
        return provider
    }

    private func recordGeminiCost(
        _ debugTrace: GeminiCallTrace?,
        status: GeminiScanLogStatus,
        in modelContext: ModelContext
    ) {
        guard let debugTrace else { return }
        let accumulator = GeminiCostAccumulator.current(in: modelContext)
        accumulator.add(
            estimatedCostUSD: debugTrace.estimatedCostUSD,
            inputTokens: debugTrace.inputTokenCount,
            outputTokens: debugTrace.outputTokenCount,
            thinkingTokens: debugTrace.thinkingTokenCount,
            model: debugTrace.resolvedModelVersion ?? debugTrace.resolvedModel,
            pricingModel: debugTrace.pricingModel,
            usedSearchGrounding: debugTrace.searchGroundingUsed,
            succeeded: status == .success
        )
    }

    private func encodedResponseJSON(_ response: GeminiNutritionResponse) -> String? {
        encodedJSONString(response)
    }

    nonisolated private static func clippedForLog(_ text: String, maxCharacters: Int = 240) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func encodedJSONString<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func visibleError(from error: Error) -> Error {
        (error as? GeminiCallFailure)?.underlying ?? error
    }

    private func errorCode(from error: Error?) -> Int? {
        guard let scanError = error as? ScanError else { return nil }
        if case .serverError(let code, _) = scanError {
            return code
        }
        return nil
    }

    private func errorMessage(from error: Error?) -> String? {
        guard let error else { return nil }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Convert a ContinuousClock.Duration to milliseconds (always positive)
    private func msFrom(_ duration: ContinuousClock.Instant.Duration) -> Int {
        let attoseconds = duration.components.attoseconds
        let seconds = duration.components.seconds
        return abs(Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Character {
    nonisolated var isFoodBankEmojiCandidate: Bool {
        unicodeScalars.contains { scalar in
            scalar.value >= 0x1F000 && scalar.properties.isEmoji
        }
    }
}

// MARK: - Prompt Templates

/// These prompts are identical to what the server used — moved on-device for BYOK.
/// Both modes return the same JSON structure; the prompts differ in what they ask Gemini to do.
extension ScanService {
    private static let aiSearchCriticalMicronutrientIDs = [
        "sodium", "fiber", "sugar", "added_sugars", "cholesterol",
        "saturated_fat", "calcium", "iron", "potassium"
    ]

    private static let aiSearchCoreLabelNutrientIDs = [
        "sodium", "fiber", "sugar", "added_sugars", "cholesterol", "saturated_fat"
    ]

    private static let aiSearchBrandedRestaurantSignals = [
        "restaurant", "menu", "brand", "nutrition facts", "label",
        "bar", "cereal", "chips", "cracker", "cookie", "soda",
        "drink", "bottle", "can", "package", "frozen", "fast food",
        "mcdonald", "starbucks", "chipotle", "taco bell", "wendy",
        "burger king", "subway", "panera", "chick-fil-a", "domino",
        "pizza hut"
    ]

    static func foodEmojiPrompt(name: String, brand: String?, servingSize: String?) -> String {
        let trimmedBrand = brand
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(\.nilIfEmpty)
        let trimmedServingSize = servingSize
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(\.nilIfEmpty)
        let brandLine = trimmedBrand.map { "Brand: \($0)" } ?? "Brand: unknown"
        let servingLine = trimmedServingSize.map { "Serving: \($0)" } ?? "Serving: unknown"

        return """
        Choose one familiar emoji icon for this saved food in a food journal.

        Food: \(name)
        \(brandLine)
        \(servingLine)

        Return JSON only, with exactly this shape:
        {"emoji":"🍎"}

        Rules:
        - Return one emoji grapheme in the emoji field.
        - Prefer concrete food emojis over generic plates when possible.
        - Do not include words, markdown, explanations, multiple emojis, or skin-tone/person emojis.
        """
    }

    static func foodIconImagePrompt(name: String, brand: String?) -> String {
        let trimmedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "Saved food"
        let trimmedBrand = brand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let prompt = FoodIconImagePrompt(brand: trimmedBrand, item: trimmedName)
        return encodedPromptJSON(prompt) ?? #"{"item":"\#(trimmedName)"}"#
    }

    private static func encodedPromptJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }


    /// Prompt for label scan mode — OCR of nutrition facts panels.
    static let labelPrompt = """
    You are a nutrition label reader. Analyze the provided photo or photos of one product and extract ALL nutritional information from its nutrition label.

    Return a JSON object with this EXACT structure:
    {
      "name": "<product name if visible, otherwise 'Unknown Product'>",
      "brand": "<brand name if visible, otherwise null>",
      "confidence": <0.0-1.0 how confident you are in the reading>,
      "serving_size": "<serving size text, e.g. '1 cup (228g)'>",
      "serving_quantity": <numeric serving amount, e.g. 1.0>,
      "serving_unit": "<unit string, e.g. 'cup', 'g', 'piece', 'tbsp'>",
      "serving_weight_grams": <weight of one serving in grams if shown, otherwise null>,
      "servings_per_container": <number or null>,
      "serving_type": "<'mass' if only grams known, 'volume' if only volume known, 'both' if both grams and volume are shown, otherwise null>",
      "serving_grams": <gram weight of ONE serving as a number, or null if unknown>,
      "serving_ml": <volume of ONE serving in mL as a number, or null if not a liquid/volume serving>,
      "calories": <number>,
      "protein": <grams as number>,
      "carbs": <grams as number>,
      "fat": <grams as number>,
      "micronutrients": {
        "<nutrient_id>": {"value": <number>, "unit": "<g|mg|mcg|IU|%>"},
        ...include ALL nutrients visible on the label
      }
    }

    IMPORTANT — Use these canonical nutrient IDs as JSON keys:
    Vitamins: vitamin_a, vitamin_c, vitamin_d, vitamin_e, vitamin_k, thiamin, riboflavin, niacin, pantothenic_acid, vitamin_b6, biotin, folate, vitamin_b12
    Minerals: calcium, iron, magnesium, phosphorus, potassium, sodium, zinc, copper, manganese, selenium, chromium, molybdenum, iodine, chloride
    Other: fiber, added_sugars, cholesterol, saturated_fat, trans_fat

    If a nutrient not in this list appears on the label, use a lowercase_snake_case ID for it.

    Rules:
    - Treat every provided photo as a different view of the SAME product, not as separate products or servings
    - Combine evidence across photos: use the clearest view for each field and use packaging photos for product name and brand when available
    - If photos overlap or repeat the same label values, report each nutrient once
    - Extract EVERY nutrient shown on the label, not just the common ones
    - Use the exact values shown on the label
    - For brand: look for the brand/manufacturer name on the packaging
    - For serving_quantity and serving_unit: parse the serving size into number + unit (e.g. "2 cookies" → quantity: 2, unit: "cookies")
    - For serving_weight_grams: if the label shows weight in grams (e.g. "1 cup (228g)"), extract the gram value as a number
    - For serving_type: use "mass" if only grams are given, "volume" if only a volume unit is given (mL, cup, tbsp, etc.), "both" if the label shows both a weight and a volume for the same serving
    - For serving_grams: the gram weight of exactly ONE serving (NOT per container). Use serving_weight_grams if available.
    - For serving_ml: the mL volume of ONE serving. Convert if label shows other volume units (1 cup = 240 mL, 1 tbsp = 15 mL, 1 fl oz = 30 mL). Omit (null) for solid foods.
    - For "% Daily Value" only nutrients, convert to actual amounts if possible, otherwise use "%" as unit
    - Use the canonical nutrient IDs listed above as micronutrient keys
    - If a value is 0, still include it
    - confidence should reflect image clarity and how readable the label is
    """

    /// Prompt for food photo mode — AI-powered estimation from a photo of food.
    static let foodPhotoPrompt = """
    You are a nutrition estimation expert. Look at the provided photo or photos of one food portion and estimate its nutritional content.

    Return a JSON object with this EXACT structure:
    {
      "name": "<descriptive name of the food/meal>",
      "brand": "<brand name if recognizable, otherwise null>",
      "confidence": <0.0-1.0 how confident you are in the estimation>,
      "serving_size": "<estimated portion description>",
      "serving_quantity": <estimated numeric serving amount>,
      "serving_unit": "<unit string, e.g. 'piece', 'cup', 'bowl', 'plate'>",
      "serving_weight_grams": <estimated weight in grams>,
      "servings_per_container": 1,
      "serving_type": "<'mass' if weight is the primary measure, 'volume' if volume is the primary measure, 'both' if both apply>",
      "serving_grams": <estimated gram weight of the shown portion>,
      "serving_ml": <estimated volume in mL if relevant, e.g. for drinks, otherwise null>,
      "calories": <estimated number>,
      "protein": <estimated grams>,
      "carbs": <estimated grams>,
      "fat": <estimated grams>,
      "micronutrients": {
        "<nutrient_id>": {"value": <number>, "unit": "<g|mg|mcg|IU>"},
        ...include common nutrients you can reasonably estimate
      }
    }

    IMPORTANT — Use these canonical nutrient IDs as JSON keys:
    Vitamins: vitamin_a, vitamin_c, vitamin_d, vitamin_e, vitamin_k, thiamin, riboflavin, niacin, pantothenic_acid, vitamin_b6, biotin, folate, vitamin_b12
    Minerals: calcium, iron, magnesium, phosphorus, potassium, sodium, zinc, copper, manganese, selenium, chromium, molybdenum, iodine, chloride
    Other: fiber, added_sugars, cholesterol, saturated_fat, trans_fat

    If a nutrient not in this list is relevant, use a lowercase_snake_case ID for it.

    Rules:
    - Treat every provided photo as a different angle of the SAME food portion, not as separate servings
    - Combine visual evidence across photos to identify ingredients and estimate the portion more accurately
    - Do not add or double-count food just because it appears in more than one photo
    - Be realistic about portion sizes shown in the image
    - Estimate based on typical nutritional values for the identified food
    - For serving_weight_grams: estimate the total weight of the food portion in grams
    - For serving_type: use "mass" for solid foods, "volume" for drinks/liquids, "both" if both weight and volume are naturally described
    - For serving_grams: estimated gram weight of the single portion shown
    - For serving_ml: estimated mL for beverages/liquids (null for solid foods)
    - confidence should be lower than label scans since these are estimates
    - Include at least fiber, sodium, cholesterol, saturated_fat in micronutrients if estimable
    - Use the canonical nutrient IDs listed above as micronutrient keys
    """

    /// Prompt for Food Bank AI Search — text query + Google Search grounding.
    static let aiSearchPrompt = """
    You are a nutrition research assistant. Use Google Search to find reliable nutrition data for the user's requested food, product, restaurant item, or generic food.

    Return a JSON object with this EXACT structure:
    {
      "name": "<specific food/product/menu item name>",
      "brand": "<brand, restaurant, or manufacturer if known, otherwise null>",
      "confidence": <0.0-1.0 how confident you are in the searched nutrition data>,
      "serving_size": "<serving size text, e.g. '1 bar (52g)', '100 g', '1 cup (240ml)'>",
      "serving_quantity": <numeric serving amount, e.g. 1.0>,
      "serving_unit": "<unit string, e.g. 'bar', 'g', 'cup', 'serving'>",
      "serving_weight_grams": <weight of one serving in grams if known, otherwise null>,
      "servings_per_container": <number or null>,
      "serving_type": "<'mass' if weight is primary, 'volume' if volume is primary, 'both' if both apply, otherwise null>",
      "serving_grams": <gram weight of ONE serving as a number, or null if unknown>,
      "serving_ml": <volume of ONE serving in mL as a number, or null if not relevant>,
      "calories": <number>,
      "protein": <grams as number>,
      "carbs": <grams as number>,
      "fat": <grams as number>,
      "micronutrients": {
        "<nutrient_id>": {"value": <number>, "unit": "<g|mg|mcg|IU|%>"},
        ...include nutrients that are reported by reliable sources
      }
    }

    IMPORTANT — Use these canonical nutrient IDs as JSON keys:
    Vitamins: vitamin_a, vitamin_c, vitamin_d, vitamin_e, vitamin_k, thiamin, riboflavin, niacin, pantothenic_acid, vitamin_b6, biotin, folate, vitamin_b12
    Minerals: calcium, iron, magnesium, phosphorus, potassium, sodium, zinc, copper, manganese, selenium, chromium, molybdenum, iodine, chloride
    Other: fiber, added_sugars, cholesterol, saturated_fat, trans_fat

    If a nutrient not in this list appears in reliable nutrition data, use a lowercase_snake_case ID for it.

    Rules:
    - Prefer official product labels, manufacturer pages, restaurant nutrition PDFs, USDA FoodData Central, and Open Food Facts over blogs or generic summaries
    - If the user names a brand, restaurant, flavor, package size, or serving size, search for that exact item first
    - If exact nutrition is found, use the serving size and values reported by the source
    - If only per-100g data is found, set serving_size to "100 g", serving_quantity to 100, serving_unit to "g", and serving_grams to 100
    - If sources conflict, prefer official/manufacturer/USDA data and lower confidence
    - Do not invent exact micronutrients. Include micronutrients only when a source reports them or they are standard label fields
    - For "% Daily Value" only nutrients, convert to actual amounts if possible, otherwise use "%" as unit
    - Return only the JSON object. Do not include citations, markdown, comments, or prose outside the JSON
    """

    private static func aiSearchValidationRetryPrompt(
        query: String,
        firstPass: GeminiNutritionResponse,
        validation: AISearchValidationResult
    ) -> String {
        let brandText = firstPass.brand ?? "null"
        let servingText = firstPass.servingSize ?? "unknown serving"
        let nutrients = validation.retryNutrientIDs.joined(separator: ", ")
        let firstPassMicros = firstPass.micronutrients ?? [:]

        return """
        You are validating missing or suspicious nutrients for an existing AI Search nutrition result. Use Google Search grounding.

        Original user search: \(query)
        Existing result: \(firstPass.name)
        Brand/restaurant/manufacturer: \(brandText)
        Serving: \(servingText)
        Existing macros: \(firstPass.calories) calories, \(firstPass.protein)g protein, \(firstPass.carbs)g carbs, \(firstPass.fat)g fat
        Existing micronutrients JSON: \(encodedPromptJSON(firstPassMicros) ?? "{}")
        Suspicious signals: \(validation.reasonSummary)

        Find only these missing or suspicious nutrients for the exact same food and serving: \(nutrients).

        Return a JSON object with the same shape as the original AI Search response. Keep the existing name, brand, serving, calories, protein, carbs, and fat unless a source is needed only to make the JSON valid. In "micronutrients", include only source-reported values for the requested nutrient IDs. Do not regenerate the full nutrition profile. Do not include zero values unless the source explicitly reports 0. Omit nutrients you cannot verify from official product labels, manufacturer pages, restaurant nutrition PDFs, USDA FoodData Central, or Open Food Facts.

        Return only JSON. No markdown, comments, citations, or prose.
        """
    }

    /// Prompt for calculator OCR import — extracts one named ingredient only.
    static func calculatorIngredientPrompt(name: String) -> String {
        """
        You are importing ONE ingredient for a restaurant/brand nutrition calculator in a food journal.

        The user is importing the ingredient named: "\(name)".

        Read the provided image(s) of this item's nutrition information. Extract data for THIS ingredient only — ignore any other menu items visible in the image.

        Return a JSON object with this EXACT structure:
        {
          "name": "<the ingredient name as the source labels it>",
          "portions": [
            {
              "label": "<visible serving amount or source label for this nutrition value, e.g. '4 oz', '1 scoop', 'Single', 'Double', or 'Serving'>",
              "calories": <number>,
              "protein": <grams as number>,
              "carbs": <grams as number>,
              "fat": <grams as number>,
              "micronutrients": { "<nutrient_id>": {"value": <number>, "unit": "<g|mg|mcg|IU|%>"} }
            }
          ]
        }

        Rules:
        - If the source lists multiple serving sizes for this one item (e.g. 4 oz vs 8 oz, single vs double, regular vs large), return ONE portion object per size, using the visible source label only to distinguish the nutrition values.
        - If only one amount is shown, return a single portion using the visible serving label, or an empty label if none is visible.
        - Do not invent app portion names such as light, normal, or extra. The app will default missing portion labels to normal.
        - Do not invent extra sizes. Do not return other ingredients.
        - Use 0 for a macro only when the source explicitly shows 0; omit micronutrients you can't read.
        - Prefer canonical micronutrient IDs: fiber, added_sugars, sugar, sodium, cholesterol, saturated_fat, trans_fat, calcium, iron, potassium, vitamin_a, vitamin_c, vitamin_d.
        - Return only JSON. No markdown, comments, citations, or prose.
        """
    }
}

private extension GeminiNutritionResponse {
    func toNutritionEntry(mode: ScanMode) -> NutritionEntry {
        // Build serving mappings if Gemini returned both a unit and gram weight
        // e.g. serving_unit = "cup", serving_weight_grams = 228
        // → mapping: { 1 cup = 228 g }
        var mappings: [ServingMapping] = []
        if let qty = servingQuantity,
           let unit = servingUnit,
           let grams = servingWeightGrams,
           unit.lowercased() != "g" {
            mappings.append(ServingMapping(
                from: ServingAmount(value: qty, unit: unit),
                to: ServingAmount(value: grams, unit: "g")
            ))
        }

        // Build the typed ServingSize enum from the structured serving fields.
        // Falls back to a mass serving derived from serving_weight_grams if the
        // prompt-level fields are absent (e.g. from older server versions).
        let serving: ServingSize? = {
            let g = servingGrams ?? servingWeightGrams
            let ml = servingMl
            switch servingType {
            case "both":
                if let g, let ml { return .both(grams: g, ml: ml) }
                fallthrough
            case "mass":
                if let g { return .mass(grams: g) }
            case "volume":
                if let ml { return .volume(ml: ml) }
            default:
                // Legacy path: derive from weight only
                if let g { return .mass(grams: g) }
            }
            return nil
        }()

        // Normalize micronutrient keys: if Gemini returns a name we recognize
        // (e.g. "Vitamin A" or "vitamin_a"), map it to the canonical ID.
        // Unknown nutrients pass through as-is with their original key.
        var normalizedMicros: [String: MicronutrientValue] = [:]
        for (key, value) in (micronutrients ?? [:]) {
            if let known = KnownMicronutrients.find(key) {
                // Use canonical ID and ensure the unit matches our reference
                normalizedMicros[known.id] = MicronutrientValue(
                    value: value.value,
                    unit: value.unit == "%" ? known.unit : value.unit
                )
            } else {
                // Unknown nutrient from Gemini — keep as-is
                normalizedMicros[key] = value
            }
        }

        return NutritionEntry(
            name: name,
            mealType: .snack, // user selects meal type before confirming
            scanMode: mode,
            confidence: confidence,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            micronutrients: normalizedMicros,
            servingSize: servingSize,
            servingsPerContainer: servingsPerContainer,
            brand: brand,
            serving: serving,
            servingQuantity: servingQuantity,
            servingUnit: servingUnit,
            servingMappings: mappings
        )
    }
}

// MARK: - UIImage Resize for OCR

private extension UIImage {
    /// Resizes the image so its longest edge is at most `maxDimension` points.
    /// Returns self unchanged if already within bounds.
    /// Uses UIGraphicsImageRenderer for memory-efficient rendering.
    /// IMPORTANT: UIImage.size returns points, not pixels. On a 3x device a 4032×3024
    /// photo has size 1344×1008 pts — well under 2000, so the resize would be skipped.
    /// We must use the pixel dimensions (size × scale) for the comparison.
    func resizedForOCR(maxDimension: CGFloat) -> UIImage {
        // Convert to pixel dimensions (size is in points, scale gives the multiplier)
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxDimension else { return self }

        let ratio = maxDimension / longest
        let newSize = CGSize(
            width: (pixelWidth * ratio).rounded(),
            height: (pixelHeight * ratio).rounded()
        )

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
