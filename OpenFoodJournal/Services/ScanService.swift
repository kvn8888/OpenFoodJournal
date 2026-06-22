// OpenFoodJournal — Scan Service (Direct Gemini REST API — BYOK)
// Calls the Gemini API directly from the device using the user's own API key.
// No server proxy needed — eliminates Render dependency and cold starts.
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
    case serverError(Int, String)
    case decodingError(Error)
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed: "Failed to encode image for upload."
        case .noImages: "Add at least one photo before analyzing."
        case .tooManyImages(let maximum): "Choose up to \(maximum) photos for one scan."
        case .emptySearchQuery: "Enter a food or product to search for."
        case .networkError(let e): "Network error: \(e.localizedDescription)"
        case .invalidResponse: "Received an invalid response from the server."
        case .serverError(let code, let msg): "Server error \(code): \(msg)"
        case .decodingError(let e): "Failed to parse nutrition data: \(e.localizedDescription)"
        case .noAPIKey: "No Gemini API key configured. Add your key in Settings."
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

// MARK: - Gemini REST API Types

/// The top-level request body sent to Gemini's generateContent endpoint.
/// Contains an array of "contents" (each with "parts") and generation config.
private struct GeminiRequest: Codable {
    let contents: [GeminiContent]
    let tools: [GeminiTool]?
    let generationConfig: GeminiGenerationConfig

    init(
        contents: [GeminiContent],
        generationConfig: GeminiGenerationConfig,
        tools: [GeminiTool]? = nil
    ) {
        self.contents = contents
        self.tools = tools
        self.generationConfig = generationConfig
    }
}

/// A single content block in the Gemini request — represents one "turn" in the conversation.
/// For our use case, there's always exactly one content with role "user".
private struct GeminiContent: Codable {
    let role: String
    let parts: [GeminiPart]
}

/// A part within a content block — either text (the prompt) or inline image data.
/// Gemini accepts both in a single request for multimodal understanding.
private enum GeminiPart: Codable {
    case text(String)
    case inlineData(mimeType: String, data: String) // base64

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(["text": text])
        case .inlineData(let mimeType, let data):
            try container.encode([
                "inline_data": [
                    "mime_type": mimeType,
                    "data": data
                ]
            ])
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let dict = try container.decode([String: AnyCodableValue].self)
        if let text = dict["text"]?.stringValue {
            self = .text(text)
        } else {
            self = .text("")
        }
    }
}

/// Simple wrapper for decoding heterogeneous JSON values in GeminiPart.
/// Only used for the Codable conformance — we never decode incoming Parts.
private struct AnyCodableValue: Codable {
    let stringValue: String?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        stringValue = try? container.decode(String.self)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue ?? "")
    }
}

/// Built-in Gemini tools. Google Search grounding lets Gemini pull current
/// public web data for text searches without adding a separate app-side API.
private struct GeminiTool: Codable {
    let googleSearch: GoogleSearch?

    static let googleSearch = GeminiTool(googleSearch: GoogleSearch())

    enum CodingKeys: String, CodingKey {
        case googleSearch = "google_search"
    }
}

private struct GoogleSearch: Codable {}

/// Generation config tells Gemini what format to return and how to "think".
private struct GeminiGenerationConfig: Codable {
    let responseMimeType: String
    let thinkingConfig: GeminiThinkingConfig?

    enum CodingKeys: String, CodingKey {
        case responseMimeType
        case thinkingConfig
    }
}

/// Controls how much reasoning/thinking the model does before responding.
/// "minimal" = fast (labels), "high" = thorough (food photos).
private struct GeminiThinkingConfig: Codable {
    let thinkingLevel: String
    let includeThoughts: Bool

    enum CodingKeys: String, CodingKey {
        case thinkingLevel
        case includeThoughts
    }

    init(thinkingLevel: String, includeThoughts: Bool = true) {
        self.thinkingLevel = thinkingLevel
        self.includeThoughts = includeThoughts
    }
}

/// The top-level response from Gemini's generateContent endpoint.
/// Contains an array of candidates — we always use the first one.
private struct GeminiAPIResponse: Codable {
    let candidates: [GeminiCandidate]?
    let error: GeminiAPIError?
    let usageMetadata: GeminiUsageMetadata?
    let modelVersion: String?
}

