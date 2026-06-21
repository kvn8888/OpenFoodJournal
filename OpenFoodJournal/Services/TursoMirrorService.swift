// OpenFoodJournal — Turso Mirror Service
// Optional push-only SQL-over-HTTP mirror for user-owned debugging databases.
// AGPL-3.0 License

import Foundation
import Observation
import SwiftData

enum TursoMirrorError: LocalizedError, Sendable {
    case missingCredentials
    case invalidDatabaseURL
    case invalidResponse
    case httpStatus(Int, String)
    case pipelineError(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Turso database URL and auth token are required."
        case .invalidDatabaseURL:
            "Enter a valid libsql:// or https:// Turso database URL."
        case .invalidResponse:
            "Turso returned an unexpected response."
        case .httpStatus(let status, let body):
            body.isEmpty ? "Turso request failed with HTTP \(status)." : "Turso request failed with HTTP \(status): \(body)"
        case .pipelineError(let message):
            "Turso SQL pipeline failed: \(message)"
        }
    }
}

struct TursoMirrorSummary: Equatable, Sendable {
    var generation: String
    var rowCounts: [String: Int]

    var totalRows: Int {
        rowCounts.values.reduce(0, +)
    }
}

enum TursoSQLValue: Encodable, Equatable, Sendable {
    case null
    case integer(Int)
    case real(Double)
    case text(String)
    case blob(Data)

    static func bool(_ value: Bool) -> TursoSQLValue {
        .integer(value ? 1 : 0)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode("null", forKey: .type)
        case .integer(let value):
            try container.encode("integer", forKey: .type)
            try container.encode(String(value), forKey: .value)
        case .real(let value):
            try container.encode("float", forKey: .type)
            try container.encode(String(value), forKey: .value)
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .value)
        case .blob(let data):
            try container.encode("blob", forKey: .type)
            try container.encode(data.base64EncodedString(), forKey: .base64)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case base64
    }
}

struct TursoSQLStatement: Encodable, Equatable, Sendable {
    var sql: String
    var args: [TursoSQLValue] = []
}

struct TursoColumnDefinition: Equatable, Sendable {
    var name: String
    var type: String
}

struct TursoTableDefinition: Equatable, Sendable {
    var name: String
    var columns: [TursoColumnDefinition]

    var createStatement: String {
        let columnSQL = columns
            .map { "\($0.name) \($0.type)" }
            .joined(separator: ", ")
        return "CREATE TABLE IF NOT EXISTS \(name) (\(columnSQL))"
    }
}

