// OpenFoodJournal — Provider-Neutral Assistant Model Proxy
// Keeps the agent loop and its tests independent from Gemini/OpenRouter wire
// formats. Provider adapters translate the shared transcript at the edge.
// AGPL-3.0 License

import Foundation

// MARK: - Provider-neutral contract

nonisolated struct ChatModelAttachment: Equatable, Sendable {
    let data: Data
    let mimeType: String
    let filename: String
}

nonisolated struct ChatModelCall: Codable, Equatable, Sendable {
    let callID: String
    let thoughtSignature: String?
    let modelTurnID: String
    let modelTurnIndex: Int
    let name: String
    let args: JSONValue
}

nonisolated struct ChatModelResponse: Equatable, Sendable {
    let callID: String
    let name: String
    let response: JSONValue
}

/// Opaque provider state that must be replayed verbatim in stateless requests.
/// Gemini thought signatures remain on `ChatModelCall` for legacy records;
/// Azure encrypted reasoning and future provider items use this envelope.
nonisolated struct ChatProviderContinuation: Codable, Equatable, Sendable {
    let providerID: String
    let modelTurnID: String
    let ordinal: Int
    let kind: String
    let payload: JSONValue
}

nonisolated struct ChatSourceCitation: Codable, Equatable, Sendable {
    let url: String
    let title: String?
    let startIndex: Int?
    let endIndex: Int?
}

nonisolated enum ChatModelPart: Equatable, Sendable {
    case text(String)
    case attachment(ChatModelAttachment)
    case providerContinuation(ChatProviderContinuation)
    case functionCall(ChatModelCall)
    case functionResponse(ChatModelResponse)
}

nonisolated struct ChatModelMessage: Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case user
        case model
    }

    let role: Role
    let parts: [ChatModelPart]
}

nonisolated struct ChatModelTool: Equatable, Sendable {
    let name: String
    let description: String
    let parameters: JSONValue?
}

nonisolated struct ChatModelRequest: Equatable, Sendable {
    let systemPrompt: String
    let messages: [ChatModelMessage]
    let tools: [ChatModelTool]
}

nonisolated struct ChatTokenUsage: Equatable, Sendable {
    var input = 0
    var cachedInput = 0
    var output = 0
    var thinking = 0
}

nonisolated struct ChatTransportMetrics: Equatable, Sendable {
    var dnsMs: Int? = nil
    var connectionMs: Int? = nil
    var tlsMs: Int? = nil
    var uploadMs: Int? = nil
    var serverWaitMs: Int? = nil
}

/// Normalized provider activity. `providerEvent` is emitted only for genuine
/// decoded provider frames, so deadline resets and visible progress never rely
/// on fabricated thinking or local timers pretending to be model output.
nonisolated enum ChatModelStreamEvent: Equatable, Sendable {
    case encodingStarted
    case requestEncoded(byteCount: Int)
    case responseHeaders(statusCode: Int, requestID: String?, retryAfter: TimeInterval?)
    case providerEvent(kind: String)
    case reasoningSummary(String)
    case visibleText(String)
    case functionCall(ChatModelCall)
    case usage(ChatTokenUsage)
    case transportMetrics(ChatTransportMetrics)
    case completed
}

nonisolated struct ChatModelTurn: Equatable, Sendable {
    var text = ""
    var textOrdinal: Int? = nil
    var calls: [ChatModelCall] = []
    var continuations: [ChatProviderContinuation] = []
    var citations: [ChatSourceCitation] = []
    var usage: ChatTokenUsage?
    var providerRequestID: String?
    var providerID: String?
    var modelID: String?
    /// Concrete provider-reported model/version. This can differ from a
    /// requested alias or an Azure deployment name.
    var resolvedModelID: String?
}

nonisolated struct ChatWebSearchResult: Equatable, Sendable {
    let text: String
    let usage: ChatTokenUsage?
    var citations: [ChatSourceCitation] = []
    var providerRequestID: String? = nil
    var providerID: String? = nil
    var modelID: String? = nil
    var durationMs: Int? = nil
    var creditsUsed: Int? = nil
    var sources: [ChatWebSearchSource] = []
    var estimatedCostUSD: Double? = nil
    var pricingSource: String? = nil
}

nonisolated struct ChatWebSearchSource: Equatable, Sendable {
    let url: String
    let title: String?
    let content: String?
    let score: Double?
}

nonisolated struct ChatWebSearchRequest: Equatable, Sendable {
    let objective: String
    let searchQueries: [String]
    let sessionID: String?
    let clientModel: String?

    init(
        objective: String,
        searchQueries: [String] = [],
        sessionID: String? = nil,
        clientModel: String? = nil
    ) {
        self.objective = objective
        self.searchQueries = searchQueries
        self.sessionID = sessionID
        self.clientModel = clientModel
    }
}

/// Research is a separate capability from conversation generation. ChatService
/// only sees this normalized surface, so Tavily and future search services can
/// be used by every Assistant model without duplicating agent-loop code.
@MainActor
protocol ChatWebSearchProviding: AnyObject {
    func search(request: ChatWebSearchRequest) async throws -> ChatWebSearchResult
}

extension ChatWebSearchProviding {
    func search(query: String) async throws -> ChatWebSearchResult {
        try await search(request: ChatWebSearchRequest(
            objective: query,
            searchQueries: [query]
        ))
    }
}

/// Adapts the existing provider-native Gemini/OpenRouter/Azure search methods
/// to the independent research contract for backward compatibility.
@MainActor
final class ModelProviderChatWebSearchProvider: ChatWebSearchProviding {
    private let searcher: any ChatNativeWebSearching
    private let descriptor: ChatModelDescriptor

    init(searcher: any ChatNativeWebSearching, descriptor: ChatModelDescriptor) {
        self.searcher = searcher
        self.descriptor = descriptor
    }

    func search(request: ChatWebSearchRequest) async throws -> ChatWebSearchResult {
        let startedAt = ContinuousClock.now
        let queryText = request.searchQueries.isEmpty
            ? request.objective
            : request.searchQueries.joined(separator: ", ")
        var result = try await searcher.searchWeb(
            prompt: "Search the web and answer concisely. Include source URLs. Objective: \(request.objective) Queries: \(queryText)"
        )
        let elapsed = startedAt.duration(to: .now).components
        result.providerID = result.providerID ?? descriptor.provider.rawValue
        result.modelID = result.modelID ?? descriptor.deploymentIdentifier
        result.durationMs = Int(
            elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        )
        return result
    }
}

/// Direct Tavily Search API adapter. It requests structured results rather than
/// a second generated answer; the selected Assistant model synthesizes the
/// returned evidence in the normal tool loop.
@MainActor
final class TavilyChatWebSearchProvider: ChatWebSearchProviding {
    static let searchURL = URL(string: "https://api.tavily.com/search")!
    static let usageURL = URL(string: "https://api.tavily.com/usage")!

    private let apiKey: String
    private let depth: TavilySearchDepth
    private let session: URLSession
    private let maxResults: Int

    init(
        apiKey: String,
        depth: TavilySearchDepth = .fast,
        session: URLSession = .shared,
        maxResults: Int = 5
    ) {
        self.apiKey = apiKey
        self.depth = depth
        self.session = session
        self.maxResults = min(max(1, maxResults), 10)
    }

    func search(request searchRequest: ChatWebSearchRequest) async throws -> ChatWebSearchResult {
        let trimmed = searchRequest.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatError.invalidResponse }

        var request = URLRequest(url: Self.searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(TavilySearchRequest(
            query: trimmed,
            searchDepth: depth.rawValue,
            includeAnswer: false,
            includeRawContent: false,
            includeImages: false,
            maxResults: maxResults
        ))

        let startedAt = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw ChatError.cancelled
        } catch {
            throw ChatError.networkError(error)
        }
        let elapsed = startedAt.duration(to: .now).components
        let measuredDurationMs = Int(
            elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        )

        guard let http = response as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(TavilyErrorEnvelope.self, from: data))?.detail
                ?? "Tavily search failed"
            throw ChatError.serverError(http.statusCode, message)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload: TavilySearchResponse
        do {
            payload = try decoder.decode(TavilySearchResponse.self, from: data)
        } catch {
            throw ChatError.invalidResponse
        }

        let sources = payload.results.map {
            ChatWebSearchSource(url: $0.url, title: $0.title, content: $0.content, score: $0.score)
        }
        let evidence = payload.results.enumerated().map { index, result in
            let title = result.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let heading = title?.isEmpty == false ? title! : result.url
            let snippet = result.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "[\(index + 1)] \(heading)\nURL: \(result.url)\n\(snippet)"
        }.joined(separator: "\n\n")
        let text: String
        if let answer = payload.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            text = evidence.isEmpty ? answer : "\(answer)\n\nSources:\n\(evidence)"
        } else {
            text = evidence
        }

        return ChatWebSearchResult(
            text: text,
            usage: nil,
            citations: payload.results.map {
                ChatSourceCitation(url: $0.url, title: $0.title, startIndex: nil, endIndex: nil)
            },
            providerRequestID: payload.requestId,
            providerID: AssistantResearchProvider.tavily.rawValue,
            modelID: "search-\(depth.rawValue)",
            durationMs: payload.responseTime.map { Int(($0 * 1_000).rounded()) } ?? measuredDurationMs,
            creditsUsed: payload.usage?.credits,
            sources: sources
        )
    }

    /// A zero-search connection check. The response body is deliberately not
    /// retained because account usage is not needed by the conversation.
    func testConnection() async throws {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw ChatError.cancelled
        } catch {
            throw ChatError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(TavilyErrorEnvelope.self, from: data))?.detail
                ?? "Tavily connection failed"
            throw ChatError.serverError(http.statusCode, message)
        }
    }
}

