// OpenFoodJournal — Gemini Scan Log
// Local diagnostic records for scan, search, and Assistant model calls.
// AGPL-3.0 License

import Foundation
import SwiftData

enum GeminiScanLogOperation: String, Codable, CaseIterable, Sendable {
    case scan
    case aiSearch
    case foodEmoji
    case foodIconImage
    case assistantChat
}

enum GeminiScanLogStatus: String, Codable, CaseIterable, Sendable {
    case success
    case failure
}

@Model
final class GeminiScanLog {
    /// Diagnostic payloads can contain prompts and provider response details,
    /// so keep them briefly instead of allowing CloudKit/Turso rows to grow
    /// forever. Conversation history has its own retention semantics.
    static let retentionDays = 14
    static let exportWindowDays = retentionDays

    var id: UUID = UUID()
    var createdAt: Date = Date()
    var operation: GeminiScanLogOperation = GeminiScanLogOperation.scan
    var status: GeminiScanLogStatus = GeminiScanLogStatus.success
    var provider: String? = nil
    var scanMode: String?
    var primaryModel: String?
    var fallbackModel: String?
    var resolvedModel: String?
    var resolvedModelVersion: String?
    var usedFallback: Bool = false
    var photoCount: Int = 0
    var durationMs: Int?
    var userPrompt: String?
    var requestPrompt: String?
    var requestPromptCharacterCount: Int = 0
    var requestMetadataJSON: String?
    var requestImageMetadataJSON: String?
    var requestPayloadBytes: Int?
    var responseHTTPStatus: Int?
    var parseStage: String?
    var responseText: String?
    var responseTextCharacterCount: Int = 0
    var rawResponseJSON: String?
    var modelAttemptsJSON: String?
    var inputTokenCount: Int = 0
    var cachedInputTokenCount: Int = 0
    var outputTokenCount: Int = 0
    var thinkingTokenCount: Int = 0
    var totalTokenCount: Int = 0
    var estimatedTokenCostUSD: Double = 0
    var pricingModel: String?
    var searchGroundingRequested: Bool = false
    var searchGroundingUsed: Bool = false
    var webSearchQueries: [String] = []
    var groundingSourceURLs: [String] = []
    var groundingSourceTitles: [String] = []
    var groundingMetadataJSON: String?
    var streamEventCount: Int = 0
    var thoughtPartCount: Int = 0
    var nonThoughtPartCount: Int = 0
    var resultName: String?
    var calories: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var errorCode: Int?
    var errorMessage: String?
    var responseJSON: String?
    var thinkingTrace: [String] = []
    var appVersion: String?
    var appBuild: String?
    var osVersion: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        operation: GeminiScanLogOperation,
        status: GeminiScanLogStatus,
        provider: String? = nil,
        scanMode: String? = nil,
        primaryModel: String? = nil,
        fallbackModel: String? = nil,
        resolvedModel: String? = nil,
        resolvedModelVersion: String? = nil,
        usedFallback: Bool = false,
        photoCount: Int = 0,
        durationMs: Int? = nil,
        userPrompt: String? = nil,
        requestPrompt: String? = nil,
        requestPromptCharacterCount: Int = 0,
        requestMetadataJSON: String? = nil,
        requestImageMetadataJSON: String? = nil,
        requestPayloadBytes: Int? = nil,
        responseHTTPStatus: Int? = nil,
        parseStage: String? = nil,
        responseText: String? = nil,
        responseTextCharacterCount: Int = 0,
        rawResponseJSON: String? = nil,
        modelAttemptsJSON: String? = nil,
        inputTokenCount: Int = 0,
        cachedInputTokenCount: Int = 0,
        outputTokenCount: Int = 0,
        thinkingTokenCount: Int = 0,
        totalTokenCount: Int = 0,
        estimatedTokenCostUSD: Double = 0,
        pricingModel: String? = nil,
        searchGroundingRequested: Bool = false,
        searchGroundingUsed: Bool = false,
        webSearchQueries: [String] = [],
        groundingSourceURLs: [String] = [],
        groundingSourceTitles: [String] = [],
        groundingMetadataJSON: String? = nil,
        streamEventCount: Int = 0,
        thoughtPartCount: Int = 0,
        nonThoughtPartCount: Int = 0,
        resultName: String? = nil,
        calories: Double? = nil,
        protein: Double? = nil,
        carbs: Double? = nil,
        fat: Double? = nil,
        errorCode: Int? = nil,
        errorMessage: String? = nil,
        responseJSON: String? = nil,
        thinkingTrace: [String] = [],
        appVersion: String? = nil,
        appBuild: String? = nil,
        osVersion: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.operation = operation
        self.status = status
        self.provider = provider
        self.scanMode = scanMode
        self.primaryModel = primaryModel
        self.fallbackModel = fallbackModel
        self.resolvedModel = resolvedModel
        self.resolvedModelVersion = resolvedModelVersion
        self.usedFallback = usedFallback
        self.photoCount = photoCount
        self.durationMs = durationMs
        self.userPrompt = userPrompt
        self.requestPrompt = requestPrompt
        self.requestPromptCharacterCount = requestPromptCharacterCount
        self.requestMetadataJSON = requestMetadataJSON
        self.requestImageMetadataJSON = requestImageMetadataJSON
        self.requestPayloadBytes = requestPayloadBytes
        self.responseHTTPStatus = responseHTTPStatus
        self.parseStage = parseStage
        self.responseText = responseText
        self.responseTextCharacterCount = responseTextCharacterCount
        self.rawResponseJSON = rawResponseJSON
        self.modelAttemptsJSON = modelAttemptsJSON
        self.inputTokenCount = inputTokenCount
        self.cachedInputTokenCount = cachedInputTokenCount
        self.outputTokenCount = outputTokenCount
        self.thinkingTokenCount = thinkingTokenCount
        self.totalTokenCount = totalTokenCount
        self.estimatedTokenCostUSD = estimatedTokenCostUSD
        self.pricingModel = pricingModel
        self.searchGroundingRequested = searchGroundingRequested
        self.searchGroundingUsed = searchGroundingUsed
        self.webSearchQueries = webSearchQueries
        self.groundingSourceURLs = groundingSourceURLs
        self.groundingSourceTitles = groundingSourceTitles
        self.groundingMetadataJSON = groundingMetadataJSON
        self.streamEventCount = streamEventCount
        self.thoughtPartCount = thoughtPartCount
        self.nonThoughtPartCount = nonThoughtPartCount
        self.resultName = resultName
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.responseJSON = responseJSON
        self.thinkingTrace = thinkingTrace
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
    }
}

