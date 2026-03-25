// OpenFoodJournal — Turso Migration View
// One-time import tool to migrate existing data from the Turso REST API
// into local SwiftData (which CloudKit will then sync across devices).
//
// This view fetches all records from the old Turso-backed Express server
// and inserts them into the local SwiftData store. It should only need
// to be run once per device.
// AGPL-3.0 License

import SwiftUI
import SwiftData

// MARK: - API Response Types (copied from the removed SyncService)
// These types decode the JSON returned by GET /api/sync on the Turso server.

/// Top-level response from the Turso sync endpoint
private struct TursoSyncResponse: Codable {
    let dailyLogs: [TursoLog]
    let nutritionEntries: [TursoEntry]
    let savedFoods: [TursoFood]
    let trackedContainers: [TursoContainer]
    let userGoals: TursoGoals?
    let preferences: TursoPreferences?

    enum CodingKeys: String, CodingKey {
        case dailyLogs = "daily_logs"
        case nutritionEntries = "nutrition_entries"
        case savedFoods = "saved_foods"
        case trackedContainers = "tracked_containers"
        case userGoals = "user_goals"
        case preferences
    }
}

/// A daily log record from Turso
private struct TursoLog: Codable {
    let id: String
    let date: String
    enum CodingKeys: String, CodingKey { case id, date }
}

/// A nutrition entry record from Turso
private struct TursoEntry: Codable {
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
    let servingType: String?
    let servingGrams: Double?
    let servingMl: Double?
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

/// A saved food record from Turso
private struct TursoFood: Codable {
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
    let servingType: String?
    let servingGrams: Double?
    let servingMl: Double?
    let scanMode: String?

    enum CodingKeys: String, CodingKey {
        case id, name, brand, calories, protein, carbs, fat, micronutrients
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

/// A tracked container record from Turso
private struct TursoContainer: Codable {
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

/// User goals from Turso
private struct TursoGoals: Codable {
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

/// User preferences from Turso
private struct TursoPreferences: Codable {
    let ringSlot1: String?
    let ringSlot2: String?
    let ringSlot3: String?
    let ringSlot4: String?
    let ringSlot5: String?

    enum CodingKeys: String, CodingKey {
        case ringSlot1 = "ring_slot_1"
        case ringSlot2 = "ring_slot_2"
        case ringSlot3 = "ring_slot_3"
        case ringSlot4 = "ring_slot_4"
        case ringSlot5 = "ring_slot_5"
    }
}

// MARK: - Migration View

/// A one-time data migration tool accessible from Settings.
/// Fetches all records from the old Turso-backed Express server and inserts
/// them into local SwiftData. CloudKit will automatically sync these
/// records to all devices signed into the same iCloud account.
struct TursoMigrationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // The base URL of the old Express server (e.g. "https://macros-xxxx.onrender.com")
    // The user enters this in a text field since the server URL is no longer hardcoded.
    @State private var serverURL: String = ""

    // Migration progress tracking
    @State private var isMigrating = false
    @State private var statusMessage = ""
    @State private var logCount = 0
    @State private var entryCount = 0
    @State private var foodCount = 0
    @State private var containerCount = 0
    @State private var migrationComplete = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Server URL input
                Section {
                    TextField("https://your-server.onrender.com", text: $serverURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } header: {
                    Text("Turso Server URL")
                } footer: {
                    Text("Enter the URL of your old Macros sync server. This is a one-time import — your data will be copied into iCloud.")
                }

                // MARK: Migration button
                Section {
                    Button {
                        Task { await runMigration() }
                    } label: {
                        HStack {
                            if isMigrating {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isMigrating ? "Migrating..." : "Start Migration")
                        }
                    }
                    .disabled(serverURL.isEmpty || isMigrating || migrationComplete)
                }

                // MARK: Progress / results
                if !statusMessage.isEmpty {
                    Section("Status") {
                        Text(statusMessage)
                            .foregroundStyle(.secondary)

                        if migrationComplete {
                            LabeledContent("Daily Logs", value: "\(logCount)")
                            LabeledContent("Entries", value: "\(entryCount)")
                            LabeledContent("Saved Foods", value: "\(foodCount)")
                            LabeledContent("Containers", value: "\(containerCount)")
                        }
                    }
                }

                // MARK: Error display
                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import from Turso")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Migration Logic

    /// Fetches all data from the Turso server and inserts it into local SwiftData.
    /// Runs on a background thread to keep the UI responsive.
    private func runMigration() async {
        // Reset state
        isMigrating = true
        errorMessage = nil
        statusMessage = "Connecting to server..."

        do {
            // 1. Build the sync URL
            let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(trimmed)/api/sync") else {
                throw MigrationError.invalidURL
            }

            // 2. Fetch all data from the Turso server
            statusMessage = "Fetching data from server..."
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw MigrationError.serverError
            }

            // 3. Decode the Turso response
            statusMessage = "Decoding..."
            let decoder = JSONDecoder()
            let syncData = try decoder.decode(TursoSyncResponse.self, from: data)

            // 4. Insert records into SwiftData
            statusMessage = "Importing records..."
            try await importData(syncData)

            // 5. Done
            migrationComplete = true
            statusMessage = "Migration complete!"

        } catch let error as MigrationError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Unexpected error: \(error.localizedDescription)"
        }

