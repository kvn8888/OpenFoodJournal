// OpenFoodJournal — Gemini Nano Banana 2 Lite request contracts.

import Foundation
import Testing
@testable import OpenFoodJournal

@MainActor
struct GeminiFoodIconContractTests {
    @Test func flashLiteImageThinkingLevelsMatchPublishedModelEnum() {
        // Source: https://ai.google.dev/gemini-api/docs/models/gemini-3.1-flash-lite-image
        let levels = Set(GeminiFlashLiteImageThinkingLevel.allCases.map(\.rawValue))

        #expect(levels == ["minimal", "high"])
        #expect(!levels.contains("low"))
        #expect(ScanService.foodIconImageThinkingLevel == .high)
    }

    @Test func productionImageRequestUsesCurrentInteractionsContract() throws {
        let request = ScanService.foodIconImageRequest(prompt: "Test food")
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let generation = try #require(json["generation_config"] as? [String: Any])
        let responseFormat = try #require(json["response_format"] as? [String: Any])
        let systemInstruction = try #require(json["system_instruction"] as? String)

        #expect(json["model"] as? String == "models/gemini-3.1-flash-lite-image")
        #expect(generation["thinking_level"] as? String == "high")
        #expect(generation["image_config"] == nil)
        #expect(generation["max_output_tokens"] == nil)
        #expect(json["response_modalities"] == nil)
        #expect(responseFormat["type"] as? String == "image")
        #expect(responseFormat["mime_type"] as? String == "image/jpeg")
        #expect(responseFormat["aspect_ratio"] as? String == "1:1")
        #expect(responseFormat["image_size"] as? String == "1K")
        #expect(systemInstruction.contains("For a dark food"))
        #expect(systemInstruction.contains("warm off-white background"))
        #expect(systemInstruction.contains("For a light food"))
        #expect(systemInstruction.contains("charcoal background"))
        #expect(systemInstruction.contains("No gradient"))
        #expect(!systemInstruction.localizedCaseInsensitiveContains("Pure White background"))
    }

    @Test func foodPromptCarriesAdaptiveBackgroundPolicy() throws {
        let prompt = ScanService.foodIconImagePrompt(
            name: "Steamed White Rice",
            brand: nil
        )
        let data = try #require(prompt.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["item"] as? String == "Steamed White Rice")
        #expect(json["background_policy"] as? String == "automatic opposite luminance")
        #expect(json["Brand"] == nil)
    }

    @Test func interactionsStringErrorCodePreservesActionableMessage() throws {
        let data = Data(#"{"error":{"message":"Thinking level LOW is not supported for this model.","code":"invalid_request"}}"#.utf8)
        let envelope = try JSONDecoder().decode(GeminiScanAPIErrorEnvelope.self, from: data)

        #expect(envelope.error?.code == "invalid_request")
        #expect(envelope.error?.message == "Thinking level LOW is not supported for this model.")
    }

    @Test func semanticMaskWinsAndFailureKeepsGeneratedFallback() {
        let generated = GeminiGeneratedFoodIconPayload(
            data: Data([0xFF, 0xD8, 0xFF]),
            mimeType: "image/jpeg"
        )
        let semanticPNG = Data([0x89, 0x50, 0x4E, 0x47])

        let masked = ScanService.storedFoodIconPayload(
            from: generated,
            semanticMaskData: semanticPNG
        )
        let fallback = ScanService.storedFoodIconPayload(
            from: generated,
            semanticMaskData: nil
        )

        #expect(masked.data == semanticPNG)
        #expect(masked.mimeType == "image/png")
        #expect(fallback.data == generated.data)
        #expect(fallback.mimeType == generated.mimeType)
    }

    @Test func legacyNumericErrorCodeStillDecodes() throws {
        let data = Data(#"{"error":{"code":400,"message":"Bad request","status":"INVALID_ARGUMENT"}}"#.utf8)
        let envelope = try JSONDecoder().decode(GeminiScanAPIErrorEnvelope.self, from: data)

        #expect(envelope.error?.code == "400")
        #expect(envelope.error?.status == "INVALID_ARGUMENT")
    }
}