/// A single candidate response from Gemini.
private struct GeminiCandidate: Codable {
    let content: GeminiResponseContent?
}

/// The content of a candidate response.
private struct GeminiResponseContent: Codable {
    let parts: [GeminiResponsePart]?
}

/// A part in the response — we only care about text parts containing our JSON.
private struct GeminiResponsePart: Codable {
    let text: String?
    let thought: Bool?
}

/// Error response from the Gemini API (e.g. invalid key, quota exceeded).
private struct GeminiAPIError: Codable {
    let code: Int?
    let message: String?
    let status: String?
}

private struct GeminiUsageMetadata: Codable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let thoughtsTokenCount: Int?
    let totalTokenCount: Int?
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
    let thinkingLevel: String // "minimal" for speed, "high" for accuracy

    // Keep these on Google's latest aliases. Do not replace them with concrete
    // dated, preview, or versioned Gemini model slugs unless Google removes the
    // latest endpoints entirely.
    private static let flashLatest = "gemini-flash-latest"
    private static let proLatest = "gemini-pro-latest"

    /// Label scans: latest Flash with minimal thinking.
    /// Optimized for OCR — reads text accurately with low latency (~2-4s).
    static let label = ModelConfig(
        primary: flashLatest,
        fallback: flashLatest,
        thinkingLevel: "minimal"
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
        thinkingLevel: "minimal"
    )

    /// AI Search uses the same user-facing model preference as food photos:
    /// Flash for speed/quota, Pro when the Settings toggle is enabled.
    static func aiSearch(useProModel: Bool) -> ModelConfig {
        useProModel ? foodPhoto : foodPhotoLite
    }
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

private struct GeminiRequestLogMetadata: Codable {
    let apiMethod: String
    let responseMimeType: String
    let thinkingLevel: String
    let includeThoughts: Bool
    let tools: [String]
    let imageCount: Int
    let maxImageDimension: Int?
    let jpegQuality: Double?
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
}

private final class GeminiCallTrace {
    let requestPrompt: String?
    let requestMetadataJSON: String?
    let imageMetadataJSON: String?
    let usesSearchGrounding: Bool
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
    var attempts: [GeminiModelAttemptLog] = []

