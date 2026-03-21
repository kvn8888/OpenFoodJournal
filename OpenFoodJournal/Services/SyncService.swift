// OpenFoodJournal — SyncService
// Handles all communication between the iOS app and the Turso-backed REST API.
// This is the single point of network communication for CRUD operations.
//
// Architecture:
//   iOS App ←→ SyncService ←→ Express Proxy ←→ Turso (libSQL)
//
// The service is @Observable so views can react to sync state (loading, errors).
// All methods are async and throw on failure.
// SwiftData remains the local cache — SyncService pushes/pulls to keep them aligned.
// AGPL-3.0 License

import Foundation
import Observation

// MARK: - Sync Errors

enum SyncError: LocalizedError {
    case networkError(Error)
    case serverError(Int, String)
    case decodingError(Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .networkError(let e): "Network error: \(e.localizedDescription)"
        case .serverError(let code, let msg): "Server error \(code): \(msg)"
        case .decodingError(let e): "Decoding error: \(e.localizedDescription)"
        case .invalidResponse: "Invalid response from server"
        }
    }
}

// MARK: - API Response Types

/// Response from GET /api/sync — contains all data for initial or incremental sync
struct SyncResponse: Codable {
    let dailyLogs: [APILog]
    let nutritionEntries: [APIEntry]
    let savedFoods: [APIFood]
    let trackedContainers: [APIContainer]
    let userGoals: APIGoals?
    let syncedAt: String

    enum CodingKeys: String, CodingKey {
        case dailyLogs = "daily_logs"
        case nutritionEntries = "nutrition_entries"
        case savedFoods = "saved_foods"
        case trackedContainers = "tracked_containers"
        case userGoals = "user_goals"
        case syncedAt = "synced_at"
    }
}

/// A daily log from the API
struct APILog: Codable {
    let id: String
    let date: String
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, date
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// A nutrition entry from the API
struct APIEntry: Codable {
    let id: String
    let dailyLogId: String
    let name: String
    let brand: String?
    let mealType: String
    let scanMode: String?
    let confidence: Double?
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let micronutrients: [String: MicronutrientValue]?
    let servingSize: String?
    let servingsPerContainer: Double?
    let servingQuantity: Double?
    let servingUnit: String?
    let servingMappings: [ServingMapping]?
    // Structured serving fields — nil for entries created before this schema version
    let servingType: String?    // "mass" | "volume" | "both"
    let servingGrams: Double?   // canonical grams value
    let servingMl: Double?      // canonical mL value (nil for mass-only)
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case id, name, brand, confidence, calories, protein, carbs, fat
        case micronutrients, timestamp
        case dailyLogId = "daily_log_id"
        case mealType = "meal_type"
        case scanMode = "scan_mode"
        case servingSize = "serving_size"
        case servingsPerContainer = "servings_per_container"
        case servingQuantity = "serving_quantity"
        case servingUnit = "serving_unit"
        case servingMappings = "serving_mappings"
        case servingType = "serving_type"
        case servingGrams = "serving_grams"
        case servingMl = "serving_ml"
    }
}

/// A saved food from the API
struct APIFood: Codable {
    let id: String
    let name: String
    let brand: String?
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let micronutrients: [String: MicronutrientValue]?
    let servingSize: String?
    let servingsPerContainer: Double?
    let servingQuantity: Double?
    let servingUnit: String?
    let servingMappings: [ServingMapping]?
    // Structured serving fields
    let servingType: String?
    let servingGrams: Double?
    let servingMl: Double?
    let scanMode: String?

    enum CodingKeys: String, CodingKey {
        case id, name, brand, calories, protein, carbs, fat
        case micronutrients
        case servingSize = "serving_size"
        case servingsPerContainer = "servings_per_container"
        case servingQuantity = "serving_quantity"
        case servingUnit = "serving_unit"
        case servingMappings = "serving_mappings"
        case servingType = "serving_type"
        case servingGrams = "serving_grams"
        case servingMl = "serving_ml"
        case scanMode = "scan_mode"
    }
}

