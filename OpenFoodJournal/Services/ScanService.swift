// OpenFoodJournal — Scan Service (Direct Gemini REST API — BYOK)
// Calls the Gemini API directly from the device using the user's own API key.
// No server proxy needed — eliminates Render dependency and cold starts.
// AGPL-3.0 License

import Foundation
import UIKit
import Observation

// MARK: - Scan Errors

enum ScanError: LocalizedError {
    case imageEncodingFailed
    case networkError(Error)
    case invalidResponse
    case serverError(Int, String)
    case decodingError(Error)
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed: "Failed to encode image for upload."
        case .networkError(let e): "Network error: \(e.localizedDescription)"
        case .invalidResponse: "Received an invalid response from the server."
        case .serverError(let code, let msg): "Server error \(code): \(msg)"
        case .decodingError(let e): "Failed to parse nutrition data: \(e.localizedDescription)"
        case .noAPIKey: "No Gemini API key configured. Add your key in Settings."
        }
    }
}

// MARK: - Gemini REST API Types

/// The top-level request body sent to Gemini's generateContent endpoint.
/// Contains an array of "contents" (each with "parts") and generation config.
private struct GeminiRequest: Codable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig
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

/// Generation config tells Gemini what format to return and how to "think".
private struct GeminiGenerationConfig: Codable {
    let responseMimeType: String
    let thinkingConfig: GeminiThinkingConfig?

    enum CodingKeys: String, CodingKey {
        case responseMimeType = "response_mime_type"
        case thinkingConfig = "thinking_config"
    }
}

/// Controls how much reasoning/thinking the model does before responding.
/// "MINIMAL" = fast (labels), "HIGH" = thorough (food photos).
private struct GeminiThinkingConfig: Codable {
    let thinkingLevel: String

    enum CodingKeys: String, CodingKey {
        case thinkingLevel = "thinking_level"
    }
}

/// The top-level response from Gemini's generateContent endpoint.
/// Contains an array of candidates — we always use the first one.
private struct GeminiAPIResponse: Codable {
    let candidates: [GeminiCandidate]?
    let error: GeminiAPIError?
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
}

/// Error response from the Gemini API (e.g. invalid key, quota exceeded).
private struct GeminiAPIError: Codable {
    let code: Int?
    let message: String?
    let status: String?
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
    let thinkingLevel: String // "MINIMAL" for speed, "HIGH" for accuracy

    /// Label scans: gemini-3.1-flash-lite-preview with minimal thinking.
    /// Optimized for OCR — reads text accurately with low latency (~2-4s).
    static let label = ModelConfig(
        primary: "gemini-3.1-flash-lite-preview",
        fallback: "gemini-2.5-flash",
        thinkingLevel: "MINIMAL"
    )

    /// Food photo scans: gemini-3.1-pro-preview with high thinking.
    /// Needs reasoning to estimate portion sizes and nutrient content (~4-8s).
    static let foodPhoto = ModelConfig(
        primary: "gemini-3.1-pro-preview",
        fallback: "gemini-2.5-pro",
        thinkingLevel: "HIGH"
    )
}

// MARK: - ScanService

@Observable
@MainActor
final class ScanService {
    // MARK: State

    var isScanning = false
    var error: ScanError?
    /// Holds the result of a background scan until the user confirms/dismisses it
    var pendingResult: NutritionEntry?
    /// Duration of the last completed scan in milliseconds
    var lastScanDurationMs: Int?

    // MARK: Configuration

    /// Base URL for the Gemini REST API. All model endpoints are under this path.
    private static let geminiBaseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60   // Gemini Pro with thinking can take ~10-15s
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

    // MARK: - Scan

    /// Kicks off a scan in the background. The caller can dismiss immediately.
    /// Result lands in `pendingResult`; errors land in `error`.
    func scanInBackground(image: UIImage, mode: ScanMode, prompt: String? = nil) {
        Task { @MainActor in
            do {
                let entry = try await scan(image: image, mode: mode, prompt: prompt)
                pendingResult = entry
            } catch {
                // error is already set via the scan() method
            }
        }
    }

