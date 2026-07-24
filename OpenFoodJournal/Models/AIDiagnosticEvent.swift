// OpenFoodJournal — remote AI diagnostic events and bounded delivery outbox.
// AGPL-3.0 License

import Foundation

/// Provider-neutral, redacted diagnostic envelope written to Turso.
///
/// Conversation content, journal/HealthKit values, source URLs or bodies,
/// attachments, and chain-of-thought must never be placed in this envelope.
struct AIDiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
    static let retentionDays = 14

    var id: UUID
    var createdAt: Date
    var expiresAt: Date
    var eventType: String
    var operation: String
    var status: String
    var providerID: String?
    var baseModelID: String?
    var deploymentID: String?
    var runID: UUID?
    var threadID: UUID?
    var turnID: String?
    var callID: String?
    var providerRequestID: String?
    var durationMs: Int?
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int
    var estimatedCostUSD: Double?
    var responseHTTPStatus: Int?
    var errorCode: String?
    var errorMessage: String?
    var payloadJSON: String?
    var appVersion: String?
    var appBuild: String?
    var osVersion: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        eventType: String,
        operation: String,
        status: String,
        providerID: String? = nil,
        baseModelID: String? = nil,
        deploymentID: String? = nil,
        runID: UUID? = nil,
        threadID: UUID? = nil,
        turnID: String? = nil,
        callID: String? = nil,
        providerRequestID: String? = nil,
        durationMs: Int? = nil,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0,
        estimatedCostUSD: Double? = nil,
        responseHTTPStatus: Int? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        payloadJSON: String? = nil,
        appVersion: String? = nil,
        appBuild: String? = nil,
        osVersion: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = Calendar.current.date(
            byAdding: .day,
            value: Self.retentionDays,
            to: createdAt
        ) ?? createdAt.addingTimeInterval(Double(Self.retentionDays) * 86_400)
        self.eventType = eventType
        self.operation = operation
        self.status = status
        self.providerID = providerID
        self.baseModelID = baseModelID
        self.deploymentID = deploymentID
        self.runID = runID
        self.threadID = threadID
        self.turnID = turnID
        self.callID = callID
        self.providerRequestID = providerRequestID
        self.durationMs = durationMs
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.responseHTTPStatus = responseHTTPStatus
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.payloadJSON = payloadJSON
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
    }
}

@MainActor
protocol AIDiagnosticWriting: AnyObject {
    func recordDiagnostic(_ event: AIDiagnosticEvent)
}

extension AIDiagnosticEvent {
    @MainActor
    init(scanLog log: GeminiScanLog) {
        let metadata = Self.metadata(from: log.requestMetadataJSON)
        self.init(
            id: log.id,
            createdAt: log.createdAt,
            eventType: "ai_request",
            operation: log.operation.rawValue,
            status: log.status.rawValue,
            providerID: log.provider,
            baseModelID: log.primaryModel,
            deploymentID: log.resolvedModel,
            runID: metadata["agent_run_id"].flatMap(UUID.init(uuidString:)),
            threadID: metadata["thread_id"].flatMap(UUID.init(uuidString:)),
            turnID: metadata["model_turn_id"],
            providerRequestID: metadata["provider_request_id"],
            durationMs: log.durationMs,
            inputTokens: log.inputTokenCount,
            cachedInputTokens: log.cachedInputTokenCount,
            outputTokens: log.outputTokenCount,
            reasoningTokens: log.thinkingTokenCount,
            estimatedCostUSD: log.pricingModel == nil ? nil : log.estimatedTokenCostUSD,
            responseHTTPStatus: log.responseHTTPStatus,
            errorCode: log.errorCode.map(String.init),
            // Provider error bodies can echo request content. HTTP/error codes
            // and parse stage are sufficient remote routing metadata.
            errorMessage: nil,
            payloadJSON: Self.scanPayload(log),
            appVersion: log.appVersion,
            appBuild: log.appBuild,
            osVersion: log.osVersion
        )
    }