/// A tracked container from the API
struct APIContainer: Codable {
    let id: String
    let foodName: String
    let foodBrand: String?
    let caloriesPerServing: Double
    let proteinPerServing: Double
    let carbsPerServing: Double
    let fatPerServing: Double
    let micronutrientsPerServing: [String: MicronutrientValue]?
    let gramsPerServing: Double
    let startWeight: Double
    let finalWeight: Double?
    let startDate: String
    let completedDate: String?
    let savedFoodId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case foodName = "food_name"
        case foodBrand = "food_brand"
        case caloriesPerServing = "calories_per_serving"
        case proteinPerServing = "protein_per_serving"
        case carbsPerServing = "carbs_per_serving"
        case fatPerServing = "fat_per_serving"
        case micronutrientsPerServing = "micronutrients_per_serving"
        case gramsPerServing = "grams_per_serving"
        case startWeight = "start_weight"
        case finalWeight = "final_weight"
        case startDate = "start_date"
        case completedDate = "completed_date"
        case savedFoodId = "saved_food_id"
    }
}

/// User goals from the API
struct APIGoals: Codable {
    let calorieGoal: Double?
    let proteinGoal: Double?
    let carbsGoal: Double?
    let fatGoal: Double?

    enum CodingKeys: String, CodingKey {
        case calorieGoal = "calorie_goal"
        case proteinGoal = "protein_goal"
        case carbsGoal = "carbs_goal"
        case fatGoal = "fat_goal"
    }
}

/// Simple response for create operations
private struct CreateResponse: Codable {
    let id: String
    let dailyLogId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case dailyLogId = "daily_log_id"
    }
}

/// Simple response for update/delete operations
private struct MutationResponse: Codable {
    let updated: Bool?
    let deleted: Bool?
}

/// Error response from the server
private struct ServerError: Codable {
    let error: String
}

// MARK: - SyncService

@Observable
@MainActor
final class SyncService {
    // ── Observable State ──────────────────────────────────────────
    var isSyncing = false
    var syncError: SyncError?