private struct TavilySearchRequest: Encodable {
    let query: String
    let searchDepth: String
    let includeAnswer: Bool
    let includeRawContent: Bool
    let includeImages: Bool
    let maxResults: Int
}

private struct TavilySearchResponse: Decodable {
    struct Result: Decodable {
        let title: String?
        let url: String
        let content: String?
        let score: Double?
    }

    struct Usage: Decodable {
        let credits: Int?
    }

    let answer: String?
    let results: [Result]
    let responseTime: Double?
    let usage: Usage?
    let requestId: String?
}

private struct TavilyErrorEnvelope: Decodable {
    let detail: String?
}

/// Parallel returns longer, objective-focused excerpts and accepts multiple
/// keyword queries in one request. This remains a pure research adapter; it
/// does not become the conversation model or bypass durable source storage.
@MainActor
final class ParallelChatWebSearchProvider: ChatWebSearchProviding {
    static let searchURL = URL(string: "https://api.parallel.ai/v1/search")!

    private let apiKey: String
    private let mode: ParallelSearchMode
    private let session: URLSession

    init(
        apiKey: String,
        mode: ParallelSearchMode = .basic,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.mode = mode
        self.session = session
    }

    func search(request searchRequest: ChatWebSearchRequest) async throws -> ChatWebSearchResult {
        let objective = searchRequest.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        var queries = searchRequest.searchQueries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if queries.isEmpty, !objective.isEmpty { queries = [objective] }
        queries = Array(queries.prefix(5))
        guard !queries.isEmpty else { throw ChatError.invalidResponse }

        var request = URLRequest(url: Self.searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(ParallelSearchRequest(
            searchQueries: queries,
            objective: objective.isEmpty ? nil : objective,
            mode: mode.rawValue,
            maxCharsTotal: 12_000,
            sessionID: searchRequest.sessionID,
            clientModel: searchRequest.clientModel
        ))

        let startedAt = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw ChatError.cancelled
        } catch {
            throw ChatError.networkError(error)
        }
        let elapsed = startedAt.duration(to: .now).components
        let durationMs = Int(
            elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        )

        guard let http = response as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ParallelErrorEnvelope.self, from: data))?.error.message
                ?? "Parallel search failed"
            throw ChatError.serverError(http.statusCode, message)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload: ParallelSearchResponse
        do {
            payload = try decoder.decode(ParallelSearchResponse.self, from: data)
        } catch {
            throw ChatError.invalidResponse
        }

        let sources = payload.results.map { result in
            ChatWebSearchSource(
                url: result.url,
                title: result.title,
                content: result.excerpts.joined(separator: "\n\n"),
                score: nil
            )
        }
        let evidence = payload.results.enumerated().map { index, result in
            let title = result.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let heading = (title?.isEmpty == false ? title : nil) ?? result.url
            let dateLine = result.publishDate.map { "Published: \($0)\n" } ?? ""
            let excerpts = result.excerpts.joined(separator: "\n")
            return "[\(index + 1)] \(heading)\nURL: \(result.url)\n\(dateLine)\(excerpts)"
        }.joined(separator: "\n\n")

        return ChatWebSearchResult(
            text: evidence,
            usage: nil,
            citations: payload.results.map {
                ChatSourceCitation(url: $0.url, title: $0.title, startIndex: nil, endIndex: nil)
            },
            providerRequestID: payload.searchId,
            providerID: AssistantResearchProvider.parallel.rawValue,
            modelID: "search-\(mode.rawValue)",
            durationMs: durationMs,
            sources: sources,
            estimatedCostUSD: Self.estimatedRequestCostUSD(for: mode),
            pricingSource: "Parallel Search public pricing verified 2026-07-21"
        )
    }

    /// Parallel does not document a free credential-health endpoint. This uses
    /// one Turbo search, and the Settings UI labels it accordingly.
    func testSearch() async throws {
        _ = try await search(request: ChatWebSearchRequest(
            objective: "Verify that this Parallel Search API key can execute a request.",
            searchQueries: ["Parallel API connection test"]
        ))
    }

    static func estimatedRequestCostUSD(for mode: ParallelSearchMode) -> Double {
        switch mode {
        case .turbo: 0.001
        case .basic, .advanced: 0.005
        }
    }
}

private struct ParallelSearchRequest: Encodable {
    let searchQueries: [String]
    let objective: String?
    let mode: String
    let maxCharsTotal: Int
    let sessionID: String?
    let clientModel: String?
}

private struct ParallelSearchResponse: Decodable {
    struct Result: Decodable {
        let url: String
        let title: String?
        let publishDate: String?
        let excerpts: [String]
    }

    let searchId: String
    let results: [Result]
    let sessionId: String
}

private struct ParallelErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}

// MARK: - Exa Search adapter

/// Exa is another provider-neutral research backend. It returns source text
/// and citations to the existing agent loop; it never becomes a second chat
/// model and never receives journal history or attachment contents.
@MainActor
final class ExaChatWebSearchProvider: ChatWebSearchProviding {
    static let searchURL = URL(string: "https://api.exa.ai/search")!

    private let apiKey: String
    private let session: URLSession
    private let maxResults: Int

    init(apiKey: String, session: URLSession = .shared, maxResults: Int = 5) {
        self.apiKey = apiKey
        self.session = session
        self.maxResults = min(max(1, maxResults), 10)
    }

    func search(request searchRequest: ChatWebSearchRequest) async throws -> ChatWebSearchResult {
        let queryParts = ([searchRequest.objective] + searchRequest.searchQueries)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { unique, value in
                if !unique.contains(value) { unique.append(value) }
            }
        let query = queryParts
            .joined(separator: " ")
        guard !query.isEmpty else { throw ChatError.invalidResponse }

        var request = URLRequest(url: Self.searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONEncoder().encode(ExaSearchRequest(
            query: query,
            type: "auto",
            numResults: maxResults,
            contents: .init(text: true, highlights: true)
        ))

        let startedAt = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw ChatError.cancelled
        } catch {
            throw ChatError.networkError(error)
        }
        let elapsed = startedAt.duration(to: .now).components
        let measuredDurationMs = Int(
            elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        )
        guard let http = response as? HTTPURLResponse else { throw ChatError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
            let message = decoded?["error"]?.stringValue
                ?? decoded?["message"]?.stringValue
                ?? "Exa search failed"
            throw ChatError.serverError(http.statusCode, message)
        }

        let payload: ExaSearchResponse
        do {
            payload = try JSONDecoder().decode(ExaSearchResponse.self, from: data)
        } catch {
            throw ChatError.invalidResponse
        }
        let sources = payload.results.map { result in
            let content = result.text ?? result.highlights?.joined(separator: "\n")
            return ChatWebSearchSource(
                url: result.url,
                title: result.title,
                content: content,
                score: result.score
            )
        }
        let evidence = sources.enumerated().map { index, source in
            "[\(index + 1)] \(source.title ?? source.url)\nURL: \(source.url)\n\(source.content ?? "")"
        }.joined(separator: "\n\n")
        return ChatWebSearchResult(
            text: evidence,
            usage: nil,
            citations: sources.map {
                ChatSourceCitation(url: $0.url, title: $0.title, startIndex: nil, endIndex: nil)
            },
            providerRequestID: payload.requestId ?? http.value(forHTTPHeaderField: "x-request-id"),
            providerID: AssistantResearchProvider.exa.rawValue,
            modelID: "exa-auto",
            durationMs: payload.searchTime.map { Int($0.rounded()) } ?? measuredDurationMs,
            sources: sources,
            estimatedCostUSD: payload.costDollars?.total,
            pricingSource: payload.costDollars == nil ? nil : "Exa API reported request cost"
        )
    }

    func testSearch() async throws {
        _ = try await search(request: ChatWebSearchRequest(
            objective: "OpenFoodJournal Exa API connection test",
            searchQueries: ["OpenFoodJournal"]
        ))
    }
}

private struct ExaSearchRequest: Encodable {
    struct Contents: Encodable {
        let text: Bool
        let highlights: Bool
    }
    let query: String
    let type: String
    let numResults: Int
    let contents: Contents
}

