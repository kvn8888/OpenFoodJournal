// OpenFoodJournal — Assistant test support
// Provider-neutral scripted model, deterministic app dependencies, and an
// in-memory SwiftData harness shared by the chat feature/API tests.

import Foundation
import SwiftData
@testable import OpenFoodJournal

final class StubChatURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: ChatTestError.missingScript("No URLProtocol handler installed"))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubChatURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Foundation may expose an uploaded request body as a stream by the time
    /// a custom URL protocol receives it. Materialize either representation so
    /// wire-contract tests behave consistently on local and hosted macOS.
    static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                return nil
            }
            if count == 0 {
                break
            }
            result.append(buffer, count: count)
        }
        return result
    }
}

@MainActor
final class ScriptedChatModelProxy: ChatModelProxy {
    struct RecordedTurn {
        let model: String
        let request: ChatModelRequest
        let apiKey: String
        let routingMode: OpenRouterRoutingMode
    }

    struct RecordedSearch {
        let model: String
        let prompt: String
        let apiKey: String
        let routingMode: OpenRouterRoutingMode
    }

    var turnResults: [Result<ChatModelTurn, Error>] = []
    var searchResults: [Result<ChatWebSearchResult, Error>] = []
    private(set) var turns: [RecordedTurn] = []
    private(set) var searches: [RecordedSearch] = []
    private(set) var descriptor = ChatModelCatalog.descriptor(
        provider: .gemini,
        model: "scripted-model"
    )
    private var routingMode: OpenRouterRoutingMode = .automatic
    private var configuredAPIKey = ""
    var nextTurnDelayNanoseconds: UInt64?
    var preResultEvents: [ChatModelStreamEvent] = []
    var nextResponseHeaders: (statusCode: Int, requestID: String?, retryAfter: TimeInterval?)?

    func configure(for selection: AssistantModelSelection, apiKey: String) {
        descriptor = selection.descriptor
        routingMode = selection.routingMode
        configuredAPIKey = apiKey
    }

    func enqueue(_ turn: ChatModelTurn) {
        turnResults.append(.success(turn))
    }

    func enqueue(error: Error) {
        turnResults.append(.failure(error))
    }

    func enqueueSearch(_ result: ChatWebSearchResult) {
        searchResults.append(.success(result))
    }

    func streamTurn(
        request: ChatModelRequest,
        onEvent: @escaping @MainActor (ChatModelStreamEvent) -> Void
    ) async throws -> ChatModelTurn {
        onEvent(.encodingStarted)
        onEvent(.requestEncoded(byteCount: 0))
        turns.append(RecordedTurn(
            model: descriptor.deploymentIdentifier,
            request: request,
            apiKey: configuredAPIKey,
            routingMode: routingMode
        ))
        if let headers = nextResponseHeaders {
            nextResponseHeaders = nil
            onEvent(.responseHeaders(
                statusCode: headers.statusCode,
                requestID: headers.requestID,
                retryAfter: headers.retryAfter
            ))
        }
        let earlyEvents = preResultEvents
        preResultEvents = []
        for event in earlyEvents { onEvent(event) }
        if let delay = nextTurnDelayNanoseconds {
            nextTurnDelayNanoseconds = nil
            try await Task.sleep(nanoseconds: delay)
        }
        guard !turnResults.isEmpty else {
            throw ChatTestError.missingScript("No scripted model turn remains")
        }
        let result = turnResults.removeFirst()
        switch result {
        case .success(let turn):
            onEvent(.providerEvent(kind: "scripted.turn"))
            if !turn.text.isEmpty { onEvent(.visibleText(turn.text)) }
            for call in turn.calls { onEvent(.functionCall(call)) }
            if let usage = turn.usage { onEvent(.usage(usage)) }
            onEvent(.completed)
            return turn
        case .failure(let error):
            throw error
        }
    }

    func searchWeb(
        prompt: String
    ) async throws -> ChatWebSearchResult {
        searches.append(RecordedSearch(
            model: descriptor.deploymentIdentifier,
            prompt: prompt,
            apiKey: configuredAPIKey,
            routingMode: routingMode
        ))
        guard !searchResults.isEmpty else {
            throw ChatTestError.missingScript("No scripted web search remains")
        }
        return try searchResults.removeFirst().get()
    }
}

@MainActor
final class ScriptedChatWebSearchProvider: ChatWebSearchProviding {
    struct RecordedSearch {
        let request: ChatWebSearchRequest

        var query: String { request.objective }
    }

    var results: [Result<ChatWebSearchResult, Error>] = []
    private(set) var searches: [RecordedSearch] = []

    func enqueue(_ result: ChatWebSearchResult) {
        results.append(.success(result))
    }

    func enqueue(error: Error) {
        results.append(.failure(error))
    }

