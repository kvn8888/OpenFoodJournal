// OpenFoodJournal — Gemini Cost Accumulator
// Local running estimate of Gemini API token costs.
// AGPL-3.0 License

import Foundation
import SwiftData

@Model
final class GeminiCostAccumulator {
    static let currentPricingSource = "Dated local Gemini and GPT-5.6 pricing catalogs; see each request's pricing model"

    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var totalEstimatedTokenCostUSD: Double = 0
    var totalInputTokens: Int = 0
    var totalCachedInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var totalThinkingTokens: Int = 0
    var totalRequests: Int = 0
    var successfulRequests: Int = 0
    var failedRequests: Int = 0
    var groundedSearchPrompts: Int = 0

    var lastEstimatedTokenCostUSD: Double = 0
    var lastInputTokens: Int = 0
    var lastCachedInputTokens: Int = 0
    var lastOutputTokens: Int = 0
    var lastThinkingTokens: Int = 0
    var lastModel: String?
    var lastPricingModel: String?
    var lastRecordedAt: Date?

    var pricingSource: String = GeminiCostAccumulator.currentPricingSource

    init() {}

    @MainActor
    static func current(in context: ModelContext) -> GeminiCostAccumulator {
        var descriptor = FetchDescriptor<GeminiCostAccumulator>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.pricingSource = currentPricingSource
            return existing
        }

        let accumulator = GeminiCostAccumulator()
        context.insert(accumulator)
        return accumulator
    }

    func add(
        estimatedCostUSD: Double,
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        outputTokens: Int,
        thinkingTokens: Int,
        model: String?,
        pricingModel: String?,
        usedSearchGrounding: Bool,
        succeeded: Bool,
        now: Date = .now
    ) {
        totalEstimatedTokenCostUSD += estimatedCostUSD
        totalInputTokens += inputTokens
        totalCachedInputTokens += cachedInputTokens
        totalOutputTokens += outputTokens
        totalThinkingTokens += thinkingTokens
        totalRequests += 1
        if succeeded {
            successfulRequests += 1
        } else {
            failedRequests += 1
        }
        if usedSearchGrounding {
            groundedSearchPrompts += 1
        }

        lastEstimatedTokenCostUSD = estimatedCostUSD
        lastInputTokens = inputTokens
        lastCachedInputTokens = cachedInputTokens
        lastOutputTokens = outputTokens
        lastThinkingTokens = thinkingTokens
        lastModel = model
        lastPricingModel = pricingModel
        lastRecordedAt = now
        updatedAt = now
    }

    func reset(now: Date = .now) {
        totalEstimatedTokenCostUSD = 0
        totalInputTokens = 0
        totalCachedInputTokens = 0
        totalOutputTokens = 0
        totalThinkingTokens = 0
        totalRequests = 0
        successfulRequests = 0
        failedRequests = 0
        groundedSearchPrompts = 0

        lastEstimatedTokenCostUSD = 0
        lastInputTokens = 0
        lastCachedInputTokens = 0
        lastOutputTokens = 0
        lastThinkingTokens = 0
        lastModel = nil
        lastPricingModel = nil
        lastRecordedAt = nil
        updatedAt = now
    }
}
