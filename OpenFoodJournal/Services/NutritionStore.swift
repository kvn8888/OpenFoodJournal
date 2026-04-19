// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import SwiftData
import Observation

@Observable
@MainActor
final class NutritionStore {
    let modelContext: ModelContext
    /// Bumped on every write so SwiftUI views that read it re-evaluate their computed properties
    private(set) var changeCount = 0

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Log Entry

    func log(_ entry: NutritionEntry, to date: Date) {
        let log = fetchOrCreateLog(for: date)
        modelContext.insert(entry)
        entry.dailyLog = log
        log.entries?.append(entry)
        save()
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
        modelContext.delete(entry)
        save()
    }

    func delete(_ log: DailyLog) {
        modelContext.delete(log)
        save()
    }

    // MARK: - Export

    /// Exports all logged entries as CSV. Core macros are always columns;
    /// micronutrients are collected across all entries and added as dynamic columns.
    /// Data comes from the local SwiftData store which CloudKit keeps in sync with iCloud.
    func exportCSV() -> String {
        // Fetch all entries directly — avoids missing orphaned entries not linked to a log
        var entryDescriptor = FetchDescriptor<NutritionEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let allEntries = (try? modelContext.fetch(entryDescriptor)) ?? []
        guard !allEntries.isEmpty else { return "" }

        // Collect all unique micronutrient names across every entry
        var allMicroNames = Set<String>()
        for entry in allEntries {
            allMicroNames.formUnion(entry.micronutrients.keys)
        }
        let sortedMicroNames = allMicroNames.sorted()

        // Build header: fixed columns + dynamic micro columns
        var header = ["Date", "Time", "Meal", "Name", "Brand", "Scan Mode", "Confidence",
                      "Calories", "Protein (g)", "Carbs (g)", "Fat (g)",
                      "Serving Qty", "Serving Unit"]
        header.append(contentsOf: sortedMicroNames)
        var rows: [String] = [header.map { "\"\($0)\"" }.joined(separator: ",")]

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short

        for entry in allEntries {
            let logDate = entry.dailyLog?.date ?? entry.timestamp
            let confidence = entry.confidence.map { String(format: "%.0f%%", $0 * 100) } ?? ""
            var fields = [
                dateFormatter.string(from: logDate),
                timeFormatter.string(from: entry.timestamp),
                entry.mealType.rawValue,
                entry.name,
                entry.brand ?? "",
                entry.scanMode.rawValue,
                confidence,
                String(format: "%.1f", entry.calories),
                String(format: "%.1f", entry.protein),
                String(format: "%.1f", entry.carbs),
                String(format: "%.1f", entry.fat),
                entry.servingQuantity.map { String(format: "%.2f", $0) } ?? "",
                entry.servingUnit ?? "",
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

        return rows.joined(separator: "\n")
    }

    // MARK: - Save (public for use in edit flows)

    func saveChanges() {
        save()
    }

    /// Find the most recent journal entry for a food by name (and optionally brand).
    /// Returns the (quantity, unit) the user last used when logging this food.
    func lastUsedServing(forFoodNamed name: String, brand: String?) -> (quantity: Double, unit: String)? {
        var descriptor = FetchDescriptor<NutritionEntry>(
            predicate: #Predicate { $0.name == name },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let entry = try? modelContext.fetch(descriptor).first,
              let qty = entry.servingQuantity, qty > 0,
              let unit = entry.servingUnit, !unit.isEmpty else {
            return nil
        }
        return (qty, unit)
    }

    /// Save an entry's edits locally
    func saveEntry(_ entry: NutritionEntry) {
        save()
    }

    // MARK: - Serving Mapping Propagation

    /// Deduplicates a mappings array so there's at most one mapping per `from.unit`.
    /// When duplicates exist, the last one wins (most recently added/edited).
    static func dedupMappings(_ mappings: [ServingMapping]) -> [ServingMapping] {
        var seen: [String: Int] = [:]  // from.unit → index in result
        var result: [ServingMapping] = []
        for mapping in mappings {
            let key = mapping.from.unit.lowercased().trimmingCharacters(in: .whitespaces)
            if let existingIndex = seen[key] {
                // Replace the earlier mapping with this newer one
                result[existingIndex] = mapping
            } else {
                seen[key] = result.count
                result.append(mapping)
            }
        }
        return result
    }

    /// Updates a SavedFood's mappings and propagates to all linked NutritionEntries.
    /// Call this when the user edits mappings on a SavedFood (e.g. in LogFoodSheet).
    func updateMappings(on food: SavedFood, to newMappings: [ServingMapping]) {
        let deduped = Self.dedupMappings(newMappings)
        food.servingMappings = deduped

        // Propagate to all entries linked to this food
        let foodID = food.id
        let descriptor = FetchDescriptor<NutritionEntry>(
            predicate: #Predicate { $0.savedFoodID == foodID }
        )
        if let entries = try? modelContext.fetch(descriptor) {
            for entry in entries {
                entry.servingMappings = deduped
            }
        }
        save()
    }

    /// Updates an entry's mappings and propagates back to its SavedFood + sibling entries.
    /// Call this when the user edits mappings on a NutritionEntry (e.g. in EditEntryView).
    func updateMappings(on entry: NutritionEntry, to newMappings: [ServingMapping]) {
        let deduped = Self.dedupMappings(newMappings)
        entry.servingMappings = deduped

        // Propagate back to the SavedFood and all sibling entries
        guard let foodID = entry.savedFoodID else {
            save()
            return
        }

        // Find and update the parent SavedFood
        let foodDescriptor = FetchDescriptor<SavedFood>(
            predicate: #Predicate { $0.id == foodID }
        )
        if let food = try? modelContext.fetch(foodDescriptor).first {
            food.servingMappings = deduped
        }

        // Update all sibling entries (same savedFoodID, different id)
        let entryID = entry.id
        let entryDescriptor = FetchDescriptor<NutritionEntry>(
            predicate: #Predicate { $0.savedFoodID == foodID && $0.id != entryID }
        )
        if let siblings = try? modelContext.fetch(entryDescriptor) {
            for sibling in siblings {
                sibling.servingMappings = deduped
            }
        }
        save()
    }

    /// Adds a new mapping (or replaces an existing one with the same from.unit)
    /// on a SavedFood and propagates to all linked entries.
    func addMapping(_ mapping: ServingMapping, to food: SavedFood) {
        var current = food.servingMappings
        current.append(mapping)
        updateMappings(on: food, to: current)
    }

    /// Adds a new mapping (or replaces an existing one with the same from.unit)
    /// on an entry and propagates to SavedFood + siblings.
    func addMapping(_ mapping: ServingMapping, to entry: NutritionEntry) {
        var current = entry.servingMappings
        current.append(mapping)
        updateMappings(on: entry, to: current)
    }

    /// Replaces a mapping at a specific index on a SavedFood and propagates.
    func replaceMapping(at index: Int, with mapping: ServingMapping, on food: SavedFood) {
        guard index < food.servingMappings.count else { return }
        var current = food.servingMappings
        current[index] = mapping
        updateMappings(on: food, to: current)
    }

    /// Replaces a mapping at a specific index on an entry and propagates.
    func replaceMapping(at index: Int, with mapping: ServingMapping, on entry: NutritionEntry) {
        guard index < entry.servingMappings.count else { return }
        var current = entry.servingMappings
        current[index] = mapping
        updateMappings(on: entry, to: current)
    }

    // MARK: - Retrolink Old Entries

    /// One-time migration: links existing NutritionEntries that have no savedFoodID
    /// to their matching SavedFood by name + brand. Call once on app launch.
    func retrolinkOrphanedEntries() {
        // Fetch all entries without a savedFoodID
        let entryDescriptor = FetchDescriptor<NutritionEntry>(
            predicate: #Predicate { $0.savedFoodID == nil }
        )
        guard let orphans = try? modelContext.fetch(entryDescriptor), !orphans.isEmpty else { return }

        // Build a lookup table of SavedFoods by (lowercased name, lowercased brand)
        let foodDescriptor = FetchDescriptor<SavedFood>()
        guard let foods = try? modelContext.fetch(foodDescriptor) else { return }

        // Key: "name|brand" (both lowercased)
        var foodLookup: [String: SavedFood] = [:]
        for food in foods {
            let key = "\(food.name.lowercased())|\(food.brand?.lowercased() ?? "")"
            foodLookup[key] = food
        }

        var linked = 0
        for entry in orphans {
            let key = "\(entry.name.lowercased())|\(entry.brand?.lowercased() ?? "")"
            if let food = foodLookup[key] {
                entry.savedFoodID = food.id
                // Also sync mappings from the SavedFood (source of truth)
                entry.servingMappings = food.servingMappings
                linked += 1
            }
        }

        if linked > 0 {
            save()
        }
    }

    /// One-time migration: deduplicates serving mappings on all SavedFoods and their
    /// linked entries. Ensures only one mapping per from.unit exists.
    func deduplicateAllMappings() {
        let foodDescriptor = FetchDescriptor<SavedFood>()
        guard let foods = try? modelContext.fetch(foodDescriptor) else { return }

        var changed = false
        for food in foods where food.servingMappings.count > 1 {
            let deduped = Self.dedupMappings(food.servingMappings)
            if deduped.count != food.servingMappings.count {
                food.servingMappings = deduped
                changed = true
            }
        }

        let entryDescriptor = FetchDescriptor<NutritionEntry>()
        if let entries = try? modelContext.fetch(entryDescriptor) {
            for entry in entries where entry.servingMappings.count > 1 {
                let deduped = Self.dedupMappings(entry.servingMappings)
                if deduped.count != entry.servingMappings.count {
                    entry.servingMappings = deduped
                    changed = true
                }
            }
        }

        if changed { save() }
    }

    /// Move an entry to a different day's log (used when the user changes the date in EditEntryView)
    func moveEntry(_ entry: NutritionEntry, to newDate: Date) {
        // Remove from old log
        if let oldLog = entry.dailyLog {
            oldLog.entries?.removeAll { $0.id == entry.id }
        }
        // Attach to new (or existing) log
        let newLog = fetchOrCreateLog(for: newDate)
        entry.dailyLog = newLog
        newLog.entries?.append(entry)
        save()
    }

    // MARK: - Micronutrient Aggregation

    /// The time period for aggregating micronutrient data
    enum TimePeriod: String, CaseIterable {
        case daily = "Day"
        case weekly = "Week"
        case monthly = "Month"
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
            for entry in log.safeEntries {
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
            for entry in log.safeEntries {
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

        return logs.flatMap(\.safeEntries)
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
        changeCount += 1
    }
}