    func search(request: ChatWebSearchRequest) async throws -> ChatWebSearchResult {
        searches.append(RecordedSearch(request: request))
        guard !results.isEmpty else {
            throw ChatTestError.missingScript("No scripted web search remains")
        }
        return try results.removeFirst().get()
    }
}

enum ChatTestError: LocalizedError {
    case missingScript(String)

    var errorDescription: String? {
        switch self {
        case .missingScript(let message): message
        }
    }
}

@MainActor
final class TestChatGoals: ChatGoalsProviding {
    var dailyCalories: Double
    var dailyProtein: Double
    var dailyCarbs: Double
    var dailyFat: Double

    init(calories: Double = 2_000, protein: Double = 150, carbs: Double = 225, fat: Double = 65) {
        dailyCalories = calories
        dailyProtein = protein
        dailyCarbs = carbs
        dailyFat = fat
    }
}

@MainActor
final class TestChatHealth: ChatHealthDataProviding, NutritionEntryHealthSyncing {
    var activeEnergy = 432.0
    var delayNanoseconds: UInt64 = 0
    var isNutritionSyncEnabled = false
    private(set) var requestedDates: [Date] = []
    private(set) var syncedEntryIDs: [UUID] = []
    private(set) var deletedEntryIDs: [UUID] = []
    private(set) var activeRequestCount = 0
    private(set) var maximumConcurrentRequests = 0

    func fetchActiveEnergy(for date: Date) async -> Double {
        requestedDates.append(date)
        activeRequestCount += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequestCount)
        defer { activeRequestCount -= 1 }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return activeEnergy
    }

    func syncNutritionEntry(_ entry: NutritionEntry, in modelContext: ModelContext) async {
        syncedEntryIDs.append(entry.id)
    }

    func deleteNutritionSamples(forEntryID entryID: UUID) async {
        deletedEntryIDs.append(entryID)
    }

    func resetNutritionMutations() {
        syncedEntryIDs = []
        deletedEntryIDs = []
    }
}

@MainActor
final class StubChatURLFetcher: ChatURLFetching {
    struct Response {
        let data: Data
        let response: URLResponse
    }

    var responses: [URL: Result<Response, Error>] = [:]
    private(set) var requestedURLs: [URL] = []

    func register(
        url: URL,
        data: Data,
        mimeType: String,
        statusCode: Int = 200,
        finalURL: URL? = nil
    ) {
        let response = HTTPURLResponse(
            url: finalURL ?? url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": mimeType]
        )!
        responses[url] = .success(Response(data: data, response: response))
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        requestedURLs.append(url)
        guard let result = responses[url] else {
            throw ChatTestError.missingScript("No URL response registered for \(url.absoluteString)")
        }
        let value = try result.get()
        return (value.data, value.response)
    }
}

@MainActor
final class TestPermissionDecider {
    var decisions: [ChatPermissionDecision] = [.approved]
    private(set) var requests: [ChatPermissionRequest] = []

    func decide(_ request: ChatPermissionRequest) async -> ChatPermissionDecision {
        requests.append(request)
        return decisions.isEmpty ? .approved : decisions.removeFirst()
    }
}

@MainActor
final class RecordingAIDiagnosticSink: AIDiagnosticWriting {
    private(set) var events: [AIDiagnosticEvent] = []

    func recordDiagnostic(_ event: AIDiagnosticEvent) {
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            events.append(event)
        }
    }
}

@MainActor
final class ChatTestHarness {
    let container: ModelContainer
    let context: ModelContext
    let nutritionStore: NutritionStore
    let goals: TestChatGoals
    let health: TestChatHealth
    let proxy: ScriptedChatModelProxy
    let research: ScriptedChatWebSearchProvider
    let fetcher: StubChatURLFetcher
    let permissions: TestPermissionDecider
    let diagnostics: RecordingAIDiagnosticSink
    let service: ChatService

