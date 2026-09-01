// Deterministic visual-test data. No fixture content is compiled into Release.
import Foundation

/// The visible calendar follows real time except in an explicitly opted-in
/// Debug screenshot run. Persistence and service clocks are not overridden.
enum AppPresentationDate {
    static var now: Date {
        #if DEBUG
        if ScreenshotConfiguration.isEnabled {
            return ScreenshotConfiguration.referenceDate
        }
        #endif
        return Date()
    }
}

#if DEBUG
import SwiftData
import UIKit

enum ScreenshotConfiguration {
    static let referenceDate = Date(timeIntervalSince1970: 1_786_536_000) // 2026-08-12 12:00 UTC

    static func isEnabled(in environment: [String: String]) -> Bool {
        environment["OFJ_UI_TEST_MODE"] == "1" && environment["OFJ_SCREENSHOT_MODE"] == "1"
    }

    // Launch flags cannot change during a capture. Cache this because calendars
    // ask for the presentation date once per visible day cell.
    static let isEnabled: Bool = isEnabled(in: ProcessInfo.processInfo.environment)

    @MainActor
    static func prepare() {
        guard isEnabled else { return }
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
        UIView.setAnimationsEnabled(false)
        let defaults = UserDefaults.standard
        // Explicit values make fresh and repeated launches produce the same UI.
        defaults.set(false, forKey: "healthkit.enabled")
        defaults.set(false, forKey: FoodBankEmojiSettings.autoGenerateKey)
        defaults.set(true, forKey: FoodBankEmojiSettings.useGeneratedIconImagesKey)
        defaults.set(true, forKey: JournalAppearanceSettings.showFoodImagesKey)
        defaults.set(OFJAccentTheme.systemBlue.rawValue, forKey: OFJAccentTheme.storageKey)
        // The fixture tracks fiber, sodium and potassium, so pinning one leaves
        // the other two in the full scroller and the History capture shows both
        // the Pinned row and the unpinned one.
        defaults.set(PinnedMicronutrientSettings.encode(["fiber"]),
                     forKey: PinnedMicronutrientSettings.idsKey)
        defaults.set(2_200.0, forKey: "goals.calories")
        defaults.set(150.0, forKey: "goals.protein")
        defaults.set(250.0, forKey: "goals.carbs")
        defaults.set(70.0, forKey: "goals.fat")
    }
}

@MainActor
enum ScreenshotFixtures {
    static let foodNames = ["Berry yogurt bowl", "Avocado toast", "Chicken rice bowl",
                            "Greek yogurt", "Salmon and greens", "Blueberries"]

    /// This must never be used against a user's on-disk database.
    static func seed(in context: ModelContext) throws {
        precondition(context.container.configurations.allSatisfy(\.isStoredInMemoryOnly))
        guard try context.fetchCount(FetchDescriptor<SavedFood>()) == 0,
              try context.fetchCount(FetchDescriptor<DailyLog>()) == 0 else {
            return
        }
        let date = ScreenshotConfiguration.referenceDate
        let preferences = Preferences.current(in: context)
        preferences.shelfRecommendationsEnabled = false
        preferences.ringSlot4 = "fiber"
        preferences.ringSlot5 = "sodium"
        let emojis = ["🥣", "🥑", "🍲", "🥛", "🥗", "🫐"]
        let nutrition: [(Double, Double, Double, Double, Double)] = [
            (380, 27, 48, 10, 300), (320, 12, 34, 17, 160),
            (610, 44, 68, 18, 420), (160, 20, 12, 3, 170),
            (520, 42, 20, 30, 350), (84, 1, 21, 0.5, 148),
        ]
        var foods: [SavedFood] = []
        for index in foodNames.indices {
            let values = nutrition[index]
            let food = SavedFood(
                id: id(index + 1), name: foodNames[index], emoji: emojis[index],
                generatedIconImageData: icon(emojis[index]), generatedIconImageMimeType: "image/png",
                generatedIconImageUpdatedAt: date, createdAt: date.addingTimeInterval(-Double(index) * 60),
                calories: values.0, protein: values.1, carbs: values.2, fat: values.3,
                micronutrients: ["fiber": .init(value: 5, unit: "g"),
                                "sodium": .init(value: 180, unit: "mg"),
                                "potassium": .init(value: 420, unit: "mg")],
                serving: .mass(grams: values.4), servingQuantity: 1, servingUnit: "serving",
                isOnShelf: true
            )
            context.insert(food)
            foods.append(food)
        }

        // Fixed meals over four weeks populate both calendar and trend views.
        let meals: [MealType] = [.breakfast, .breakfast, .lunch, .snack]
        for offset in -27...0 {
            let day = Calendar.current.date(byAdding: .day, value: offset, to: date)!
            let log = DailyLog(date: day, id: id(100 + offset + 27))
            context.insert(log)
            var entries: [NutritionEntry] = []
            for index in 0..<4 {
                let food = foods[index]
                let factor = offset == 0 ? 1.0 : 0.8 + Double((-offset) % 6) * 0.17
                let timestamp = Calendar.current.date(bySettingHour: [8, 8, 12, 15][index],
                                                     minute: index == 1 ? 15 : 0, second: 0, of: day)!
                let entry = NutritionEntry(
                    id: id(1_000 + (offset + 27) * 4 + index), timestamp: timestamp,
                    name: food.name, mealType: meals[index],
                    calories: food.calories * factor, protein: food.protein * factor,
                    carbs: food.carbs * factor, fat: food.fat * factor,
                    micronutrients: food.micronutrients.mapValues {
                        MicronutrientValue(value: $0.value * factor, unit: $0.unit)
                    },
                    serving: food.serving, servingCount: factor,
                    servingQuantity: factor, servingUnit: "serving", savedFoodID: food.id
                )
                context.insert(entry)
                entry.dailyLog = log
                entries.append(entry)
            }
            log.entries = entries
        }

        let thread = ChatThread(title: "Today's nutrition")
        thread.id = id(2_000)
        thread.createdAt = date
        thread.updatedAt = date
        context.insert(thread)
        let question = ChatMessage(role: .user, text: "How am I doing today?", timestamp: date)
        let answer = ChatMessage(
            role: .model,
            text: "You've logged **1,470 calories** and **103 g of protein** so far.\n\n"
                + "A dinner with vegetables and a protein source would fit the rest of your day. "
                + "You have **730 calories remaining** toward your 2,200-calorie goal.",
            timestamp: date.addingTimeInterval(1)
        )
        for (index, message) in [question, answer].enumerated() {
            message.id = id(2_001 + index)
            message.transcriptOrdinal = Int64(index + 1)
            context.insert(message)
            message.thread = thread
        }
        thread.messages = [question, answer]
        try context.save()
    }

    private static func id(_ number: Int) -> UUID {
        // The fixed decimal suffix is always a valid 12-character UUID segment.
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }

    private static func icon(_ emoji: String) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80), format: format)
            .pngData { _ in
                (emoji as NSString).draw(in: CGRect(x: 8, y: 4, width: 64, height: 72),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 58)])
            }
    }
}
#endif