private struct ExaSearchResponse: Decodable {
    struct Result: Decodable {
        let title: String?
        let url: String
        let text: String?
        let highlights: [String]?
        let score: Double?
    }
    struct Cost: Decodable { let total: Double? }
    let requestId: String?
    let searchTime: Double?
    let costDollars: Cost?
    let results: [Result]
}

/// A complete, configured provider target. Authentication, deployment names,
/// endpoint selection, and routing never leak into the shared agent loop.
nonisolated struct ChatProxyConfiguration: Equatable, Sendable {
    let descriptor: ChatModelDescriptor
    let apiKey: String
    let endpoint: URL?
    let routingMode: OpenRouterRoutingMode

    init(
        descriptor: ChatModelDescriptor,
        apiKey: String,
        endpoint: URL? = nil,
        routingMode: OpenRouterRoutingMode = .automatic
    ) {
        self.descriptor = descriptor
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.routingMode = routingMode
    }
}

/// The only LLM-facing interface used by ChatService. Tests provide a scripted
/// proxy; production selects a thin Gemini or OpenRouter adapter.
@MainActor
protocol ChatModelProxy: AnyObject {
    var descriptor: ChatModelDescriptor { get }

    func streamTurn(
        request: ChatModelRequest,
        onEvent: @escaping @MainActor (ChatModelStreamEvent) -> Void
    ) async throws -> ChatModelTurn
}

extension ChatModelProxy {
    /// Source-compatible convenience for older call sites while the app-level
    /// coordinator consumes the richer event stream.
    func streamTurn(
        request: ChatModelRequest,
        onTextUpdate: @escaping @MainActor (String) -> Void
    ) async throws -> ChatModelTurn {
        try await streamTurn(request: request) { event in
            if case .visibleText(let text) = event { onTextUpdate(text) }
        }
    }
}

/// Optional capability implemented only by model adapters that expose native
/// search. New conversation providers do not need this when Tavily is used.
@MainActor
protocol ChatNativeWebSearching: AnyObject {
    func searchWeb(
        prompt: String
    ) async throws -> ChatWebSearchResult
}

#if DEBUG
/// Deterministic, network-free adapter used only by the UI-test launch mode.
/// Production never selects it; UI tests can exercise streaming controls,
/// context notices, citations, and recovery without provider credentials.
@MainActor
final class AssistantUITestModelProxy: ChatModelProxy, ChatNativeWebSearching {
    let descriptor: ChatModelDescriptor

    init(descriptor: ChatModelDescriptor) {
        self.descriptor = descriptor
    }

    func streamTurn(
        request: ChatModelRequest,
        onEvent: @escaping @MainActor (ChatModelStreamEvent) -> Void
    ) async throws -> ChatModelTurn {
        onEvent(.encodingStarted)
        onEvent(.requestEncoded(byteCount: 0))
        if request.systemPrompt.localizedCaseInsensitiveContains("portable provider-neutral state") {
            onEvent(.providerEvent(kind: "scripted.checkpoint"))
            onEvent(.completed)
            return ChatModelTurn(text: "not valid checkpoint json")
        }
        let shouldBlock = request.messages.contains { message in
            message.parts.contains { part in
                if case .text(let text) = part { return text.contains("UI_TEST_BLOCK") }
                return false
            }
        }
        if shouldBlock {
            onEvent(.providerEvent(kind: "scripted.text"))
            onEvent(.visibleText("Working…"))
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        onEvent(.providerEvent(kind: "scripted.text"))
        onEvent(.visibleText("UI test response with a durable source."))
        let usage = ChatTokenUsage(input: 1_234, output: 24, thinking: 5)
        onEvent(.usage(usage))
        onEvent(.completed)
        return ChatModelTurn(
            text: "UI test response with a durable source.",
            textOrdinal: 0,
            citations: [ChatSourceCitation(
                url: "https://example.com/ui-test-source",
                title: "Test source",
                startIndex: 0,
                endIndex: 14
            )],
            usage: usage,
            providerRequestID: "ui-test-request"
        )
    }

    func searchWeb(prompt: String) async throws -> ChatWebSearchResult {
        ChatWebSearchResult(
            text: "UI test research",
            usage: ChatTokenUsage(input: 20, output: 8, thinking: 0),
            citations: [ChatSourceCitation(
                url: "https://example.com/ui-test-search",
                title: "Test search source",
                startIndex: 0,
                endIndex: 8
            )],
            providerRequestID: "ui-test-search-request"
        )
    }
}
#endif

@MainActor
enum ConfiguredChatModelProxyFactory {
    static func make(
        selection: AssistantModelSelection,
        session: URLSession,
        apiKeyProvider: (AssistantProvider) -> String?,
        azureHostResolver: any ChatHostResolving = SystemChatHostResolver()
    ) throws -> any ChatModelProxy {
        guard !selection.descriptor.deploymentIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatError.serverError(
                400,
                "Configure the \(selection.descriptor.displayName) deployment name."
            )
        }
        let endpoint: URL?
        if selection.provider == .azureOpenAI {
            guard let candidate = selection.endpoint else {
                throw ChatError.serverError(400, "Configure an Azure OpenAI resource endpoint.")
            }
            let normalized = try AzureOpenAIEndpoint.normalizedBaseURL(from: candidate.absoluteString)
            try AzureOpenAIEndpoint.validatePublicDestination(
                normalized,
                resolver: azureHostResolver
            )
            endpoint = normalized
        } else if let selectedEndpoint = selection.endpoint {
            endpoint = selectedEndpoint
        } else {
            endpoint = switch selection.provider {
            case .openAI: URL(string: "https://api.openai.com/v1")
            case .anthropic: URL(string: "https://api.anthropic.com/v1")
            case .museSpark: URL(string: "https://api.meta.ai/v1")
            case .gemini, .openRouter, .azureOpenAI, .openAICompatible: nil
            }
        }
        // A custom OpenAI-compatible target has no default host to fall back
        // to — an unconfigured or malformed base URL must fail before any
        // credential is attached.
        if selection.provider == .openAICompatible, endpoint == nil {
            throw ChatError.serverError(400, "Configure the OpenAI-compatible base URL in Settings.")
        }
        // Do not retrieve or attach credentials until a user-entered Azure
        // destination has passed structure, suffix, and public-address checks.
        guard let apiKey = apiKeyProvider(selection.provider), !apiKey.isEmpty else {
            throw ChatError.noAPIKey(selection.provider.displayName)
        }
        let configuration = ChatProxyConfiguration(
            descriptor: selection.descriptor,
            apiKey: apiKey,
            endpoint: endpoint,
            routingMode: selection.routingMode
        )
        switch selection.provider {
        case .gemini:
            return GeminiChatModelProxy(configuration: configuration, session: session)
        case .openRouter:
            return OpenRouterChatModelProxy(configuration: configuration, session: session)
        case .azureOpenAI:
            return AzureOpenAIChatModelProxy(configuration: configuration, session: session)
        case .openAI:
            return OpenAIResponsesChatModelProxy(configuration: configuration, session: session)
        case .anthropic:
            return AnthropicChatModelProxy(configuration: configuration, session: session)
        case .museSpark, .openAICompatible:
            return MuseSparkChatModelProxy(configuration: configuration, session: session)
        }
    }
}

@MainActor
protocol ChatURLFetching: AnyObject {
    func data(from url: URL) async throws -> (Data, URLResponse)
}

extension URLSession: ChatURLFetching {}

@MainActor
protocol ChatGoalsProviding: AnyObject {
    var dailyCalories: Double { get set }
    var dailyProtein: Double { get set }
    var dailyCarbs: Double { get set }
    var dailyFat: Double { get set }
}

extension UserGoals: ChatGoalsProviding {}

@MainActor
protocol ChatHealthDataProviding: AnyObject {
    func fetchActiveEnergy(for date: Date) async -> Double
}

extension HealthKitService: ChatHealthDataProviding {}

// MARK: - Gemini adapter

@MainActor
final class GeminiChatModelProxy: ChatModelProxy, ChatNativeWebSearching {
    private let session: URLSession
    private let configuration: ChatProxyConfiguration
    private static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    var descriptor: ChatModelDescriptor { configuration.descriptor }

    init(configuration: ChatProxyConfiguration, session: URLSession = .shared) {
        precondition(configuration.descriptor.provider == .gemini)
        self.configuration = configuration
        self.session = session
    }

    func streamTurn(
        request: ChatModelRequest,
        onEvent: @escaping @MainActor (ChatModelStreamEvent) -> Void
    ) async throws -> ChatModelTurn {
        let model = descriptor.deploymentIdentifier
        guard let url = URL(string: "\(Self.baseURL)/\(model):streamGenerateContent?alt=sse") else {
            throw ChatError.invalidResponse
        }

        onEvent(.encodingStarted)
        let encodedRequest = try Self.encodedTurnRequest(request)
        onEvent(.requestEncoded(byteCount: encodedRequest.count))
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = encodedRequest

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            let delegate = ChatStreamTaskDelegate { metrics in
                Task { @MainActor in onEvent(.transportMetrics(metrics)) }
            }
            (bytes, response) = try await session.bytes(for: urlRequest, delegate: delegate)
        } catch {
            throw ChatError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }
        onEvent(.responseHeaders(
            statusCode: httpResponse.statusCode,
            requestID: Self.requestID(from: httpResponse),
            retryAfter: Self.retryAfter(from: httpResponse)
        ))
        guard (200..<300).contains(httpResponse.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let envelope = try? JSONDecoder().decode(GeminiAPIErrorEnvelope.self, from: errorData)
            throw ChatError.serverError(
                httpResponse.statusCode,
                envelope?.error?.message ?? "HTTP \(httpResponse.statusCode)"
            )
        }

