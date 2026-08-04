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

        #expect(json["model"] as? String == "models/gemini-3.1-flash-lite-image")
        #expect(generation["thinking_level"] as? String == "high")
        #expect(generation["image_config"] == nil)
        #expect(generation["max_output_tokens"] == nil)
        #expect(json["response_modalities"] == nil)
        #expect(responseFormat["type"] as? String == "image")
        #expect(responseFormat["mime_type"] as? String == "image/jpeg")
        #expect(responseFormat["aspect_ratio"] as? String == "1:1")
        #expect(responseFormat["image_size"] as? String == "1K")
    }

    @Test func interactionsStringErrorCodePreservesActionableMessage() throws {
        let data = Data(#"{"error":{"message":"Thinking level LOW is not supported for this model.","code":"invalid_request"}}"#.utf8)
        let envelope = try JSONDecoder().decode(GeminiScanAPIErrorEnvelope.self, from: data)

        #expect(envelope.error?.code == "invalid_request")
        #expect(envelope.error?.message == "Thinking level LOW is not supported for this model.")
    }

    @Test func legacyNumericErrorCodeStillDecodes() throws {
        let data = Data(#"{"error":{"code":400,"message":"Bad request","status":"INVALID_ARGUMENT"}}"#.utf8)
        let envelope = try JSONDecoder().decode(GeminiScanAPIErrorEnvelope.self, from: data)

        #expect(envelope.error?.code == "400")
        #expect(envelope.error?.status == "INVALID_ARGUMENT")
    }
}