    init(
        provider: AssistantProvider = .gemini,
        apiKey: String? = "test-api-key",
        primary: String = "test-primary",
        fallback: String = "test-fallback",
        contextBudget: ChatContextBudget = .balanced,
        deadlinePolicy: ChatDeadlinePolicy = .fast,
        retryPolicy: ChatRetryPolicy = .fast,
        monotonicClock: (any ChatMonotonicClock)? = nil,
        modelCatalog: RuntimeModelCatalog? = nil,
        healthSyncEnabled: Bool = false
    ) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: NutritionEntry.self,
            DailyLog.self,
            SavedFood.self,
            GeminiScanLog.self,
            GeminiCostAccumulator.self,
            ChatThread.self,
            ChatMessage.self,
            ChatAttachment.self,
            ChatContextCheckpoint.self,
            ChatSourceArtifact.self,
            ChatAgentRun.self,
            ChatWriteExecutionRecord.self,
            ChatDiagnosticSpan.self,
            ChatUsageDailyAggregate.self,
            configurations: configuration
        )
        context = container.mainContext
        goals = TestChatGoals()
        let testHealth = TestChatHealth()
        testHealth.isNutritionSyncEnabled = healthSyncEnabled
        health = testHealth
        nutritionStore = NutritionStore(
            modelContext: context,
            healthSyncer: testHealth,
            isHealthSyncEnabled: { testHealth.isNutritionSyncEnabled }
        )
        proxy = ScriptedChatModelProxy()
        research = ScriptedChatWebSearchProvider()
        fetcher = StubChatURLFetcher()
        permissions = TestPermissionDecider()
        diagnostics = RecordingAIDiagnosticSink()

        let proxy = self.proxy
        let research = self.research
        let permissions = self.permissions
        service = ChatService(
            modelContext: context,
            nutritionStore: nutritionStore,
            userGoals: goals,
            healthKitService: health,
            diagnosticSink: diagnostics,
            modelProxyFactory: { selection in
                proxy.configure(for: selection, apiKey: apiKey ?? "")
                return proxy
            },
            webSearchProviderFactory: { _ in research },
            apiKeyProvider: { _ in apiKey },
            requestConfigProvider: { _ in
                ChatRequestConfig(
                    primary: AssistantModelSelection(
                        descriptor: ChatModelCatalog.descriptor(provider: provider, model: primary),
                        endpoint: provider == .azureOpenAI
                            ? URL(string: "https://test.openai.azure.com/openai/v1")
                            : nil,
                        routingMode: .automatic
                    ),
                    fallback: AssistantModelSelection(
                        descriptor: ChatModelCatalog.descriptor(provider: provider, model: fallback),
                        endpoint: provider == .azureOpenAI
                            ? URL(string: "https://test.openai.azure.com/openai/v1")
                            : nil,
                        routingMode: .automatic
                    )
                )
            },
            contextBudgetProvider: { contextBudget },
            urlFetcher: fetcher,
            deadlinePolicy: deadlinePolicy,
            retryPolicy: retryPolicy,
            monotonicClock: monotonicClock,
            jitterUnitProvider: { 0 },
            permissionDecisionProvider: { request in await permissions.decide(request) },
            modelCatalog: modelCatalog
        )
    }

    func makeThread(title: String = "") -> ChatThread {
        let thread = ChatThread(title: title)
        context.insert(thread)
        return thread
    }

    func replacementService(
        provider: AssistantProvider,
        primary: String,
        fallback: String = "replacement-fallback",
        contextBudget: ChatContextBudget = .balanced
    ) -> ChatService {
        let proxy = self.proxy
        let research = self.research
        let permissions = self.permissions
        return ChatService(
            modelContext: context,
            nutritionStore: nutritionStore,
            userGoals: goals,
            healthKitService: health,
            diagnosticSink: diagnostics,
            modelProxyFactory: { selection in
                proxy.configure(for: selection, apiKey: "replacement-key")
                return proxy
            },
            webSearchProviderFactory: { _ in research },
            apiKeyProvider: { _ in "replacement-key" },
            requestConfigProvider: { _ in
                ChatRequestConfig(
                    primary: AssistantModelSelection(
                        descriptor: ChatModelCatalog.descriptor(provider: provider, model: primary),
                        endpoint: nil,
                        routingMode: .automatic
                    ),
                    fallback: AssistantModelSelection(
                        descriptor: ChatModelCatalog.descriptor(provider: provider, model: fallback),
                        endpoint: nil,
                        routingMode: .automatic
                    )
                )
            },
            contextBudgetProvider: { contextBudget },
            urlFetcher: fetcher,
            permissionDecisionProvider: { request in
                await permissions.decide(request)
            }
        )
    }

    func insertMessage(_ role: ChatRole, text: String, into thread: ChatThread, timestamp: Date = .now) -> ChatMessage {
        let message = ChatMessage(role: role, text: text, timestamp: timestamp)
        message.thread = thread
        context.insert(message)
        thread.messages?.append(message)
        return message
    }

    func enqueueToolCall(
        _ name: String,
        args: JSONValue = .object([:]),
        callID: String = UUID().uuidString,
        modelTurnID: String = UUID().uuidString,
        modelTurnIndex: Int = 0,
        thoughtSignature: String? = nil
    ) {
        proxy.enqueue(ChatModelTurn(calls: [ChatModelCall(
            callID: callID,
            thoughtSignature: thoughtSignature,
            modelTurnID: modelTurnID,
            modelTurnIndex: modelTurnIndex,
            name: name,
            args: args
        )]))
        proxy.enqueue(ChatModelTurn(text: "Done"))
    }

    @discardableResult
    func runTool(
        _ name: String,
        args: JSONValue = .object([:]),
        permission: ChatPermissionDecision = .approved
    ) async -> ChatToolRecord? {
        permissions.decisions = [permission]
        enqueueToolCall(name, args: args)
        let thread = makeThread()
        await service.send("Exercise \(name)", in: thread)
        return thread.safeMessages.compactMap(\.toolRecord).last
    }
}