    /// Sends a captured image directly to Gemini's REST API and returns a NutritionEntry.
    /// Requires a Gemini API key stored in Keychain.
    /// The entry is NOT inserted into SwiftData — caller should review and confirm.
    func scan(image: UIImage, mode: ScanMode, prompt: String? = nil) async throws -> NutritionEntry {
        isScanning = true
        error = nil
        defer { isScanning = false }

        // Retrieve the user's API key from Keychain
        guard let apiKey = KeychainService.geminiAPIKey else {
            let err = ScanError.noAPIKey
            self.error = err
            throw err
        }

        // Start timing the full scan pipeline
        let scanStart = ContinuousClock.now

        // Resize to max 1200px on longest edge before JPEG encoding.
        // OCR doesn't need high resolution — 1200px captures all text on a
        // nutrition label clearly while keeping JPEG size under ~200KB.
        let resized = image.resizedForOCR(maxDimension: 1200)

        // Label scans only need readable text → aggressive 50% JPEG quality (~100-200KB)
        // Food photos need visual detail for portion estimation → 80% quality (~300-600KB)
        let jpegQuality: CGFloat = mode == .label ? 0.50 : 0.80
        guard let jpegData = resized.jpegData(compressionQuality: jpegQuality) else {
            let err = ScanError.imageEncodingFailed
            self.error = err
            throw err
        }

        let prepEnd = ContinuousClock.now
        let prepMs = msFrom(prepEnd.duration(to: scanStart))
        #if DEBUG
        print("📐 Image: \(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale))px → \(Int(resized.size.width * resized.scale))×\(Int(resized.size.height * resized.scale))px, JPEG: \(jpegData.count / 1024)KB")
        #endif

        // Pick model config and prompt based on scan mode
        let modelConfig = mode == .label ? ModelConfig.label : ModelConfig.foodPhoto
        let systemPrompt = mode == .label ? Self.labelPrompt : Self.foodPhotoPrompt

        // If user provided additional context (e.g. "this is walnut shrimp"),
        // append it to the system prompt
        let finalPrompt: String
        if let prompt, !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            finalPrompt = systemPrompt + "\n\nAdditional context from user: \(prompt)"
        } else {
            finalPrompt = systemPrompt
        }

        // Encode image as base64 for the Gemini API
        let base64Image = jpegData.base64EncodedString()

        // Build the Gemini request body
        let request = GeminiRequest(
            contents: [
                GeminiContent(
                    role: "user",
                    parts: [
                        .text(finalPrompt),
                        .inlineData(mimeType: "image/jpeg", data: base64Image)
                    ]
                )
            ],
            generationConfig: GeminiGenerationConfig(
                responseMimeType: "application/json",
                thinkingConfig: GeminiThinkingConfig(thinkingLevel: modelConfig.thinkingLevel)
            )
        )

        // Try primary model, fall back on 500/503
        let (nutritionData, usedFallback) = try await callGemini(
            request: request,
            apiKey: apiKey,
            primaryModel: modelConfig.primary,
            fallbackModel: modelConfig.fallback
        )

        let networkEnd = ContinuousClock.now
        let networkMs = msFrom(networkEnd.duration(to: prepEnd))

        // Measure and log the full scan duration
        let totalMs = msFrom(ContinuousClock.now.duration(to: scanStart))
        let decodeMs = totalMs - abs(prepMs) - abs(networkMs)
        lastScanDurationMs = totalMs
        #if DEBUG
        print("📸 Scan completed in \(totalMs)ms (mode: \(mode.rawValue), model: \(usedFallback ? modelConfig.fallback : modelConfig.primary))")
        print("   ├─ Image prep (resize + JPEG): \(abs(prepMs))ms")
        print("   ├─ Gemini API round-trip: \(abs(networkMs))ms")
        print("   └─ Client decode: \(abs(decodeMs))ms")
        #endif

