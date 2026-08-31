#if DEBUG
import Foundation
import SwiftData
import Testing
@testable import OpenFoodJournal

@MainActor
struct ScreenshotFixtureTests {
    @Test func screenshotModeRequiresBothExplicitFlags() {
        #expect(!ScreenshotConfiguration.isEnabled(in: [:]))
        #expect(!ScreenshotConfiguration.isEnabled(in: ["OFJ_UI_TEST_MODE": "1"]))
        #expect(!ScreenshotConfiguration.isEnabled(in: ["OFJ_SCREENSHOT_MODE": "1"]))
        #expect(ScreenshotConfiguration.isEnabled(in: ["OFJ_UI_TEST_MODE": "1", "OFJ_SCREENSHOT_MODE": "1"]))
    }

    @Test func fixturesAreCompleteAndDoNotDuplicateOnReseeding() throws {
        let container = try ModelContainer(
            for: DailyLog.self, NutritionEntry.self, SavedFood.self, Preferences.self, ChatThread.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = container.mainContext
        try ScreenshotFixtures.seed(in: context)
        try ScreenshotFixtures.seed(in: context)
        #expect(try context.fetchCount(FetchDescriptor<DailyLog>()) == 28)
        #expect(try context.fetchCount(FetchDescriptor<NutritionEntry>()) == 112)
        let foods = try context.fetch(FetchDescriptor<SavedFood>())
        #expect(foods.count == 6)
        #expect(foods.allSatisfy { $0.hasGeneratedFoodIconImage && $0.isOnShelf })
        let logs = try context.fetch(FetchDescriptor<DailyLog>())
        let today = try #require(logs.first {
            Calendar.current.isDate($0.date, inSameDayAs: ScreenshotConfiguration.referenceDate)
        })
        #expect(today.safeEntries.count == 4)
        #expect(today.totalCalories == 1_470)
        #expect(today.totalProtein == 103)
        let threads = try context.fetch(FetchDescriptor<ChatThread>())
        #expect(threads.count == 1)
        #expect(threads.first?.safeMessages.count == 2)
        #expect(threads.first?.agentRuns?.isEmpty == true)
    }
}
#endif
