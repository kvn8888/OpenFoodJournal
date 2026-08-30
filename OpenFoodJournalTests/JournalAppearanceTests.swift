import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import OpenFoodJournal

@MainActor
struct JournalAppearanceTests {
    private func food(image: Bool = true) -> SavedFood {
        let food = SavedFood(name: "Same food name", calories: 100, protein: 5, carbs: 10, fat: 3)
        food.generatedIconImageData = image ? Data([1, 2, 3]) : nil
        return food
    }

    @Test func pillAndImageGeometryMatchesPlayground() {
        #expect(OFJLayout.journalMacroDiameter == 40)
        #expect(OFJLayout.journalMacroOverlap == 5)
        #expect(OFJLayout.journalMacroPillWidth == 3 * OFJLayout.journalMacroDiameter - 2 * OFJLayout.journalMacroOverlap)
        #expect(FoodIconMetrics.imageSize == 51)
        #expect(FoodIconMetrics.columnWidth == 58)
        #expect(OFJLayout.journalNutrientRingStroke == 4.3)
        #expect(OFJLayout.journalGradientLocations == [0, 0.25, 1])
        #expect(OFJLayout.journalGradientEndRadius == 800)
    }

    @Test func neutralPaletteIsNotTheRGBExperiment() {
        let env = EnvironmentValues()
        let protein = OFJColor.journalProtein.resolve(in: env)
        let carbs = OFJColor.journalCarbohydrates.resolve(in: env)
        let fat = OFJColor.journalFat.resolve(in: env)
        #expect(abs(protein.red - 0.54) < 0.001)
        #expect(abs(protein.green - 0.58) < 0.001)
        #expect(abs(carbs.red - 0.26) < 0.001)
        #expect(abs(carbs.green - 0.80) < 0.001)
        #expect(abs(fat.red - 1) < 0.001)
        #expect(abs(fat.green - 0.75) < 0.001)
    }

    @Test func gradientsUseModeSpecificStrengths() {
        let cases: [(OFJColor.JournalCalorieState, [Float], [Float])] = [
            (.belowGoal, [0.13, 0.08, 0], [0.20, 0.20, 0]),
            (.approachingGoal, [0.13, 0.08, 0], [0.20, 0.20, 0]),
            (.goalMet, [0.14, 0.05, 0], [0.20, 0.10, 0]),
            (.overGoal, [0.15, 0.10, 0], [0.20, 0.15, 0])
        ]
        for (state, light, dark) in cases {
            for (scheme, expected) in [(ColorScheme.light, light), (.dark, dark)] {
                let actual = state.backgroundGradientColors(for: scheme).map { $0.resolve(in: EnvironmentValues()).opacity }
                #expect(actual.count == expected.count)
                for (a, e) in zip(actual, expected) { #expect(abs(a - e) < 0.001) }
            }
        }
    }

    @Test func imagePreferenceRoundTripsAndLegacyBackupsDefaultOn() throws {
        let old = try JSONDecoder().decode(AppSettingsRecord.self, from: Data("{}".utf8))
        #expect(old.showJournalFoodImages)
        let settings = AppSettingsRecord(useProModel: false, showJournalFoodImages: false, offContributeEnabled: false)
        let decoded = try JSONDecoder().decode(AppSettingsRecord.self, from: JSONEncoder().encode(settings))
        #expect(!decoded.showJournalFoodImages)
        #expect(!decoded.useGeneratedFoodIconImages)
    }

    @Test func imagePreferencePersistsWithoutEnablingGeneration() throws {
        let suite = "JournalAppearanceTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(JournalAppearanceSettings.showFoodImages(in: defaults))
        defaults.set(false, forKey: JournalAppearanceSettings.showFoodImagesKey)
        #expect(!JournalAppearanceSettings.showFoodImages(in: defaults))
        defaults.set(true, forKey: JournalAppearanceSettings.showFoodImagesKey)
        #expect(JournalAppearanceSettings.showFoodImages(in: defaults))
        #expect(!defaults.bool(forKey: FoodBankEmojiSettings.autoGenerateKey))
        #expect(!defaults.bool(forKey: FoodBankEmojiSettings.useGeneratedIconImagesKey))
    }

    @Test func linkedFoodWinsAndArchivedImagesRemainAvailable() {
        let entryID = UUID()
        let linked = food()
        linked.archivedAt = .now
        let snapshot = food()
        snapshot.sourceJournalEntryID = entryID
        let unrelated = food()
        #expect(JournalFoodImageLookup.food(in: [unrelated, snapshot, linked], entryID: entryID, savedFoodID: linked.id)?.id == linked.id)
        #expect(JournalFoodImageLookup.food(in: [unrelated, snapshot], entryID: entryID, savedFoodID: linked.id)?.id == snapshot.id)
    }

    @Test func missingImagesNeverGuessByFoodName() {
        let entryID = UUID()
        let unrelated = food()
        let empty = food(image: false)
        empty.sourceJournalEntryID = entryID
        #expect(JournalFoodImageLookup.food(in: [unrelated, empty], entryID: entryID, savedFoodID: nil) == nil)
        #expect(JournalFoodImageLookup.food(in: [unrelated, empty], entryID: entryID, savedFoodID: empty.id) == nil)
    }

    @Test func newlySavedScanOrManualFoodRetainsImageProvenance() {
        let entry = NutritionEntry(name: "New scan", calories: 200, protein: 10, carbs: 20, fat: 5)
        let saved = SavedFood(from: entry)
        #expect(saved.sourceJournalEntryID == entry.id)
        #expect(entry.savedFoodID == nil)
        #expect(saved.calories == entry.calories)
        saved.generatedIconImageData = Data([1])
        #expect(JournalFoodImageLookup.food(in: [saved], entryID: entry.id, savedFoodID: nil)?.id == saved.id)
    }

    @Test func scopedPredicateAndNewImageDataAreVisibleWithoutReopening() throws {
        let container = try ModelContainer(for: SavedFood.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let entryID = UUID()
        let linked = food(image: false)
        let snapshot = food()
        snapshot.sourceJournalEntryID = entryID
        let unrelated = food()
        for item in [linked, snapshot, unrelated] { context.insert(item) }
        try context.save()
        let descriptor = FetchDescriptor<SavedFood>(predicate: JournalFoodImageLookup.predicate(entryID: entryID, savedFoodID: linked.id))
        let candidates = try context.fetch(descriptor)
        #expect(Set(candidates.map(\.id)) == Set([linked.id, snapshot.id]))
        #expect(JournalFoodImageLookup.food(in: candidates, entryID: entryID, savedFoodID: linked.id)?.id == snapshot.id)
        linked.generatedIconImageData = Data([4, 5, 6])
        #expect(JournalFoodImageLookup.food(in: candidates, entryID: entryID, savedFoodID: linked.id)?.id == linked.id)
        let snapshotOnly = try context.fetch(FetchDescriptor<SavedFood>(predicate: JournalFoodImageLookup.predicate(entryID: entryID, savedFoodID: nil)))
        #expect(snapshotOnly.map(\.id) == [snapshot.id])
    }
}