        isMigrating = false
    }

    /// Inserts all decoded Turso records into the local SwiftData store.
    /// De-duplicates by UUID — if a record with the same ID already exists, it's skipped.
    @MainActor
    private func importData(_ data: TursoSyncResponse) throws {
        // --- Daily Logs ---
        // Build a lookup of existing logs by date to avoid duplicates
        let existingLogs = try modelContext.fetch(FetchDescriptor<DailyLog>())
        let existingLogDates = Set(existingLogs.map { Calendar.current.startOfDay(for: $0.date) })
        var logsByDate: [Date: DailyLog] = [:]
        for log in existingLogs {
            logsByDate[Calendar.current.startOfDay(for: log.date)] = log
        }

        // Create missing daily logs
        for tursoLog in data.dailyLogs {
            guard let date = parseDate(tursoLog.date) else { continue }
            let startOfDay = Calendar.current.startOfDay(for: date)

            if !existingLogDates.contains(startOfDay) {
                let newLog = DailyLog(
                    date: startOfDay,
                    id: UUID(uuidString: tursoLog.id) ?? UUID()
                )
                modelContext.insert(newLog)
                logsByDate[startOfDay] = newLog
                logCount += 1
            }
        }

        // --- Nutrition Entries ---
        // Build a set of existing entry IDs for fast dedup
        let existingEntries = try modelContext.fetch(FetchDescriptor<NutritionEntry>())
        let existingEntryIDs = Set(existingEntries.map { $0.id })

        for tursoEntry in data.nutritionEntries {
            let entryID = UUID(uuidString: tursoEntry.id) ?? UUID()
            guard !existingEntryIDs.contains(entryID) else { continue }

            // Find the parent log by looking up the Turso daily_log_id
            // First find the turso log's date, then find our local log
            let parentLog: DailyLog? = {
                guard let tursoLog = data.dailyLogs.first(where: { $0.id == tursoEntry.dailyLogId }),
                      let date = parseDate(tursoLog.date) else { return nil }
                return logsByDate[Calendar.current.startOfDay(for: date)]
            }()

            let entry = NutritionEntry(
                id: entryID,
                timestamp: parseTimestamp(tursoEntry.timestamp) ?? Date(),
                name: tursoEntry.name,
                mealType: parseMealType(tursoEntry.mealType),
                scanMode: parseScanMode(tursoEntry.scanMode),
                confidence: tursoEntry.confidence,
                calories: tursoEntry.calories,
                protein: tursoEntry.protein,
                carbs: tursoEntry.carbs,
                fat: tursoEntry.fat,
                micronutrients: tursoEntry.micronutrients ?? [:],
                servingSize: tursoEntry.servingSize,
                servingsPerContainer: tursoEntry.servingsPerContainer,
                brand: tursoEntry.brand,
                serving: buildServingSize(
                    type: tursoEntry.servingType,
                    grams: tursoEntry.servingGrams,
                    ml: tursoEntry.servingMl
                ),
                servingQuantity: tursoEntry.servingQuantity,
                servingUnit: tursoEntry.servingUnit,
                servingMappings: tursoEntry.servingMappings ?? []
            )

            modelContext.insert(entry)

            // Wire up the relationship to the parent daily log
            if let log = parentLog {
                entry.dailyLog = log
                if log.entries == nil { log.entries = [] }
                log.entries?.append(entry)
            }

            entryCount += 1
        }

        // --- Saved Foods ---
        let existingFoods = try modelContext.fetch(FetchDescriptor<SavedFood>())
        let existingFoodIDs = Set(existingFoods.map { $0.id })

        for tursoFood in data.savedFoods {
            let foodID = UUID(uuidString: tursoFood.id) ?? UUID()
            guard !existingFoodIDs.contains(foodID) else { continue }

            let food = SavedFood(
                id: foodID,
                name: tursoFood.name,
                brand: tursoFood.brand,
                calories: tursoFood.calories,
                protein: tursoFood.protein,
                carbs: tursoFood.carbs,
                fat: tursoFood.fat,
                micronutrients: tursoFood.micronutrients ?? [:],
                servingSize: tursoFood.servingSize,
                servingsPerContainer: tursoFood.servingsPerContainer,
                serving: buildServingSize(
                    type: tursoFood.servingType,
                    grams: tursoFood.servingGrams,
                    ml: tursoFood.servingMl
                ),
                servingQuantity: tursoFood.servingQuantity,
                servingUnit: tursoFood.servingUnit,
                servingMappings: tursoFood.servingMappings ?? [],
                originalScanMode: parseScanMode(tursoFood.scanMode)
            )

            modelContext.insert(food)
            foodCount += 1
        }

        // --- Tracked Containers ---
        let existingContainers = try modelContext.fetch(FetchDescriptor<TrackedContainer>())
        let existingContainerIDs = Set(existingContainers.map { $0.id })

        for tc in data.trackedContainers {
            let containerID = UUID(uuidString: tc.id) ?? UUID()
            guard !existingContainerIDs.contains(containerID) else { continue }

            let container = TrackedContainer(
                id: containerID,
                foodName: tc.foodName,
                foodBrand: tc.foodBrand,
                caloriesPerServing: tc.caloriesPerServing,
                proteinPerServing: tc.proteinPerServing,
                carbsPerServing: tc.carbsPerServing,
                fatPerServing: tc.fatPerServing,
                micronutrientsPerServing: tc.micronutrientsPerServing ?? [:],
                gramsPerServing: tc.gramsPerServing,
                startWeight: tc.startWeight,
                startDate: parseDate(tc.startDate) ?? Date(),
                savedFoodID: tc.savedFoodId.flatMap { UUID(uuidString: $0) }
            )
            // Set fields that aren't part of the init
            container.finalWeight = tc.finalWeight
            container.completedDate = tc.completedDate.flatMap { parseDate($0) }

            modelContext.insert(container)
            containerCount += 1
        }

        // --- User Goals (→ @AppStorage) ---
        if let goals = data.userGoals {
            if let cal = goals.calorieGoal { UserDefaults.standard.set(cal, forKey: "calorieGoal") }
            if let pro = goals.proteinGoal { UserDefaults.standard.set(pro, forKey: "proteinGoal") }
            if let carb = goals.carbsGoal { UserDefaults.standard.set(carb, forKey: "carbsGoal") }
            if let fatG = goals.fatGoal { UserDefaults.standard.set(fatG, forKey: "fatGoal") }
        }

        // --- Preferences (ring slots → @AppStorage) ---
        if let prefs = data.preferences {
            if let s1 = prefs.ringSlot1 { UserDefaults.standard.set(s1, forKey: "ringSlot1") }
            if let s2 = prefs.ringSlot2 { UserDefaults.standard.set(s2, forKey: "ringSlot2") }
            if let s3 = prefs.ringSlot3 { UserDefaults.standard.set(s3, forKey: "ringSlot3") }
            if let s4 = prefs.ringSlot4 { UserDefaults.standard.set(s4, forKey: "ringSlot4") }
            if let s5 = prefs.ringSlot5 { UserDefaults.standard.set(s5, forKey: "ringSlot5") }
        }

        // Persist all changes
        try modelContext.save()
    }