enum TursoSchema {
    static let tables: [TursoTableDefinition] = [
        TursoTableDefinition(name: "ofj_sync_runs", columns: [
            .init(name: "id", type: "TEXT PRIMARY KEY"),
            .init(name: "started_at", type: "TEXT"),
            .init(name: "finished_at", type: "TEXT"),
            .init(name: "status", type: "TEXT"),
            .init(name: "reason", type: "TEXT"),
            .init(name: "row_count", type: "INTEGER"),
            .init(name: "table_counts_json", type: "TEXT"),
            .init(name: "error", type: "TEXT"),
            .init(name: "mirror_generation", type: "TEXT")
        ]),
        TursoTableDefinition(name: "ofj_daily_logs", columns: [
            .init(name: "id", type: "TEXT PRIMARY KEY"),
            .init(name: "date", type: "TEXT"),
            .init(name: "notes", type: "TEXT"),
            .init(name: "entry_count", type: "INTEGER"),
            .init(name: "total_calories", type: "REAL"),
            .init(name: "total_protein", type: "REAL"),
            .init(name: "total_carbs", type: "REAL"),
            .init(name: "total_fat", type: "REAL"),
            .init(name: "mirror_generation", type: "TEXT")
        ]),
        TursoTableDefinition(name: "ofj_nutrition_entries", columns: [
            .init(name: "id", type: "TEXT PRIMARY KEY"),
            .init(name: "daily_log_id", type: "TEXT"),
            .init(name: "log_date", type: "TEXT"),
            .init(name: "timestamp", type: "TEXT"),
            .init(name: "meal_type", type: "TEXT"),
            .init(name: "name", type: "TEXT"),
            .init(name: "brand", type: "TEXT"),
            .init(name: "scan_mode", type: "TEXT"),
            .init(name: "confidence", type: "REAL"),
            .init(name: "calories", type: "REAL"),
            .init(name: "protein", type: "REAL"),
            .init(name: "carbs", type: "REAL"),
            .init(name: "fat", type: "REAL"),
            .init(name: "serving_size", type: "TEXT"),
            .init(name: "servings_per_container", type: "REAL"),
            .init(name: "serving_count", type: "REAL"),
            .init(name: "serving_quantity", type: "REAL"),
            .init(name: "serving_unit", type: "TEXT"),
            .init(name: "saved_food_id", type: "TEXT"),
            .init(name: "scan_duration_ms", type: "INTEGER"),
            .init(name: "selection_summary", type: "TEXT"),
            .init(name: "healthkit_sync_status", type: "TEXT"),
            .init(name: "healthkit_synced_at", type: "TEXT"),
            .init(name: "healthkit_sync_version", type: "INTEGER"),
            .init(name: "healthkit_last_error", type: "TEXT"),
            .init(name: "healthkit_last_write_hash", type: "TEXT"),
            .init(name: "micronutrients_json", type: "TEXT"),
            .init(name: "serving_json", type: "TEXT"),
            .init(name: "serving_mappings_json", type: "TEXT"),
            .init(name: "mirror_generation", type: "TEXT")
        ]),
        TursoTableDefinition(name: "ofj_saved_foods", columns: [
            .init(name: "id", type: "TEXT PRIMARY KEY"),
            .init(name: "name", type: "TEXT"),
            .init(name: "brand", type: "TEXT"),
            .init(name: "created_at", type: "TEXT"),
            .init(name: "last_used_at", type: "TEXT"),
            .init(name: "archived_at", type: "TEXT"),
            .init(name: "kind", type: "TEXT"),
            .init(name: "original_scan_mode", type: "TEXT"),
            .init(name: "calories", type: "REAL"),
            .init(name: "protein", type: "REAL"),
            .init(name: "carbs", type: "REAL"),
            .init(name: "fat", type: "REAL"),
            .init(name: "serving_size", type: "TEXT"),
            .init(name: "servings_per_container", type: "REAL"),
            .init(name: "serving_quantity", type: "REAL"),
            .init(name: "serving_unit", type: "TEXT"),
            .init(name: "micronutrients_json", type: "TEXT"),
            .init(name: "serving_json", type: "TEXT"),
            .init(name: "serving_mappings_json", type: "TEXT"),
            .init(name: "composite_ingredients_json", type: "TEXT"),
            .init(name: "calculator_groups_json", type: "TEXT"),
            .init(name: "calculator_presets_json", type: "TEXT"),
            .init(name: "mirror_generation", type: "TEXT")
        ]),
        TursoTableDefinition(name: "ofj_tracked_containers", columns: [
            .init(name: "id", type: "TEXT PRIMARY KEY"),
            .init(name: "food_name", type: "TEXT"),
            .init(name: "food_brand", type: "TEXT"),
            .init(name: "calories_per_serving", type: "REAL"),
            .init(name: "protein_per_serving", type: "REAL"),
            .init(name: "carbs_per_serving", type: "REAL"),
            .init(name: "fat_per_serving", type: "REAL"),
            .init(name: "grams_per_serving", type: "REAL"),
            .init(name: "start_weight", type: "REAL"),
            .init(name: "final_weight", type: "REAL"),
            .init(name: "start_date", type: "TEXT"),
            .init(name: "completed_date", type: "TEXT"),
            .init(name: "saved_food_id", type: "TEXT"),
            .init(name: "micronutrients_json", type: "TEXT"),
            .init(name: "mirror_generation", type: "TEXT")
        ]),
        TursoTableDefinition(name: "ofj_preferences", columns: [
            .init(name: "id", type: "TEXT PRIMARY KEY"),
            .init(name: "ring_slot_1", type: "TEXT"),
            .init(name: "ring_slot_2", type: "TEXT"),
            .init(name: "ring_slot_3", type: "TEXT"),
            .init(name: "ring_slot_4", type: "TEXT"),
            .init(name: "ring_slot_5", type: "TEXT"),
            .init(name: "created_at", type: "TEXT"),
            .init(name: "updated_at", type: "TEXT"),
            .init(name: "mirror_generation", type: "TEXT")
        ]),
        TursoTableDefinition(name: "ofj_user_goals", columns: [
            .init(name: "id", type: "TEXT PRIMARY KEY"),
            .init(name: "daily_calories", type: "REAL"),
            .init(name: "daily_protein", type: "REAL"),
            .init(name: "daily_carbs", type: "REAL"),
            .init(name: "daily_fat", type: "REAL"),
            .init(name: "mirror_generation", type: "TEXT")
        ]),
        TursoTableDefinition(name: "ofj_app_settings", columns: [
            .init(name: "id", type: "TEXT PRIMARY KEY"),
            .init(name: "use_gemini_pro", type: "INTEGER"),
            .init(name: "off_contribute_enabled", type: "INTEGER"),
            .init(name: "off_contribution_success_count", type: "INTEGER"),
            .init(name: "off_last_contribution_at", type: "TEXT"),
            .init(name: "healthkit_enabled", type: "INTEGER"),
            .init(name: "turso_enabled", type: "INTEGER"),
            .init(name: "turso_include_diagnostics", type: "INTEGER"),
            .init(name: "app_version", type: "TEXT"),
            .init(name: "app_build", type: "TEXT"),
            .init(name: "mirror_generation", type: "TEXT")
        ]),
        TursoTableDefinition(name: "ofj_gemini_scan_logs", columns: [
            .init(name: "id", type: "TEXT PRIMARY KEY"),
            .init(name: "created_at", type: "TEXT"),
            .init(name: "operation", type: "TEXT"),
            .init(name: "status", type: "TEXT"),
            .init(name: "scan_mode", type: "TEXT"),
            .init(name: "primary_model", type: "TEXT"),
            .init(name: "fallback_model", type: "TEXT"),
            .init(name: "resolved_model", type: "TEXT"),
            .init(name: "resolved_model_version", type: "TEXT"),
            .init(name: "used_fallback", type: "INTEGER"),
            .init(name: "photo_count", type: "INTEGER"),
            .init(name: "duration_ms", type: "INTEGER"),
            .init(name: "user_prompt", type: "TEXT"),
            .init(name: "request_prompt", type: "TEXT"),
            .init(name: "request_prompt_character_count", type: "INTEGER"),
            .init(name: "request_metadata_json", type: "TEXT"),
            .init(name: "request_image_metadata_json", type: "TEXT"),
            .init(name: "request_payload_bytes", type: "INTEGER"),
            .init(name: "response_http_status", type: "INTEGER"),
            .init(name: "parse_stage", type: "TEXT"),
            .init(name: "response_text", type: "TEXT"),
            .init(name: "response_text_character_count", type: "INTEGER"),
            .init(name: "raw_response_json", type: "TEXT"),
            .init(name: "model_attempts_json", type: "TEXT"),
            .init(name: "input_token_count", type: "INTEGER"),
            .init(name: "output_token_count", type: "INTEGER"),
            .init(name: "thinking_token_count", type: "INTEGER"),
            .init(name: "total_token_count", type: "INTEGER"),
            .init(name: "estimated_token_cost_usd", type: "REAL"),
            .init(name: "pricing_model", type: "TEXT"),
            .init(name: "search_grounding_used", type: "INTEGER"),
            .init(name: "stream_event_count", type: "INTEGER"),
            .init(name: "thought_part_count", type: "INTEGER"),
            .init(name: "non_thought_part_count", type: "INTEGER"),
            .init(name: "result_name", type: "TEXT"),
            .init(name: "calories", type: "REAL"),
            .init(name: "protein", type: "REAL"),
            .init(name: "carbs", type: "REAL"),
            .init(name: "fat", type: "REAL"),
            .init(name: "error_code", type: "INTEGER"),
            .init(name: "error_message", type: "TEXT"),
            .init(name: "response_json", type: "TEXT"),
            .init(name: "thinking_trace_json", type: "TEXT"),
            .init(name: "app_version", type: "TEXT"),
            .init(name: "app_build", type: "TEXT"),
            .init(name: "os_version", type: "TEXT"),
            .init(name: "mirror_generation", type: "TEXT")
        ]),
        TursoTableDefinition(name: "ofj_gemini_cost_accumulators", columns: [
            .init(name: "id", type: "TEXT PRIMARY KEY"),
            .init(name: "created_at", type: "TEXT"),
            .init(name: "updated_at", type: "TEXT"),
            .init(name: "total_estimated_token_cost_usd", type: "REAL"),
            .init(name: "total_input_tokens", type: "INTEGER"),
            .init(name: "total_output_tokens", type: "INTEGER"),
            .init(name: "total_thinking_tokens", type: "INTEGER"),
            .init(name: "total_requests", type: "INTEGER"),
            .init(name: "successful_requests", type: "INTEGER"),
            .init(name: "failed_requests", type: "INTEGER"),
            .init(name: "grounded_search_prompts", type: "INTEGER"),
            .init(name: "last_estimated_token_cost_usd", type: "REAL"),
            .init(name: "last_input_tokens", type: "INTEGER"),
            .init(name: "last_output_tokens", type: "INTEGER"),
            .init(name: "last_thinking_tokens", type: "INTEGER"),
            .init(name: "last_model", type: "TEXT"),
            .init(name: "last_pricing_model", type: "TEXT"),
            .init(name: "last_recorded_at", type: "TEXT"),
            .init(name: "pricing_source", type: "TEXT"),
            .init(name: "mirror_generation", type: "TEXT")
        ])
    ]