    @MainActor
    init(span: ChatDiagnosticSpan) {
        var payload: [String: String] = [:]
        if let value = span.timeoutKind { payload["timeout_kind"] = value }
        if let value = span.retryReason { payload["retry_reason"] = value }
        if let value = span.dnsMs { payload["dns_ms"] = String(value) }
        if let value = span.connectionMs { payload["connection_ms"] = String(value) }
        if let value = span.tlsMs { payload["tls_ms"] = String(value) }
        if let value = span.uploadMs { payload["upload_ms"] = String(value) }
        if let value = span.serverWaitMs { payload["server_wait_ms"] = String(value) }

        self.init(
            id: span.id,
            createdAt: span.startedAt,
            eventType: "assistant_span",
            operation: span.kind,
            status: span.outcome,
            providerID: span.providerID.nilIfEmpty,
            baseModelID: span.baseModelID.nilIfEmpty,
            deploymentID: span.deploymentID.nilIfEmpty,
            runID: span.runID,
            threadID: span.threadID,
            turnID: span.turnID,
            callID: span.callID,
            providerRequestID: span.providerRequestID,
            durationMs: span.durationMs,
            errorCode: span.timeoutKind,
            payloadJSON: Self.jsonString(payload),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    private static func scanPayload(_ log: GeminiScanLog) -> String? {
        var payload: [String: String] = [:]
        func put(_ key: String, _ value: String?) {
            guard let value = value?.nilIfEmpty else { return }
            payload[key] = bounded(value)
        }
        put("scan_mode", log.scanMode)
        put("fallback_model", log.fallbackModel)
        put("resolved_model_version", log.resolvedModelVersion)
        put("request_metadata_json", log.requestMetadataJSON)
        put("request_image_metadata_json", log.requestImageMetadataJSON)
        put("parse_stage", log.parseStage)
        put("pricing_model", log.pricingModel)
        if log.usedFallback { payload["used_fallback"] = "true" }
        if log.photoCount > 0 { payload["photo_count"] = String(log.photoCount) }
        if let value = log.requestPayloadBytes { payload["request_payload_bytes"] = String(value) }
        if log.streamEventCount > 0 { payload["stream_event_count"] = String(log.streamEventCount) }
        if log.thoughtPartCount > 0 { payload["thought_part_count"] = String(log.thoughtPartCount) }
        if log.nonThoughtPartCount > 0 { payload["non_thought_part_count"] = String(log.nonThoughtPartCount) }
        put("result_name", log.resultName)
        return jsonString(payload)
    }

    private static func metadata(from json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.reduce(into: [:]) { result, pair in
            if let value = pair.value as? String { result[pair.key] = value }
            else if let value = pair.value as? NSNumber { result[pair.key] = value.stringValue }
        }
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func bounded(_ value: String, maximum: Int = 12_000) -> String {
        guard value.count > maximum else { return value }
        return String(value.prefix(maximum)) + "\n[truncated]"
    }
}

/// A small non-CloudKit queue that survives temporary network loss. It is not
/// a diagnostic history: acknowledged events are deleted immediately.
final class AIDiagnosticOutboxStore {
    nonisolated static let defaultMaximumEvents = 500
    nonisolated static let defaultMaximumBytes = 2 * 1_024 * 1_024
    nonisolated static let defaultMaximumAge: TimeInterval = 48 * 60 * 60

    private let fileURL: URL
    private let maximumEvents: Int
    private let maximumBytes: Int
    private let maximumAge: TimeInterval
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileURL: URL? = nil,
        maximumEvents: Int = defaultMaximumEvents,
        maximumBytes: Int = defaultMaximumBytes,
        maximumAge: TimeInterval = defaultMaximumAge,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.maximumEvents = max(1, maximumEvents)
        self.maximumBytes = max(1_024, maximumBytes)
        self.maximumAge = max(60, maximumAge)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    var count: Int { load().count }

    func events(now: Date = .now) -> [AIDiagnosticEvent] {
        let loaded = load()
        let retained = retainedEvents(loaded, now: now)
        if retained.count != loaded.count { try? save(retained) }
        return retained
    }

    @discardableResult
    func append(_ event: AIDiagnosticEvent, now: Date = .now) -> Int {
        var values = retainedEvents(load(), now: now)
        if let index = values.firstIndex(where: { $0.id == event.id }) {
            values[index] = event
        } else {
            values.append(event)
        }
        values.sort { $0.createdAt < $1.createdAt }
        if values.count > maximumEvents {
            values.removeFirst(values.count - maximumEvents)
        }
        while values.count > 1,
              let data = try? encoder.encode(values),
              data.count > maximumBytes {
            values.removeFirst()
        }
        try? save(values)
        return values.count
    }

    @discardableResult
    func remove(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return count }
        let values = load().filter { !ids.contains($0.id) }
        try? save(values)
        return values.count
    }

    func clear() {
        try? fileManager.removeItem(at: fileURL)
    }

    private func load() -> [AIDiagnosticEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let events = try? decoder.decode([AIDiagnosticEvent].self, from: data) else {
            return []
        }
        return events
    }

    private func retainedEvents(_ events: [AIDiagnosticEvent], now: Date) -> [AIDiagnosticEvent] {
        let deliveryCutoff = now.addingTimeInterval(-maximumAge)
        return events.filter { $0.createdAt >= deliveryCutoff && $0.expiresAt > now }
    }

    private func save(_ events: [AIDiagnosticEvent]) throws {
        guard !events.isEmpty else {
            clear()
            return
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(events)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(values)
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appending(path: "OpenFoodJournal", directoryHint: .isDirectory)
            .appending(path: "ai-diagnostic-outbox.json", directoryHint: .notDirectory)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
