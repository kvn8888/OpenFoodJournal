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
            for: NutritionEntry.self, DailyLog.self,
            configurations: config
        )

        // Seed with sample data
        let context = container.mainContext
        let log = DailyLog(date: .now)
        context.insert(log)

        for entry in NutritionEntry.samples {
            context.insert(entry)
            log.entries.append(entry)
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
            fiber: 0,
            sugar: 4,
            sodium: 65,
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
            fiber: 3.6,
            sugar: 14.7
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
            sodium: 890
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
            fiber: 5,
            sugar: 8,
            sodium: 140,
            saturatedFat: 2,
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
