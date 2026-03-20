// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import SwiftData
import Observation

@Observable
@MainActor
final class NutritionStore {
    let modelContext: ModelContext

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