    // MARK: - Helpers

    /// Parse a date string in "YYYY-MM-DD" format (Turso stores dates this way)
    private func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)
    }

    /// Parse an ISO 8601 timestamp (used for entry timestamps)
    private func parseTimestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? {
            // Fallback without fractional seconds
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            return basic.date(from: string)
        }()
    }

    /// Convert a Turso meal type string to the MealType enum.
    /// Turso stores raw values like "Breakfast", "Lunch", etc.
    private func parseMealType(_ string: String) -> MealType {
        MealType(rawValue: string) ?? .snack
    }

    /// Convert a Turso scan mode string to the ScanMode enum.
    /// Turso stores raw values like "Label Scan", "Food Photo", "Manual".
    private func parseScanMode(_ string: String?) -> ScanMode {
        guard let string else { return .manual }
        return ScanMode(rawValue: string) ?? .manual
    }

    /// Build a ServingSize enum from the Turso fields (type, grams, ml).
    /// Returns nil if no serving type is specified.
    private func buildServingSize(type: String?, grams: Double?, ml: Double?) -> ServingSize? {
        switch type {
        case "mass":
            guard let g = grams else { return nil }
            return .mass(grams: g)
        case "volume":
            guard let m = ml else { return nil }
            return .volume(ml: m)
        case "both":
            guard let g = grams, let m = ml else { return nil }
            return .both(grams: g, ml: m)
        default:
            return nil
        }
    }
}

// MARK: - Migration Errors

private enum MigrationError: LocalizedError {
    case invalidURL
    case serverError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL. Please enter a valid URL."
        case .serverError:
            return "Server returned an error. Make sure the server is running and accessible."
        }
    }
}