    static var createTableStatements: [String] {
        tables.map(\.createStatement)
    }

    static var mirroredTableNames: [String] {
        tables.map(\.name).filter { $0 != "ofj_sync_runs" }
    }
}

struct TursoMirrorRow: Sendable {
    var table: String
    var primaryKey: String = "id"
    var columns: [String: TursoSQLValue]
}

@Observable
@MainActor
final class TursoMirrorService {
    static let enabledKey = "turso.enabled"
    static let includeDiagnosticsKey = "turso.includeDiagnostics"
    static let lastSyncAtKey = "turso.lastSyncAt"
    static let lastErrorKey = "turso.lastError"
    static let lastRowCountKey = "turso.lastRowCount"

    @ObservationIgnored
    private let modelContext: ModelContext
    @ObservationIgnored
    private let session: URLSession
    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let encoder: JSONEncoder
    @ObservationIgnored
    private let isoFormatter: ISO8601DateFormatter
    @ObservationIgnored
    private var scheduledTask: Task<Void, Never>?

    private(set) var isMirroring = false
    private(set) var isTestingConnection = false
    private(set) var lastSummary: TursoMirrorSummary?

    init(
        modelContext: ModelContext,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.modelContext = modelContext
        self.session = session
        self.defaults = defaults

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = isoFormatter

        if defaults.object(forKey: Self.includeDiagnosticsKey) == nil {
            defaults.set(true, forKey: Self.includeDiagnosticsKey)
        }
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    var includeDiagnostics: Bool {
        defaults.object(forKey: Self.includeDiagnosticsKey) as? Bool ?? true
    }

    var lastSyncAt: Date? {
        let timestamp = defaults.double(forKey: Self.lastSyncAtKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    var lastError: String? {
        let value = defaults.string(forKey: Self.lastErrorKey) ?? ""
        return value.isEmpty ? nil : value
    }

    var lastRowCount: Int {
        defaults.integer(forKey: Self.lastRowCountKey)
    }

    nonisolated static func normalizedHTTPURLString(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }

        let normalized: String
        if trimmed.lowercased().hasPrefix("libsql://") {
            normalized = "https://" + String(trimmed.dropFirst("libsql://".count))
        } else {
            normalized = trimmed
        }

        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    nonisolated static func pipelineURL(for databaseURL: URL) -> URL {
        databaseURL.appending(path: "v2").appending(path: "pipeline")
    }

    nonisolated static func healthURL(for databaseURL: URL) -> URL {
        databaseURL.appending(path: "health")
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            scheduleMirror(reason: "enabled")
        } else {
            scheduledTask?.cancel()
            scheduledTask = nil
        }
    }

    func setIncludeDiagnostics(_ include: Bool) {
        defaults.set(include, forKey: Self.includeDiagnosticsKey)
        if isEnabled {
            scheduleMirror(reason: "settings_include_diagnostics_changed")
        }
    }

    func testConnection() async throws {
        isTestingConnection = true
        defer { isTestingConnection = false }

        let credentials = try loadCredentials()
        var request = URLRequest(url: Self.healthURL(for: credentials.url))
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
    }

    func runMigrations() async throws {
        let credentials = try loadCredentials()
        for statement in TursoSchema.createTableStatements {
            try await execute([TursoSQLStatement(sql: statement)], credentials: credentials)
        }

        for table in TursoSchema.tables {
            try await ensureColumns(for: table, credentials: credentials)
        }
    }

    func scheduleMirror(reason: String) {
        guard isEnabled, KeychainService.hasTursoCredentials else { return }
        scheduledTask?.cancel()
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await self?.mirrorAll(reason: reason)
        }
    }

    func mirrorAll(reason: String) async {
        guard isEnabled else { return }
        guard !isMirroring else {
            scheduleMirror(reason: reason)
            return
        }

        isMirroring = true
        let generation = UUID().uuidString
        let runID = UUID().uuidString
        let startedAt = Date()
        var rowCounts: [String: Int] = [:]

        do {
            let credentials = try loadCredentials()
            try await runMigrations()
            try await upsertSyncRun(
                id: runID,
                generation: generation,
                startedAt: startedAt,
                finishedAt: nil,
                status: "running",
                reason: reason,
                rowCounts: [:],
                error: nil,
                credentials: credentials
            )

            let rowsByTable = try buildMirrorRows(generation: generation)
            for table in TursoSchema.mirroredTableNames {
                let rows = rowsByTable[table] ?? []
                try await mirror(rows: rows, in: table, generation: generation, credentials: credentials)
                rowCounts[table] = rows.count
            }

            try await upsertSyncRun(
                id: runID,
                generation: generation,
                startedAt: startedAt,
                finishedAt: Date(),
                status: "success",
                reason: reason,
                rowCounts: rowCounts,
                error: nil,
                credentials: credentials
            )

            let summary = TursoMirrorSummary(generation: generation, rowCounts: rowCounts)
            lastSummary = summary
            defaults.set(Date().timeIntervalSince1970, forKey: Self.lastSyncAtKey)
            defaults.set("", forKey: Self.lastErrorKey)
            defaults.set(summary.totalRows, forKey: Self.lastRowCountKey)
        } catch {
            let message = redacted(error.localizedDescription)
            defaults.set(message, forKey: Self.lastErrorKey)
            if let credentials = try? loadCredentials() {
                try? await upsertSyncRun(
                    id: runID,
                    generation: generation,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    status: "failure",
                    reason: reason,
                    rowCounts: rowCounts,
                    error: message,
                    credentials: credentials
                )
            }
        }

        isMirroring = false
    }

    // MARK: - Credentials

    private func loadCredentials() throws -> (url: URL, token: String) {
        guard let urlString = KeychainService.tursoDatabaseURL,
              let normalized = Self.normalizedHTTPURLString(urlString),
              let url = URL(string: normalized),
              let token = KeychainService.tursoAuthToken,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TursoMirrorError.missingCredentials
        }
        return (url, token)
    }

