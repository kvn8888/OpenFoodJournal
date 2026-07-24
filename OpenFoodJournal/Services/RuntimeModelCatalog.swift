// OpenFoodJournal — Runtime model metadata
// Cached models.dev capabilities and pricing. This is metadata only; provider
// routing, authentication, and behavioral guarantees remain app-owned.
// AGPL-3.0 License

import Foundation

@MainActor
protocol ModelCatalogFetching: AnyObject {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ModelCatalogFetching {}

nonisolated struct ChatModelCatalogResolution: Equatable, Sendable {
    let selection: AssistantModelSelection
    let resolvedModelID: String
    let pricing: ChatModelPricing?
    let catalogVersion: String?
    let verifiedAt: String?
}

@MainActor
final class RuntimeModelCatalog {
    nonisolated static let refreshInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let endpoint = URL(string: "https://models.dev/api.json")!

    private let fetcher: any ModelCatalogFetching
    private let cacheURL: URL
    private let now: () -> Date
    private let endpoint: URL
    private let refreshInterval: TimeInterval

    private var cache: CacheEnvelope?
    private var isRefreshing = false

    private(set) var lastRefreshErrorDescription: String?

    init(
        fetcher: any ModelCatalogFetching = URLSession.shared,
        cacheURL: URL? = nil,
        endpoint: URL = RuntimeModelCatalog.endpoint,
        refreshInterval: TimeInterval = RuntimeModelCatalog.refreshInterval,
        now: @escaping () -> Date = Date.init
    ) {
        self.fetcher = fetcher
        self.cacheURL = cacheURL ?? Self.defaultCacheURL()
        self.endpoint = endpoint
        self.refreshInterval = refreshInterval
        self.now = now
        self.cache = Self.loadCache(from: self.cacheURL)
    }

    var lastSuccessfulRefreshAt: Date? {
        cache?.fetchedAt
    }

    /// Refreshes at launch/foreground at most once per 24 hours. A failed
    /// metadata request leaves the last good cache in place and never blocks
    /// an Assistant request from using the shipped fallback catalog.
    @discardableResult
    func refreshIfNeeded(force: Bool = false) async -> Bool {
        guard !isRefreshing else { return false }
        if !force,
           let fetchedAt = cache?.fetchedAt,
           now().timeIntervalSince(fetchedAt) < refreshInterval {
            return false
        }

        isRefreshing = true
        defer { isRefreshing = false }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = cache?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await fetcher.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CatalogError.invalidResponse
            }

            if httpResponse.statusCode == 304, var existing = cache {
                existing.fetchedAt = now()
                existing.etag = httpResponse.value(forHTTPHeaderField: "ETag") ?? existing.etag
                cache = existing
                try persist(existing)
                lastRefreshErrorDescription = nil
                return true
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw CatalogError.httpStatus(httpResponse.statusCode)
            }

            let providers = try JSONDecoder().decode(
                [String: ProviderPayload].self,
                from: data
            )
            let retained = Dictionary(uniqueKeysWithValues: ["google", "openrouter", "azure"].compactMap {
                providerID in providers[providerID].map { (providerID, $0) }
            })
            guard !retained.isEmpty else { throw CatalogError.missingProviders }