        var turn = ChatModelTurn()
        let modelTurnID = UUID().uuidString
        let decoder = JSONDecoder()
        var nextOutputOrdinal = 0

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(GeminiStreamChunk.self, from: data)
            else { continue }
            onEvent(.providerEvent(kind: "gemini.chunk"))
            if let modelVersion = chunk.modelVersion, !modelVersion.isEmpty {
                turn.resolvedModelID = modelVersion
            }

            if let usage = chunk.usageMetadata {
                turn.usage = ChatTokenUsage(
                    input: usage.promptTokenCount ?? 0,
                    output: usage.candidatesTokenCount ?? 0,
                    thinking: usage.thoughtsTokenCount ?? 0
                )
                if let usage = turn.usage { onEvent(.usage(usage)) }
            }

            for part in chunk.candidates?.first?.content?.parts ?? [] {
                if let call = part.functionCall {
                    let callOrdinal = nextOutputOrdinal
                    nextOutputOrdinal += 1
                    let normalizedCall = ChatModelCall(
                        callID: call.id ?? UUID().uuidString,
                        thoughtSignature: part.thoughtSignature,
                        modelTurnID: modelTurnID,
                        modelTurnIndex: callOrdinal,
                        name: call.name,
                        args: call.args ?? .object([:])
                    )
                    turn.calls.append(normalizedCall)
                    onEvent(.functionCall(normalizedCall))
                } else if part.thought != true, let text = part.text {
                    if turn.textOrdinal == nil {
                        turn.textOrdinal = nextOutputOrdinal
                        nextOutputOrdinal += 1
                    }
                    turn.text += text
                    onEvent(.visibleText(turn.text))
                }
            }
        }

        onEvent(.completed)
        return turn
    }

    func searchWeb(
        prompt: String
    ) async throws -> ChatWebSearchResult {
        let model = descriptor.deploymentIdentifier
        guard let url = URL(string: "\(Self.baseURL)/\(model):generateContent") else {
            throw ChatError.invalidResponse
        }
        let body = GeminiChatRequest(
            systemInstruction: .init(parts: [GeminiPart(text: "You are a factual web research helper.")]),
            contents: [GeminiContent(role: "user", parts: [GeminiPart(text: prompt)])],
            tools: [GeminiToolDecl(googleSearch: .init())]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            let envelope = try? JSONDecoder().decode(GeminiAPIErrorEnvelope.self, from: data)
            throw ChatError.serverError(
                (response as? HTTPURLResponse)?.statusCode ?? 0,
                envelope?.error?.message ?? "search failed"
            )
        }

        let decoded = try JSONDecoder().decode(GeminiGenerateResponse.self, from: data)
        let text = (decoded.candidates?.first?.content?.parts ?? [])
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined()
        let usage = decoded.usageMetadata.map {
            ChatTokenUsage(
                input: $0.promptTokenCount ?? 0,
                output: $0.candidatesTokenCount ?? 0,
                thinking: $0.thoughtsTokenCount ?? 0
            )
        }
        return ChatWebSearchResult(
            text: text,
            usage: usage,
            providerID: AssistantProvider.gemini.rawValue,
            modelID: decoded.modelVersion ?? descriptor.deploymentIdentifier
        )
    }

    /// Internal so adapter contract tests can validate the edge mapping without
    /// making a live API request.
    static func encodedTurnRequest(_ request: ChatModelRequest) throws -> Data {
        let declarations = request.tools.map {
            GeminiToolDecl.Declaration(
                name: $0.name,
                description: $0.description,
                parameters: $0.parameters.map { ChatToolRegistry.geminiSchema($0) }
            )
        }
        let body = GeminiChatRequest(
            systemInstruction: .init(parts: [GeminiPart(text: request.systemPrompt)]),
            contents: request.messages.map(Self.content),
            tools: [GeminiToolDecl(functionDeclarations: declarations)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    private static func requestID(from response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "x-request-id")
            ?? response.value(forHTTPHeaderField: "x-goog-request-id")
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    }

    private static func content(_ message: ChatModelMessage) -> GeminiContent {
        GeminiContent(role: message.role.rawValue, parts: message.parts.compactMap { part in
            switch part {
            case .text(let text):
                return GeminiPart(text: text)
            case .attachment(let attachment):
                return GeminiPart(inlineData: .init(
                    mimeType: attachment.mimeType,
                    data: attachment.data.base64EncodedString()
                ))
            case .providerContinuation:
                // Provider-opaque continuation items are not portable wire
                // payloads. Gemini's portable state is its call signature.
                return nil
            case .functionCall(let call):
                return GeminiPart(
                    functionCall: .init(id: call.callID, name: call.name, args: call.args),
                    thoughtSignature: call.thoughtSignature
                )
            case .functionResponse(let response):
                return GeminiPart(functionResponse: .init(
                    id: response.callID,
                    name: response.name,
                    response: response.response
                ))
            }
        })
    }
}

// MARK: - OpenRouter adapter

@MainActor
final class OpenRouterChatModelProxy: ChatModelProxy, ChatNativeWebSearching {
    private let session: URLSession
    private let configuration: ChatProxyConfiguration
    private static let chatCompletionsURL = "https://openrouter.ai/api/v1/chat/completions"

    var descriptor: ChatModelDescriptor { configuration.descriptor }

    init(configuration: ChatProxyConfiguration, session: URLSession = .shared) {
        precondition(configuration.descriptor.provider == .openRouter)
        self.configuration = configuration
        self.session = session
    }

    func streamTurn(
        request: ChatModelRequest,
        onEvent: @escaping @MainActor (ChatModelStreamEvent) -> Void
    ) async throws -> ChatModelTurn {
        let model = descriptor.deploymentIdentifier
        guard let url = URL(string: Self.chatCompletionsURL) else {
            throw ChatError.invalidResponse
        }

        onEvent(.encodingStarted)
        let encodedRequest = try Self.encodedTurnRequest(
            model: model,
            request: request,
            routingMode: configuration.routingMode
        )
        onEvent(.requestEncoded(byteCount: encodedRequest.count))
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = encodedRequest

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            let delegate = ChatStreamTaskDelegate { metrics in
                Task { @MainActor in onEvent(.transportMetrics(metrics)) }
            }
            (bytes, response) = try await session.bytes(for: urlRequest, delegate: delegate)
        } catch {
            throw ChatError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }
        onEvent(.responseHeaders(
            statusCode: httpResponse.statusCode,
            requestID: httpResponse.value(forHTTPHeaderField: "x-request-id"),
            retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        ))
        guard (200..<300).contains(httpResponse.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let envelope = try? JSONDecoder().decode(ORErrorEnvelope.self, from: errorData)
            throw ChatError.serverError(
                httpResponse.statusCode,
                envelope?.error?.message ?? "HTTP \(httpResponse.statusCode)"
            )
        }

        var turn = ChatModelTurn()
        let modelTurnID = UUID().uuidString
        var callBuffers: [Int: (id: String?, name: String, arguments: String)] = [:]
        let decoder = JSONDecoder()

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(ORStreamChunk.self, from: data)
            else { continue }
            onEvent(.providerEvent(kind: "openrouter.chunk"))
            if let model = chunk.model, !model.isEmpty {
                turn.resolvedModelID = model
            }

            if let usage = chunk.usage {
                turn.usage = ChatTokenUsage(
                    input: usage.promptTokens ?? 0,
                    output: usage.completionTokens ?? 0,
                    thinking: 0
                )
                if let usage = turn.usage { onEvent(.usage(usage)) }
            }

            guard let delta = chunk.choices?.first?.delta else { continue }
            if let content = delta.content, !content.isEmpty {
                if turn.textOrdinal == nil { turn.textOrdinal = 0 }
                turn.text += content
                onEvent(.visibleText(turn.text))
            }
            for fragment in delta.toolCalls ?? [] {
                let index = fragment.index ?? 0
                var buffer = callBuffers[index] ?? (id: nil, name: "", arguments: "")
                if let id = fragment.id { buffer.id = id }
                if let name = fragment.function?.name { buffer.name += name }
                if let arguments = fragment.function?.arguments { buffer.arguments += arguments }
                callBuffers[index] = buffer
            }
        }

        for index in callBuffers.keys.sorted() {
            guard let buffer = callBuffers[index], !buffer.name.isEmpty else { continue }
            let normalizedCall = ChatModelCall(
                callID: buffer.id ?? UUID().uuidString,
                thoughtSignature: nil,
                modelTurnID: modelTurnID,
                modelTurnIndex: index,
                name: buffer.name,
                args: JSONValue.parse(buffer.arguments) ?? .object([:])
            )
            turn.calls.append(normalizedCall)
            onEvent(.functionCall(normalizedCall))
        }
        onEvent(.completed)
        return turn
    }

    func searchWeb(
        prompt: String
    ) async throws -> ChatWebSearchResult {
        let model = descriptor.deploymentIdentifier
        guard let url = URL(string: Self.chatCompletionsURL) else {
            throw ChatError.invalidResponse
        }
        let body = ORChatRequest(
            model: model,
            messages: [
                ORMessage(role: "system", content: .text("You are a factual web research helper.")),
                ORMessage(role: "user", content: .text(prompt)),
            ],
            stream: false,
            provider: .from(configuration.routingMode),
            plugins: [ORPlugin(id: "web")]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            let envelope = try? JSONDecoder().decode(ORErrorEnvelope.self, from: data)
            throw ChatError.serverError(
                (response as? HTTPURLResponse)?.statusCode ?? 0,
                envelope?.error?.message ?? "search failed"
            )
        }

        let decoded = try JSONDecoder().decode(ORNonStreamResponse.self, from: data)
        let usage = decoded.usage.map {
            ChatTokenUsage(
                input: $0.promptTokens ?? 0,
                output: $0.completionTokens ?? 0,
                thinking: 0
            )
        }
        return ChatWebSearchResult(
            text: decoded.choices?.first?.message?.content ?? "",
            usage: usage,
            providerID: AssistantProvider.openRouter.rawValue,
            modelID: decoded.model ?? descriptor.deploymentIdentifier
        )
    }

    static func encodedTurnRequest(
        model: String,
        request: ChatModelRequest,
        routingMode: OpenRouterRoutingMode
    ) throws -> Data {
        let body = ORChatRequest(
            model: model,
            messages: messages(for: request),
            stream: true,
            tools: request.tools.map {
                ORToolDecl(function: .init(
                    name: $0.name,
                    description: $0.description,
                    parameters: $0.parameters
                ))
            },
            provider: .from(routingMode),
            streamOptions: .init(includeUsage: true)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    private static func messages(for request: ChatModelRequest) -> [ORMessage] {
        var messages = [ORMessage(role: "system", content: .text(request.systemPrompt))]
        for message in request.messages {
            let calls = message.parts.compactMap { part -> ChatModelCall? in
                if case .functionCall(let call) = part { return call }
                return nil
            }
            if !calls.isEmpty {
                let text = message.parts.compactMap { part -> String? in
                    if case .text(let text) = part { return text }
                    return nil
                }.joined()
                messages.append(ORMessage(
                    role: "assistant",
                    content: text.isEmpty ? nil : .text(text),
                    toolCalls: calls.map {
                        ORToolCall(
                            id: $0.callID,
                            function: .init(name: $0.name, arguments: $0.args.jsonString)
                        )
                    }
                ))
                continue
            }

            let responses = message.parts.compactMap { part -> ChatModelResponse? in
                if case .functionResponse(let response) = part { return response }
                return nil
            }
            if !responses.isEmpty {
                for response in responses {
                    messages.append(ORMessage(
                        role: "tool",
                        content: .text(response.response.jsonString),
                        toolCallID: response.callID
                    ))
                }
                continue
            }

            let attachments = message.parts.compactMap { part -> ChatModelAttachment? in
                if case .attachment(let attachment) = part { return attachment }
                return nil
            }
            let text = message.parts.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }.joined()

            if attachments.isEmpty {
                guard !text.isEmpty else { continue }
                messages.append(ORMessage(
                    role: message.role == .model ? "assistant" : "user",
                    content: .text(text)
                ))
            } else {
                var parts: [ORPart] = []
                if !text.isEmpty { parts.append(.text(text)) }
                parts.append(contentsOf: attachments.map(Self.part))
                messages.append(ORMessage(role: "user", content: .parts(parts)))
            }
        }
        return messages
    }

    private static func part(_ attachment: ChatModelAttachment) -> ORPart {
        let dataURL = "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
        if attachment.mimeType.hasPrefix("image/") {
            return .imageDataURL(dataURL)
        }
        let filename = attachment.filename.isEmpty ? "document.pdf" : attachment.filename
        return .fileData(filename: filename, dataURL: dataURL)
    }
}

