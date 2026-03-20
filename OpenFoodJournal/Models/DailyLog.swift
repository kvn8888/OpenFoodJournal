// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import SwiftData

@Model
final class DailyLog {
    @Attribute(.unique)
    var date: Date  // normalized to start of day (midnight)

    var id: UUID
    var notes: String?

    @Relationship(deleteRule: .cascade, inverse: \NutritionEntry.dailyLog)
    var entries: [NutritionEntry]

    init(date: Date, id: UUID = UUID(), notes: String? = nil) {
        self.date = Calendar.current.startOfDay(for: date)
        self.id = id
        self.notes = notes
        self.entries = []
    }

    // MARK: - Computed Totals

    var totalCalories: Double {
        entries.reduce(0) { $0 + $1.calories }
    }

    var totalProtein: Double {
        entries.reduce(0) { $0 + $1.protein }
    }

    var totalCarbs: Double {
        entries.reduce(0) { $0 + $1.carbs }
    }

    var totalFat: Double {
        entries.reduce(0) { $0 + $1.fat }
    }

    // MARK: - Grouped Entries

    func entries(for mealType: MealType) -> [NutritionEntry] {
        entries
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
