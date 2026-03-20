// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import SwiftData
import Observation

@Observable
@MainActor
final class NutritionStore {
    private let modelContext: ModelContext

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

    func exportCSV() -> String {
        let logs = fetchAllLogs()
        var rows: [String] = [
            "Date,Meal,Name,Scan Mode,Confidence,Calories,Protein (g),Carbs (g),Fat (g),Fiber (g),Sugar (g),Sodium (mg)"
        ]

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short

        for log in logs {
            for entry in log.entries.sorted(by: { $0.timestamp < $1.timestamp }) {
                let confidence = entry.confidence.map { String(format: "%.0f%%", $0 * 100) } ?? ""
                let row = [
                    dateFormatter.string(from: log.date),
                    entry.mealType.rawValue,
                    entry.name,
                    entry.scanMode.rawValue,
                    confidence,
                    String(format: "%.1f", entry.calories),
                    String(format: "%.1f", entry.protein),
                    String(format: "%.1f", entry.carbs),
                    String(format: "%.1f", entry.fat),
                    entry.fiber.map { String(format: "%.1f", $0) } ?? "",
                    entry.sugar.map { String(format: "%.1f", $0) } ?? "",
                    entry.sodium.map { String(format: "%.1f", $0) } ?? "",
                ].map { "\"\($0)\"" }.joined(separator: ",")
                rows.append(row)
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
