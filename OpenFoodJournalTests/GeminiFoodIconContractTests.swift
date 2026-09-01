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

    // MARK: - OpenAI-compatible images endpoint contract

    @Test func openAICompatibleImageRequestUsesMinimalImagesAPIBody() throws {
        let prompt = ScanService.foodIconImagePrompt(name: "Steamed White Rice", brand: nil)
        let request = ScanService.openAICompatibleFoodIconImageRequest(
            model: "muse-image-1.0",
            prompt: prompt
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["model"] as? String == "muse-image-1.0")
        #expect(json["n"] as? Int == 1)
        // Optional Images API parameters are rejected by some compatible
        // servers, so the body must stay minimal.
        #expect(json.keys.sorted() == ["model", "n", "prompt"])

        // The Images API has no system-instruction field: style rules must
        // travel inside the prompt, followed by the per-food JSON.
        let sentPrompt = try #require(json["prompt"] as? String)
        #expect(sentPrompt.contains("For a dark food"))
        #expect(sentPrompt.contains("No gradient"))
        #expect(sentPrompt.contains("Steamed White Rice"))
    }

    @Test func openAICompatibleImageResponseDecodesBase64AndURLVariants() throws {
        let base64Body = Data(#"{"created":1,"data":[{"b64_json":"iVBORw0KGgo="}]}"#.utf8)
        let urlBody = Data(#"{"created":1,"data":[{"url":"https://cdn.example.com/img.png"}]}"#.utf8)

        let base64Envelope = try JSONDecoder().decode(OpenAICompatibleImageResponseEnvelope.self, from: base64Body)
        let urlEnvelope = try JSONDecoder().decode(OpenAICompatibleImageResponseEnvelope.self, from: urlBody)

        #expect(base64Envelope.data?.first?.b64JSON == "iVBORw0KGgo=")
        #expect(base64Envelope.data?.first?.url == nil)
        #expect(urlEnvelope.data?.first?.url == "https://cdn.example.com/img.png")
        #expect(urlEnvelope.data?.first?.b64JSON == nil)
    }

    @Test func openAICompatibleBaseURLNormalizationAcceptsCommonShapes() {
        #expect(
            OpenAICompatibleEndpoint.normalizedBaseURL(from: " https://api.meta.ai/v1/ ")?.absoluteString
                == "https://api.meta.ai/v1"
        )
        // Self-hosted LAN inference servers are a supported BYOK target.
        #expect(
            OpenAICompatibleEndpoint.normalizedBaseURL(from: "http://192.168.1.20:8000/v1")?.absoluteString
                == "http://192.168.1.20:8000/v1"
        )
        #expect(OpenAICompatibleEndpoint.normalizedBaseURL(from: "") == nil)
        #expect(OpenAICompatibleEndpoint.normalizedBaseURL(from: "   ") == nil)
        #expect(OpenAICompatibleEndpoint.normalizedBaseURL(from: "api.meta.ai/v1") == nil)
        #expect(OpenAICompatibleEndpoint.normalizedBaseURL(from: "ftp://api.meta.ai/v1") == nil)
    }
}
