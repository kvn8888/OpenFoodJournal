// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import SwiftData
import Observation

@Observable
@MainActor
final class NutritionStore {
    let modelContext: ModelContext
    var syncService: SyncService?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Log Entry

    func log(_ entry: NutritionEntry, to date: Date) {
        let log = fetchOrCreateLog(for: date)
        modelContext.insert(entry)
        entry.dailyLog = log
        log.entries.append(entry)
        save()

        // Fire-and-forget sync to server
        let sync = syncService
        Task { try? await sync?.createEntry(entry, date: date) }
    }

    // MARK: - Fetch

    func fetchLog(for date: Date) -> DailyLog? {
        let startOfDay = Calendar.current.startOfDay(for: date)
        var descriptor = FetchDescriptor<DailyLog>(
            predicate: #Predicate { $0.date == startOfDay }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    func fetchLogs(from startDate: Date, to endDate: Date) -> [DailyLog] {
        let start = Calendar.current.startOfDay(for: startDate)
        let end = Calendar.current.startOfDay(for: endDate)
        let descriptor = FetchDescriptor<DailyLog>(
            predicate: #Predicate { $0.date >= start && $0.date <= end },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func fetchAllLogs() -> [DailyLog] {
        let descriptor = FetchDescriptor<DailyLog>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Delete

    func delete(_ entry: NutritionEntry) {
        let entryId = entry.id
        modelContext.delete(entry)
        save()

        // Fire-and-forget sync to server
        let sync = syncService
        Task { try? await sync?.deleteEntry(id: entryId) }
    }

    func delete(_ log: DailyLog) {
        // Delete all entries in this log from the server first
        let entryIds = log.entries.map(\.id)
        modelContext.delete(log)
        save()

        let sync = syncService
        Task {
            for id in entryIds {
                try? await sync?.deleteEntry(id: id)
            }
        }
    }

    // MARK: - Export

    /// Exports all logged entries as CSV. Core macros are always columns;
    /// micronutrients are collected across all entries and added as dynamic columns.
    func exportCSV() -> String {
        let logs = fetchAllLogs()

        // Collect all unique micronutrient names across every entry
        var allMicroNames = Set<String>()
        for log in logs {
            for entry in log.entries {
                allMicroNames.formUnion(entry.micronutrients.keys)
            }
        }
        let sortedMicroNames = allMicroNames.sorted()

        // Build header: fixed columns + dynamic micro columns
        var header = ["Date", "Meal", "Name", "Scan Mode", "Confidence",
                      "Calories", "Protein (g)", "Carbs (g)", "Fat (g)"]
        header.append(contentsOf: sortedMicroNames)
        var rows: [String] = [header.map { "\"\($0)\"" }.joined(separator: ",")]

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short

        for log in logs {
            for entry in log.entries.sorted(by: { $0.timestamp < $1.timestamp }) {
                let confidence = entry.confidence.map { String(format: "%.0f%%", $0 * 100) } ?? ""
                var fields = [
                    dateFormatter.string(from: log.date),
                    entry.mealType.rawValue,
                    entry.name,
                    entry.scanMode.rawValue,
                    confidence,
                    String(format: "%.1f", entry.calories),
                    String(format: "%.1f", entry.protein),
                    String(format: "%.1f", entry.carbs),
                    String(format: "%.1f", entry.fat),
                ]
                // Append each micronutrient value (or empty if entry doesn't have it)
                for microName in sortedMicroNames {
                    if let micro = entry.micronutrients[microName] {
                        fields.append(String(format: "%.1f %@", micro.value, micro.unit))
                    } else {
                        fields.append("")
                    }
                }
                rows.append(fields.map { "\"\($0)\"" }.joined(separator: ","))
            }
        }

        return rows.joined(separator: "\n")
    }

    // MARK: - Save (public for use in edit flows)

    func saveChanges() {
        save()
    }

    /// Save an entry's edits locally and sync the update to the server
    func saveAndSyncEntry(_ entry: NutritionEntry) {
        save()
        let sync = syncService
        Task { try? await sync?.updateEntry(entry) }
    }

    // MARK: - Server Sync

    /// Merges a SyncResponse from the server into the local SwiftData store.
    /// Inserts records that don't exist locally and updates records that do.
    /// Also applies user goals if present in the response.
    func applySync(_ response: SyncResponse, userGoals: UserGoals? = nil) {
        // ── Collect existing records for upsert ──────────────────────────
        let existingEntries = (try? modelContext.fetch(FetchDescriptor<NutritionEntry>())) ?? []
        let existingEntryMap = Dictionary(uniqueKeysWithValues: existingEntries.map { ($0.id, $0) })

        let existingFoods = (try? modelContext.fetch(FetchDescriptor<SavedFood>())) ?? []
        let existingFoodMap = Dictionary(uniqueKeysWithValues: existingFoods.map { ($0.id, $0) })

        let existingContainers = (try? modelContext.fetch(FetchDescriptor<TrackedContainer>())) ?? []
        let existingContainerMap = Dictionary(uniqueKeysWithValues: existingContainers.map { ($0.id, $0) })

        // ── 1. Ensure every APILog has a corresponding DailyLog ───────────
        var logByDate: [String: DailyLog] = [:]
        for apiLog in response.dailyLogs {
            let date = Self.parseDate(apiLog.date) ?? .now
            let log = fetchOrCreateLog(for: date)
            logByDate[apiLog.id] = log
        }

        // ── 2. Upsert NutritionEntry records ────────────────────────────
        for apiEntry in response.nutritionEntries {
            guard let entryUUID = UUID(uuidString: apiEntry.id) else { continue }
            guard let log = logByDate[apiEntry.dailyLogId] else { continue }

            let serving = Self.buildServingSize(
                type: apiEntry.servingType,
                grams: apiEntry.servingGrams,
                ml: apiEntry.servingMl
            )
            let timestamp = ISO8601DateFormatter().date(from: apiEntry.timestamp ?? "") ?? .now

            if let existing = existingEntryMap[entryUUID] {
                // Update existing entry with server values
                existing.name = apiEntry.name
                existing.mealType = MealType(rawValue: apiEntry.mealType) ?? .snack
                existing.scanMode = ScanMode(rawValue: apiEntry.scanMode ?? "manual") ?? .manual
                existing.confidence = apiEntry.confidence
                existing.calories = apiEntry.calories
                existing.protein = apiEntry.protein
                existing.carbs = apiEntry.carbs
                existing.fat = apiEntry.fat
                existing.micronutrients = apiEntry.micronutrients ?? [:]
                existing.servingSize = apiEntry.servingSize
                existing.servingsPerContainer = apiEntry.servingsPerContainer
                existing.brand = apiEntry.brand
                existing.serving = serving
                existing.servingQuantity = apiEntry.servingQuantity
                existing.servingUnit = apiEntry.servingUnit
                existing.servingMappings = apiEntry.servingMappings ?? []
            } else {
                let entry = NutritionEntry(
                    id: entryUUID,
                    timestamp: timestamp,
                    name: apiEntry.name,
                    mealType: MealType(rawValue: apiEntry.mealType) ?? .snack,
                    scanMode: ScanMode(rawValue: apiEntry.scanMode ?? "manual") ?? .manual,
                    confidence: apiEntry.confidence,
                    calories: apiEntry.calories,
                    protein: apiEntry.protein,
                    carbs: apiEntry.carbs,
                    fat: apiEntry.fat,
                    micronutrients: apiEntry.micronutrients ?? [:],
                    servingSize: apiEntry.servingSize,
                    servingsPerContainer: apiEntry.servingsPerContainer,
                    brand: apiEntry.brand,
                    serving: serving,
                    servingQuantity: apiEntry.servingQuantity,
                    servingUnit: apiEntry.servingUnit,
                    servingMappings: apiEntry.servingMappings ?? []
                )
                modelContext.insert(entry)
                entry.dailyLog = log
                log.entries.append(entry)
            }
        }

        // ── 3. Upsert SavedFood records ─────────────────────────────────
        for apiFood in response.savedFoods {
            guard let foodUUID = UUID(uuidString: apiFood.id) else { continue }

            let serving = Self.buildServingSize(
                type: apiFood.servingType,
                grams: apiFood.servingGrams,
                ml: apiFood.servingMl
            )

            if let existing = existingFoodMap[foodUUID] {
                existing.name = apiFood.name
                existing.brand = apiFood.brand
                existing.calories = apiFood.calories
                existing.protein = apiFood.protein
                existing.carbs = apiFood.carbs
                existing.fat = apiFood.fat
                existing.micronutrients = apiFood.micronutrients ?? [:]
                existing.servingSize = apiFood.servingSize
                existing.servingsPerContainer = apiFood.servingsPerContainer
                existing.serving = serving
                existing.servingQuantity = apiFood.servingQuantity
                existing.servingUnit = apiFood.servingUnit
                existing.servingMappings = apiFood.servingMappings ?? []
            } else {
                let food = SavedFood(
                    id: foodUUID,
                    name: apiFood.name,
                    brand: apiFood.brand,
                    calories: apiFood.calories,
                    protein: apiFood.protein,
                    carbs: apiFood.carbs,
                    fat: apiFood.fat,
                    micronutrients: apiFood.micronutrients ?? [:],
                    servingSize: apiFood.servingSize,
                    servingsPerContainer: apiFood.servingsPerContainer,
                    serving: serving,
                    servingQuantity: apiFood.servingQuantity,
                    servingUnit: apiFood.servingUnit,
                    servingMappings: apiFood.servingMappings ?? [],
                    originalScanMode: ScanMode(rawValue: apiFood.scanMode ?? "manual") ?? .manual
                )
                modelContext.insert(food)
            }
        }

        // ── 4. Upsert TrackedContainer records ──────────────────────────
        for apiContainer in response.trackedContainers {
            guard let containerUUID = UUID(uuidString: apiContainer.id) else { continue }

            if let existing = existingContainerMap[containerUUID] {
                existing.foodName = apiContainer.foodName
                existing.foodBrand = apiContainer.foodBrand
                existing.caloriesPerServing = apiContainer.caloriesPerServing
                existing.proteinPerServing = apiContainer.proteinPerServing
                existing.carbsPerServing = apiContainer.carbsPerServing
                existing.fatPerServing = apiContainer.fatPerServing
                existing.micronutrientsPerServing = apiContainer.micronutrientsPerServing ?? [:]
                existing.gramsPerServing = apiContainer.gramsPerServing
                existing.startWeight = apiContainer.startWeight
                existing.finalWeight = apiContainer.finalWeight
                if let completedStr = apiContainer.completedDate {
                    existing.completedDate = ISO8601DateFormatter().date(from: completedStr)
                }
            } else {
                let startDate = ISO8601DateFormatter().date(from: apiContainer.startDate) ?? .now
                let container = TrackedContainer(
                    id: containerUUID,
                    foodName: apiContainer.foodName,
                    foodBrand: apiContainer.foodBrand,
                    caloriesPerServing: apiContainer.caloriesPerServing,
                    proteinPerServing: apiContainer.proteinPerServing,
                    carbsPerServing: apiContainer.carbsPerServing,
                    fatPerServing: apiContainer.fatPerServing,
                    micronutrientsPerServing: apiContainer.micronutrientsPerServing ?? [:],
                    gramsPerServing: apiContainer.gramsPerServing,
                    startWeight: apiContainer.startWeight,
                    startDate: startDate,
                    savedFoodID: apiContainer.savedFoodId.flatMap { UUID(uuidString: $0) }
                )
                container.finalWeight = apiContainer.finalWeight
                container.completedDate = apiContainer.completedDate.flatMap { ISO8601DateFormatter().date(from: $0) }
                modelContext.insert(container)
            }
        }

        // ── 5. Apply user goals if present ───────────────────────────────
        if let goals = userGoals, let apiGoals = response.userGoals {
            if let cal = apiGoals.calorieGoal { goals.dailyCalories = cal }
            if let pro = apiGoals.proteinGoal { goals.dailyProtein = pro }
            if let carb = apiGoals.carbsGoal { goals.dailyCarbs = carb }
            if let fat = apiGoals.fatGoal { goals.dailyFat = fat }
        }

        // ── 6. Apply preferences if present ──────────────────────────────
        if let apiPrefs = response.preferences {
            let prefs = Preferences.current(in: modelContext)
            if let s1 = apiPrefs.ringSlot1 { prefs.ringSlot1 = s1 }
            if let s2 = apiPrefs.ringSlot2 { prefs.ringSlot2 = s2 }
            if let s3 = apiPrefs.ringSlot3 { prefs.ringSlot3 = s3 }
            if let s4 = apiPrefs.ringSlot4 { prefs.ringSlot4 = s4 }
            if let s5 = apiPrefs.ringSlot5 { prefs.ringSlot5 = s5 }
        }

        save()
    }

    // MARK: - Sync Helpers

    /// Parse an ISO date string like "2025-01-15" into the start-of-day Date in local time.
    private static func parseDate(_ string: String) -> Date? {
        // Try plain YYYY-MM-DD first (most common from the server)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        if let date = formatter.date(from: string) {
            return Calendar.current.startOfDay(for: date)
        }
        // Fall back to full ISO 8601
        return ISO8601DateFormatter().date(from: string).map {
            Calendar.current.startOfDay(for: $0)
        }
    }

    /// Reconstruct a ServingSize enum from the three column values stored in the database.
    /// Mirrors the fallback logic in ScanService.toNutritionEntry().
    private static func buildServingSize(type: String?, grams: Double?, ml: Double?) -> ServingSize? {
        switch type {
        case "both":
            if let g = grams, let m = ml { return .both(grams: g, ml: m) }
            fallthrough  // if one value is missing, degrade to mass or volume
        case "mass":
            if let g = grams { return .mass(grams: g) }
        case "volume":
            if let m = ml { return .volume(ml: m) }
        default:
            // Legacy rows — derive from gram weight if available
            if let g = grams { return .mass(grams: g) }
        }
        return nil
    }

    // MARK: - Micronutrient Aggregation

    /// The time period for aggregating micronutrient data
    enum TimePeriod: String, CaseIterable {
        case daily = "Today"
        case weekly = "This Week"
        case monthly = "This Month"
    }

    /// Aggregates all micronutrient values across entries in the given time period.
    /// Returns a dictionary of nutrient ID → total MicronutrientValue.
    /// For weekly/monthly, the values are per-day averages (total ÷ number of days in period).
    func aggregateMicronutrients(period: TimePeriod, referenceDate: Date = .now) -> [String: MicronutrientValue] {
        let calendar = Calendar.current
        let logs: [DailyLog]
        let dayCount: Double

        switch period {
        case .daily:
            // Just today's log
            if let log = fetchLog(for: referenceDate) {
                logs = [log]
            } else {
                logs = []
            }
            dayCount = 1

        case .weekly:
            // Last 7 days
            let start = calendar.date(byAdding: .day, value: -6, to: referenceDate) ?? referenceDate
            logs = fetchLogs(from: start, to: referenceDate)
            dayCount = 7

        case .monthly:
            // Last 30 days
            let start = calendar.date(byAdding: .day, value: -29, to: referenceDate) ?? referenceDate
            logs = fetchLogs(from: start, to: referenceDate)
            dayCount = 30
        }

        // Sum all micronutrient values across all entries in the fetched logs
        var totals: [String: (value: Double, unit: String)] = [:]
        for log in logs {
            for entry in log.entries {
                for (key, micro) in entry.micronutrients {
                    if let existing = totals[key] {
                        totals[key] = (existing.value + micro.value, micro.unit)
                    } else {
                        totals[key] = (micro.value, micro.unit)
                    }
                }
            }
        }

        // For daily view, return raw totals. For weekly/monthly, return daily average.
        let divisor = period == .daily ? 1.0 : dayCount
        var result: [String: MicronutrientValue] = [:]
        for (key, total) in totals {
            result[key] = MicronutrientValue(
                value: total.value / divisor,
                unit: total.unit
            )
        }

        return result
    }

    /// Aggregates macro totals across entries in the given time period.
    /// For weekly/monthly returns daily averages.
    func aggregateMacros(period: TimePeriod, referenceDate: Date = .now) -> (cal: Double, protein: Double, carbs: Double, fat: Double) {
        let calendar = Calendar.current
        let logs: [DailyLog]
        let dayCount: Double

        switch period {
        case .daily:
            if let log = fetchLog(for: referenceDate) {
                logs = [log]
            } else {
                logs = []
            }
            dayCount = 1
        case .weekly:
            let start = calendar.date(byAdding: .day, value: -6, to: referenceDate) ?? referenceDate
            logs = fetchLogs(from: start, to: referenceDate)
            dayCount = 7
        case .monthly:
            let start = calendar.date(byAdding: .day, value: -29, to: referenceDate) ?? referenceDate
            logs = fetchLogs(from: start, to: referenceDate)
            dayCount = 30
        }

        var cal = 0.0, protein = 0.0, carbs = 0.0, fat = 0.0
        for log in logs {
            for entry in log.entries {
                cal += entry.calories
                protein += entry.protein
                carbs += entry.carbs
                fat += entry.fat
            }
        }

        let divisor = period == .daily ? 1.0 : dayCount
        return (cal / divisor, protein / divisor, carbs / divisor, fat / divisor)
    }

    /// Returns all entries within the given time period, for per-food breakdowns.
    func entriesForPeriod(_ period: TimePeriod, referenceDate: Date = .now) -> [NutritionEntry] {
        let calendar = Calendar.current
        let logs: [DailyLog]

        switch period {
        case .daily:
            if let log = fetchLog(for: referenceDate) {
                logs = [log]
            } else {
                logs = []
            }
        case .weekly:
            let start = calendar.date(byAdding: .day, value: -6, to: referenceDate) ?? referenceDate
            logs = fetchLogs(from: start, to: referenceDate)
        case .monthly:
            let start = calendar.date(byAdding: .day, value: -29, to: referenceDate) ?? referenceDate
            logs = fetchLogs(from: start, to: referenceDate)
        }

        return logs.flatMap(\.entries)
    }

    // MARK: - Private

    private func fetchOrCreateLog(for date: Date) -> DailyLog {
        if let existing = fetchLog(for: date) {
            return existing
        }
        let log = DailyLog(date: date)
        modelContext.insert(log)
        return log
    }

    private func save() {
        try? modelContext.save()
    }
}
