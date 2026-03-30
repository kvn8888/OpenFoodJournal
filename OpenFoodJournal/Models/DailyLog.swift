// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import SwiftData

@Model
final class DailyLog {
    // CloudKit note: @Attribute(.unique) removed — CloudKit can't enforce uniqueness.
    // App-level dedup via fetchOrCreateLog(for:) in NutritionStore handles this.
    var date: Date = Date()

    var id: UUID = UUID()
    var notes: String?

    // CloudKit note: relationships must be optional.
    @Relationship(deleteRule: .cascade, inverse: \NutritionEntry.dailyLog)
    var entries: [NutritionEntry]? = []

    init(date: Date, id: UUID = UUID(), notes: String? = nil) {
        self.date = Calendar.current.startOfDay(for: date)
        self.id = id
        self.notes = notes
        self.entries = []
    }

    // MARK: - Computed Totals

    // Convenience accessor that unwraps the optional relationship
    var safeEntries: [NutritionEntry] { entries ?? [] }

    var totalCalories: Double {
        safeEntries.reduce(0) { $0 + $1.calories }
    }

    var totalProtein: Double {
        safeEntries.reduce(0) { $0 + $1.protein }
    }

    var totalCarbs: Double {
        safeEntries.reduce(0) { $0 + $1.carbs }
    }

    var totalFat: Double {
        safeEntries.reduce(0) { $0 + $1.fat }
    }

    // MARK: - Grouped Entries

    func entries(for mealType: MealType) -> [NutritionEntry] {
        safeEntries
            .filter { $0.mealType == mealType }
            .sorted { $0.timestamp < $1.timestamp }
    }
}

// MARK: - Date Helpers

extension Date {
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }
}
