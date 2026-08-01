// OpenFoodJournal — Turso Mirror Service
// Optional push-only SQL-over-HTTP mirror for user-owned debugging databases.
// AGPL-3.0 License

import Foundation
import Observation
import SwiftData

enum TursoMirrorError: LocalizedError, Sendable {
    case missingCredentials
    case disabledInDeveloperBuild
    case invalidDatabaseURL
    case invalidResponse
    case httpStatus(Int, String)
    case pipelineError(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Turso database URL and auth token are required."
        case .disabledInDeveloperBuild:
            "Turso is disabled in developer builds."
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
            try container.encode(value, forKey: .value)
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
            .init(name: "emoji", type: "TEXT"),
            .init(name: "created_at", type: "TEXT"),
            .init(name: "last_used_at", type: "TEXT"),
            .init(name: "archived_at", type: "TEXT"),
            .init(name: "is_on_shelf", type: "INTEGER"),
            .init(name: "kind", type: "TEXT"),
            .init(name: "generated_icon_image_bytes", type: "INTEGER"),
            .init(name: "generated_icon_image_mime_type", type: "TEXT"),
            .init(name: "generated_icon_image_updated_at", type: "TEXT"),
            .init(name: "generated_icon_image_prompt", type: "TEXT"),
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
            .init(name: "calculator_ingredients_json", type: "TEXT"),
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
            .init(name: "tare_weight", type: "REAL"),
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
            .init(name: "shelf_recommendations_enabled", type: "INTEGER"),
            .init(name: "shelf_suggestion_count", type: "INTEGER"),
            .init(name: "shelf_recommendation_style", type: "TEXT"),
            .init(name: "shelf_trigger_fraction", type: "REAL"),
            .init(name: "shelf_calorie_flexibility", type: "TEXT"),
            .init(name: "shelf_incomplete_nutrition_policy", type: "TEXT"),
            .init(name: "shelf_energy_intent", type: "TEXT"),
            .init(name: "shelf_nutrition_emphasis", type: "TEXT"),
            .init(name: "shelf_use_rolling_week_context", type: "INTEGER"),
            .init(name: "shelf_hard_cap_calories", type: "INTEGER"),
            .init(name: "shelf_hard_cap_sodium", type: "INTEGER"),
            .init(name: "shelf_custom_calories_policy", type: "TEXT"),
            .init(name: "shelf_custom_protein_policy", type: "TEXT"),
            .init(name: "shelf_custom_fiber_policy", type: "TEXT"),
            .init(name: "shelf_custom_carbs_policy", type: "TEXT"),
            .init(name: "shelf_custom_fat_policy", type: "TEXT"),
            .init(name: "shelf_custom_sodium_policy", type: "TEXT"),
            .init(name: "shelf_custom_calories_strength", type: "TEXT"),
            .init(name: "shelf_custom_protein_strength", type: "TEXT"),
            .init(name: "shelf_custom_fiber_strength", type: "TEXT"),
            .init(name: "shelf_custom_carbs_strength", type: "TEXT"),
            .init(name: "shelf_custom_fat_strength", type: "TEXT"),
            .init(name: "shelf_custom_sodium_strength", type: "TEXT"),
            .init(name: "shelf_custom_calories_role", type: "TEXT"),
            .init(name: "shelf_custom_protein_role", type: "TEXT"),
            .init(name: "shelf_custom_fiber_role", type: "TEXT"),
            .init(name: "shelf_custom_carbs_role", type: "TEXT"),
            .init(name: "shelf_custom_fat_role", type: "TEXT"),
            .init(name: "shelf_custom_sodium_role", type: "TEXT"),
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
            .init(name: "accent_theme", type: "TEXT"),
            .init(name: "use_gemini_pro", type: "INTEGER"),
            .init(name: "food_bank_auto_generate_emojis", type: "INTEGER"),
            .init(name: "food_bank_use_generated_icon_images", type: "INTEGER"),
            .init(name: "off_contribute_enabled", type: "INTEGER"),
            .init(name: "off_contribution_success_count", type: "INTEGER"),
            .init(name: "off_last_contribution_at", type: "TEXT"),
            .init(name: "meal_breakfast_start_minutes", type: "INTEGER"),
            .init(name: "meal_lunch_start_minutes", type: "INTEGER"),
            .init(name: "meal_dinner_start_minutes", type: "INTEGER"),
            .init(name: "healthkit_enabled", type: "INTEGER"),
            .init(name: "turso_enabled", type: "INTEGER"),
            .init(name: "turso_include_diagnostics", type: "INTEGER"),
            .init(name: "app_version", type: "TEXT"),
            .init(name: "app_bundle_id", type: "TEXT"),
            .init(name: "app_build", type: "TEXT"),
            .init(name: "mirror_generation", type: "TEXT")
        ]),
        TursoTableDefinition(name: "ofj_ai_diagnostic_events", columns: [
            .init(name: "id", type: "TEXT PRIMARY KEY"),
            .init(name: "created_at", type: "TEXT NOT NULL"),
            .init(name: "expires_at", type: "TEXT NOT NULL"),
            .init(name: "event_type", type: "TEXT NOT NULL"),
            .init(name: "operation", type: "TEXT NOT NULL"),
            .init(name: "status", type: "TEXT NOT NULL"),
            .init(name: "provider", type: "TEXT"),
            .init(name: "base_model", type: "TEXT"),
            .init(name: "deployment", type: "TEXT"),
            .init(name: "run_id", type: "TEXT"),
            .init(name: "thread_id", type: "TEXT"),
            .init(name: "turn_id", type: "TEXT"),
            .init(name: "call_id", type: "TEXT"),
            .init(name: "provider_request_id", type: "TEXT"),
            .init(name: "duration_ms", type: "INTEGER"),
            .init(name: "input_tokens", type: "INTEGER NOT NULL DEFAULT 0"),
            .init(name: "cached_input_tokens", type: "INTEGER NOT NULL DEFAULT 0"),
            .init(name: "output_tokens", type: "INTEGER NOT NULL DEFAULT 0"),
            .init(name: "reasoning_tokens", type: "INTEGER NOT NULL DEFAULT 0"),
            .init(name: "estimated_cost_usd", type: "REAL"),
            .init(name: "response_http_status", type: "INTEGER"),
            .init(name: "error_code", type: "TEXT"),
            .init(name: "error_message", type: "TEXT"),
            .init(name: "payload_json", type: "TEXT"),
            .init(name: "app_version", type: "TEXT"),
            .init(name: "app_build", type: "TEXT"),
            .init(name: "os_version", type: "TEXT")
        ]),
        TursoTableDefinition(name: "ofj_gemini_scan_logs", columns: [
            .init(name: "id", type: "TEXT PRIMARY KEY"),
            .init(name: "created_at", type: "TEXT"),
            .init(name: "operation", type: "TEXT"),
            .init(name: "status", type: "TEXT"),
            .init(name: "provider", type: "TEXT"),
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
            .init(name: "cached_input_token_count", type: "INTEGER"),
            .init(name: "output_token_count", type: "INTEGER"),
            .init(name: "thinking_token_count", type: "INTEGER"),
            .init(name: "total_token_count", type: "INTEGER"),
            .init(name: "estimated_token_cost_usd", type: "REAL"),
            .init(name: "pricing_model", type: "TEXT"),
            .init(name: "search_grounding_requested", type: "INTEGER"),
            .init(name: "search_grounding_used", type: "INTEGER"),
            .init(name: "web_search_queries_json", type: "TEXT"),
            .init(name: "grounding_source_urls_json", type: "TEXT"),
            .init(name: "grounding_source_titles_json", type: "TEXT"),
            .init(name: "grounding_metadata_json", type: "TEXT"),
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
            .init(name: "total_cached_input_tokens", type: "INTEGER"),
            .init(name: "total_output_tokens", type: "INTEGER"),
            .init(name: "total_thinking_tokens", type: "INTEGER"),
            .init(name: "total_requests", type: "INTEGER"),
            .init(name: "successful_requests", type: "INTEGER"),
            .init(name: "failed_requests", type: "INTEGER"),
            .init(name: "grounded_search_prompts", type: "INTEGER"),
            .init(name: "last_estimated_token_cost_usd", type: "REAL"),
            .init(name: "last_input_tokens", type: "INTEGER"),
            .init(name: "last_cached_input_tokens", type: "INTEGER"),
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
        // Diagnostic events are append-only and have their own acknowledgement
        // path. A full generation mirror must never prune that table.
        tables.map(\.name).filter {
            $0 != "ofj_sync_runs" && $0 != "ofj_ai_diagnostic_events"
        }
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
    static let lastDiagnosticUploadAtKey = "turso.lastDiagnosticUploadAt"

    @ObservationIgnored
    private let modelContext: ModelContext
    @ObservationIgnored
    private let session: URLSession
    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let credentialProvider: () -> (databaseURL: String?, authToken: String?)
    @ObservationIgnored
    private let encoder: JSONEncoder
    @ObservationIgnored
    private let isoFormatter: ISO8601DateFormatter
    @ObservationIgnored
    private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored
    private var diagnosticFlushTask: Task<Void, Never>?
    @ObservationIgnored
    private let diagnosticOutbox: AIDiagnosticOutboxStore
    @ObservationIgnored
    private var didRunMigrationsInProcess = false

    private(set) var isMirroring = false
    private(set) var isTestingConnection = false
    private(set) var lastSummary: TursoMirrorSummary?
    private(set) var pendingDiagnosticCount = 0

    init(
        modelContext: ModelContext,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        diagnosticOutboxURL: URL? = nil,
        diagnosticOutboxMaximumEvents: Int = AIDiagnosticOutboxStore.defaultMaximumEvents,
        diagnosticOutboxMaximumBytes: Int = AIDiagnosticOutboxStore.defaultMaximumBytes,
        diagnosticOutboxMaximumAge: TimeInterval = AIDiagnosticOutboxStore.defaultMaximumAge,
        credentialProvider: (() -> (databaseURL: String?, authToken: String?))? = nil
    ) {
        self.modelContext = modelContext
        self.session = session
        self.defaults = defaults
        self.credentialProvider = credentialProvider ?? {
            (KeychainService.tursoDatabaseURL, KeychainService.tursoAuthToken)
        }
        diagnosticOutbox = AIDiagnosticOutboxStore(
            fileURL: diagnosticOutboxURL,
            maximumEvents: diagnosticOutboxMaximumEvents,
            maximumBytes: diagnosticOutboxMaximumBytes,
            maximumAge: diagnosticOutboxMaximumAge
        )

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
        pendingDiagnosticCount = diagnosticOutbox.count
    }

    var isEnabled: Bool {
        #if DEBUG
        // Developer builds never mirror. The mirror is generation-pruned, so a
        // developer build pushing its own (separate, possibly empty) dataset
        // could delete rows the production app still relies on. Keychain
        // scoping already makes production credentials unreachable from a
        // Debug build, but that is incidental; this is the actual guarantee.
        return false
        #else
        return defaults.bool(forKey: Self.enabledKey)
        #endif
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
            Task { [weak self] in await self?.migrateLegacyDiagnostics() }
        } else {
            scheduledTask?.cancel()
            scheduledTask = nil
            diagnosticFlushTask?.cancel()
            diagnosticFlushTask = nil
            diagnosticOutbox.clear()
            pendingDiagnosticCount = 0
        }
    }

    func setIncludeDiagnostics(_ include: Bool) {
        defaults.set(include, forKey: Self.includeDiagnosticsKey)
        if !include {
            diagnosticFlushTask?.cancel()
            diagnosticOutbox.clear()
            pendingDiagnosticCount = 0
        }
        if isEnabled {
            scheduleMirror(reason: "settings_include_diagnostics_changed")
            if include {
                Task { [weak self] in await self?.migrateLegacyDiagnostics() }
            } else {
                Task { [weak self] in await self?.clearRemoteDiagnostics() }
            }
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
        try await ensureDiagnosticIndexes(credentials: credentials)
        didRunMigrationsInProcess = true
    }

    func scheduleMirror(reason: String) {
        guard isEnabled, hasCredentials else { return }
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

    // MARK: - Append-only AI diagnostics

    /// Enqueues an already-redacted event in a small local-only delivery queue.
    /// No diagnostic row is inserted into SwiftData or CloudKit.
    func recordDiagnostic(_ event: AIDiagnosticEvent) {
        guard isEnabled, includeDiagnostics, hasCredentials else { return }
        pendingDiagnosticCount = diagnosticOutbox.append(sanitized(event))
        diagnosticFlushTask?.cancel()
        diagnosticFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            _ = await self?.flushDiagnosticOutbox()
        }
    }

    /// Flushes the delivery queue with idempotent UUID upserts. Failure leaves
    /// events queued and never affects the scan or Assistant request that
    /// produced them.
    @discardableResult
    func flushDiagnosticOutbox() async -> Bool {
        guard isEnabled, includeDiagnostics, hasCredentials else {
            return false
        }
        let events = diagnosticOutbox.events()
        pendingDiagnosticCount = events.count

        do {
            let credentials = try loadCredentials()
            try await uploadDiagnosticEvents(events, credentials: credentials)

            pendingDiagnosticCount = diagnosticOutbox.remove(ids: Set(events.map(\.id)))
            if !events.isEmpty {
                defaults.set(Date().timeIntervalSince1970, forKey: Self.lastDiagnosticUploadAtKey)
            }
            defaults.set("", forKey: Self.lastErrorKey)
            return true
        } catch {
            defaults.set(redacted(error.localizedDescription), forKey: Self.lastErrorKey)
            pendingDiagnosticCount = diagnosticOutbox.count
            return false
        }
    }

    /// Converts the prior CloudKit-backed diagnostic rows once, uploads them,
    /// and only then deletes them locally. New diagnostics never take this path.
    func migrateLegacyDiagnostics() async {
        guard isEnabled, includeDiagnostics, hasCredentials else { return }
        let logs = fetch(FetchDescriptor<GeminiScanLog>(sortBy: [SortDescriptor(\.createdAt)]))
        let spans = fetch(FetchDescriptor<ChatDiagnosticSpan>(sortBy: [SortDescriptor(\.startedAt)]))
        let events = logs.map(AIDiagnosticEvent.init(scanLog:))
            + spans.map(AIDiagnosticEvent.init(span:))
        guard !events.isEmpty else {
            _ = await flushDiagnosticOutbox()
            return
        }

        do {
            let credentials = try loadCredentials()
            var index = 0
            while index < events.count {
                let end = min(index + 200, events.count)
                try await uploadDiagnosticEvents(
                    events[index..<end].map(sanitized),
                    credentials: credentials
                )
                index = end
            }

            for log in logs { modelContext.delete(log) }
            for span in spans { modelContext.delete(span) }
            try modelContext.save()
            defaults.set(Date().timeIntervalSince1970, forKey: Self.lastDiagnosticUploadAtKey)
            defaults.set("", forKey: Self.lastErrorKey)
            _ = await flushDiagnosticOutbox()
        } catch {
            defaults.set(redacted(error.localizedDescription), forKey: Self.lastErrorKey)
        }
    }

    func clearAIDiagnostics() async {
        diagnosticFlushTask?.cancel()
        diagnosticOutbox.clear()
        pendingDiagnosticCount = 0
        for log in fetch(FetchDescriptor<GeminiScanLog>()) { modelContext.delete(log) }
        for span in fetch(FetchDescriptor<ChatDiagnosticSpan>()) { modelContext.delete(span) }
        try? modelContext.save()
        await clearRemoteDiagnostics()
    }

    func exportDiagnosticCSV() async throws -> String {
        guard isEnabled, includeDiagnostics else { return "" }
        _ = await flushDiagnosticOutbox()
        let credentials = try loadCredentials()
        if !didRunMigrationsInProcess { try await runMigrations() }
        let columns = [
            "id", "created_at", "event_type", "operation", "status", "provider",
            "base_model", "deployment", "run_id", "thread_id", "turn_id", "call_id",
            "provider_request_id", "duration_ms", "input_tokens", "cached_input_tokens",
            "output_tokens", "reasoning_tokens", "estimated_cost_usd",
            "response_http_status", "error_code", "error_message", "payload_json",
            "app_version", "app_build", "os_version",
        ]
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -AIDiagnosticEvent.retentionDays,
            to: .now
        ) ?? .now
        let rows = try await queryRows(
            sql: "SELECT \(columns.joined(separator: ", ")) FROM ofj_ai_diagnostic_events WHERE created_at >= ? ORDER BY created_at DESC",
            args: [.text(iso(cutoff))],
            credentials: credentials
        )
        guard !rows.isEmpty else { return "" }
        func csv(_ value: String) -> String {
            "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        var output = [columns.map(csv).joined(separator: ",")]
        output.append(contentsOf: rows.map { row in
            columns.map { csv((row[$0] ?? nil) ?? "") }.joined(separator: ",")
        })
        return output.joined(separator: "\n")
    }

    private func uploadDiagnosticEvents(
        _ events: [AIDiagnosticEvent],
        credentials: (url: URL, token: String)
    ) async throws {
        if !didRunMigrationsInProcess { try await runMigrations() }
        if !events.isEmpty {
            try await execute(
                events.map { Self.upsertStatement(for: diagnosticRow(for: $0)) },
                credentials: credentials
            )
        }
        try await execute([
            TursoSQLStatement(
                sql: "DELETE FROM ofj_ai_diagnostic_events WHERE expires_at <= ?",
                args: [.text(iso(.now))]
            )
        ], credentials: credentials)
    }

    private func clearRemoteDiagnostics() async {
        guard hasCredentials else { return }
        do {
            let credentials = try loadCredentials()
            if !didRunMigrationsInProcess { try await runMigrations() }
            try await execute([
                TursoSQLStatement(sql: "DELETE FROM ofj_ai_diagnostic_events"),
                TursoSQLStatement(sql: "DELETE FROM ofj_gemini_scan_logs"),
            ], credentials: credentials)
        } catch {
            defaults.set(redacted(error.localizedDescription), forKey: Self.lastErrorKey)
        }
    }

    private func diagnosticRow(for event: AIDiagnosticEvent) -> TursoMirrorRow {
        TursoMirrorRow(table: "ofj_ai_diagnostic_events", columns: [
            "id": .text(event.id.uuidString),
            "created_at": .text(iso(event.createdAt)),
            "expires_at": .text(iso(event.expiresAt)),
            "event_type": .text(event.eventType),
            "operation": .text(event.operation),
            "status": .text(event.status),
            "provider": optionalString(event.providerID),
            "base_model": optionalString(event.baseModelID),
            "deployment": optionalString(event.deploymentID),
            "run_id": optionalUUID(event.runID),
            "thread_id": optionalUUID(event.threadID),
            "turn_id": optionalString(event.turnID),
            "call_id": optionalString(event.callID),
            "provider_request_id": optionalString(event.providerRequestID),
            "duration_ms": optionalInt(event.durationMs),
            "input_tokens": .integer(event.inputTokens),
            "cached_input_tokens": .integer(event.cachedInputTokens),
            "output_tokens": .integer(event.outputTokens),
            "reasoning_tokens": .integer(event.reasoningTokens),
            "estimated_cost_usd": optionalDouble(event.estimatedCostUSD),
            "response_http_status": optionalInt(event.responseHTTPStatus),
            "error_code": optionalString(event.errorCode),
            "error_message": optionalString(event.errorMessage),
            "payload_json": optionalString(event.payloadJSON),
            "app_version": optionalString(event.appVersion),
            "app_build": optionalString(event.appBuild),
            "os_version": optionalString(event.osVersion),
        ])
    }

    private func sanitized(_ event: AIDiagnosticEvent) -> AIDiagnosticEvent {
        var event = event
        event.errorMessage = event.errorMessage.map(redacted)
        event.payloadJSON = event.payloadJSON.map(redacted)
        return event
    }

    // MARK: - Credentials

    private var hasCredentials: Bool {
        let credentials = credentialProvider()
        return Self.normalizedHTTPURLString(credentials.databaseURL ?? "") != nil
            && credentials.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func loadCredentials() throws -> (url: URL, token: String) {
        #if DEBUG
        // Every network path — mirrorAll, scheduleMirror, testConnection,
        // runMigrations, the diagnostic flush/export, and clearRemoteDiagnostics
        // — resolves credentials here. Failing at this one point disables all of
        // them, including any path added later. Guarding only `isEnabled` left
        // testConnection, runMigrations and clearRemoteDiagnostics reachable,
        // and clearRemoteDiagnostics issues DELETE statements.
        throw TursoMirrorError.disabledInDeveloperBuild
        #else
        let credentials = credentialProvider()
        guard let urlString = credentials.databaseURL,
              let normalized = Self.normalizedHTTPURLString(urlString),
              let url = URL(string: normalized),
              let token = credentials.authToken,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TursoMirrorError.missingCredentials
        }
        return (url, token)
        #endif
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

    private func ensureDiagnosticIndexes(
        credentials: (url: URL, token: String)
    ) async throws {
        try await execute([
            TursoSQLStatement(sql: "CREATE INDEX IF NOT EXISTS idx_ofj_ai_events_created_at ON ofj_ai_diagnostic_events(created_at)"),
            TursoSQLStatement(sql: "CREATE INDEX IF NOT EXISTS idx_ofj_ai_events_run_id ON ofj_ai_diagnostic_events(run_id)"),
            TursoSQLStatement(sql: "CREATE INDEX IF NOT EXISTS idx_ofj_ai_events_request_id ON ofj_ai_diagnostic_events(provider_request_id)"),
            TursoSQLStatement(sql: "CREATE INDEX IF NOT EXISTS idx_ofj_ai_events_provider_model ON ofj_ai_diagnostic_events(provider, base_model, deployment)"),
            TursoSQLStatement(sql: "CREATE INDEX IF NOT EXISTS idx_ofj_ai_events_operation_status ON ofj_ai_diagnostic_events(operation, status)"),
            TursoSQLStatement(sql: "CREATE INDEX IF NOT EXISTS idx_ofj_ai_events_expires_at ON ofj_ai_diagnostic_events(expires_at)"),
        ], credentials: credentials)
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

    static func trackedContainerMirrorRow(
        _ container: TrackedContainer,
        generation: String,
        startDate: String,
        completedDate: String?,
        micronutrientsJSON: String
    ) -> TursoMirrorRow {
        TursoMirrorRow(table: "ofj_tracked_containers", columns: [
            "id": .text(container.id.uuidString),
            "food_name": .text(container.foodName),
            "food_brand": container.foodBrand.map(TursoSQLValue.text) ?? .null,
            "calories_per_serving": .real(container.caloriesPerServing),
            "protein_per_serving": .real(container.proteinPerServing),
            "carbs_per_serving": .real(container.carbsPerServing),
            "fat_per_serving": .real(container.fatPerServing),
            "grams_per_serving": .real(container.gramsPerServing),
            "tare_weight": container.tareWeight.map(TursoSQLValue.real) ?? .null,
            "start_weight": .real(container.startWeight),
            "final_weight": container.finalWeight.map(TursoSQLValue.real) ?? .null,
            "start_date": .text(startDate),
            "completed_date": completedDate.map(TursoSQLValue.text) ?? .null,
            "saved_food_id": container.savedFoodID.map {
                .text($0.uuidString)
            } ?? .null,
            "micronutrients_json": .text(micronutrientsJSON),
            "mirror_generation": .text(generation)
        ])
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
                "emoji": optionalString(food.emoji),
                "created_at": .text(iso(food.createdAt)),
                "last_used_at": .text(iso(food.lastUsedAt)),
                "archived_at": optionalDate(food.archivedAt),
                "is_on_shelf": .bool(food.isOnShelf),
                "kind": .text(food.kind.rawValue),
                "generated_icon_image_bytes": optionalInt(food.generatedIconImageData?.count),
                "generated_icon_image_mime_type": optionalString(food.generatedIconImageMimeType),
                "generated_icon_image_updated_at": optionalDate(food.generatedIconImageUpdatedAt),
                "generated_icon_image_prompt": optionalString(food.generatedIconImagePrompt),
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
                "calculator_ingredients_json": .text(jsonString(food.calculatorIngredients)),
                "mirror_generation": .text(generation)
            ]))
        }

        for container in containers {
            append(Self.trackedContainerMirrorRow(
                container,
                generation: generation,
                startDate: iso(container.startDate),
                completedDate: container.completedDate.map { iso($0) },
                micronutrientsJSON: jsonString(container.micronutrientsPerServing)
            ))
        }

        append(TursoMirrorRow(table: "ofj_preferences", columns: [
            "id": .text("default"),
            "ring_slot_1": .text(preferences.ringSlot1),
            "ring_slot_2": .text(preferences.ringSlot2),
            "ring_slot_3": .text(preferences.ringSlot3),
            "ring_slot_4": .text(preferences.ringSlot4),
            "ring_slot_5": .text(preferences.ringSlot5),
            "shelf_recommendations_enabled": .bool(preferences.shelfRecommendationsEnabled),
            "shelf_suggestion_count": .integer(preferences.clampedShelfSuggestionCount),
            "shelf_recommendation_style": .text(preferences.shelfRecommendationStyleRawValue),
            "shelf_trigger_fraction": .real(preferences.shelfTriggerFraction),
            "shelf_calorie_flexibility": .text(preferences.shelfCalorieFlexibilityRawValue),
            "shelf_incomplete_nutrition_policy": .text(preferences.shelfIncompleteNutritionPolicyRawValue),
            "shelf_energy_intent": .text(preferences.shelfEnergyIntentRawValue),
            "shelf_nutrition_emphasis": .text(preferences.shelfNutritionEmphasis.rawValue),
            "shelf_use_rolling_week_context": .bool(preferences.shelfUseRollingWeekContext),
            "shelf_hard_cap_calories": .bool(preferences.shelfHardCapCalories),
            "shelf_hard_cap_sodium": .bool(preferences.shelfHardCapSodium),
            "shelf_custom_calories_policy": .text(preferences.shelfCustomCaloriesPolicyRawValue),
            "shelf_custom_protein_policy": .text(preferences.shelfCustomProteinPolicyRawValue),
            "shelf_custom_fiber_policy": .text(preferences.shelfCustomFiberPolicyRawValue),
            "shelf_custom_carbs_policy": .text(preferences.shelfCustomCarbsPolicyRawValue),
            "shelf_custom_fat_policy": .text(preferences.shelfCustomFatPolicyRawValue),
            "shelf_custom_sodium_policy": .text(preferences.shelfCustomSodiumPolicyRawValue),
            "shelf_custom_calories_strength": .text(preferences.shelfCustomCaloriesStrengthRawValue),
            "shelf_custom_protein_strength": .text(preferences.shelfCustomProteinStrengthRawValue),
            "shelf_custom_fiber_strength": .text(preferences.shelfCustomFiberStrengthRawValue),
            "shelf_custom_carbs_strength": .text(preferences.shelfCustomCarbsStrengthRawValue),
            "shelf_custom_fat_strength": .text(preferences.shelfCustomFatStrengthRawValue),
            "shelf_custom_sodium_strength": .text(preferences.shelfCustomSodiumStrengthRawValue),
            "shelf_custom_calories_role": .text(preferences.shelfCustomCaloriesRoleRawValue),
            "shelf_custom_protein_role": .text(preferences.shelfCustomProteinRoleRawValue),
            "shelf_custom_fiber_role": .text(preferences.shelfCustomFiberRoleRawValue),
            "shelf_custom_carbs_role": .text(preferences.shelfCustomCarbsRoleRawValue),
            "shelf_custom_fat_role": .text(preferences.shelfCustomFatRoleRawValue),
            "shelf_custom_sodium_role": .text(preferences.shelfCustomSodiumRoleRawValue),
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
            "accent_theme": .text(
                OFJAccentTheme.resolved(
                    from: defaults.string(forKey: OFJAccentTheme.storageKey)
                        ?? OFJAccentTheme.defaultTheme.rawValue
                ).rawValue
            ),
            "use_gemini_pro": .bool(defaults.bool(forKey: "scan.useProModel")),
            "food_bank_auto_generate_emojis": .bool(defaults.bool(forKey: FoodBankEmojiSettings.autoGenerateKey)),
            "food_bank_use_generated_icon_images": .bool(defaults.bool(forKey: FoodBankEmojiSettings.useGeneratedIconImagesKey)),
            "off_contribute_enabled": .bool(defaults.bool(forKey: "off.contributeEnabled")),
            "off_contribution_success_count": .integer(defaults.integer(forKey: "off.contributionSuccessCount")),
            "off_last_contribution_at": optionalDate(timestamp: defaults.double(forKey: "off.lastContributionAt")),
            "meal_breakfast_start_minutes": .integer(defaults.integerOrDefault(forKey: "mealSchedule.breakfastStartMinutes", default: MealScheduleDefaults.breakfastStartMinutes)),
            "meal_lunch_start_minutes": .integer(defaults.integerOrDefault(forKey: "mealSchedule.lunchStartMinutes", default: MealScheduleDefaults.lunchStartMinutes)),
            "meal_dinner_start_minutes": .integer(defaults.integerOrDefault(forKey: "mealSchedule.dinnerStartMinutes", default: MealScheduleDefaults.dinnerStartMinutes)),
            "healthkit_enabled": .bool(defaults.bool(forKey: "healthkit.enabled")),
            "turso_enabled": .bool(isEnabled),
            "turso_include_diagnostics": .bool(includeDiagnostics),
            "app_version": .text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"),
            // CURRENT_PROJECT_VERSION is only stamped with a real number by CI,
            // so app_build alone cannot identify which app produced a row.
            // Record the bundle identifier so every row is self-identifying.
            "app_bundle_id": .text(Bundle.main.bundleIdentifier ?? "unknown"),
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
                    "provider": optionalString(log.provider),
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
                    "cached_input_token_count": .integer(log.cachedInputTokenCount),
                    "output_token_count": .integer(log.outputTokenCount),
                    "thinking_token_count": .integer(log.thinkingTokenCount),
                    "total_token_count": .integer(log.totalTokenCount),
                    "estimated_token_cost_usd": .real(log.estimatedTokenCostUSD),
                    "pricing_model": optionalString(log.pricingModel),
                    "search_grounding_requested": .bool(log.searchGroundingRequested),
                    "search_grounding_used": .bool(log.searchGroundingUsed),
                    "web_search_queries_json": .text(jsonString(log.webSearchQueries)),
                    "grounding_source_urls_json": .text(jsonString(log.groundingSourceURLs)),
                    "grounding_source_titles_json": .text(jsonString(log.groundingSourceTitles)),
                    "grounding_metadata_json": optionalString(log.groundingMetadataJSON),
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
                    "total_cached_input_tokens": .integer(accumulator.totalCachedInputTokens),
                    "total_output_tokens": .integer(accumulator.totalOutputTokens),
                    "total_thinking_tokens": .integer(accumulator.totalThinkingTokens),
                    "total_requests": .integer(accumulator.totalRequests),
                    "successful_requests": .integer(accumulator.successfulRequests),
                    "failed_requests": .integer(accumulator.failedRequests),
                    "grounded_search_prompts": .integer(accumulator.groundedSearchPrompts),
                    "last_estimated_token_cost_usd": .real(accumulator.lastEstimatedTokenCostUSD),
                    "last_input_tokens": .integer(accumulator.lastInputTokens),
                    "last_cached_input_tokens": .integer(accumulator.lastCachedInputTokens),
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
        let diagnosticCredentials = credentialProvider()
        let secrets = [
            KeychainService.geminiAPIKey,
            KeychainService.openRouterAPIKey,
            KeychainService.azureOpenAIAPIKey,
            KeychainService.tavilyAPIKey,
            KeychainService.parallelAPIKey,
            KeychainService.tursoAuthToken,
            diagnosticCredentials.authToken,
        ]
        for secret in secrets.compactMap({ $0 }).filter({ !$0.isEmpty }) {
            output = output.replacingOccurrences(of: secret, with: "[redacted]")
        }
        let databaseURLs = [KeychainService.tursoDatabaseURL, diagnosticCredentials.databaseURL]
        for url in databaseURLs.compactMap({ $0 }).filter({ !$0.isEmpty }) {
            output = output.replacingOccurrences(of: url, with: "[database-url]")
        }
        return output
    }
}

extension TursoMirrorService: AIDiagnosticWriting {}

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

    func integerOrDefault(forKey key: String, default defaultValue: Int) -> Int {
        object(forKey: key) == nil ? defaultValue : integer(forKey: key)
    }
}
