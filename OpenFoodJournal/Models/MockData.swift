// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import SwiftData

// MARK: - Preview Model Container

extension ModelContainer {
    @MainActor
    static var preview: ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(
            for: NutritionEntry.self, DailyLog.self, SavedFood.self, TrackedContainer.self,
            configurations: config
        )

        // Seed with sample data
        let context = container.mainContext
        let log = DailyLog(date: .now)
        context.insert(log)

        for entry in NutritionEntry.samples {
            context.insert(entry)
            log.entries?.append(entry)
        }

        // Seed food bank with one saved food
        for food in SavedFood.samples {
            context.insert(food)
        }

        try? context.save()
        return container
    }
}

// MARK: - NutritionEntry Mock Data

extension NutritionEntry {
    static let samples: [NutritionEntry] = [
        NutritionEntry(
            name: "Greek Yogurt",
            mealType: .breakfast,
            scanMode: .label,
            confidence: 0.97,
            calories: 100,
            protein: 17,
            carbs: 6,
            fat: 0.7,
            micronutrients: [
                "Fiber": MicronutrientValue(value: 0, unit: "g"),
                "Sugar": MicronutrientValue(value: 4, unit: "g"),
                "Sodium": MicronutrientValue(value: 65, unit: "mg"),
                "Calcium": MicronutrientValue(value: 200, unit: "mg"),
            ],
            servingSize: "170g",
            servingsPerContainer: 1
        ),
        NutritionEntry(
            name: "Blueberries",
            mealType: .breakfast,
            scanMode: .foodPhoto,
            confidence: 0.72,
            calories: 84,
            protein: 1.1,
            carbs: 21.4,
            fat: 0.5,
            micronutrients: [
                "Fiber": MicronutrientValue(value: 3.6, unit: "g"),
                "Sugar": MicronutrientValue(value: 14.7, unit: "g"),
                "Vitamin C": MicronutrientValue(value: 14.4, unit: "mg"),
                "Vitamin K": MicronutrientValue(value: 28.6, unit: "mcg"),
            ]
        ),
        NutritionEntry(
            name: "Chicken Rice Bowl",
            mealType: .lunch,
            scanMode: .foodPhoto,
            confidence: 0.68,
            calories: 620,
            protein: 45,
            carbs: 72,
            fat: 14,
            micronutrients: [
                "Sodium": MicronutrientValue(value: 890, unit: "mg"),
            ]
        ),
        NutritionEntry(
            name: "Protein Bar",
            mealType: .snack,
            scanMode: .label,
            confidence: 0.99,
            calories: 200,
            protein: 20,
            carbs: 22,
            fat: 6,
            micronutrients: [
                "Fiber": MicronutrientValue(value: 5, unit: "g"),
                "Sugar": MicronutrientValue(value: 8, unit: "g"),
                "Sodium": MicronutrientValue(value: 140, unit: "mg"),
                "Saturated Fat": MicronutrientValue(value: 2, unit: "g"),
                "Iron": MicronutrientValue(value: 4, unit: "mg"),
            ],
            servingSize: "60g",
            servingsPerContainer: 1
        ),
        NutritionEntry(
            name: "Salmon & Vegetables",
            mealType: .dinner,
            scanMode: .manual,
            calories: 480,
            protein: 38,
            carbs: 24,
            fat: 22
        ),
    ]

    static let preview: NutritionEntry = samples[0]
}

// MARK: - SavedFood Mock Data

extension SavedFood {
    static let samples: [SavedFood] = [
        SavedFood(
            name: "Greek Yogurt (Fage 0%)",
            calories: 100,
            protein: 17,
            carbs: 6,
            fat: 0.7,
            micronutrients: [
                "Calcium": MicronutrientValue(value: 200, unit: "mg"),
                "Sugar": MicronutrientValue(value: 4, unit: "g"),
            ],
            servingSize: "170g",
            servingsPerContainer: 1,
            originalScanMode: .label
        ),
        SavedFood(
            name: "Protein Bar (Kirkland)",
            calories: 200,
            protein: 20,
            carbs: 22,
            fat: 6,
            micronutrients: [
                "Fiber": MicronutrientValue(value: 5, unit: "g"),
                "Sugar": MicronutrientValue(value: 8, unit: "g"),
                "Iron": MicronutrientValue(value: 4, unit: "mg"),
            ],
            servingSize: "60g",
            servingsPerContainer: 1,
            originalScanMode: .label
        ),
    ]

    static let preview: SavedFood = samples[0]
}

// MARK: - DailyLog Mock Data

extension DailyLog {
    @MainActor
    static var preview: DailyLog {
        let log = DailyLog(date: .now)
        log.entries = NutritionEntry.samples
        return log
    }

    @MainActor
    static var weekSamples: [DailyLog] {
        var logs: [DailyLog] = []
        let cal = Calendar.current
        for dayOffset in 0..<7 {
            guard let date = cal.date(byAdding: .day, value: -dayOffset, to: .now) else { continue }
            let log = DailyLog(date: date)
            // Vary calorie totals slightly per day
            let calMult = Double.random(in: 0.7...1.2)
            let entry = NutritionEntry(
                name: "Daily food",
                mealType: .lunch,
                scanMode: .manual,
                calories: 1800 * calMult,
                protein: 140 * calMult,
                carbs: 180 * calMult,
                fat: 60 * calMult
            )
            log.entries = [entry]
            logs.append(log)
        }
        return logs
    }
}
