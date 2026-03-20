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
    let confidence: Double?
    let servingSize: String?
    let servingsPerContainer: Double?

    // Core macros — always present
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double

    // Dynamic micronutrients — Gemini returns whatever it finds on the label/food.
    // e.g. { "Fiber": { "value": 3.0, "unit": "g" }, "Vitamin A": { "value": 300, "unit": "mcg" } }
    let micronutrients: [String: MicronutrientValue]?

    let scanMode: String?

    enum CodingKeys: String, CodingKey {
        case name, confidence, calories, protein, carbs, fat
        case micronutrients
        case servingSize = "serving_size"
        case servingsPerContainer = "servings_per_container"
        case scanMode = "scan_mode"
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

    // MARK: Configuration

    /// Base URL of the Render proxy. Override with environment variable in development.
    private let proxyBaseURL: URL = {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "RENDER_PROXY_URL") as? String
            ?? "https://macros-proxy.onrender.com"
        return URL(string: urlString)!
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    // MARK: - Scan

    /// Sends a captured image to the Render proxy and returns a NutritionEntry.
    /// The entry is NOT inserted into SwiftData — caller should review and confirm.
    func scan(image: UIImage, mode: ScanMode) async throws -> NutritionEntry {
        isScanning = true
        error = nil
        defer { isScanning = false }

        guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
            throw ScanError.imageEncodingFailed
        }

        let request = try buildRequest(imageData: jpegData, mode: mode)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ScanError.networkError(error)
        }

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

        return geminiResponse.toNutritionEntry(mode: mode, imageData: jpegData)
    }

    // MARK: - Private Helpers

    private func buildRequest(imageData: Data, mode: ScanMode) throws -> URLRequest {
        let url = proxyBaseURL.appendingPathComponent("scan")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Mode field
        let modeParam = mode == .label ? "label" : "food_photo"
        body.appendFormField(name: "mode", value: modeParam, boundary: boundary)

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
        NutritionEntry(
            name: name,
            mealType: .snack, // user selects meal type before confirming
            scanMode: mode,
            confidence: confidence,
            sourceImage: imageData,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            micronutrients: micronutrients ?? [:],
            servingSize: servingSize,
            servingsPerContainer: servingsPerContainer
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
