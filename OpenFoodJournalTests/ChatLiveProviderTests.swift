// OpenFoodJournal — Opt-in live provider smoke contracts.
// These never run during normal CI/local tests. Enable explicitly with
// OFJ_RUN_LIVE_CHAT_TESTS=1 and provider-specific environment credentials.

import Foundation
import XCTest
@testable import OpenFoodJournal

@MainActor
final class ChatLiveProviderTests: XCTestCase {
    func testGeminiFoodIconImageLiveContract() async throws {
        guard environment("OFJ_RUN_LIVE_GEMINI_IMAGE_TESTS") == "1" else {
            throw XCTSkip("Set OFJ_RUN_LIVE_GEMINI_IMAGE_TESTS=1 to enable the billable Gemini image contract.")
        }
        let key = try requireEnvironment("OFJ_GEMINI_API_KEY")
        let body = ScanService.foodIconImageRequest(
            prompt: #"{"item":"single blueberry"}"#
        )
        let url = try XCTUnwrap(URL(string: ScanService.geminiInteractionsURL))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await liveSession().data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        guard (200..<300).contains(httpResponse.statusCode) else {
            let envelope = try? JSONDecoder().decode(GeminiScanAPIErrorEnvelope.self, from: data)
            XCTFail(
                "Gemini image contract returned HTTP \(httpResponse.statusCode): "
                    + (envelope?.error?.message ?? "Unknown provider error")
            )
            return
        }

        let image = try XCTUnwrap(
            ScanService.extractGeneratedFoodIconImage(from: data),
            "Gemini returned success without a decodable image."
        )
        XCTAssertGreaterThan(image.data.count, 1_000)
    }

    func testGeminiLiveContract() async throws {
        try requireLiveRun()
        let key = try requireEnvironment("OFJ_GEMINI_API_KEY")
        let model = environment("OFJ_GEMINI_MODEL") ?? "gemini-flash-latest"
        let proxy = GeminiChatModelProxy(
            configuration: ChatProxyConfiguration(
                descriptor: ChatModelCatalog.descriptor(provider: .gemini, model: model),
                apiKey: key
            ),
            session: liveSession()
        )
        try await assertLowCostContract(proxy)
    }

    func testOpenRouterLiveContract() async throws {
        try requireLiveRun()
        let key = try requireEnvironment("OFJ_OPENROUTER_API_KEY")
        let model = try requireEnvironment("OFJ_OPENROUTER_MODEL")
        let proxy = OpenRouterChatModelProxy(
            configuration: ChatProxyConfiguration(
                descriptor: ChatModelCatalog.descriptor(provider: .openRouter, model: model),
                apiKey: key
            ),
            session: liveSession()
        )
        try await assertLowCostContract(proxy)
    }

    func testOpenAILiveContract() async throws {
        try requireLiveRun()
        let key = try requireEnvironment("OFJ_OPENAI_API_KEY")
        let model = environment("OFJ_OPENAI_MODEL") ?? AIProviderSettings.defaultOpenAIFastModel
        let proxy = OpenAIResponsesChatModelProxy(
            configuration: ChatProxyConfiguration(
                descriptor: ChatModelCatalog.descriptor(provider: .openAI, model: model),
                apiKey: key,
                endpoint: URL(string: "https://api.openai.com/v1")
            ),
            session: liveSession()
        )
        try await assertLowCostContract(proxy)
    }

    func testAnthropicLiveContract() async throws {
        try requireLiveRun()
        let key = try requireEnvironment("OFJ_ANTHROPIC_API_KEY")
        let model = environment("OFJ_ANTHROPIC_MODEL") ?? AIProviderSettings.defaultAnthropicFastModel
        let proxy = AnthropicChatModelProxy(
            configuration: ChatProxyConfiguration(
                descriptor: ChatModelCatalog.descriptor(provider: .anthropic, model: model),
                apiKey: key,
                endpoint: URL(string: "https://api.anthropic.com/v1")
            ),
            session: liveSession()
        )
        try await assertLowCostContract(proxy)
    }

    func testMuseSparkLiveContract() async throws {
        try requireLiveRun()
        let key = try requireEnvironment("OFJ_MUSE_SPARK_API_KEY")
        let model = environment("OFJ_MUSE_SPARK_MODEL") ?? AIProviderSettings.defaultMuseSparkModel
        let proxy = MuseSparkChatModelProxy(
            configuration: ChatProxyConfiguration(
                descriptor: ChatModelCatalog.descriptor(provider: .museSpark, model: model),
                apiKey: key,
                endpoint: URL(string: "https://api.meta.ai/v1")
            ),
            session: liveSession()
        )
        try await assertLowCostContract(proxy)
    }

    func testExaLiveContract() async throws {
        try requireLiveRun()
        let key = try requireEnvironment("OFJ_EXA_API_KEY")
        let result = try await ExaChatWebSearchProvider(
            apiKey: key,
            session: liveSession(),
            maxResults: 1
        ).search(query: "OpenFoodJournal GitHub")
        XCTAssertFalse(result.sources.isEmpty)
        XCTAssertEqual(result.providerID, AssistantResearchProvider.exa.rawValue)
    }

    func testAzureSolLiveContract() async throws {
        try await assertAzureContract(model: .sol, deploymentKey: "OFJ_AZURE_SOL_DEPLOYMENT")
    }

    func testAzureTerraLiveContract() async throws {
        try await assertAzureContract(model: .terra, deploymentKey: "OFJ_AZURE_TERRA_DEPLOYMENT")
    }

    private func assertAzureContract(
        model: AzureAssistantModel,
        deploymentKey: String
    ) async throws {
        try requireLiveRun()
        let key = try requireEnvironment("OFJ_AZURE_OPENAI_API_KEY")
        let endpoint = try AzureOpenAIEndpoint.normalizedBaseURL(
            from: try requireEnvironment("OFJ_AZURE_OPENAI_ENDPOINT")
        )
        let deployment = try requireEnvironment(deploymentKey)
        let proxy = AzureOpenAIChatModelProxy(
            configuration: ChatProxyConfiguration(
                descriptor: ChatModelCatalog.azureDescriptor(model: model, deployment: deployment),
                apiKey: key,
                endpoint: endpoint
            ),
            session: liveSession()
        )
        try await assertLowCostContract(proxy)
    }

    private func assertLowCostContract(_ proxy: any ChatModelProxy) async throws {
        let turn = try await proxy.streamTurn(
            request: ChatModelRequest(
                systemPrompt: "Reply with only the word OK.",
                messages: [ChatModelMessage(role: .user, parts: [.text("OK")])],
                tools: []
            ),
            onTextUpdate: { _ in }
        )
        XCTAssertFalse(turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(turn.calls.isEmpty)
    }

    private func requireLiveRun() throws {
        guard environment("OFJ_RUN_LIVE_CHAT_TESTS") == "1" else {
            throw XCTSkip("Set OFJ_RUN_LIVE_CHAT_TESTS=1 to enable live provider contracts.")
        }
    }

    private func requireEnvironment(_ key: String) throws -> String {
        guard let value = environment(key), !value.isEmpty else {
            throw XCTSkip("Missing \(key); this provider's live contract is skipped.")
        }
        return value
    }

    private func environment(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func liveSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }
}
