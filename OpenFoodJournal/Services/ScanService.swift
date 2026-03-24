// Macros — Food Journaling App
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

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed: "Failed to encode image for upload."
        case .networkError(let e): "Network error: \(e.localizedDescription)"
        case .invalidResponse: "Received an invalid response from the server."
        case .serverError(let code, let msg): "Server error \(code): \(msg)"
        case .decodingError(let e): "Failed to parse nutrition data: \(e.localizedDescription)"
        }
    }
}

// MARK: - API Response Shape

/// Response from the Gemini 3.1 Pro proxy.
/// Core macros are required fields; micronutrients is a flexible dictionary
/// that can contain any nutrient Gemini detects (fiber, sodium, Vitamin A, etc.).
/// Each micronutrient has a value and unit, both filled by Gemini.
private struct GeminiNutritionResponse: Codable {
    let name: String
    let brand: String?
    let confidence: Double?
    let servingSize: String?
    let servingQuantity: Double?
    let servingUnit: String?
    let servingWeightGrams: Double?
    let servingsPerContainer: Double?
    // Structured serving fields — populated by updated Gemini prompt
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

    /// Server-side timing breakdown returned by the proxy
    let serverTiming: ServerTiming?

    struct ServerTiming: Codable {
        let totalMs: Int
        let geminiMs: Int
        let prepMs: Int

        enum CodingKeys: String, CodingKey {
            case totalMs = "total_ms"
            case geminiMs = "gemini_ms"
            case prepMs = "prep_ms"
        }
    }

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
        case serverTiming = "server_timing"
    }
}

private struct ServerErrorResponse: Codable {
    let error: String
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
    /// Duration of the last completed scan in milliseconds (upload + Gemini + decode)
    var lastScanDurationMs: Int?

    // MARK: Configuration

    /// Base URL of the Render proxy. Override with environment variable in development.
    private let proxyBaseURL: URL = {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "RENDER_PROXY_URL") as? String
            ?? "https://openfoodjournal.onrender.com"
        return URL(string: urlString)!
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
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

    /// Sends a captured image to the Render proxy and returns a NutritionEntry.
    /// The entry is NOT inserted into SwiftData — caller should review and confirm.
    func scan(image: UIImage, mode: ScanMode, prompt: String? = nil) async throws -> NutritionEntry {
        isScanning = true
        error = nil
        defer { isScanning = false }

        // Start timing the full scan pipeline
        let scanStart = ContinuousClock.now

        // Resize to max 1200px on longest edge before JPEG encoding.
        // OCR doesn't need high resolution — 1200px captures all text on a
        // nutrition label clearly while keeping JPEG size under ~200KB.
        // Combined with 0.80 quality, this cuts upload from ~5MB to ~150-300KB
        // on cellular, shaving 1-2 seconds off round-trip time.
        let resized = image.resizedForOCR(maxDimension: 1200)

        guard let jpegData = resized.jpegData(compressionQuality: 0.80) else {
            throw ScanError.imageEncodingFailed
        }

        let prepEnd = ContinuousClock.now
        let prepMs = msFrom(prepEnd.duration(to: scanStart))
        print("📐 Image: \(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale))px → \(Int(resized.size.width * resized.scale))×\(Int(resized.size.height * resized.scale))px, JPEG: \(jpegData.count / 1024)KB")

        let request = try buildRequest(imageData: jpegData, mode: mode, prompt: prompt)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ScanError.networkError(error)
        }

        let networkEnd = ContinuousClock.now
        let networkMs = msFrom(networkEnd.duration(to: prepEnd))

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ScanError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerErrorResponse.self, from: data))?.error ?? "Unknown error"
            throw ScanError.serverError(httpResponse.statusCode, message)
        }

        let geminiResponse: GeminiNutritionResponse
        do {
            geminiResponse = try JSONDecoder().decode(GeminiNutritionResponse.self, from: data)
        } catch {
            throw ScanError.decodingError(error)
        }

        // Measure and log the full scan duration broken down by phase
        let totalMs = msFrom(ContinuousClock.now.duration(to: scanStart))
        let decodeMs = totalMs - abs(prepMs) - abs(networkMs)
        lastScanDurationMs = totalMs

        print("📸 Scan completed in \(totalMs)ms (mode: \(mode.rawValue))")
        print("   ├─ Image prep (resize + JPEG): \(abs(prepMs))ms")
        print("   ├─ Network round-trip: \(abs(networkMs))ms")
        if let st = geminiResponse.serverTiming {
            print("   │  ├─ Server total: \(st.totalMs)ms")
            print("   │  │  ├─ Server prep (base64): \(st.prepMs)ms")
            print("   │  │  └─ Gemini API call: \(st.geminiMs)ms")
            let uploadMs = abs(networkMs) - st.totalMs
            if uploadMs > 0 {
                print("   │  └─ Upload + download overhead: \(uploadMs)ms")
            }
        }
        print("   └─ Client decode: \(abs(decodeMs))ms")

        var entry = geminiResponse.toNutritionEntry(mode: mode, imageData: jpegData)
        entry.scanDurationMs = totalMs
        return entry
    }

    /// Convert a ContinuousClock.Duration to milliseconds (always positive)
    private func msFrom(_ duration: ContinuousClock.Instant.Duration) -> Int {
        let attoseconds = duration.components.attoseconds
        let seconds = duration.components.seconds
        return abs(Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000))
    }

    // MARK: - Private Helpers

    private func buildRequest(imageData: Data, mode: ScanMode, prompt: String? = nil) throws -> URLRequest {
        let url = proxyBaseURL.appendingPathComponent("scan")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Mode field
        let modeParam = mode == .label ? "label" : "food_photo"
        body.appendFormField(name: "mode", value: modeParam, boundary: boundary)

        // Optional user prompt for additional context (e.g. "this is walnut shrimp")
        if let prompt, !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            body.appendFormField(name: "prompt", value: prompt, boundary: boundary)
        }

        // Image field
        body.appendFormFile(name: "image", filename: "capture.jpg", mimeType: "image/jpeg", data: imageData, boundary: boundary)

        // Final boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        return request
    }
}

// MARK: - Response Mapping

private extension GeminiNutritionResponse {
    func toNutritionEntry(mode: ScanMode, imageData: Data) -> NutritionEntry {
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
            sourceImage: imageData,
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

// MARK: - Multipart Helpers

private extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendFormFile(name: String, filename: String, mimeType: String, data fileData: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(fileData)
        append("\r\n".data(using: .utf8)!)
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