        var entry = nutritionData.toNutritionEntry(mode: mode)
        entry.scanDurationMs = totalMs
        return entry
    }

    // MARK: - Gemini API Call

    /// Calls the Gemini generateContent endpoint. If the primary model fails with 500/503,
    /// automatically retries with the fallback model.
    /// Returns the parsed nutrition data and whether the fallback was used.
    private func callGemini(
        request: GeminiRequest,
        apiKey: String,
        primaryModel: String,
        fallbackModel: String
    ) async throws -> (GeminiNutritionResponse, Bool) {
        do {
            let result = try await callGeminiModel(request: request, apiKey: apiKey, model: primaryModel)
            return (result, false)
        } catch let scanError as ScanError {
            // Check if it's a retryable server error (500/503)
            if case .serverError(let code, _) = scanError, (code == 500 || code == 503) {
                print("⚠️ Primary model failed (\(code)), falling back to \(fallbackModel)...")
                let result = try await callGeminiModel(request: request, apiKey: apiKey, model: fallbackModel)
                return (result, true)
            }
            self.error = scanError
            throw scanError
        }
    }

    /// Makes a single HTTP request to Gemini's generateContent endpoint for a specific model.
    /// Parses the response, extracts the JSON text, and decodes it into GeminiNutritionResponse.
    private func callGeminiModel(
        request: GeminiRequest,
        apiKey: String,
        model: String
    ) async throws -> GeminiNutritionResponse {
        // Build the URL: /v1beta/models/{model}:generateContent?key={apiKey}
        let urlString = "\(Self.geminiBaseURL)/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw ScanError.invalidResponse
        }

        // Create the HTTP request
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Encode the request body
        let encoder = JSONEncoder()
        httpRequest.httpBody = try encoder.encode(request)

        // Make the network call
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: httpRequest)
        } catch {
            let err = ScanError.networkError(error)
            self.error = err
            throw err
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            let err = ScanError.invalidResponse
            self.error = err
            throw err
        }

        // Handle HTTP errors
        guard (200..<300).contains(httpResponse.statusCode) else {
            // Try to parse Gemini's error response for a useful message
            let apiResponse = try? JSONDecoder().decode(GeminiAPIResponse.self, from: data)
            let message = apiResponse?.error?.message ?? "HTTP \(httpResponse.statusCode)"
            let err = ScanError.serverError(httpResponse.statusCode, message)
            self.error = err
            throw err
        }

        // Parse the Gemini API response envelope
        let apiResponse: GeminiAPIResponse
        do {
            apiResponse = try JSONDecoder().decode(GeminiAPIResponse.self, from: data)
        } catch {
            let err = ScanError.decodingError(error)
            self.error = err
            throw err
        }

        // Check for API-level errors in the response body
        if let apiError = apiResponse.error {
            let err = ScanError.serverError(apiError.code ?? 500, apiError.message ?? "Unknown Gemini error")
            self.error = err
            throw err
        }

        // Extract the text content from the first candidate's first part.
        // Gemini returns structured JSON since we set responseMimeType: "application/json".
        // With thinking enabled, there may be multiple parts — the actual JSON is in the
        // last text part (earlier parts contain the model's reasoning).
        guard let candidate = apiResponse.candidates?.first,
              let parts = candidate.content?.parts,
              let jsonText = parts.last(where: { $0.text != nil })?.text else {
            let err = ScanError.invalidResponse
            self.error = err
            throw err
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
            self.error = err
            throw err
        }

        return nutritionResponse
    }

    /// Convert a ContinuousClock.Duration to milliseconds (always positive)
    private func msFrom(_ duration: ContinuousClock.Instant.Duration) -> Int {
        let attoseconds = duration.components.attoseconds
        let seconds = duration.components.seconds
        return abs(Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000))
    }
}

// MARK: - Prompt Templates

/// These prompts are identical to what the server used — moved on-device for BYOK.
/// Both modes return the same JSON structure; the prompts differ in what they ask Gemini to do.
extension ScanService {

    /// Prompt for label scan mode — OCR of nutrition facts panels.
    static let labelPrompt = """
    You are a nutrition label reader. Analyze this nutrition label image and extract ALL nutritional information.

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
    You are a nutrition estimation expert. Look at this photo of food and estimate its nutritional content.

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