            let refreshed = CacheEnvelope(
                fetchedAt: now(),
                etag: httpResponse.value(forHTTPHeaderField: "ETag"),
                providers: retained,
                resolvedAliases: cache?.resolvedAliases ?? [:]
            )
            cache = refreshed
            try persist(refreshed)
            lastRefreshErrorDescription = nil
            return true
        } catch {
            lastRefreshErrorDescription = error.localizedDescription
            return false
        }
    }

    /// Starts refresh without adding catalog latency to a user-visible model
    /// request. App lifecycle refreshes still await completion so the cache is
    /// normally warm before the Assistant is opened.
    func refreshInBackgroundIfNeeded(force: Bool = false) {
        Task { [weak self] in
            _ = await self?.refreshIfNeeded(force: force)
        }
    }

    /// Applies cached runtime limits and feature flags before request
    /// construction. Unknown models retain the app's conservative fallback.
    func selectionResolvingRuntimeMetadata(
        _ selection: AssistantModelSelection
    ) -> AssistantModelSelection {
        resolution(for: selection, resolvedModelID: nil).selection
    }

    /// Resolves pricing and provenance against the concrete model returned by
    /// a provider. The Azure deployment identifier remains unchanged.
    func resolution(
        for selection: AssistantModelSelection,
        resolvedModelID: String?
    ) -> ChatModelCatalogResolution {
        let requestedID = selection.descriptor.deploymentIdentifier
        let normalizedResolved = normalizedModelID(
            resolvedModelID ?? cachedResolution(
                provider: selection.provider,
                requestedModelID: requestedID
            ) ?? selection.descriptor.baseModelID
        )
        let record = modelRecord(
            provider: selection.provider,
            modelID: normalizedResolved
        ) ?? modelRecord(
            provider: selection.provider,
            modelID: selection.descriptor.baseModelID
        ) ?? modelRecord(
            provider: selection.provider,
            modelID: requestedID
        )
        let effectiveModelID = record.map {
            normalizedModelID(
                normalizedResolved == normalizedModelID(selection.descriptor.baseModelID)
                    ? $0.id
                    : normalizedResolved
            )
        } ?? normalizedResolved
        let descriptor = descriptor(
            from: record,
            resolvedModelID: effectiveModelID,
            fallback: selection.descriptor
        )
        let effectiveSelection = AssistantModelSelection(
            descriptor: descriptor,
            endpoint: selection.endpoint,
            routingMode: selection.routingMode
        )
        let runtimePricing = record.flatMap {
            pricing(from: $0, provider: selection.provider, modelID: effectiveModelID)
        }
        return ChatModelCatalogResolution(
            selection: effectiveSelection,
            resolvedModelID: effectiveModelID,
            pricing: runtimePricing ?? ChatPricingCatalog.pricing(for: effectiveSelection),
            catalogVersion: runtimePricing == nil ? ChatPricingCatalog.version : cacheVersion,
            verifiedAt: runtimePricing == nil ? ChatPricingCatalog.lastVerifiedAt : verifiedAt
        )
    }

    func pricing(
        provider: AssistantProvider,
        modelID: String
    ) -> ChatModelPricing? {
        guard let record = modelRecord(provider: provider, modelID: modelID) else {
            return nil
        }
        return pricing(
            from: record,
            provider: provider,
            modelID: normalizedModelID(modelID)
        )
    }

    /// Provider aliases can move between the daily refreshes. Persist the
    /// concrete value immediately and force a background metadata refresh when
    /// it changes or is absent from the current cache.
    func observeResolvedModel(
        provider: AssistantProvider,
        requestedModelID: String,
        resolvedModelID: String?
    ) {
        guard let resolvedModelID else { return }
        let requested = normalizedModelID(requestedModelID)
        let resolved = normalizedModelID(resolvedModelID)
        guard !resolved.isEmpty else { return }

        let key = aliasKey(provider: provider, requestedModelID: requested)
        let previous = cache?.resolvedAliases[key]
        let changed = previous != resolved
        if cache == nil {
            cache = CacheEnvelope(
                fetchedAt: .distantPast,
                etag: nil,
                providers: [:],
                resolvedAliases: [key: resolved]
            )
        } else {
            cache?.resolvedAliases[key] = resolved
        }
        if let cache { try? persist(cache) }

        guard changed || modelRecord(provider: provider, modelID: resolved) == nil else {
            return
        }
        refreshInBackgroundIfNeeded(force: true)
    }

    private var cacheVersion: String? {
        guard let cache else { return nil }
        if let etag = cache.etag?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
           !etag.isEmpty {
            return "models.dev:\(etag)"
        }
        return "models.dev:\(Self.dayFormatter.string(from: cache.fetchedAt))"
    }

    private var verifiedAt: String? {
        cache.map { Self.dayFormatter.string(from: $0.fetchedAt) }
    }

    private func cachedResolution(
        provider: AssistantProvider,
        requestedModelID: String
    ) -> String? {
        cache?.resolvedAliases[
            aliasKey(provider: provider, requestedModelID: normalizedModelID(requestedModelID))
        ]
    }

    private func aliasKey(
        provider: AssistantProvider,
        requestedModelID: String
    ) -> String {
        "\(provider.rawValue)|\(requestedModelID)"
    }

    private func modelRecord(
        provider: AssistantProvider,
        modelID: String
    ) -> ModelRecord? {
        guard let models = cache?.providers[catalogProviderID(for: provider)]?.models else {
            return nil
        }
        for candidate in lookupCandidates(provider: provider, modelID: modelID) {
            if let record = models[candidate] { return record }
            if let record = models.values.first(where: {
                normalizedModelID($0.id) == normalizedModelID(candidate)
            }) {
                return record
            }
        }
        return nil
    }

    private func lookupCandidates(
        provider: AssistantProvider,
        modelID: String
    ) -> [String] {
        let normalized = normalizedModelID(modelID)
        var candidates = [normalized]
        if provider == .openRouter, !normalized.hasPrefix("~") {
            candidates.append("~\(normalized)")
        }
        return candidates
    }

    private func normalizedModelID(_ modelID: String) -> String {
        var normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("models/") {
            normalized.removeFirst("models/".count)
        }
        return normalized
    }

    private func catalogProviderID(for provider: AssistantProvider) -> String {
        switch provider {
        case .gemini: "google"
        case .openRouter: "openrouter"
        case .azureOpenAI: "azure"
        }
    }

    private func descriptor(
        from record: ModelRecord?,
        resolvedModelID: String,
        fallback: ChatModelDescriptor
    ) -> ChatModelDescriptor {
        guard let record else { return fallback }
        let inputModalities = Set(record.modalities?.input ?? [])
        let maximumInput = record.limit.input ?? record.limit.context
        return ChatModelDescriptor(
            provider: fallback.provider,
            baseModelID: resolvedModelID,
            deploymentIdentifier: fallback.deploymentIdentifier,
            displayName: record.name,
            capabilities: ChatModelCapabilities(
                maximumInputTokens: max(1, maximumInput),
                maximumOutputTokens: max(1, record.limit.output),
                supportsStreaming: fallback.capabilities.supportsStreaming,
                supportsFunctions: fallback.capabilities.supportsFunctions && record.toolCall,
                supportsParallelCalls: fallback.capabilities.supportsParallelCalls,
                supportsImages: fallback.capabilities.supportsImages && inputModalities.contains("image"),
                supportsPDFs: fallback.capabilities.supportsPDFs && inputModalities.contains("pdf"),
                supportsWebSearch: fallback.capabilities.supportsWebSearch,
                supportsNativeCompaction: fallback.capabilities.supportsNativeCompaction
            ),
            lastVerifiedAt: verifiedAt ?? fallback.lastVerifiedAt
        )
    }

    private func pricing(
        from record: ModelRecord,
        provider: AssistantProvider,
        modelID: String
    ) -> ChatModelPricing? {
        guard let cost = record.cost,
              let input = cost.input,
              let output = cost.output
        else { return nil }

        let tier = cost.tiers?.first {
            $0.tier.type == "context" && $0.tier.size > 0
        }
        let cached = cost.cacheRead ?? input
        return ChatModelPricing(
            inputPerMillionUSD: input,
            cachedInputPerMillionUSD: cached,
            outputPerMillionUSD: output,
            longContextThreshold: tier?.tier.size,
            longContextInputMultiplier: Self.multiplier(tier?.input, base: input),
            longContextCachedInputMultiplier: Self.multiplier(tier?.cacheRead, base: cached),
            longContextOutputMultiplier: Self.multiplier(tier?.output, base: output),
            outputIncludesThinking: provider == .azureOpenAI,
            source: "models.dev \(catalogProviderID(for: provider))/\(modelID), fetched \(verifiedAt ?? "unknown")"
        )
    }

    private static func multiplier(_ tierRate: Double?, base: Double) -> Double {
        guard let tierRate, base > 0 else { return 1 }
        return tierRate / base
    }

    private func persist(_ envelope: CacheEnvelope) throws {
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(envelope).write(to: cacheURL, options: .atomic)
    }

    private static func loadCache(from url: URL) -> CacheEnvelope? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CacheEnvelope.self, from: data)
    }

    private static func defaultCacheURL() -> URL {
        let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("OpenFoodJournal", isDirectory: true)
            .appendingPathComponent("models-dev-cache.json")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private extension RuntimeModelCatalog {
    enum CatalogError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case missingProviders

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "models.dev returned an invalid response."
            case .httpStatus(let status): "models.dev returned HTTP \(status)."
            case .missingProviders: "models.dev returned no supported providers."
            }
        }
    }

    struct CacheEnvelope: Codable {
        var fetchedAt: Date
        var etag: String?
        var providers: [String: ProviderPayload]
        var resolvedAliases: [String: String]
    }

    struct ProviderPayload: Codable {
        let id: String
        let name: String
        let models: [String: ModelRecord]
    }

    struct ModelRecord: Codable {
        struct Modalities: Codable {
            let input: [String]
            let output: [String]
        }

        struct Limit: Codable {
            let context: Int
            let input: Int?
            let output: Int
        }

        struct Cost: Codable {
            struct Tier: Codable {
                struct Condition: Codable {
                    let type: String
                    let size: Int
                }

                let input: Double?
                let output: Double?
                let cacheRead: Double?
                let tier: Condition

                enum CodingKeys: String, CodingKey {
                    case input, output, tier
                    case cacheRead = "cache_read"
                }
            }

            let input: Double?
            let output: Double?
            let cacheRead: Double?
            let tiers: [Tier]?

            enum CodingKeys: String, CodingKey {
                case input, output, tiers
                case cacheRead = "cache_read"
            }
        }

        let id: String
        let name: String
        let attachment: Bool
        let reasoning: Bool
        let toolCall: Bool
        let modalities: Modalities?
        let limit: Limit
        let cost: Cost?
        let lastUpdated: String?

        enum CodingKeys: String, CodingKey {
            case id, name, attachment, reasoning, modalities, limit, cost
            case toolCall = "tool_call"
            case lastUpdated = "last_updated"
        }
    }
}