    // MARK: - SQL-over-HTTP

    private func execute(
        _ statements: [TursoSQLStatement],
        credentials: (url: URL, token: String)
    ) async throws {
        guard !statements.isEmpty else { return }
        for chunk in statements.chunked(into: 40) {
            _ = try await executePipeline(chunk, credentials: credentials)
        }
    }

    private func queryRows(
        sql: String,
        args: [TursoSQLValue] = [],
        credentials: (url: URL, token: String)
    ) async throws -> [[String: String?]] {
        let response = try await executePipeline(
            [TursoSQLStatement(sql: sql, args: args)],
            credentials: credentials
        )
        guard let result = response.firstStatementResult else { return [] }
        let names = result.cols?.map(\.name) ?? []
        guard !names.isEmpty else { return [] }

        return (result.rows ?? []).map { row in
            var output: [String: String?] = [:]
            for (index, name) in names.enumerated() {
                output[name] = index < row.count ? row[index].stringValue : nil
            }
            return output
        }
    }

    private func executePipeline(
        _ statements: [TursoSQLStatement],
        credentials: (url: URL, token: String)
    ) async throws -> TursoPipelineResponse {
        let operations = statements.map { TursoPipelineOperation.execute($0) } + [.close]
        let body = try JSONEncoder().encode(TursoPipelineRequest(requests: operations))

        var request = URLRequest(url: Self.pipelineURL(for: credentials.url))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 45

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let pipelineResponse = try JSONDecoder().decode(TursoPipelineResponse.self, from: data)
        if let error = pipelineResponse.firstError {
            throw TursoMirrorError.pipelineError(error)
        }
        return pipelineResponse
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TursoMirrorError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TursoMirrorError.httpStatus(http.statusCode, redacted(body))
        }
    }

    private func ensureColumns(
        for table: TursoTableDefinition,
        credentials: (url: URL, token: String)
    ) async throws {
        let rows = try await queryRows(sql: "PRAGMA table_info(\(table.name))", credentials: credentials)
        let existing = Set(rows.compactMap { $0["name"] ?? nil })
        guard !existing.isEmpty else { return }

        let missing = table.columns.filter { !existing.contains($0.name) && $0.type != "TEXT PRIMARY KEY" }
        guard !missing.isEmpty else { return }

        let statements = missing.map {
            TursoSQLStatement(sql: "ALTER TABLE \(table.name) ADD COLUMN \($0.name) \($0.type)")
        }
        try await execute(statements, credentials: credentials)
    }

    // MARK: - Mirror

    private func mirror(
        rows: [TursoMirrorRow],
        in table: String,
        generation: String,
        credentials: (url: URL, token: String)
    ) async throws {
        let upserts = rows.map(Self.upsertStatement(for:))
        try await execute(upserts, credentials: credentials)
        try await execute(
            [TursoSQLStatement(sql: "DELETE FROM \(table) WHERE mirror_generation != ?", args: [.text(generation)])],
            credentials: credentials
        )
    }

    nonisolated static func upsertStatement(for row: TursoMirrorRow) -> TursoSQLStatement {
        let columns = row.columns.keys.sorted()
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let updateAssignments = columns
            .filter { $0 != row.primaryKey }
            .map { "\($0) = excluded.\($0)" }
            .joined(separator: ", ")
        let sql = """
        INSERT INTO \(row.table) (\(columns.joined(separator: ", ")))
        VALUES (\(placeholders))
        ON CONFLICT(\(row.primaryKey)) DO UPDATE SET \(updateAssignments)
        """
        return TursoSQLStatement(sql: sql, args: columns.compactMap { row.columns[$0] })
    }

    private func upsertSyncRun(
        id: String,
        generation: String,
        startedAt: Date,
        finishedAt: Date?,
        status: String,
        reason: String,
        rowCounts: [String: Int],
        error: String?,
        credentials: (url: URL, token: String)
    ) async throws {
        let row = TursoMirrorRow(table: "ofj_sync_runs", columns: [
            "id": .text(id),
            "started_at": .text(iso(startedAt)),
            "finished_at": optionalDate(finishedAt),
            "status": .text(status),
            "reason": .text(reason),
            "row_count": .integer(rowCounts.values.reduce(0, +)),
            "table_counts_json": .text(jsonString(rowCounts)),
            "error": optionalString(error),
            "mirror_generation": .text(generation)
        ])
        try await execute([Self.upsertStatement(for: row)], credentials: credentials)
    }

    private func buildMirrorRows(generation: String) throws -> [String: [TursoMirrorRow]] {
        var rowsByTable: [String: [TursoMirrorRow]] = [:]

        func append(_ row: TursoMirrorRow) {
            rowsByTable[row.table, default: []].append(row)
        }

        let dailyLogs = fetch(FetchDescriptor<DailyLog>(sortBy: [SortDescriptor(\.date, order: .forward)]))
        let entries = fetch(FetchDescriptor<NutritionEntry>(sortBy: [SortDescriptor(\.timestamp, order: .forward)]))
        let foods = fetch(FetchDescriptor<SavedFood>(sortBy: [SortDescriptor(\.createdAt, order: .forward)]))
        let containers = fetch(FetchDescriptor<TrackedContainer>(sortBy: [SortDescriptor(\.startDate, order: .forward)]))
        let preferences = Preferences.current(in: modelContext)

        for log in dailyLogs {
            append(TursoMirrorRow(table: "ofj_daily_logs", columns: [
                "id": .text(log.id.uuidString),
                "date": .text(dayString(log.date)),
                "notes": optionalString(log.notes),
                "entry_count": .integer(log.safeEntries.count),
                "total_calories": .real(log.totalCalories),
                "total_protein": .real(log.totalProtein),
                "total_carbs": .real(log.totalCarbs),
                "total_fat": .real(log.totalFat),
                "mirror_generation": .text(generation)
            ]))
        }

        for entry in entries {
            append(TursoMirrorRow(table: "ofj_nutrition_entries", columns: [
                "id": .text(entry.id.uuidString),
                "daily_log_id": optionalUUID(entry.dailyLog?.id),
                "log_date": .text(dayString(entry.dailyLog?.date ?? entry.timestamp)),
                "timestamp": .text(iso(entry.timestamp)),
                "meal_type": .text(entry.mealType.rawValue),
                "name": .text(entry.name),
                "brand": optionalString(entry.brand),
                "scan_mode": .text(entry.scanMode.rawValue),
                "confidence": optionalDouble(entry.confidence),
                "calories": .real(entry.calories),
                "protein": .real(entry.protein),
                "carbs": .real(entry.carbs),
                "fat": .real(entry.fat),
                "serving_size": optionalString(entry.servingSize),
                "servings_per_container": optionalDouble(entry.servingsPerContainer),
                "serving_count": .real(entry.servingCount),
                "serving_quantity": optionalDouble(entry.servingQuantity),
                "serving_unit": optionalString(entry.servingUnit),
                "saved_food_id": optionalUUID(entry.savedFoodID),
                "scan_duration_ms": optionalInt(entry.scanDurationMs),
                "selection_summary": optionalString(entry.selectionSummary),
                "healthkit_sync_status": .text(entry.healthKitSyncStatus.rawValue),
                "healthkit_synced_at": optionalDate(entry.healthKitSyncedAt),
                "healthkit_sync_version": .integer(entry.healthKitSyncVersion),
                "healthkit_last_error": optionalString(entry.healthKitLastError),
                "healthkit_last_write_hash": optionalString(entry.healthKitLastWriteHash),
                "micronutrients_json": .text(jsonString(entry.micronutrients)),
                "serving_json": optionalJSON(entry.serving),
                "serving_mappings_json": .text(jsonString(entry.servingMappings)),
                "mirror_generation": .text(generation)
            ]))
        }

        for food in foods {
            append(TursoMirrorRow(table: "ofj_saved_foods", columns: [
                "id": .text(food.id.uuidString),
                "name": .text(food.name),
                "brand": optionalString(food.brand),
                "created_at": .text(iso(food.createdAt)),
                "last_used_at": .text(iso(food.lastUsedAt)),
                "archived_at": optionalDate(food.archivedAt),
                "kind": .text(food.kind.rawValue),
                "original_scan_mode": .text(food.originalScanMode.rawValue),
                "calories": .real(food.calories),
                "protein": .real(food.protein),
                "carbs": .real(food.carbs),
                "fat": .real(food.fat),
                "serving_size": optionalString(food.servingSize),
                "servings_per_container": optionalDouble(food.servingsPerContainer),
                "serving_quantity": optionalDouble(food.servingQuantity),
                "serving_unit": optionalString(food.servingUnit),
                "micronutrients_json": .text(jsonString(food.micronutrients)),
                "serving_json": optionalJSON(food.serving),
                "serving_mappings_json": .text(jsonString(food.servingMappings)),
                "composite_ingredients_json": .text(jsonString(food.compositeIngredients)),
                "calculator_groups_json": .text(jsonString(food.calculatorGroups)),
                "calculator_presets_json": .text(jsonString(food.calculatorPresets)),
                "mirror_generation": .text(generation)
            ]))
        }

        for container in containers {
            append(TursoMirrorRow(table: "ofj_tracked_containers", columns: [
                "id": .text(container.id.uuidString),
                "food_name": .text(container.foodName),
                "food_brand": optionalString(container.foodBrand),
                "calories_per_serving": .real(container.caloriesPerServing),
                "protein_per_serving": .real(container.proteinPerServing),
                "carbs_per_serving": .real(container.carbsPerServing),
                "fat_per_serving": .real(container.fatPerServing),
                "grams_per_serving": .real(container.gramsPerServing),
                "start_weight": .real(container.startWeight),
                "final_weight": optionalDouble(container.finalWeight),
                "start_date": .text(iso(container.startDate)),
                "completed_date": optionalDate(container.completedDate),
                "saved_food_id": optionalUUID(container.savedFoodID),
                "micronutrients_json": .text(jsonString(container.micronutrientsPerServing)),
                "mirror_generation": .text(generation)
            ]))
        }

        append(TursoMirrorRow(table: "ofj_preferences", columns: [
            "id": .text("default"),
            "ring_slot_1": .text(preferences.ringSlot1),
            "ring_slot_2": .text(preferences.ringSlot2),
            "ring_slot_3": .text(preferences.ringSlot3),
            "ring_slot_4": .text(preferences.ringSlot4),
            "ring_slot_5": .text(preferences.ringSlot5),
            "created_at": .text(iso(preferences.createdAt)),
            "updated_at": .text(iso(preferences.updatedAt)),
            "mirror_generation": .text(generation)
        ]))

        append(TursoMirrorRow(table: "ofj_user_goals", columns: [
            "id": .text("default"),
            "daily_calories": .real(defaults.doubleOrDefault(forKey: "goals.calories", default: 2000)),
            "daily_protein": .real(defaults.doubleOrDefault(forKey: "goals.protein", default: 150)),
            "daily_carbs": .real(defaults.doubleOrDefault(forKey: "goals.carbs", default: 200)),
            "daily_fat": .real(defaults.doubleOrDefault(forKey: "goals.fat", default: 65)),
            "mirror_generation": .text(generation)
        ]))

        append(TursoMirrorRow(table: "ofj_app_settings", columns: [
            "id": .text("default"),
            "use_gemini_pro": .bool(defaults.bool(forKey: "scan.useProModel")),
            "off_contribute_enabled": .bool(defaults.bool(forKey: "off.contributeEnabled")),
            "off_contribution_success_count": .integer(defaults.integer(forKey: "off.contributionSuccessCount")),
            "off_last_contribution_at": optionalDate(timestamp: defaults.double(forKey: "off.lastContributionAt")),
            "healthkit_enabled": .bool(defaults.bool(forKey: "healthkit.enabled")),
            "turso_enabled": .bool(isEnabled),
            "turso_include_diagnostics": .bool(includeDiagnostics),
            "app_version": .text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"),
            "app_build": .text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"),
            "mirror_generation": .text(generation)
        ]))

        if includeDiagnostics {
            let scanLogs = fetch(FetchDescriptor<GeminiScanLog>(sortBy: [SortDescriptor(\.createdAt, order: .forward)]))
            for log in scanLogs {
                append(TursoMirrorRow(table: "ofj_gemini_scan_logs", columns: [
                    "id": .text(log.id.uuidString),
                    "created_at": .text(iso(log.createdAt)),
                    "operation": .text(log.operation.rawValue),
                    "status": .text(log.status.rawValue),
                    "scan_mode": optionalString(log.scanMode),
                    "primary_model": optionalString(log.primaryModel),
                    "fallback_model": optionalString(log.fallbackModel),
                    "resolved_model": optionalString(log.resolvedModel),
                    "resolved_model_version": optionalString(log.resolvedModelVersion),
                    "used_fallback": .bool(log.usedFallback),
                    "photo_count": .integer(log.photoCount),
                    "duration_ms": optionalInt(log.durationMs),
                    "user_prompt": optionalString(log.userPrompt),
                    "request_prompt": optionalString(log.requestPrompt),
                    "request_prompt_character_count": .integer(log.requestPromptCharacterCount),
                    "request_metadata_json": optionalString(log.requestMetadataJSON),
                    "request_image_metadata_json": optionalString(log.requestImageMetadataJSON),
                    "request_payload_bytes": optionalInt(log.requestPayloadBytes),
                    "response_http_status": optionalInt(log.responseHTTPStatus),
                    "parse_stage": optionalString(log.parseStage),
                    "response_text": optionalString(log.responseText),
                    "response_text_character_count": .integer(log.responseTextCharacterCount),
                    "raw_response_json": optionalString(log.rawResponseJSON),
                    "model_attempts_json": optionalString(log.modelAttemptsJSON),
                    "input_token_count": .integer(log.inputTokenCount),
                    "output_token_count": .integer(log.outputTokenCount),
                    "thinking_token_count": .integer(log.thinkingTokenCount),
                    "total_token_count": .integer(log.totalTokenCount),
                    "estimated_token_cost_usd": .real(log.estimatedTokenCostUSD),
                    "pricing_model": optionalString(log.pricingModel),
                    "search_grounding_used": .bool(log.searchGroundingUsed),
                    "stream_event_count": .integer(log.streamEventCount),
                    "thought_part_count": .integer(log.thoughtPartCount),
                    "non_thought_part_count": .integer(log.nonThoughtPartCount),
                    "result_name": optionalString(log.resultName),
                    "calories": optionalDouble(log.calories),
                    "protein": optionalDouble(log.protein),
                    "carbs": optionalDouble(log.carbs),
                    "fat": optionalDouble(log.fat),
                    "error_code": optionalInt(log.errorCode),
                    "error_message": optionalString(log.errorMessage),
                    "response_json": optionalString(log.responseJSON),
                    "thinking_trace_json": .text(jsonString(log.thinkingTrace)),
                    "app_version": optionalString(log.appVersion),
                    "app_build": optionalString(log.appBuild),
                    "os_version": optionalString(log.osVersion),
                    "mirror_generation": .text(generation)
                ]))
            }

            let accumulators = fetch(FetchDescriptor<GeminiCostAccumulator>(sortBy: [SortDescriptor(\.createdAt, order: .forward)]))
            for accumulator in accumulators {
                append(TursoMirrorRow(table: "ofj_gemini_cost_accumulators", columns: [
                    "id": .text(accumulator.id.uuidString),
                    "created_at": .text(iso(accumulator.createdAt)),
                    "updated_at": .text(iso(accumulator.updatedAt)),
                    "total_estimated_token_cost_usd": .real(accumulator.totalEstimatedTokenCostUSD),
                    "total_input_tokens": .integer(accumulator.totalInputTokens),
                    "total_output_tokens": .integer(accumulator.totalOutputTokens),
                    "total_thinking_tokens": .integer(accumulator.totalThinkingTokens),
                    "total_requests": .integer(accumulator.totalRequests),
                    "successful_requests": .integer(accumulator.successfulRequests),
                    "failed_requests": .integer(accumulator.failedRequests),
                    "grounded_search_prompts": .integer(accumulator.groundedSearchPrompts),
                    "last_estimated_token_cost_usd": .real(accumulator.lastEstimatedTokenCostUSD),
                    "last_input_tokens": .integer(accumulator.lastInputTokens),
                    "last_output_tokens": .integer(accumulator.lastOutputTokens),
                    "last_thinking_tokens": .integer(accumulator.lastThinkingTokens),
                    "last_model": optionalString(accumulator.lastModel),
                    "last_pricing_model": optionalString(accumulator.lastPricingModel),
                    "last_recorded_at": optionalDate(accumulator.lastRecordedAt),
                    "pricing_source": .text(accumulator.pricingSource),
                    "mirror_generation": .text(generation)
                ]))
            }
        }

        return rowsByTable
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T] {
        (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Value Helpers

    private func optionalString(_ value: String?) -> TursoSQLValue {
        guard let value, !value.isEmpty else { return .null }
        return .text(value)
    }

    private func optionalUUID(_ value: UUID?) -> TursoSQLValue {
        value.map { .text($0.uuidString) } ?? .null
    }

    private func optionalDouble(_ value: Double?) -> TursoSQLValue {
        value.map(TursoSQLValue.real) ?? .null
    }

    private func optionalInt(_ value: Int?) -> TursoSQLValue {
        value.map(TursoSQLValue.integer) ?? .null
    }

    private func optionalDate(_ value: Date?) -> TursoSQLValue {
        value.map { .text(iso($0)) } ?? .null
    }

    private func optionalDate(timestamp: Double) -> TursoSQLValue {
        timestamp > 0 ? .text(iso(Date(timeIntervalSince1970: timestamp))) : .null
    }

    private func optionalJSON<T: Encodable>(_ value: T?) -> TursoSQLValue {
        value.map { .text(jsonString($0)) } ?? .null
    }

    private func jsonString<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private func dayString(_ date: Date) -> String {
        String(iso(date).prefix(10))
    }

    private func redacted(_ value: String) -> String {
        var output = value
        if let token = KeychainService.tursoAuthToken, !token.isEmpty {
            output = output.replacingOccurrences(of: token, with: "[redacted]")
        }
        if let url = KeychainService.tursoDatabaseURL, !url.isEmpty {
            output = output.replacingOccurrences(of: url, with: "[database-url]")
        }
        return output
    }
}

private struct TursoPipelineRequest: Encodable {
    var requests: [TursoPipelineOperation]
}

private enum TursoPipelineOperation: Encodable {
    case execute(TursoSQLStatement)
    case close

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .execute(let statement):
            try container.encode("execute", forKey: .type)
            try container.encode(statement, forKey: .stmt)
        case .close:
            try container.encode("close", forKey: .type)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case stmt
    }
}