    init(
        requestPrompt: String?,
        requestMetadataJSON: String?,
        imageMetadataJSON: String?,
        usesSearchGrounding: Bool
    ) {
        self.requestPrompt = requestPrompt
        self.requestMetadataJSON = requestMetadataJSON
        self.imageMetadataJSON = imageMetadataJSON
        self.usesSearchGrounding = usesSearchGrounding
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
        resolvedModel = attempt.model
        if let modelVersion = attempt.modelVersion {
            resolvedModelVersion = modelVersion
        }

        if attempt.succeeded {
            resolvedModelVersion = attempt.modelVersion
        }
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

// MARK: - ScanService

@Observable
@MainActor
final class ScanService {
    static let maxImagesPerScan = 4

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
    /// Last image set and scan settings submitted to Gemini, used for redo.
    var lastSubmittedScan: ScanRedoRequest?

    @ObservationIgnored private let modelContext: ModelContext?
    @ObservationIgnored private let tursoMirror: TursoMirrorService?

    init(modelContext: ModelContext? = nil, tursoMirror: TursoMirrorService? = nil) {
        self.modelContext = modelContext
        self.tursoMirror = tursoMirror
    }

    // MARK: Configuration

    /// Base URL for the Gemini REST API. All model endpoints are under this path.
    private static let geminiBaseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    @ObservationIgnored
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60   // Gemini Pro with thinking can take ~10-15s
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

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

    /// Sends a single captured image directly to Gemini's REST API.
    func scan(image: UIImage, mode: ScanMode, prompt: String? = nil, useProModel: Bool = false) async throws -> NutritionEntry {
        try await scan(images: [image], mode: mode, prompt: prompt, useProModel: useProModel)
    }

    /// Sends captured images directly to Gemini's REST API and returns a NutritionEntry.
    /// Requires a Gemini API key stored in Keychain.
    /// The entry is NOT inserted into SwiftData — caller should review and confirm.
    func scan(images: [UIImage], mode: ScanMode, prompt: String? = nil, useProModel: Bool = false) async throws -> NutritionEntry {
        isScanning = true
        error = nil
        thinkingTrace = []
        scanProgressMessage = "Preparing photos..."
        defer { isScanning = false }
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

        // Retrieve the user's API key from Keychain
        guard let apiKey = KeychainService.geminiAPIKey else {
            let err = ScanError.noAPIKey
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

        // Pick model config and prompt based on scan mode.
        // Food photos default to lite unless the user enables Pro in Settings.
        let modelConfig: ModelConfig
        if mode == .label {
            modelConfig = .label
        } else if useProModel {
            modelConfig = .foodPhoto
        } else {
            modelConfig = .foodPhotoLite
        }
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

        // Encode each photo as its own inline_data part. Gemini can reason over
        // multiple image parts in the same user message.
        let imageParts = jpegData.map {
            GeminiPart.inlineData(mimeType: "image/jpeg", data: $0.base64EncodedString())
        }

        // Build the Gemini request body
        let request = GeminiRequest(
            contents: [
                GeminiContent(
                    role: "user",
                    parts: [.text(finalPrompt)] + imageParts
                )
            ],
            generationConfig: GeminiGenerationConfig(
                responseMimeType: "application/json",
                thinkingConfig: GeminiThinkingConfig(thinkingLevel: modelConfig.thinkingLevel)
            )
        )
        let requestMetadata = GeminiRequestLogMetadata(
            apiMethod: "streamGenerateContent",
            responseMimeType: "application/json",
            thinkingLevel: modelConfig.thinkingLevel,
            includeThoughts: true,
            tools: [],
            imageCount: images.count,
            maxImageDimension: Int(maxImageDimension),
            jpegQuality: Double(jpegQuality)
        )
        let trace = GeminiCallTrace(
            requestPrompt: finalPrompt,
            requestMetadataJSON: encodedJSONString(requestMetadata),
            imageMetadataJSON: encodedJSONString(preparedImages.map(\.metadata)),
            usesSearchGrounding: false
        )

        // Try primary model, fall back on 500/503
        scanProgressMessage = "Waiting for Gemini..."
        let nutritionData: GeminiNutritionResponse
        do {
            nutritionData = try await callGemini(
                request: request,
                apiKey: apiKey,
                primaryModel: modelConfig.primary,
                fallbackModel: modelConfig.fallback,
                trace: trace
            )
        } catch {
            let visibleError = visibleError(from: error)
            recordGeminiScanLog(
                operation: .scan,
                status: .failure,
                scanMode: mode,
                primaryModel: modelConfig.primary,
                fallbackModel: modelConfig.fallback,
                resolvedModel: trace.resolvedModel ?? modelConfig.primary,
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
        print("📸 Scan completed in \(totalMs)ms (mode: \(mode.rawValue), photos: \(images.count), model: \(usedFallback ? modelConfig.fallback : modelConfig.primary))")
        print("   ├─ Image prep (resize + JPEG): \(abs(prepMs))ms")
        print("   ├─ Gemini API round-trip: \(abs(networkMs))ms")
        print("   └─ Client decode: \(abs(decodeMs))ms")
        #endif

        let entry = nutritionData.toNutritionEntry(mode: mode)
        entry.scanDurationMs = totalMs
        recordGeminiScanLog(
            operation: .scan,
            status: .success,
            scanMode: mode,
            primaryModel: modelConfig.primary,
            fallbackModel: modelConfig.fallback,
            resolvedModel: trace.resolvedModel ?? modelConfig.primary,
            usedFallback: trace.usedFallback,
            photoCount: images.count,
            userPrompt: prompt,
            durationMs: totalMs,
            debugTrace: trace,
            response: nutritionData
        )
        return entry
    }

    /// Uses Gemini with Google Search grounding to look up nutrition data from
    /// current public web sources. The result is returned for manual review.
    func searchNutrition(query: String, useProModel: Bool = false) async throws -> NutritionEntry {
        isScanning = true
        error = nil
        thinkingTrace = []
        scanProgressMessage = "Searching nutrition sources..."
        defer { isScanning = false }
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

        guard let apiKey = KeychainService.geminiAPIKey else {
            let err = ScanError.noAPIKey
            self.error = err
            recordGeminiScanLog(
                operation: .aiSearch,
                status: .failure,
                userPrompt: trimmed,
                durationMs: msFrom(ContinuousClock.now.duration(to: searchStart)),
                error: err
            )
            throw err
        }

        let modelConfig = ModelConfig.aiSearch(useProModel: useProModel)
        let finalPrompt = Self.aiSearchPrompt + "\n\nUser search prompt: \(trimmed)"

        let request = GeminiRequest(
            contents: [
                GeminiContent(
                    role: "user",
                    parts: [.text(finalPrompt)]
                )
            ],
            generationConfig: GeminiGenerationConfig(
                responseMimeType: "application/json",
                thinkingConfig: GeminiThinkingConfig(thinkingLevel: modelConfig.thinkingLevel)
            ),
            tools: [.googleSearch]
        )
        let requestMetadata = GeminiRequestLogMetadata(
            apiMethod: "streamGenerateContent",
            responseMimeType: "application/json",
            thinkingLevel: modelConfig.thinkingLevel,
            includeThoughts: true,
            tools: ["google_search"],
            imageCount: 0,
            maxImageDimension: nil,
            jpegQuality: nil
        )
        let trace = GeminiCallTrace(
            requestPrompt: finalPrompt,
            requestMetadataJSON: encodedJSONString(requestMetadata),
            imageMetadataJSON: nil,
            usesSearchGrounding: true
        )

        scanProgressMessage = "Waiting for Gemini..."
        let nutritionData: GeminiNutritionResponse
        do {
            nutritionData = try await callGemini(
                request: request,
                apiKey: apiKey,
                primaryModel: modelConfig.primary,
                fallbackModel: modelConfig.fallback,
                trace: trace
            )
        } catch {
            let visibleError = visibleError(from: error)
            recordGeminiScanLog(
                operation: .aiSearch,
                status: .failure,
                primaryModel: modelConfig.primary,
                fallbackModel: modelConfig.fallback,
                resolvedModel: trace.resolvedModel ?? modelConfig.primary,
                usedFallback: trace.usedFallback,
                userPrompt: trimmed,
                durationMs: msFrom(ContinuousClock.now.duration(to: searchStart)),
                debugTrace: trace,
                error: visibleError
            )
            throw visibleError
        }

        let totalMs = msFrom(ContinuousClock.now.duration(to: searchStart))
        scanProgressMessage = "Building nutrition entry..."
        lastScanDurationMs = totalMs
        #if DEBUG
        let usedFallback = trace.usedFallback
        print("🔎 AI nutrition search completed in \(totalMs)ms (model: \(usedFallback ? modelConfig.fallback : modelConfig.primary))")
        #endif

        let entry = nutritionData.toNutritionEntry(mode: .manual)
        entry.scanDurationMs = totalMs
        recordGeminiScanLog(
            operation: .aiSearch,
            status: .success,
            primaryModel: modelConfig.primary,
            fallbackModel: modelConfig.fallback,
            resolvedModel: trace.resolvedModel ?? modelConfig.primary,
            usedFallback: trace.usedFallback,
            userPrompt: trimmed,
            durationMs: totalMs,
            debugTrace: trace,
            response: nutritionData
        )
        return entry
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
        scanProgressMessage = "Reading ingredient image..."
        defer { isScanning = false }
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
        guard let apiKey = KeychainService.geminiAPIKey else {
            let err = ScanError.noAPIKey
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

        let modelConfig = ModelConfig.aiSearch(useProModel: useProModel)
        let prompt = Self.calculatorIngredientPrompt(name: trimmedName)
        let imageParts = preparedImages.map {
            GeminiPart.inlineData(mimeType: "image/jpeg", data: $0.data.base64EncodedString())
        }
        let request = GeminiRequest(
            contents: [
                GeminiContent(
                    role: "user",
                    parts: [.text(prompt)] + imageParts
                )
            ],
            generationConfig: GeminiGenerationConfig(
                responseMimeType: "application/json",
                thinkingConfig: GeminiThinkingConfig(thinkingLevel: modelConfig.thinkingLevel)
            )
        )
        let requestMetadata = GeminiRequestLogMetadata(
            apiMethod: "streamGenerateContent",
            responseMimeType: "application/json",
            thinkingLevel: modelConfig.thinkingLevel,
            includeThoughts: true,
            tools: [],
            imageCount: images.count,
            maxImageDimension: Int(maxImageDimension),
            jpegQuality: Double(jpegQuality)
        )
        let trace = GeminiCallTrace(
            requestPrompt: prompt,
            requestMetadataJSON: encodedJSONString(requestMetadata),
            imageMetadataJSON: encodedJSONString(preparedImages.map(\.metadata)),
            usesSearchGrounding: false
        )

        scanProgressMessage = "Waiting for Gemini..."
        let text: String
        do {
            text = try await callGeminiText(
                request: request,
                apiKey: apiKey,
                primaryModel: modelConfig.primary,
                fallbackModel: modelConfig.fallback,
                trace: trace
            )
        } catch {
            let visibleError = visibleError(from: error)
            recordGeminiScanLog(
                operation: .scan,
                status: .failure,
                primaryModel: modelConfig.primary,
                fallbackModel: modelConfig.fallback,
                resolvedModel: trace.resolvedModel ?? modelConfig.primary,
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
            let response = try JSONDecoder().decode(CalculatorIngredientDraft.self, from: Data(text.utf8))
            let filteredPortions = response.portions.filter {
                !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            recordGeminiScanLog(
                operation: .scan,
                status: .success,
                primaryModel: modelConfig.primary,
                fallbackModel: modelConfig.fallback,
                resolvedModel: trace.resolvedModel ?? modelConfig.primary,
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
                primaryModel: modelConfig.primary,
                fallbackModel: modelConfig.fallback,
                resolvedModel: trace.resolvedModel ?? modelConfig.primary,
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

    /// Calls the Gemini generateContent endpoint. If the primary model fails with 500/503,
    /// automatically retries with the fallback model.
    /// Returns the parsed nutrition data and whether the fallback was used.
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
            // Check if it's a retryable server error (500/503)
            if let scanError = visible as? ScanError,
               case .serverError(let code, _) = scanError,
               (code == 500 || code == 503) {
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
            if let scanError = visible as? ScanError,
               case .serverError(let code, _) = scanError,
               (code == 500 || code == 503) {
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

    private func callGeminiTextModel(
        request: GeminiRequest,
        apiKey: String,
        model: String,
        trace: GeminiCallTrace
    ) async throws -> String {
        let urlString = "\(Self.geminiBaseURL)/\(model):streamGenerateContent?key=\(apiKey)&alt=sse"
        let redactedEndpoint = "\(Self.geminiBaseURL)/\(model):streamGenerateContent?alt=sse"
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

        guard let url = URL(string: urlString) else {
            try fail(ScanError.invalidResponse, stage: "build_url")
        }

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = try JSONEncoder().encode(request)
        trace.requestPayloadBytes = httpRequest.httpBody?.count

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

        guard (200..<300).contains(httpResponse.statusCode) else {
            let data = try await collectData(from: bytes)
            attempt.rawErrorBody = String(data: data, encoding: .utf8)
            let apiResponse = try? JSONDecoder().decode(GeminiAPIResponse.self, from: data)
            let message = apiResponse?.error?.message ?? "HTTP \(httpResponse.statusCode)"
            try fail(ScanError.serverError(httpResponse.statusCode, message), stage: "http_error")
        }

        var jsonText = ""
        var eventPayloadLines: [String] = []
        var rawEventPayloads: [String] = []

        do {
            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty {
                    let payload = eventPayloadLines.joined(separator: "\n")
                    if !payload.isEmpty {
                        rawEventPayloads.append(payload)
                    }
                    try consumeGeminiStreamEvent(payload, jsonText: &jsonText, attempt: &attempt)
                    eventPayloadLines.removeAll()
                    continue
                }

                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]" else { break }
                eventPayloadLines.append(String(payload))
            }

            if !eventPayloadLines.isEmpty {
                let payload = eventPayloadLines.joined(separator: "\n")
                rawEventPayloads.append(payload)
                try consumeGeminiStreamEvent(payload, jsonText: &jsonText, attempt: &attempt)
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
        trace.absorb(attempt)
        return jsonText
    }

    /// Makes a single HTTP request to Gemini's generateContent endpoint for a specific model.
    /// Parses the response, extracts the JSON text, and decodes it into GeminiNutritionResponse.
    private func callGeminiModel(
        request: GeminiRequest,
        apiKey: String,
        model: String,
        trace: GeminiCallTrace
    ) async throws -> GeminiNutritionResponse {
        // Build the URL: /v1beta/models/{model}:streamGenerateContent?key={apiKey}&alt=sse
        // Streaming lets the UI show Gemini thought summaries before the final JSON arrives.
        let urlString = "\(Self.geminiBaseURL)/\(model):streamGenerateContent?key=\(apiKey)&alt=sse"
        let redactedEndpoint = "\(Self.geminiBaseURL)/\(model):streamGenerateContent?alt=sse"
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

        guard let url = URL(string: urlString) else {
            try fail(ScanError.invalidResponse, stage: "build_url")
        }

        // Create the HTTP request
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Encode the request body
        let encoder = JSONEncoder()
        httpRequest.httpBody = try encoder.encode(request)
        trace.requestPayloadBytes = httpRequest.httpBody?.count

        // Make the streaming network call.
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: httpRequest)
        } catch {
            let err = ScanError.networkError(error)
            try fail(err, stage: "network")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            let err = ScanError.invalidResponse
            try fail(err, stage: "http_response")
        }
        attempt.httpStatus = httpResponse.statusCode

        // Handle HTTP errors
        guard (200..<300).contains(httpResponse.statusCode) else {
            // Try to parse Gemini's error response for a useful message
            let data = try await collectData(from: bytes)
            attempt.rawErrorBody = String(data: data, encoding: .utf8)
            let apiResponse = try? JSONDecoder().decode(GeminiAPIResponse.self, from: data)
            let message = apiResponse?.error?.message ?? "HTTP \(httpResponse.statusCode)"
            let err = ScanError.serverError(httpResponse.statusCode, message)
            try fail(err, stage: "http_error")
        }

        var jsonText = ""
        var eventPayloadLines: [String] = []
        var rawEventPayloads: [String] = []

        do {
            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

                if line.isEmpty {
                    let payload = eventPayloadLines.joined(separator: "\n")
                    if !payload.isEmpty {
                        rawEventPayloads.append(payload)
                    }
                    try consumeGeminiStreamEvent(payload, jsonText: &jsonText, attempt: &attempt)
                    eventPayloadLines.removeAll()
                    continue
                }

                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]" else { break }
                eventPayloadLines.append(String(payload))
            }

            if !eventPayloadLines.isEmpty {
                let payload = eventPayloadLines.joined(separator: "\n")
                rawEventPayloads.append(payload)
                try consumeGeminiStreamEvent(payload, jsonText: &jsonText, attempt: &attempt)
            }
        } catch let scanError as ScanError {
            attempt.rawResponseJSON = encodedJSONString(rawEventPayloads)
            attempt.responseText = jsonText
            attempt.responseTextCharacters = jsonText.count
            try fail(scanError, stage: attempt.parseStage ?? "stream")
        } catch {
            let err = ScanError.decodingError(error)
            attempt.rawResponseJSON = encodedJSONString(rawEventPayloads)
            attempt.responseText = jsonText
            attempt.responseTextCharacters = jsonText.count
            try fail(err, stage: attempt.parseStage ?? "stream_decode")
        }

        attempt.rawResponseJSON = encodedJSONString(rawEventPayloads)
        attempt.responseText = jsonText
        attempt.responseTextCharacters = jsonText.count

        guard !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let err = ScanError.invalidResponse
            try fail(err, stage: "empty_response_text")
        }

        // Parse the nutrition JSON from Gemini's response text
        let nutritionResponse: GeminiNutritionResponse
        do {
            guard let jsonData = jsonText.data(using: .utf8) else {
                throw ScanError.invalidResponse
            }
            nutritionResponse = try JSONDecoder().decode(GeminiNutritionResponse.self, from: jsonData)
        } catch {
            let err = ScanError.decodingError(error)
            try fail(err, stage: "nutrition_json_decode")
        }

        attempt.succeeded = true
        attempt.parseStage = "complete"
        attempt.durationMs = msFrom(ContinuousClock.now.duration(to: attemptStart))
        trace.absorb(attempt)
        return nutritionResponse
    }

    private func consumeGeminiStreamEvent(
        _ payload: String,
        jsonText: inout String,
        attempt: inout GeminiModelAttemptLog
    ) throws {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        attempt.parseStage = "stream_event_decode"
        if let data = trimmed.data(using: .utf8),
           let apiResponse = try? JSONDecoder().decode(GeminiAPIResponse.self, from: data) {
            try consumeGeminiAPIResponse(apiResponse, jsonText: &jsonText, attempt: &attempt)
            return
        }

        let eventFragments = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for fragment in eventFragments {
            guard let data = fragment.data(using: .utf8) else { continue }
            let apiResponse = try JSONDecoder().decode(GeminiAPIResponse.self, from: data)
            try consumeGeminiAPIResponse(apiResponse, jsonText: &jsonText, attempt: &attempt)
        }
    }

    private func consumeGeminiAPIResponse(
        _ apiResponse: GeminiAPIResponse,
        jsonText: inout String,
        attempt: inout GeminiModelAttemptLog
    ) throws {
        attempt.streamEventCount += 1
        applyUsageMetadata(apiResponse.usageMetadata, modelVersion: apiResponse.modelVersion, to: &attempt)

        if let apiError = apiResponse.error {
            attempt.parseStage = "stream_api_error"
            throw ScanError.serverError(apiError.code ?? 500, apiError.message ?? "Unknown Gemini error")
        }

        attempt.parseStage = "stream_parts"
        guard let parts = apiResponse.candidates?.first?.content?.parts else { return }
        for part in parts {
            guard let text = part.text, !text.isEmpty else { continue }
            if part.thought == true {
                attempt.thoughtPartCount += 1
                recordThinkingTrace(text)
            } else {
                attempt.nonThoughtPartCount += 1
                jsonText += text
            }
        }
    }

    private func applyUsageMetadata(
        _ usage: GeminiUsageMetadata?,
        modelVersion: String?,
        to attempt: inout GeminiModelAttemptLog
    ) {
        guard let usage else { return }

        let inputTokens = usage.promptTokenCount ?? 0
        let thinkingTokens = usage.thoughtsTokenCount ?? 0
        let candidateTokens = usage.candidatesTokenCount ?? 0
        let totalTokens = usage.totalTokenCount ?? inputTokens + candidateTokens + thinkingTokens
        let outputTokens = max(candidateTokens + thinkingTokens, totalTokens - inputTokens)
        let modelIdentifier = modelVersion ?? attempt.model
        let estimate = estimateGeminiTokenCost(
            modelIdentifier: modelIdentifier,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )

        attempt.modelVersion = modelVersion
        attempt.inputTokenCount = inputTokens
        attempt.outputTokenCount = outputTokens
        attempt.thinkingTokenCount = thinkingTokens
        attempt.totalTokenCount = totalTokens
        attempt.estimatedCostUSD = estimate.estimatedCostUSD
        attempt.pricingModel = estimate.pricingModel
        attempt.inputRatePerMillionTokens = estimate.inputRatePerMillionTokens
        attempt.outputRatePerMillionTokens = estimate.outputRatePerMillionTokens
    }

    private func estimateGeminiTokenCost(
        modelIdentifier: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> GeminiPricingEstimate {
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
        thinkingTrace.append(clipped)
        if thinkingTrace.count > 4 {
            thinkingTrace.removeFirst(thinkingTrace.count - 4)
        }
        scanProgressMessage = "Gemini is reasoning..."
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
        error: Error? = nil
    ) {
        guard let modelContext else { return }

        let cleanedPrompt = userPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let log = GeminiScanLog(
            operation: operation,
            status: status,
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
            searchGroundingUsed: debugTrace?.usesSearchGrounding ?? false,
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

        modelContext.insert(log)
        recordGeminiCost(debugTrace, status: status, in: modelContext)
        GeminiScanLog.pruneExpired(in: modelContext)
        do {
            try modelContext.save()
            tursoMirror?.scheduleMirror(reason: "gemini_log_saved")
        } catch {
            // Preserve diagnostics as best-effort; scan/search UI should not fail on logging.
        }
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
            usedSearchGrounding: debugTrace.usesSearchGrounding,
            succeeded: status == .success
        )
    }

    private func encodedResponseJSON(_ response: GeminiNutritionResponse) -> String? {
        encodedJSONString(response)
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

// MARK: - Prompt Templates

/// These prompts are identical to what the server used — moved on-device for BYOK.
/// Both modes return the same JSON structure; the prompts differ in what they ask Gemini to do.
extension ScanService {

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
