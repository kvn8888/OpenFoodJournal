// OpenFoodJournal — Log Food presentation contracts
// AGPL-3.0 License

import Testing
@testable import OpenFoodJournal

@MainActor
struct LogFoodPresentationTests {
    private var converter: ServingConverter {
        ServingConverter(
            calories: 330,
            protein: 5,
            carbs: 9,
            fat: 30,
            quantity: 1,
            unit: "serving",
            serving: .mass(grams: 60),
            mappings: [
                ServingMapping(
                    from: ServingAmount(value: 1, unit: "cup"),
                    to: ServingAmount(value: 240, unit: "g")
                ),
            ]
        )
    }

    @Test("quantity units keep the food baseline first, then common cup and gram controls")
    func unitOrdering() {
        let ordered = LogFoodPresentation.orderedUnits(
            ["tbsp", "g", "cup", "serving"],
            baseUnit: "serving"
        )

        #expect(ordered == ["serving", "cup", "g", "tbsp"])
    }

    @Test("unit labels are readable without changing stored unit identifiers")
    func unitLabels() {
        #expect(LogFoodPresentation.unitPickerLabel("serving") == "servings")
        #expect(LogFoodPresentation.unitPickerLabel("cup") == "cups")
        #expect(LogFoodPresentation.unitPickerLabel("g") == "grams")
        #expect(LogFoodPresentation.unitLabel("serving", quantity: 1) == "serving")
        #expect(LogFoodPresentation.unitLabel("serving", quantity: 2) == "servings")
        #expect(LogFoodPresentation.unitLabel("g", quantity: 1) == "g")
    }

    @Test("quantity selector converts values without changing the represented food amount")
    func quantityConversion() throws {
        let grams = LogFoodPresentation.convertedAmount(
            1,
            from: "serving",
            to: "g",
            using: converter
        )
        #expect(grams == 60)

        let servings = LogFoodPresentation.convertedQuantity(
            120,
            from: "g",
            to: "serving",
            using: converter
        )
        #expect(servings == 2)
    }

    @Test("quantity buttons use practical deterministic increments")
    func quantitySteps() {
        #expect(LogFoodPresentation.quantityStep(for: "serving") == 1)
        #expect(LogFoodPresentation.quantityStep(for: "cup") == 0.25)
        #expect(LogFoodPresentation.quantityStep(for: "g") == 1)
        #expect(LogFoodPresentation.quantityStep(for: "kg") == 0.1)
    }

    @Test("macro calorie shares use Atwater factors and stay bounded")
    func macroCalorieShares() {
        #expect(
            LogFoodPresentation.calorieShare(
                grams: 30,
                caloriesPerGram: 9,
                totalCalories: 330
            ) == 270.0 / 330.0
        )
        #expect(
            LogFoodPresentation.calorieShare(
                grams: 100,
                caloriesPerGram: 9,
                totalCalories: 100
            ) == 1
        )
        #expect(
            LogFoodPresentation.calorieShare(
                grams: 10,
                caloriesPerGram: 4,
                totalCalories: 0
            ) == 0
        )
    }

    @Test("micronutrients follow the reviewed summary order before other nutrients")
    func micronutrientOrdering() {
        let ordered = LogFoodPresentation.orderedMicronutrientKeys([
            "vitamin_c",
            "fiber",
            "sodium",
            "saturated_fat",
        ])

        #expect(ordered == ["saturated_fat", "sodium", "fiber", "vitamin_c"])
    }

    @Test("scaled micronutrients use the same serving factor as macros")
    func micronutrientScaling() {
        let values = converter.scaledMicronutrients(
            ["sodium": MicronutrientValue(value: 340, unit: "mg")],
            quantity: 120,
            unit: "g"
        )

        #expect(values["sodium"]?.value == 680)
        #expect(values["sodium"]?.unit == "mg")
    }
}