private struct TursoPipelineResponse: Decodable {
    var results: [TursoPipelineResult]

    var firstError: String? {
        for result in results {
            if let error = result.error?.message {
                return error
            }
            if let responseError = result.response?.error?.message {
                return responseError
            }
        }
        return nil
    }

    var firstStatementResult: TursoStatementResult? {
        results.compactMap { $0.response?.result }.first
    }
}

private struct TursoPipelineResult: Decodable {
    var response: TursoExecuteResponse?
    var error: TursoPipelineFailure?
}

private struct TursoExecuteResponse: Decodable {
    var result: TursoStatementResult?
    var error: TursoPipelineFailure?
}

private struct TursoPipelineFailure: Decodable {
    var message: String?
}

private struct TursoStatementResult: Decodable {
    var cols: [TursoColumn]?
    var rows: [[TursoTypedValue]]?
}

private struct TursoColumn: Decodable {
    var name: String
}

private struct TursoTypedValue: Decodable {
    var type: String?
    var value: String?
    var base64: String?

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            type = try keyed.decodeIfPresent(String.self, forKey: .type)
            value = try keyed.decodeIfPresent(String.self, forKey: .value)
            base64 = try keyed.decodeIfPresent(String.self, forKey: .base64)
            return
        }

        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            type = "null"
            value = nil
            base64 = nil
        } else if let string = try? single.decode(String.self) {
            type = "text"
            value = string
            base64 = nil
        } else if let int = try? single.decode(Int.self) {
            type = "integer"
            value = String(int)
            base64 = nil
        } else if let double = try? single.decode(Double.self) {
            type = "float"
            value = String(double)
            base64 = nil
        } else {
            type = nil
            value = nil
            base64 = nil
        }
    }

    var stringValue: String? {
        guard type != "null" else { return nil }
        return value ?? base64
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case base64
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

private extension UserDefaults {
    func doubleOrDefault(forKey key: String, default defaultValue: Double) -> Double {
        object(forKey: key) == nil ? defaultValue : double(forKey: key)
    }
}
