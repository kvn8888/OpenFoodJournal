// OpenFoodJournal — Shared, query-backed Journal presentation values
// AGPL-3.0 License

import Foundation
import SwiftData

/// A render-time value, never a persisted cache. The Journal passes these same
/// totals to the macro bar and calendar so they cannot fetch different data.
nonisolated struct JournalDayTotals: Equatable, Sendable {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var micronutrients: [String: Double] = [:]

    static let zero = JournalDayTotals()

    init() {}

    @MainActor
    init(entries: [NutritionEntry]) {
        for entry in entries {
            calories += entry.calories
            protein += entry.protein
            carbs += entry.carbs
            fat += entry.fat
            for (key, nutrient) in entry.micronutrients {
                let normalized = KnownMicronutrients.normalize(key)
                micronutrients[normalized, default: 0] += nutrient.value
            }
        }
    }

    func calorieProgress(goal: Double) -> Double {
        guard goal.isFinite, goal > 0, calories.isFinite else { return 0 }
        return max(0, calories / goal)
    }
}

@MainActor
enum JournalDayData {
    static let weeksOfHistory = 52

    /// Used by @Query, not an imperative fetch in each calendar cell. No upper
    /// bound means a newly created tomorrow is still observable after midnight.
    static func fetchDescriptor(
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> FetchDescriptor<DailyLog> {
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: referenceDate)?.start
            ?? calendar.startOfDay(for: referenceDate)
        let firstWeek = calendar.date(byAdding: .weekOfYear, value: -weeksOfHistory, to: currentWeek)
            ?? currentWeek
        return FetchDescriptor<DailyLog>(
            predicate: #Predicate { $0.date >= firstWeek },
            sortBy: [SortDescriptor(\DailyLog.date)]
        )
    }

    /// Match NutritionStore.fetchLog's CloudKit duplicate-day rule: prefer the
    /// populated row, then the lowest stable UUID. Do not add duplicate totals.
    static func preferredLogs(
        from logs: [DailyLog],
        calendar: Calendar = .current
    ) -> [Date: DailyLog] {
        var result: [Date: DailyLog] = [:]
        for log in logs {
            let day = calendar.startOfDay(for: log.date)
            if let existing = result[day] {
                let count = log.safeEntries.count
                let existingCount = existing.safeEntries.count
                guard count > existingCount
                    || (count == existingCount && log.id.uuidString < existing.id.uuidString)
                else { continue }
            }
            result[day] = log
        }
        return result
    }

    static func totalsByDate(from logs: [Date: DailyLog]) -> [Date: JournalDayTotals] {
        logs.mapValues { JournalDayTotals(entries: $0.safeEntries) }
    }
}