// MARK: - Anthropic Messages adapter

@MainActor
final class AnthropicChatModelProxy: ChatModelProxy {
    private struct ToolBuffer { var id = ""; var name = ""; var arguments = "" }
    private struct ThinkingBuffer { var text = ""; var signature = "" }

    private let configuration: ChatProxyConfiguration
    private let session: URLSession
    var descriptor: ChatModelDescriptor { configuration.descriptor }

    init(configuration: ChatProxyConfiguration, session: URLSession = .shared) {
        precondition(configuration.descriptor.provider == .anthropic)
        precondition(configuration.endpoint != nil)
        self.configuration = configuration
        self.session = session
    }

    func streamTurn(
        request: ChatModelRequest,
        onEvent: @escaping @MainActor (ChatModelStreamEvent) -> Void
    ) async throws -> ChatModelTurn {
        guard let url = configuration.endpoint?.appendingPathComponent("messages") else {
            throw ChatError.invalidResponse
        }
        onEvent(.encodingStarted)
        let body = try Self.encodedTurnRequest(configuration: configuration, request: request)
        onEvent(.requestEncoded(byteCount: body.count))
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = body

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            let delegate = ChatStreamTaskDelegate(rejectRedirects: true) { metrics in
                Task { @MainActor in onEvent(.transportMetrics(metrics)) }
            }
            (bytes, response) = try await session.bytes(for: urlRequest, delegate: delegate)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ChatError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ChatError.invalidResponse }
        let headerRequestID = http.value(forHTTPHeaderField: "request-id")
            ?? http.value(forHTTPHeaderField: "x-request-id")
        onEvent(.responseHeaders(
            statusCode: http.statusCode,
            requestID: headerRequestID,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        ))
        guard (200..<300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let value = try? JSONDecoder().decode(JSONValue.self, from: errorData)
            throw ChatError.serverError(
                http.statusCode,
                value?["error"]?["message"]?.stringValue ?? "Anthropic request failed"
            )
        }

