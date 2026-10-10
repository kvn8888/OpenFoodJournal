import Foundation
import Testing
@testable import OpenFoodJournal

@MainActor
struct ChatUsageAnchorTests {
    private var selection: AssistantModelSelection {
        AssistantModelSelection(descriptor: ChatModelCatalog.azureDescriptor(baseModelID: "model-a", deployment: "Prod-A"), endpoint: URL(string: "https://sample.openai.azure.com/openai/v1"), routingMode: .automatic)
    }
    private var request: ChatModelRequest {
        ChatModelRequest(systemPrompt: "System", messages: [.init(role: .user, parts: [.text("Original message")])], tools: [.init(name: "get_goals", description: "Read goals", parameters: nil)])
    }

    @Test func reportedPrefixSurvivesSerializationAndOnlyAppendedInputIsEstimated() throws {
        let anchor = ChatUsageAnchor(request: request, selection: selection, usage: ChatTokenUsage(input: 800, output: 40, thinking: 10))
        let restored = try JSONDecoder().decode(ChatUsageAnchor.self, from: JSONEncoder().encode(anchor))
        #expect(restored.estimate(request: request, selection: selection) == 800)
        let tail = ChatModelMessage(role: .model, parts: [.text("New answer")])
        let appended = ChatModelRequest(systemPrompt: request.systemPrompt, messages: request.messages + [tail], tools: request.tools)
        #expect(restored.estimate(request: appended, selection: selection) == 840 + ChatContextAccumulator.estimate(message: tail))
        #expect(!String(decoding: try JSONEncoder().encode(anchor), as: UTF8.self).contains("Original message"))
    }

    @Test func changesToContextOrModelInvalidateTheAnchor() {
        let anchor = ChatUsageAnchor(request: request, selection: selection, usage: ChatTokenUsage(input: 800))
        #expect(anchor.estimate(request: .init(systemPrompt: "Changed instructions", messages: request.messages, tools: request.tools), selection: selection) == nil)
        #expect(anchor.estimate(request: .init(systemPrompt: request.systemPrompt, messages: [.init(role: .user, parts: [.text("Edited")])], tools: request.tools), selection: selection) == nil)
        #expect(anchor.estimate(request: .init(systemPrompt: request.systemPrompt, messages: request.messages, tools: []), selection: selection) == nil)
        #expect(anchor.estimate(request: .init(systemPrompt: request.systemPrompt, messages: [], tools: request.tools), selection: selection) == nil)
        let switched = AssistantModelSelection(descriptor: ChatModelCatalog.azureDescriptor(baseModelID: "model-b", deployment: "Prod-A"), endpoint: selection.endpoint, routingMode: .automatic)
        #expect(anchor.estimate(request: request, selection: switched) == nil)
    }

    @Test func summaryOutputCapsAreSerializedByProviderAdapters() throws {
        var summary = request
        summary.maximumOutputTokens = 768
        let azure = ChatProxyConfiguration(descriptor: selection.descriptor, apiKey: "not-in-payload", endpoint: selection.endpoint)
        let responses = try JSONDecoder().decode(JSONValue.self, from: OpenAIResponsesChatModelProxy.encodedTurnRequest(configuration: azure, request: summary))
        #expect(responses["max_output_tokens"]?.doubleValue == 768)
        let gemini = try JSONDecoder().decode(JSONValue.self, from: GeminiChatModelProxy.encodedTurnRequest(summary))
        #expect(gemini["generationConfig"]?["maxOutputTokens"]?.doubleValue == 768)
        let compatible = try JSONDecoder().decode(JSONValue.self, from: OpenRouterChatModelProxy.encodedTurnRequest(model: "model-a", request: summary, routingMode: .automatic))
        #expect(compatible["max_completion_tokens"]?.doubleValue == 768)
    }
}