    /// Persisted across launches so incremental sync knows where to resume from
    var lastSyncDate: Date? {
        get { UserDefaults.standard.object(forKey: "sync.lastSyncDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "sync.lastSyncDate") }
    }

    // ── Configuration ─────────────────────────────────────────────
    private let baseURL: URL = {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "RENDER_PROXY_URL") as? String
            ?? "https://openfoodjournal.onrender.com"
        return URL(string: urlString)!
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    // ══════════════════════════════════════════════════════════════
    // SYNC
    // ══════════════════════════════════════════════════════════════

    /// Pull all data from the server. Returns a SyncResponse containing everything.
    /// Call this on app launch to populate local SwiftData.
    func fetchAll() async throws -> SyncResponse {
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }

        let url = baseURL.appendingPathComponent("api/sync")
        let data = try await get(url: url)
        let response = try decoder.decode(SyncResponse.self, from: data)
        lastSyncDate = .now
        return response
    }

    /// Incremental sync — fetch only items changed since last sync
    func fetchChanges(since: Date) async throws -> SyncResponse {
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }

        var components = URLComponents(url: baseURL.appendingPathComponent("api/sync"), resolvingAgainstBaseURL: true)!
        components.queryItems = [URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since))]

        let data = try await get(url: components.url!)
        let response = try decoder.decode(SyncResponse.self, from: data)
        lastSyncDate = .now
        return response
    }

    // ══════════════════════════════════════════════════════════════
    // NUTRITION ENTRIES
    // ══════════════════════════════════════════════════════════════

    /// Create a nutrition entry on the server
    func createEntry(_ entry: NutritionEntry, date: Date) async throws {
        let dateStr = formatDate(date)
        let body: [String: Any] = [
            "id": entry.id.uuidString,
            "date": dateStr,
            "name": entry.name,
            "brand": entry.brand as Any,
            "meal_type": entry.mealType.rawValue,
            "scan_mode": entry.scanMode.rawValue,
            "confidence": entry.confidence as Any,
            "calories": entry.calories,
            "protein": entry.protein,
            "carbs": entry.carbs,
            "fat": entry.fat,
            "micronutrients": encodeMicronutrients(entry.micronutrients),
            "serving_size": entry.servingSize as Any,
            "servings_per_container": entry.servingsPerContainer as Any,
            "serving_quantity": entry.servingQuantity as Any,
            "serving_unit": entry.servingUnit as Any,
            "serving_mappings": encodeServingMappings(entry.servingMappings),
            "serving_type": entry.serving?.type as Any,
            "serving_grams": entry.serving?.grams as Any,
            "serving_ml": entry.serving?.ml as Any,
        ]

        let url = baseURL.appendingPathComponent("api/entries")
        try await post(url: url, body: body)
    }

    /// Update a nutrition entry on the server
    func updateEntry(_ entry: NutritionEntry) async throws {
        let body: [String: Any] = [
            "name": entry.name,
            "brand": entry.brand as Any,
            "meal_type": entry.mealType.rawValue,
            "calories": entry.calories,
            "protein": entry.protein,
            "carbs": entry.carbs,
            "fat": entry.fat,
            "micronutrients": encodeMicronutrients(entry.micronutrients),
            "serving_size": entry.servingSize as Any,
            "serving_quantity": entry.servingQuantity as Any,
            "serving_unit": entry.servingUnit as Any,
            "serving_mappings": encodeServingMappings(entry.servingMappings),
            "serving_type": entry.serving?.type as Any,
            "serving_grams": entry.serving?.grams as Any,
            "serving_ml": entry.serving?.ml as Any,
        ]

        let url = baseURL.appendingPathComponent("api/entries/\(entry.id.uuidString)")
        try await put(url: url, body: body)
    }

    /// Delete a nutrition entry on the server
    func deleteEntry(id: UUID) async throws {
        let url = baseURL.appendingPathComponent("api/entries/\(id.uuidString)")
        try await delete(url: url)
    }

    // ══════════════════════════════════════════════════════════════
    // SAVED FOODS (Food Bank)
    // ══════════════════════════════════════════════════════════════

    /// Create a saved food on the server
    func createFood(_ food: SavedFood) async throws {
        let body: [String: Any] = [
            "id": food.id.uuidString,
            "name": food.name,
            "brand": food.brand as Any,
            "calories": food.calories,
            "protein": food.protein,
            "carbs": food.carbs,
            "fat": food.fat,
            "micronutrients": encodeMicronutrients(food.micronutrients),
            "serving_size": food.servingSize as Any,
            "servings_per_container": food.servingsPerContainer as Any,
            "serving_quantity": food.servingQuantity as Any,
            "serving_unit": food.servingUnit as Any,
            "serving_mappings": encodeServingMappings(food.servingMappings),
            "serving_type": food.serving?.type as Any,
            "serving_grams": food.serving?.grams as Any,
            "serving_ml": food.serving?.ml as Any,
            "scan_mode": food.originalScanMode.rawValue,
        ]

        let url = baseURL.appendingPathComponent("api/foods")
        try await post(url: url, body: body)
    }

    /// Update a saved food on the server
    func updateFood(_ food: SavedFood) async throws {
        let body: [String: Any] = [
            "name": food.name,
            "brand": food.brand as Any,
            "calories": food.calories,
            "protein": food.protein,
            "carbs": food.carbs,
            "fat": food.fat,
            "micronutrients": encodeMicronutrients(food.micronutrients),
            "serving_size": food.servingSize as Any,
            "serving_quantity": food.servingQuantity as Any,
            "serving_unit": food.servingUnit as Any,
            "serving_mappings": encodeServingMappings(food.servingMappings),
            "serving_type": food.serving?.type as Any,
            "serving_grams": food.serving?.grams as Any,
            "serving_ml": food.serving?.ml as Any,
        ]

        let url = baseURL.appendingPathComponent("api/foods/\(food.id.uuidString)")
        try await put(url: url, body: body)
    }

    /// Delete a saved food on the server
    func deleteFood(id: UUID) async throws {
        let url = baseURL.appendingPathComponent("api/foods/\(id.uuidString)")
        try await delete(url: url)
    }

    // ══════════════════════════════════════════════════════════════
    // TRACKED CONTAINERS
    // ══════════════════════════════════════════════════════════════

    /// Create a tracked container on the server
    func createContainer(_ container: TrackedContainer) async throws {
        let body: [String: Any] = [
            "id": container.id.uuidString,
            "food_name": container.foodName,
            "food_brand": container.foodBrand as Any,
            "calories_per_serving": container.caloriesPerServing,
            "protein_per_serving": container.proteinPerServing,
            "carbs_per_serving": container.carbsPerServing,
            "fat_per_serving": container.fatPerServing,
            "micronutrients_per_serving": encodeMicronutrients(container.micronutrientsPerServing),
            "grams_per_serving": container.gramsPerServing,
            "start_weight": container.startWeight,
            "saved_food_id": container.savedFoodID?.uuidString as Any,
        ]

        let url = baseURL.appendingPathComponent("api/containers")
        try await post(url: url, body: body)
    }

    /// Complete a container (set final weight) on the server
    func completeContainer(id: UUID, finalWeight: Double) async throws {
        let body: [String: Any] = [
            "final_weight": finalWeight,
            "completed_date": ISO8601DateFormatter().string(from: .now),
        ]

        let url = baseURL.appendingPathComponent("api/containers/\(id.uuidString)")
        try await put(url: url, body: body)
    }

    /// Delete a tracked container on the server
    func deleteContainer(id: UUID) async throws {
        let url = baseURL.appendingPathComponent("api/containers/\(id.uuidString)")
        try await delete(url: url)
    }

    // ══════════════════════════════════════════════════════════════
    // USER GOALS
    // ══════════════════════════════════════════════════════════════

    /// Fetch user goals from the server
    func fetchGoals() async throws -> APIGoals {
        let url = baseURL.appendingPathComponent("api/goals")
        let data = try await get(url: url)
        return try decoder.decode(APIGoals.self, from: data)
    }

    /// Update user goals on the server
    func updateGoals(calories: Double, protein: Double, carbs: Double, fat: Double) async throws {
        let body: [String: Any] = [
            "calorie_goal": calories,
            "protein_goal": protein,
            "carbs_goal": carbs,
            "fat_goal": fat,
        ]

        let url = baseURL.appendingPathComponent("api/goals")
        try await put(url: url, body: body)
    }

    // ══════════════════════════════════════════════════════════════
    // PRIVATE NETWORK HELPERS
    // ══════════════════════════════════════════════════════════════

    /// Perform a GET request and return the response data
    private func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await execute(request)
    }

    /// Perform a POST request with a JSON body
    @discardableResult
    private func post(url: URL, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await execute(request)
    }

    /// Perform a PUT request with a JSON body
    @discardableResult
    private func put(url: URL, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await execute(request)
    }

    /// Perform a DELETE request
    @discardableResult
    private func delete(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        return try await execute(request)
    }

    /// Execute a URLRequest, handling errors and status codes
    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let syncErr = SyncError.networkError(error)
            self.syncError = syncErr
            throw syncErr
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            let syncErr = SyncError.invalidResponse
            self.syncError = syncErr
            throw syncErr
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error ?? "Unknown error"
            let syncErr = SyncError.serverError(httpResponse.statusCode, message)
            self.syncError = syncErr
            throw syncErr
        }

        return data
    }

    // ── Encoding Helpers ──────────────────────────────────────────

    /// Convert micronutrients dictionary to a JSON-serializable format
    private func encodeMicronutrients(_ micros: [String: MicronutrientValue]) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for (key, value) in micros {
            result[key] = ["value": value.value, "unit": value.unit]
        }
        return result
    }

    /// Convert serving mappings to a JSON-serializable format
    private func encodeServingMappings(_ mappings: [ServingMapping]) -> [[String: Any]] {
        mappings.map { mapping in
            [
                "from": ["value": mapping.from.value, "unit": mapping.from.unit],
                "to": ["value": mapping.to.value, "unit": mapping.to.unit],
            ]
        }
    }

    /// Format a Date as YYYY-MM-DD for the API
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