        var turn = ChatModelTurn()
        turn.providerRequestID = headerRequestID
        turn.providerID = AssistantProvider.anthropic.rawValue
        var modelTurnID = UUID().uuidString
        var toolBuffers: [Int: ToolBuffer] = [:]
        var thinkingBuffers: [Int: ThinkingBuffer] = [:]
        var cachedInput = 0
        var uncachedInput = 0
        var output = 0
        let decoder = JSONDecoder()

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? decoder.decode(JSONValue.self, from: data) else { continue }
            let eventType = event["type"]?.stringValue ?? "anthropic.event"
            onEvent(.providerEvent(kind: eventType))
            switch eventType {
            case "message_start":
                if let message = event["message"] {
                    modelTurnID = message["id"]?.stringValue ?? modelTurnID
                    turn.providerRequestID = headerRequestID ?? message["id"]?.stringValue
                    turn.resolvedModelID = message["model"]?.stringValue
                    uncachedInput = Int(message["usage"]?["input_tokens"]?.doubleValue ?? 0)
                    cachedInput = Int(message["usage"]?["cache_read_input_tokens"]?.doubleValue ?? 0)
                        + Int(message["usage"]?["cache_creation_input_tokens"]?.doubleValue ?? 0)
                }
            case "content_block_start":
                let index = Int(event["index"]?.doubleValue ?? 0)
                guard let block = event["content_block"] else { continue }
                switch block["type"]?.stringValue {
                case "text":
                    if turn.textOrdinal == nil { turn.textOrdinal = index }
                    if let text = block["text"]?.stringValue, !text.isEmpty {
                        turn.text += text
                        onEvent(.visibleText(turn.text))
                    }
                case "tool_use":
                    let initialInput = block["input"]
                    let initialArguments = initialInput?.objectValue?.isEmpty == false
                        ? (initialInput?.jsonString ?? "")
                        : ""
                    toolBuffers[index] = ToolBuffer(
                        id: block["id"]?.stringValue ?? UUID().uuidString,
                        name: block["name"]?.stringValue ?? "",
                        arguments: initialArguments
                    )
                case "thinking", "redacted_thinking":
                    thinkingBuffers[index] = ThinkingBuffer(
                        text: block["thinking"]?.stringValue ?? "",
                        signature: block["signature"]?.stringValue ?? ""
                    )
                default: break
                }
            case "content_block_delta":
                let index = Int(event["index"]?.doubleValue ?? 0)
                guard let delta = event["delta"] else { continue }
                switch delta["type"]?.stringValue {
                case "text_delta":
                    if turn.textOrdinal == nil { turn.textOrdinal = index }
                    if let text = delta["text"]?.stringValue {
                        turn.text += text
                        onEvent(.visibleText(turn.text))
                    }
                case "input_json_delta":
                    toolBuffers[index, default: ToolBuffer()].arguments += delta["partial_json"]?.stringValue ?? ""
                case "thinking_delta":
                    thinkingBuffers[index, default: ThinkingBuffer()].text += delta["thinking"]?.stringValue ?? ""
                case "signature_delta":
                    thinkingBuffers[index, default: ThinkingBuffer()].signature += delta["signature"]?.stringValue ?? ""
                default: break
                }
            case "content_block_stop":
                let index = Int(event["index"]?.doubleValue ?? 0)
                if let buffer = toolBuffers.removeValue(forKey: index), !buffer.name.isEmpty {
                    let call = ChatModelCall(
                        callID: buffer.id,
                        thoughtSignature: nil,
                        modelTurnID: modelTurnID,
                        modelTurnIndex: index,
                        name: buffer.name,
                        args: JSONValue.parse(buffer.arguments) ?? .object([:])
                    )
                    turn.calls.append(call)
                    onEvent(.functionCall(call))
                }
                if let buffer = thinkingBuffers.removeValue(forKey: index), !buffer.signature.isEmpty {
                    turn.continuations.append(ChatProviderContinuation(
                        providerID: AssistantProvider.anthropic.rawValue,
                        modelTurnID: modelTurnID,
                        ordinal: index,
                        kind: "thinking.signature",
                        payload: .object([
                            "type": .string("thinking"),
                            "thinking": .string(buffer.text),
                            "signature": .string(buffer.signature),
                        ])
                    ))
                }
            case "message_delta":
                output = Int(event["usage"]?["output_tokens"]?.doubleValue ?? Double(output))
            case "error":
                throw ChatError.serverError(
                    0,
                    event["error"]?["message"]?.stringValue ?? "Anthropic stream failed"
                )
            default: break
            }
        }
        let usage = ChatTokenUsage(
            input: uncachedInput + cachedInput,
            cachedInput: cachedInput,
            output: output,
            thinking: 0
        )
        turn.usage = usage
        onEvent(.usage(usage))
        onEvent(.completed)
        return turn
    }

    static func encodedTurnRequest(
        configuration: ChatProxyConfiguration,
        request: ChatModelRequest
    ) throws -> Data {
        var object: [String: JSONValue] = [
            "model": .string(configuration.descriptor.deploymentIdentifier),
            "max_tokens": .number(Double(min(
                max(1, configuration.descriptor.capabilities.maximumOutputTokens),
                16_384
            ))),
            "system": .string(request.systemPrompt),
            "messages": .array(messages(for: request)),
            "stream": .bool(true),
        ]
        if !request.tools.isEmpty {
            object["tools"] = .array(request.tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.parameters ?? .object(["type": .string("object")]),
                ])
            })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(JSONValue.object(object))
    }

    private static func messages(for request: ChatModelRequest) -> [JSONValue] {
        request.messages.compactMap { message in
            var blocks: [JSONValue] = []
            for part in message.parts {
                switch part {
                case .text(let text):
                    blocks.append(.object(["type": .string("text"), "text": .string(text)]))
                case .attachment(let attachment):
                    let source: JSONValue = .object([
                        "type": .string("base64"),
                        "media_type": .string(attachment.mimeType),
                        "data": .string(attachment.data.base64EncodedString()),
                    ])
                    blocks.append(.object([
                        "type": .string(attachment.mimeType.hasPrefix("image/") ? "image" : "document"),
                        "source": source,
                    ]))
                case .providerContinuation(let continuation):
                    if continuation.providerID == AssistantProvider.anthropic.rawValue {
                        blocks.append(continuation.payload)
                    }
                case .functionCall(let call):
                    blocks.append(.object([
                        "type": .string("tool_use"),
                        "id": .string(call.callID),
                        "name": .string(call.name),
                        "input": call.args,
                    ]))
                case .functionResponse(let response):
                    blocks.append(.object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string(response.callID),
                        "content": .string(response.response.jsonString),
                    ]))
                }
            }
            guard !blocks.isEmpty else { return nil }
            return .object([
                "role": .string(message.role == .model ? "assistant" : "user"),
                "content": .array(blocks),
            ])
        }
    }
}

// MARK: - Muse Spark / OpenAI-compatible adapter

/// Meta's Model API is OpenAI Chat Completions compatible. Keeping this as a
/// thin adapter lets Muse Spark use the shared agent contract without coupling
/// the app to OpenRouter's endpoint or routing extensions. The same adapter
/// serves the user-configured OpenAI-compatible provider, which speaks the
/// identical `/chat/completions` wire format against a custom base URL.
@MainActor
final class MuseSparkChatModelProxy: ChatModelProxy {
    private let configuration: ChatProxyConfiguration
    private let session: URLSession
    var descriptor: ChatModelDescriptor { configuration.descriptor }

    init(configuration: ChatProxyConfiguration, session: URLSession = .shared) {
        precondition(
            configuration.descriptor.provider == .museSpark
                || configuration.descriptor.provider == .openAICompatible
        )
        precondition(configuration.endpoint != nil)
        self.configuration = configuration
        self.session = session
    }

    func streamTurn(
        request: ChatModelRequest,
        onEvent: @escaping @MainActor (ChatModelStreamEvent) -> Void
    ) async throws -> ChatModelTurn {
        guard let endpoint = configuration.endpoint?.appendingPathComponent("chat/completions") else {
            throw ChatError.invalidResponse
        }
        onEvent(.encodingStarted)
        let body = try OpenRouterChatModelProxy.encodedTurnRequest(
            model: descriptor.deploymentIdentifier,
            request: request,
            routingMode: .automatic
        )
        onEvent(.requestEncoded(byteCount: body.count))
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = body

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            let delegate = ChatStreamTaskDelegate(rejectRedirects: true) { metrics in
                Task { @MainActor in onEvent(.transportMetrics(metrics)) }
            }
            (bytes, response) = try await session.bytes(for: urlRequest, delegate: delegate)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ChatError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ChatError.invalidResponse }
        let requestID = http.value(forHTTPHeaderField: "x-request-id")
        onEvent(.responseHeaders(
            statusCode: http.statusCode,
            requestID: requestID,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        ))
        guard (200..<300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let envelope = try? JSONDecoder().decode(ORErrorEnvelope.self, from: errorData)
            throw ChatError.serverError(
                http.statusCode,
                envelope?.error?.message ?? "\(descriptor.provider.displayName) request failed"
            )
        }

        var turn = ChatModelTurn()
        turn.providerRequestID = requestID
        turn.providerID = descriptor.provider.rawValue
        let modelTurnID = UUID().uuidString
        var callBuffers: [Int: (id: String?, name: String, arguments: String)] = [:]
        let decoder = JSONDecoder()
        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(ORStreamChunk.self, from: data) else { continue }
            onEvent(.providerEvent(kind: "muse.chunk"))
            if let model = chunk.model, !model.isEmpty { turn.resolvedModelID = model }
            if let usage = chunk.usage {
                let normalized = ChatTokenUsage(
                    input: usage.promptTokens ?? 0,
                    output: usage.completionTokens ?? 0,
                    thinking: 0
                )
                turn.usage = normalized
                onEvent(.usage(normalized))
            }
            guard let delta = chunk.choices?.first?.delta else { continue }
            if let content = delta.content, !content.isEmpty {
                if turn.textOrdinal == nil { turn.textOrdinal = 0 }
                turn.text += content
                onEvent(.visibleText(turn.text))
            }
            for fragment in delta.toolCalls ?? [] {
                let index = fragment.index ?? 0
                var buffer = callBuffers[index] ?? (id: nil, name: "", arguments: "")
                if let id = fragment.id { buffer.id = id }
                if let name = fragment.function?.name { buffer.name += name }
                if let arguments = fragment.function?.arguments { buffer.arguments += arguments }
                callBuffers[index] = buffer
            }
        }
        for index in callBuffers.keys.sorted() {
            guard let buffer = callBuffers[index], !buffer.name.isEmpty else { continue }
            let call = ChatModelCall(
                callID: buffer.id ?? UUID().uuidString,
                thoughtSignature: nil,
                modelTurnID: modelTurnID,
                modelTurnIndex: index,
                name: buffer.name,
                args: JSONValue.parse(buffer.arguments) ?? .object([:])
            )
            turn.calls.append(call)
            onEvent(.functionCall(call))
        }
        onEvent(.completed)
        return turn
    }
}

// MARK: - OpenAI Responses adapter (OpenAI and Azure)

@MainActor
final class OpenAIResponsesChatModelProxy: ChatModelProxy, ChatNativeWebSearching {
    private let configuration: ChatProxyConfiguration
    private let session: URLSession

    var descriptor: ChatModelDescriptor { configuration.descriptor }

    init(configuration: ChatProxyConfiguration, session: URLSession = .shared) {
        precondition(
            configuration.descriptor.provider == .azureOpenAI
                || configuration.descriptor.provider == .openAI
        )
        precondition(configuration.endpoint != nil)
        self.configuration = configuration
        self.session = session
    }