extension GeminiScanLog {
    @MainActor
    static func fetchExportableLogs(
        in modelContext: ModelContext,
        days: Int = exportWindowDays,
        now: Date = .now
    ) -> [GeminiScanLog] {
        let cutoff = cutoffDate(days: days, now: now)
        let descriptor = FetchDescriptor<GeminiScanLog>(
            predicate: #Predicate { $0.createdAt >= cutoff },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    @MainActor
    static func pruneExpired(
        in modelContext: ModelContext,
        days: Int = exportWindowDays,
        now: Date = .now
    ) -> Int {
        let cutoff = cutoffDate(days: days, now: now)
        let descriptor = FetchDescriptor<GeminiScanLog>(
            predicate: #Predicate { $0.createdAt < cutoff }
        )
        let expired = (try? modelContext.fetch(descriptor)) ?? []
        for log in expired {
            modelContext.delete(log)
        }
        return expired.count
    }

    @MainActor
    static func exportCSV(
        from modelContext: ModelContext,
        days: Int = exportWindowDays,
        now: Date = .now
    ) -> String {
        let logs = fetchExportableLogs(in: modelContext, days: days, now: now)
        guard !logs.isEmpty else { return "" }

        let header = [
            "Log ID", "Timestamp", "Operation", "Status", "Provider", "Scan Mode",
            "Primary Model", "Fallback Model", "Resolved Model", "Used Fallback",
            "Resolved Model Version", "Photo Count", "Duration Ms", "User Prompt Or Query",
            "Request Prompt", "Request Prompt Characters", "Request Metadata JSON",
            "Image Metadata JSON", "Request Payload Bytes", "Response HTTP Status",
            "Parse Stage", "Response Text Characters", "Raw Response Text",
            "Raw Response JSON", "Model Attempts JSON", "Input Tokens", "Cached Input Tokens",
            "Output Tokens", "Thinking Tokens", "Total Tokens",
            "Estimated Token Cost USD", "Pricing Model", "Search Grounding Requested",
            "Search Grounding Used", "Web Search Queries", "Grounding Source URLs",
            "Grounding Source Titles", "Grounding Metadata JSON",
            "Stream Event Count",
            "Thought Part Count", "Non Thought Part Count",
            "Result Name", "Calories", "Protein (g)", "Carbs (g)", "Fat (g)",
            "Error Code", "Error Message", "Thinking Trace", "Response JSON",
            "App Version", "App Build", "OS Version"
        ]
        var rows = [header.map(Self.csvEscape).joined(separator: ",")]

        for log in logs {
            var fields: [String] = []
            fields.append(log.id.uuidString)
            fields.append(Self.isoTimestampFormatter.string(from: log.createdAt))
            fields.append(log.operation.rawValue)
            fields.append(log.status.rawValue)
            fields.append(log.provider ?? "")
            fields.append(log.scanMode ?? "")
            fields.append(log.primaryModel ?? "")
            fields.append(log.fallbackModel ?? "")
            fields.append(log.resolvedModel ?? "")
            fields.append(log.usedFallback ? "true" : "false")
            fields.append(log.resolvedModelVersion ?? "")
            fields.append(String(log.photoCount))
            fields.append(log.durationMs.map(String.init) ?? "")
            fields.append(log.userPrompt ?? "")
            fields.append(log.requestPrompt ?? "")
            fields.append(String(log.requestPromptCharacterCount))
            fields.append(log.requestMetadataJSON ?? "")
            fields.append(log.requestImageMetadataJSON ?? "")
            fields.append(log.requestPayloadBytes.map(String.init) ?? "")
            fields.append(log.responseHTTPStatus.map(String.init) ?? "")
            fields.append(log.parseStage ?? "")
            fields.append(String(log.responseTextCharacterCount))
            fields.append(log.responseText ?? "")
            fields.append(log.rawResponseJSON ?? "")
            fields.append(log.modelAttemptsJSON ?? "")
            fields.append(String(log.inputTokenCount))
            fields.append(String(log.cachedInputTokenCount))
            fields.append(String(log.outputTokenCount))
            fields.append(String(log.thinkingTokenCount))
            fields.append(String(log.totalTokenCount))
            fields.append(Self.usd(log.estimatedTokenCostUSD))
            fields.append(log.pricingModel ?? "")
            fields.append(log.searchGroundingRequested ? "true" : "false")
            fields.append(log.searchGroundingUsed ? "true" : "false")
            fields.append(log.webSearchQueries.joined(separator: " | "))
            fields.append(log.groundingSourceURLs.joined(separator: " | "))
            fields.append(log.groundingSourceTitles.joined(separator: " | "))
            fields.append(log.groundingMetadataJSON ?? "")
            fields.append(String(log.streamEventCount))
            fields.append(String(log.thoughtPartCount))
            fields.append(String(log.nonThoughtPartCount))
            fields.append(log.resultName ?? "")
            fields.append(log.calories.map(Self.decimal) ?? "")
            fields.append(log.protein.map(Self.decimal) ?? "")
            fields.append(log.carbs.map(Self.decimal) ?? "")
            fields.append(log.fat.map(Self.decimal) ?? "")
            fields.append(log.errorCode.map(String.init) ?? "")
            fields.append(log.errorMessage ?? "")
            fields.append(log.thinkingTrace.joined(separator: " | "))
            fields.append(log.responseJSON ?? "")
            fields.append(log.appVersion ?? "")
            fields.append(log.appBuild ?? "")
            fields.append(log.osVersion ?? "")
            rows.append(fields.map(Self.csvEscape).joined(separator: ","))
        }

        return rows.joined(separator: "\n")
    }

    private static func cutoffDate(days: Int, now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
    }

    private static func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func usd(_ value: Double) -> String {
        String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static let isoTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
