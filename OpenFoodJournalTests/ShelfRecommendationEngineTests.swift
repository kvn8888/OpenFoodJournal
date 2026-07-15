import Foundation
import Testing
@testable import OpenFoodJournal

struct ShelfRecommendationEngineTests {
    private let goals = ShelfNutritionGoals(
        calories: 2_000,
        protein: 150,
        fiber: 28,
        carbs: 200,
        fat: 65,
        sodium: 2_300
    )

    @Test func triggerHonorsEnabledThresholdAndZeroGoal() {
        let configuration = ShelfRecommendationConfiguration(triggerFraction: 0.5)

        #expect(!ShelfRecommendationEngine.shouldShow(
            currentCalories: 999,
            calorieGoal: 2_000,
            configuration: configuration
        ))
        #expect(ShelfRecommendationEngine.shouldShow(
            currentCalories: 1_000,
            calorieGoal: 2_000,
            configuration: configuration
        ))

        var disabled = configuration
        disabled.enabled = false
        #expect(!ShelfRecommendationEngine.shouldShow(
            currentCalories: 2_000,
            calorieGoal: 2_000,
            configuration: disabled
        ))
        #expect(!ShelfRecommendationEngine.shouldShow(
            currentCalories: 2_000,
            calorieGoal: 0,
            configuration: configuration
        ))
    }

    @Test func proteinAndFiberProfilesProduceDifferentLeaders() throws {
        let proteinFood = candidate(
            name: "Protein Bowl",
            calories: 250,
            protein: 42,
            fiber: 2,
            sodium: 220
        )
        let fiberFood = candidate(
            name: "Lentils",
            calories: 250,
            protein: 14,
            fiber: 13,
            sodium: 80
        )
        let current = ShelfNutrition(
            calories: 1_100,
            protein: 65,
            fiber: 9,
            carbs: 100,
            fat: 35,
            sodium: 900
        )

        var proteinConfig = ShelfRecommendationConfiguration(nutritionEmphasis: .proteinFocus)
        proteinConfig.suggestionCount = 2
        var fiberConfig = proteinConfig
        fiberConfig.nutritionEmphasis = .fiberFocus

        let proteinResults = ShelfRecommendationEngine.recommend(
            foods: [fiberFood, proteinFood], current: current, goals: goals, configuration: proteinConfig
        )
        let fiberResults = ShelfRecommendationEngine.recommend(
            foods: [proteinFood, fiberFood], current: current, goals: goals, configuration: fiberConfig
        )

        #expect(try #require(proteinResults.first).foodName == "Protein Bowl")
        #expect(try #require(fiberResults.first).foodName == "Lentils")
    }

    @Test func squaredDeficitHasDiminishingReturnsNearGoal() throws {
        let food = candidate(name: "Lean Bite", calories: 100, protein: 15, fiber: 1, sodium: 40)
        let configuration = ShelfRecommendationConfiguration()
        let far = ShelfNutrition(calories: 1_100, protein: 30, fiber: 20, carbs: 150, fat: 50, sodium: 700)
        let near = ShelfNutrition(calories: 1_100, protein: 140, fiber: 20, carbs: 150, fat: 50, sodium: 700)

        let farScore = try #require(ShelfRecommendationEngine.recommend(
            foods: [food], current: far, goals: goals, configuration: configuration
        ).first).score
        let nearScore = try #require(ShelfRecommendationEngine.recommend(
            foods: [food], current: near, goals: goals, configuration: configuration
        ).first).score

        #expect(farScore > nearScore)
    }

    @Test func lowSodiumProfileAvoidsHighSodiumChoice() throws {
        let highSodium = candidate(
            name: "Salty Protein",
            calories: 160,
            protein: 100,
            fiber: 1,
            sodium: 650
        )
        let lowSodium = candidate(
            name: "Unsalted Yogurt",
            calories: 160,
            protein: 4,
            fiber: 1,
            sodium: 35
        )
        let current = ShelfNutrition(
            calories: 1_200,
            protein: 70,
            fiber: 16,
            carbs: 120,
            fat: 35,
            sodium: 1_700
        )
        var balanced = ShelfRecommendationConfiguration(nutritionEmphasis: .balanced)
        balanced.suggestionCount = 2
        var lowSodiumConfig = balanced
        lowSodiumConfig.nutritionEmphasis = .lowSodium

        let balancedResults = ShelfRecommendationEngine.recommend(
            foods: [highSodium, lowSodium], current: current, goals: goals, configuration: balanced
        )
        let lowSodiumResults = ShelfRecommendationEngine.recommend(
            foods: [highSodium, lowSodium], current: current, goals: goals, configuration: lowSodiumConfig
        )

        #expect(try #require(balancedResults.first).foodName == "Salty Protein")
        #expect(try #require(lowSodiumResults.first).foodName == "Unsalted Yogurt")
        #expect(ShelfRecommendationEngine.sodiumPressure(1.05) > ShelfRecommendationEngine.sodiumPressure(0.95))
        #expect(ShelfRecommendationEngine.sodiumPressure(0.95) > ShelfRecommendationEngine.sodiumPressure(0.75))
    }

    @Test func unknownSodiumIsConservativeAndLabeled() throws {
        let knownLow = candidate(name: "Known", calories: 180, protein: 20, fiber: 5, sodium: 0)
        let unknown = candidate(name: "Unknown", calories: 180, protein: 20, fiber: 5, sodium: nil)
        let current = ShelfNutrition(
            calories: 1_200,
            protein: 70,
            fiber: 12,
            carbs: 100,
            fat: 35,
            sodium: 1_900
        )
        var configuration = ShelfRecommendationConfiguration()
        configuration.suggestionCount = 2

        let results = ShelfRecommendationEngine.recommend(
            foods: [unknown, knownLow], current: current, goals: goals, configuration: configuration
        )
        let unknownResult = try #require(results.first(where: { $0.foodName == "Unknown" }))

        #expect(results.first?.foodName == "Known")
        #expect(unknownResult.hasIncompleteNutrition)
        #expect(unknownResult.reason.localizedCaseInsensitiveContains("sodium unknown"))

        configuration.incompleteNutritionPolicy = .exclude
        let excluded = ShelfRecommendationEngine.recommend(
            foods: [unknown, knownLow], current: current, goals: goals, configuration: configuration
        )
        #expect(!excluded.contains { $0.foodName == "Unknown" })
    }

    @Test func noHardCapKeepsOvershootingFoodEligible() {
        let food = candidate(name: "Large Snack", calories: 200, protein: 25, fiber: 5, sodium: 50)
        let current = ShelfNutrition(
            calories: 1_990,
            protein: 60,
            fiber: 10,
            carbs: 130,
            fat: 40,
            sodium: 800
        )

        let results = ShelfRecommendationEngine.recommend(
            foods: [food], current: current, goals: goals, configuration: ShelfRecommendationConfiguration()
        )
        #expect(results.first?.foodName == "Large Snack")
    }

    @Test func enabledCalorieHardCapRejectsOvershootingServings() {
        let food = candidate(name: "Large Snack", calories: 200, protein: 25, fiber: 5, sodium: 50)
        let current = ShelfNutrition(
            calories: 1_990,
            protein: 60,
            fiber: 10,
            carbs: 130,
            fat: 40,
            sodium: 800
        )
        var configuration = ShelfRecommendationConfiguration()
        configuration.hardCaps = [.calories]

        let results = ShelfRecommendationEngine.recommend(
            foods: [food], current: current, goals: goals, configuration: configuration
        )
        #expect(results.isEmpty)
    }

    @Test func bulkAtOneThousandCaloriesStillSuggestsFoodNearSodiumGoal() throws {
        let food = candidate(
            name: "Bulk Burrito",
            calories: 600,
            protein: 35,
            fiber: 8,
            sodium: 700
        )
        let current = ShelfNutrition(
            calories: 1_000,
            protein: 65,
            fiber: 12,
            carbs: 90,
            fat: 30,
            sodium: 2_000
        )
        var configuration = ShelfRecommendationConfiguration(energyIntent: .bulk)
        configuration.nutritionEmphasis = .balanced

        let result = try #require(ShelfRecommendationEngine.recommend(
            foods: [food], current: current, goals: goals, configuration: configuration
        ).first)

        #expect(result.foodName == "Bulk Burrito")
        #expect(result.reason.localizedCaseInsensitiveContains("calories"))

        configuration.hardCaps = [.sodium]
        #expect(ShelfRecommendationEngine.recommend(
            foods: [food], current: current, goals: goals, configuration: configuration
        ).isEmpty)
    }

    @Test func cutIntentPrefersLowerCalorieChoiceWithSameNutrition() throws {
        let lighter = candidate(name: "Lighter", calories: 120, protein: 20, fiber: 4, sodium: 80)
        let denser = candidate(name: "Denser", calories: 480, protein: 20, fiber: 4, sodium: 80)
        let current = ShelfNutrition(
            calories: 1_050,
            protein: 70,
            fiber: 12,
            carbs: 100,
            fat: 30,
            sodium: 900
        )
        var configuration = ShelfRecommendationConfiguration(energyIntent: .cut)
        configuration.suggestionCount = 2

        let results = ShelfRecommendationEngine.recommend(
            foods: [denser, lighter], current: current, goals: goals, configuration: configuration
        )

        #expect(try #require(results.first).foodName == "Lighter")
        #expect(try #require(results.first).reason.localizedCaseInsensitiveContains("calories"))
    }

    @Test func rollingWeekUsesSixCoveredDaysAndClampsExtraBudget() throws {
        let context = ShelfRollingWeekContext(
            priorDayCalories: [1_800, 1_800, 1_800, 1_800, 1_800, 1_800]
        )
        let configuration = ShelfRecommendationConfiguration()
        let target = ShelfRecommendationEngine.effectiveCalorieTarget(
            dailyGoal: 2_000,
            context: context,
            configuration: configuration
        )

        #expect(target.usedRollingWeek)
        #expect(target.coveredPriorDays == 6)
        #expect(target.adjustment == 300)
        #expect(target.calories == 2_300)

        let food = candidate(name: "Weekly Fit", calories: 250, protein: 20, fiber: 5, sodium: 100)
        let current = ShelfNutrition(
            calories: 1_100,
            protein: 70,
            fiber: 12,
            carbs: 100,
            fat: 30,
            sodium: 900
        )
        let result = try #require(ShelfRecommendationEngine.recommend(
            foods: [food],
            current: current,
            goals: goals,
            configuration: configuration,
            rollingWeekContext: context
        ).first)
        #expect(result.reason.localizedCaseInsensitiveContains("weekly pace"))
        #expect(result.reason.localizedCaseInsensitiveContains("300"))
    }

    @Test func rollingWeekRequiresSufficientCoverage() {
        let context = ShelfRollingWeekContext(
            priorDayCalories: [1_800, nil, nil, 1_800, nil, 1_800]
        )
        let target = ShelfRecommendationEngine.effectiveCalorieTarget(
            dailyGoal: 2_000,
            context: context,
            configuration: ShelfRecommendationConfiguration()
        )

        #expect(!target.usedRollingWeek)
        #expect(target.calories == 2_000)
    }

    @Test func calorieHardCapUsesDailyGoalInsteadOfRaisedRollingTarget() {
        let context = ShelfRollingWeekContext(
            priorDayCalories: [1_800, 1_800, 1_800, 1_800, 1_800, 1_800]
        )
        let food = candidate(
            name: "Fits Only Adjusted Target",
            calories: 250,
            protein: 30,
            fiber: 6,
            sodium: 100
        )
        let current = ShelfNutrition(
            calories: 1_900,
            protein: 70,
            fiber: 12,
            carbs: 100,
            fat: 30,
            sodium: 900
        )
        var configuration = ShelfRecommendationConfiguration()
        configuration.hardCaps = [.calories]

        let results = ShelfRecommendationEngine.recommend(
            foods: [food],
            current: current,
            goals: goals,
            configuration: configuration,
            rollingWeekContext: context
        )

        #expect(results.isEmpty)
    }

    @Test func servingsStayWithinCandidatesAndPrefillActualBaseUnits() throws {
        let food = candidate(
            name: "Almonds",
            calories: 170,
            protein: 6,
            fiber: 4,
            sodium: 0,
            baseQuantity: 28,
            baseUnit: "g"
        )
        let current = ShelfNutrition(
            calories: 1_200,
            protein: 80,
            fiber: 15,
            carbs: 110,
            fat: 35,
            sodium: 900
        )
        let result = try #require(ShelfRecommendationEngine.recommend(
            foods: [food], current: current, goals: goals, configuration: ShelfRecommendationConfiguration()
        ).first)

        #expect(ShelfRecommendationEngine.servingMultipliers.contains(result.servingMultiplier))
        #expect(result.servingMultiplier >= 0.5 && result.servingMultiplier <= 2)
        #expect(result.quantity == 28 * result.servingMultiplier)
        #expect(result.unit == "g")
    }

    @Test func topCountClampsToFiveAndTieBreakingIsStable() {
        let ids = (0..<6).map { index in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
        }
        let names = ["Zulu", "Alpha", "Echo", "Bravo", "Delta", "Charlie"]
        let foods = zip(ids, names).map { id, name in
            candidate(id: id, name: name, calories: 120, protein: 18, fiber: 4, sodium: 50)
        }
        let current = ShelfNutrition(
            calories: 1_100,
            protein: 60,
            fiber: 10,
            carbs: 100,
            fat: 30,
            sodium: 700
        )
        var configuration = ShelfRecommendationConfiguration()
        configuration.suggestionCount = 99

        let results = ShelfRecommendationEngine.recommend(
            foods: Array(foods.reversed()), current: current, goals: goals, configuration: configuration
        )

        #expect(results.count == 5)
        #expect(results.map(\.foodName) == ["Alpha", "Bravo", "Charlie", "Delta", "Echo"])
    }

    @Test func offShelfAndManuallyArchivedFoodsAreExcluded() {
        let offShelf = candidate(name: "Off Shelf", calories: 100, protein: 10, fiber: 2, sodium: 10, isOnShelf: false)
        let archived = candidate(name: "Archived", calories: 100, protein: 10, fiber: 2, sodium: 10, isArchived: true)
        let current = ShelfNutrition(calories: 1_100, protein: 50, fiber: 10, carbs: 90, fat: 25, sodium: 500)

        #expect(ShelfRecommendationEngine.recommend(
            foods: [offShelf, archived], current: current, goals: goals, configuration: ShelfRecommendationConfiguration()
        ).isEmpty)
    }

    @Test func shelfBypassesAgeArchiveButNotManualArchive() {
        let agedShelfFood = SavedFood(name: "Pantry Oats", calories: 150, protein: 5, carbs: 27, fat: 3)
        agedShelfFood.lastUsedAt = .now.addingTimeInterval(-15 * 24 * 60 * 60)
        agedShelfFood.isOnShelf = true

        #expect(!agedShelfFood.isArchivedInFoodBank)

        agedShelfFood.archiveForFoodBank()
        #expect(agedShelfFood.isArchivedInFoodBank)
    }

    private func candidate(
        id: UUID = UUID(),
        name: String,
        calories: Double,
        protein: Double,
        fiber: Double?,
        sodium: Double?,
        baseQuantity: Double = 1,
        baseUnit: String = "serving",
        isOnShelf: Bool = true,
        isArchived: Bool = false
    ) -> ShelfFoodCandidate {
        ShelfFoodCandidate(
            id: id,
            name: name,
            baseQuantity: baseQuantity,
            baseUnit: baseUnit,
            nutrition: ShelfNutrition(
                calories: calories,
                protein: protein,
                fiber: fiber,
                carbs: max(calories / 10, 1),
                fat: max(calories / 50, 1),
                sodium: sodium
            ),
            isOnShelf: isOnShelf,
            isManuallyArchived: isArchived
        )
    }
}