    func streamTurn(
        request: ChatModelRequest,
        onEvent: @escaping @MainActor (ChatModelStreamEvent) -> Void
    ) async throws -> ChatModelTurn {
        onEvent(.encodingStarted)
        let urlRequest = try makeRequest(
            body: Self.turnBody(descriptor: descriptor, request: request, stream: true)
        )
        onEvent(.requestEncoded(byteCount: urlRequest.httpBody?.count ?? 0))

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            let delegate = ChatStreamTaskDelegate(rejectRedirects: true) { metrics in
                Task { @MainActor in onEvent(.transportMetrics(metrics)) }
            }
            (bytes, response) = try await session.bytes(
                for: urlRequest,
                delegate: delegate
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ChatError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }
        onEvent(.responseHeaders(
            statusCode: httpResponse.statusCode,
            requestID: httpResponse.value(forHTTPHeaderField: "x-request-id")
                ?? httpResponse.value(forHTTPHeaderField: "apim-request-id"),
            retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        ))
        guard (200..<300).contains(httpResponse.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            throw Self.serverError(statusCode: httpResponse.statusCode, data: errorData)
        }

        var streamedText = ""
        var completedResponse: JSONValue?
        var completedItems: [Int: JSONValue] = [:]
        var reasoningSummary = ""
        let streamingModelTurnID = UUID().uuidString
        let decoder = JSONDecoder()

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? decoder.decode(JSONValue.self, from: data)
            else { continue }

            let eventType = event["type"]?.stringValue ?? "openai.event"
            onEvent(.providerEvent(kind: eventType))

            switch eventType {
            case "response.output_text.delta":
                if let delta = event["delta"]?.stringValue {
                    streamedText += delta
                    onEvent(.visibleText(streamedText))
                }
            case "response.reasoning_summary_text.delta":
                if let delta = event["delta"]?.stringValue {
                    reasoningSummary += delta
                    onEvent(.reasoningSummary(reasoningSummary))
                }
            case "response.output_item.done":
                if let item = event["item"] {
                    let index = Int(event["output_index"]?.doubleValue ?? Double(completedItems.count))
                    completedItems[index] = item
                    if item["type"]?.stringValue == "function_call",
                       let name = item["name"]?.stringValue {
                        let call = ChatModelCall(
                            callID: item["call_id"]?.stringValue
                                ?? item["id"]?.stringValue
                                ?? UUID().uuidString,
                            thoughtSignature: nil,
                            modelTurnID: event["response_id"]?.stringValue ?? streamingModelTurnID,
                            modelTurnIndex: index,
                            name: name,
                            args: item["arguments"]?.stringValue.flatMap(JSONValue.parse)
                                ?? item["arguments"]
                                ?? .object([:])
                        )
                        onEvent(.functionCall(call))
                    }
                }
            case "response.completed":
                completedResponse = event["response"]
            case "response.failed", "error":
                let message = event["error"]?["message"]?.stringValue
                    ?? event["message"]?.stringValue
                    ?? "OpenAI response failed."
                throw ChatError.serverError(0, message)
            default:
                continue
            }
        }

        let responseValue = completedResponse ?? .object([
            "output": .array(completedItems.keys.sorted().compactMap { completedItems[$0] }),
        ])
        var turn = Self.normalizedTurn(
            from: responseValue,
            providerID: descriptor.provider.rawValue
        )
        if turn.text.isEmpty { turn.text = streamedText }
        turn.providerRequestID = httpResponse.value(forHTTPHeaderField: "x-request-id")
            ?? turn.providerRequestID
        for call in turn.calls { onEvent(.functionCall(call)) }
        if let usage = turn.usage { onEvent(.usage(usage)) }
        onEvent(.completed)
        return turn
    }

    func searchWeb(prompt: String) async throws -> ChatWebSearchResult {
        guard descriptor.capabilities.supportsWebSearch else {
            throw ChatError.serverError(400, "This model does not support native web search.")
        }

        let body: JSONValue = .object([
            "model": .string(descriptor.deploymentIdentifier),
            "instructions": .string("You are a factual web research helper. Cite the sources you use."),
            "input": .array([
                .object([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string(prompt)]),
                    ]),
                ]),
            ]),
            "tools": .array([.object(["type": .string("web_search")])]),
            "include": .array([.string("reasoning.encrypted_content")]),
            "store": .bool(false),
            "stream": .bool(false),
        ])
        let urlRequest = try makeRequest(body: body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(
                for: urlRequest,
                delegate: ChatStreamTaskDelegate(rejectRedirects: true) { _ in }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ChatError.networkError(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.serverError(statusCode: httpResponse.statusCode, data: data)
        }
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        let turn = Self.normalizedTurn(
            from: decoded,
            providerID: descriptor.provider.rawValue
        )
        return ChatWebSearchResult(
            text: turn.text,
            usage: turn.usage,
            citations: turn.citations,
            providerRequestID: httpResponse.value(forHTTPHeaderField: "x-request-id")
                ?? turn.providerRequestID,
            providerID: descriptor.provider.rawValue,
            modelID: turn.resolvedModelID ?? descriptor.deploymentIdentifier
        )
    }

    /// Internal so provider contract tests can assert the wire shape without
    /// making a live Azure request or duplicating the provider-neutral suite.
    static func encodedTurnRequest(
        configuration: ChatProxyConfiguration,
        request: ChatModelRequest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(turnBody(
            descriptor: configuration.descriptor,
            request: request,
            stream: true
        ))
    }

    private func makeRequest(body: JSONValue) throws -> URLRequest {
        guard let baseURL = configuration.endpoint else {
            throw ChatError.invalidResponse
        }
        let url = baseURL.appendingPathComponent("responses")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if descriptor.provider == .azureOpenAI {
            request.setValue(configuration.apiKey, forHTTPHeaderField: "api-key")
        } else {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        return request
    }

    private static func turnBody(
        descriptor: ChatModelDescriptor,
        request: ChatModelRequest,
        stream: Bool
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "model": .string(descriptor.deploymentIdentifier),
            "instructions": .string(request.systemPrompt),
            "input": .array(inputItems(
                for: request.messages,
                providerID: descriptor.provider.rawValue
            )),
            "tools": .array(request.tools.map(toolItem)),
            "parallel_tool_calls": .bool(true),
            "include": .array([.string("reasoning.encrypted_content")]),
            "store": .bool(false),
            "stream": .bool(stream),
        ]
        if request.tools.isEmpty {
            object.removeValue(forKey: "tools")
            object.removeValue(forKey: "parallel_tool_calls")
        }
        return .object(object)
    }

    private static func toolItem(_ tool: ChatModelTool) -> JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": tool.parameters ?? .object(["type": .string("object")]),
            "strict": .bool(false),
        ])
    }

    private static func inputItems(
        for messages: [ChatModelMessage],
        providerID: String
    ) -> [JSONValue] {
        var items: [JSONValue] = []
        for message in messages {
            var content: [JSONValue] = []
            func flushContent() {
                guard !content.isEmpty else { return }
                items.append(.object([
                    "type": .string("message"),
                    "role": .string(message.role == .model ? "assistant" : "user"),
                    "content": .array(content),
                ]))
                content.removeAll(keepingCapacity: true)
            }
            for part in message.parts {
                switch part {
                case .text(let text):
                    content.append(.object([
                        "type": .string(message.role == .model ? "output_text" : "input_text"),
                        "text": .string(text),
                    ]))
                case .attachment(let attachment):
                    let dataURL = "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
                    if attachment.mimeType.hasPrefix("image/") {
                        content.append(.object([
                            "type": .string("input_image"),
                            "image_url": .string(dataURL),
                        ]))
                    } else {
                        content.append(.object([
                            "type": .string("input_file"),
                            "filename": .string(attachment.filename.isEmpty ? "document.pdf" : attachment.filename),
                            "file_data": .string(dataURL),
                        ]))
                    }
                case .providerContinuation(let continuation):
                    flushContent()
                    if continuation.providerID == providerID {
                        items.append(continuation.payload)
                    }
                case .functionCall(let call):
                    flushContent()
                    items.append(.object([
                        "type": .string("function_call"),
                        "call_id": .string(call.callID),
                        "name": .string(call.name),
                        "arguments": .string(call.args.jsonString),
                    ]))
                case .functionResponse(let response):
                    flushContent()
                    items.append(.object([
                        "type": .string("function_call_output"),
                        "call_id": .string(response.callID),
                        "output": .string(response.response.jsonString),
                    ]))
                }
            }
            flushContent()
        }
        return items
    }

    private static func normalizedTurn(
        from response: JSONValue,
        providerID: String
    ) -> ChatModelTurn {
        let responseID = response["id"]?.stringValue ?? UUID().uuidString
        var turn = ChatModelTurn()
        turn.providerRequestID = responseID
        turn.providerID = providerID
        turn.resolvedModelID = response["model"]?.stringValue

        if let usage = response["usage"] {
            turn.usage = ChatTokenUsage(
                input: Int(usage["input_tokens"]?.doubleValue ?? 0),
                cachedInput: Int(usage["input_tokens_details"]?["cached_tokens"]?.doubleValue ?? 0),
                output: Int(usage["output_tokens"]?.doubleValue ?? 0),
                thinking: Int(usage["output_tokens_details"]?["reasoning_tokens"]?.doubleValue ?? 0)
            )
        }

        for (ordinal, item) in (response["output"]?.arrayValue ?? []).enumerated() {
            switch item["type"]?.stringValue {
            case "reasoning":
                // Persist the complete item rather than interpreting the
                // encrypted payload. Azure requires byte-for-byte replay.
                if item["encrypted_content"]?.stringValue != nil {
                    turn.continuations.append(ChatProviderContinuation(
                        providerID: providerID,
                        modelTurnID: responseID,
                        ordinal: ordinal,
                        kind: "reasoning.encrypted_content",
                        payload: item
                    ))
                }
            case "function_call":
                guard let name = item["name"]?.stringValue else { continue }
                let arguments = item["arguments"]?.stringValue ?? "{}"
                turn.calls.append(ChatModelCall(
                    callID: item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? UUID().uuidString,
                    thoughtSignature: nil,
                    modelTurnID: responseID,
                    modelTurnIndex: ordinal,
                    name: name,
                    args: JSONValue.parse(arguments) ?? .object([:])
                ))
            case "message":
                if turn.textOrdinal == nil { turn.textOrdinal = ordinal }
                for content in item["content"]?.arrayValue ?? [] {
                    guard content["type"]?.stringValue == "output_text" else { continue }
                    turn.text += content["text"]?.stringValue ?? ""
                    for annotation in content["annotations"]?.arrayValue ?? [] {
                        guard annotation["type"]?.stringValue == "url_citation",
                              let url = annotation["url"]?.stringValue
                        else { continue }
                        turn.citations.append(ChatSourceCitation(
                            url: url,
                            title: annotation["title"]?.stringValue,
                            startIndex: annotation["start_index"]?.doubleValue.map(Int.init),
                            endIndex: annotation["end_index"]?.doubleValue.map(Int.init)
                        ))
                    }
                }
            default:
                continue
            }
        }
        return turn
    }

    private static func serverError(statusCode: Int, data: Data) -> ChatError {
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        let message = decoded?["error"]?["message"]?.stringValue
            ?? decoded?["message"]?.stringValue
            ?? "HTTP \(statusCode)"
        return .serverError(statusCode, message)
    }
}

/// Source-compatible name retained for Azure-specific tests and Settings code.
typealias AzureOpenAIChatModelProxy = OpenAIResponsesChatModelProxy

/// Provider API calls never need cross-origin redirects. Rejecting every redirect
/// guarantees the custom `api-key` header cannot be forwarded to a destination
/// that did not pass the configured endpoint validation.
private final class ChatStreamTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let rejectRedirects: Bool
    private let onMetrics: @Sendable (ChatTransportMetrics) -> Void

    init(
        rejectRedirects: Bool = false,
        onMetrics: @escaping @Sendable (ChatTransportMetrics) -> Void
    ) {
        self.rejectRedirects = rejectRedirects
        self.onMetrics = onMetrics
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(rejectRedirects ? nil : request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        func milliseconds(_ start: Date?, _ end: Date?) -> Int? {
            guard let start, let end else { return nil }
            return Int(max(0, end.timeIntervalSince(start)) * 1_000)
        }
        onMetrics(ChatTransportMetrics(
            dnsMs: milliseconds(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            connectionMs: milliseconds(transaction.connectStartDate, transaction.connectEndDate),
            tlsMs: milliseconds(
                transaction.secureConnectionStartDate,
                transaction.secureConnectionEndDate
            ),
            uploadMs: milliseconds(transaction.requestStartDate, transaction.requestEndDate),
            serverWaitMs: milliseconds(transaction.requestEndDate, transaction.responseStartDate)
        ))
    }
}

// MARK: - Gemini wire types

private struct GeminiPart: Encodable {
    var text: String? = nil
    var inlineData: InlineData? = nil
    var functionCall: FunctionCall? = nil
    var functionResponse: FunctionResponse? = nil
    var thoughtSignature: String? = nil

    struct InlineData: Encodable {
        let mimeType: String
        let data: String
    }

    struct FunctionCall: Encodable {
        let id: String
        let name: String
        let args: JSONValue
    }

    struct FunctionResponse: Encodable {
        let id: String
        let name: String
        let response: JSONValue
    }
}

private struct GeminiContent: Encodable {
    let role: String
    var parts: [GeminiPart]
}

private struct GeminiToolDecl: Encodable {
    var functionDeclarations: [Declaration]? = nil
    var googleSearch: EmptyPayload? = nil

    struct Declaration: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue?
    }

    struct EmptyPayload: Encodable {}
}

private struct GeminiChatRequest: Encodable {
    struct SystemInstruction: Encodable {
        let parts: [GeminiPart]
    }

    let systemInstruction: SystemInstruction
    let contents: [GeminiContent]
    var tools: [GeminiToolDecl]? = nil
}

private struct GeminiStreamChunk: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            let parts: [Part]?
        }

        struct Part: Decodable {
            let text: String?
            let thought: Bool?
            let functionCall: FunctionCallPayload?
            let thoughtSignature: String?
        }

        let content: Content?
    }

    struct FunctionCallPayload: Decodable {
        let id: String?
        let name: String
        let args: JSONValue?
    }

    struct Usage: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let thoughtsTokenCount: Int?
    }

    let candidates: [Candidate]?
    let usageMetadata: Usage?
    let modelVersion: String?
}

private struct GeminiAPIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}

private struct GeminiGenerateResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
                let thought: Bool?
            }

            let parts: [Part]?
        }

        let content: Content?
    }

    let candidates: [Candidate]?
    let usageMetadata: GeminiStreamChunk.Usage?
    let modelVersion: String?
}

// MARK: - OpenRouter wire types

private enum ORPart: Encodable {
    case text(String)
    case imageDataURL(String)
    case fileData(filename: String, dataURL: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, imageURL = "image_url", file
    }
    private enum ImageKeys: String, CodingKey { case url }
    private enum FileKeys: String, CodingKey {
        case filename
        case fileData = "file_data"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageDataURL(let url):
            try container.encode("image_url", forKey: .type)
            var image = container.nestedContainer(keyedBy: ImageKeys.self, forKey: .imageURL)
            try image.encode(url, forKey: .url)
        case .fileData(let filename, let dataURL):
            try container.encode("file", forKey: .type)
            var file = container.nestedContainer(keyedBy: FileKeys.self, forKey: .file)
            try file.encode(filename, forKey: .filename)
            try file.encode(dataURL, forKey: .fileData)
        }
    }
}

private enum ORContent: Encodable {
    case text(String)
    case parts([ORPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .parts(let parts): try container.encode(parts)
        }
    }
}

private struct ORToolCall: Encodable {
    let id: String
    var type: String = "function"
    let function: Function

    struct Function: Encodable {
        let name: String
        let arguments: String
    }
}

private struct ORMessage: Encodable {
    let role: String
    var content: ORContent? = nil
    var toolCalls: [ORToolCall]? = nil
    var toolCallID: String? = nil

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

private struct ORToolDecl: Encodable {
    var type: String = "function"
    let function: Function

    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue?
    }
}

private struct ORProviderPreferences: Encodable {
    let order: [String]?
    let allowFallbacks: Bool?

    enum CodingKeys: String, CodingKey {
        case order
        case allowFallbacks = "allow_fallbacks"
    }

    static func from(_ mode: OpenRouterRoutingMode) -> ORProviderPreferences? {
        switch mode {
        case .automatic:
            nil
        case .preferGoogleVertex:
            ORProviderPreferences(
                order: [AIProviderSettings.googleVertexProviderSlug],
                allowFallbacks: true
            )
        case .requireGoogleVertex:
            ORProviderPreferences(
                order: [AIProviderSettings.googleVertexProviderSlug],
                allowFallbacks: false
            )
        }
    }
}

private struct ORPlugin: Encodable {
    let id: String
}

private struct ORChatRequest: Encodable {
    let model: String
    let messages: [ORMessage]
    let stream: Bool
    var tools: [ORToolDecl]? = nil
    var provider: ORProviderPreferences? = nil
    var plugins: [ORPlugin]? = nil
    var streamOptions: StreamOptions? = nil

    struct StreamOptions: Encodable {
        let includeUsage: Bool

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools, provider, plugins
        case streamOptions = "stream_options"
    }
}

private struct ORStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let toolCalls: [ToolCallDelta]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }

        let delta: Delta?
    }

    struct ToolCallDelta: Decodable {
        let index: Int?
        let id: String?
        let function: Function?

        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    let choices: [Choice]?
    let usage: Usage?
    let model: String?
}

private struct ORNonStreamResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message?
    }

    let choices: [Choice]?
    let usage: ORStreamChunk.Usage?
    let model: String?
}

private struct ORErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}
