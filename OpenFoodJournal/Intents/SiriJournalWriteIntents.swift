// AGPL-3.0 License

import AppIntents
import Foundation

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct LogMeasuredFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Food With Known Nutrition"
    static let description = IntentDescription("Log a food in OpenFoodJournal when the person supplies its actual nutrition. Calories and macros describe the entire portion. Ask for confirmation before saving.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Name") var name: String
    @Parameter(title: "Brand") var brand: String?
    @Parameter(title: "Quantity", default: 1) var quantity: Double
    @Parameter(title: "Unit", default: "serving") var unit: String
    @Parameter(title: "Calories", description: "Known calories for the whole portion in kcal.") var calories: Double
    @Parameter(title: "Protein in Grams", default: 0) var protein: Double
    @Parameter(title: "Carbohydrates in Grams", default: 0) var carbs: Double
    @Parameter(title: "Fat in Grams", default: 0) var fat: Double
    @Parameter(title: "Meal") var meal: MealTypeAppEnum?
    @Parameter(title: "Journal Day") var date: Date?

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriJournalEntryRecord> & ProvidesDialog {
        let data = runtime.journalData
        try data.requireUnlock()
        let now = data.now()
        let day = data.calendar.startOfDay(for: date ?? now)
        let meal = meal?.meal ?? data.mealTimes.mealType(for: now, calendar: data.calendar)
        let values = try SiriStoredNutrition.manual(name: name, brand: brand, quantity: quantity, unit: unit,
                                                    calories: calories, protein: protein, carbs: carbs, fat: fat)
        try await confirmJournalAddition(values: values, meal: meal, day: day, requestedAt: now, data: data,
                                         dialog: "Add \(values.portionLabel) for \(meal.rawValue.lowercased()) on \(day.formatted(date: .long, time: .omitted))? It has \(values.macrosLabel).")
        let saved = try data.createEntry(values, meal: meal, day: day, requestedAt: now)
        return .result(value: SiriJournalEntryRecord(saved), dialog: "Logged \(values.label) for \(meal.rawValue.lowercased()).")
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct EditJournalFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Edit Journal Food"
    static let description = IntentDescription("Edit one identified OpenFoodJournal entry. Only fields supplied are changed. Amount changes scale the saved nutrition unless replacement values are supplied. Requires confirmation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Entry", description: "A specific entry from the journal. Resolve the correct day and meal first.")
    var item: SiriJournalEntryRecord
    @Parameter(title: "New Name") var name: String?
    @Parameter(title: "New Brand") var brand: String?
    @Parameter(title: "New Quantity") var quantity: Double?
    @Parameter(title: "New Unit") var unit: String?
    @Parameter(title: "New Calories in kcal") var calories: Double?
    @Parameter(title: "New Protein in Grams") var protein: Double?
    @Parameter(title: "New Carbohydrates in Grams") var carbs: Double?
    @Parameter(title: "New Fat in Grams") var fat: Double?
    @Parameter(title: "Micronutrient to Change", description: "Name of one micronutrient to set, such as sodium.") var nutrientName: String?
    @Parameter(title: "Micronutrient Amount") var nutrientAmount: Double?
    @Parameter(title: "Micronutrient Unit", description: "Unit for the named micronutrient, such as mg or mcg.") var nutrientUnit: String?
    @Parameter(title: "New Meal") var meal: MealTypeAppEnum?
    @Parameter(title: "New Journal Day") var date: Date?

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriJournalEntryRecord> & ProvidesDialog {
        let data = runtime.journalData
        guard let entry = try data.entry(id: item.id) else { throw SiriJournalDataError.itemUnavailable }
        let expected = SiriJournalEntrySnapshot(entry)
        let edit = SiriNutritionEdit(name: name, brand: brand, quantity: quantity, unit: unit, calories: calories,
                                     protein: protein, carbs: carbs, fat: fat, nutrientName: nutrientName,
                                     nutrientAmount: nutrientAmount, nutrientUnit: nutrientUnit)
        let values = try edit.apply(to: expected.nutrition, serving: expected.serving, mappings: expected.mappings)
        let day = data.calendar.startOfDay(for: date ?? expected.day)
        let meal = meal?.meal ?? expected.meal
        guard values != expected.nutrition || meal != expected.meal || !data.calendar.isDate(day, inSameDayAs: expected.day) else {
            throw SiriJournalDataError.invalidEdit
        }
        let nutrientChange = edit.nutrientSummary(in: values)
        try await requestConfirmation(actionName: .continue,
                                      dialog: "Change \(expected.nutrition.label) to \(values.portionLabel) for \(meal.rawValue.lowercased()) on \(day.formatted(date: .long, time: .omitted))? It has \(values.macrosLabel)\(nutrientChange).")
        let saved = try data.updateEntry(expected, values: values, meal: meal, day: day)
        return .result(value: SiriJournalEntryRecord(saved), dialog: "Updated \(values.label) in the journal.")
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct DeleteJournalFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Journal Food"
    static let description = IntentDescription("Remove one identified food entry from the OpenFoodJournal journal. Confirm the specific food, meal, and date before deleting.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Entry", description: "The exact journal entry to remove. Resolve the food, day, and meal before calling.")
    var item: SiriJournalEntryRecord

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let data = runtime.journalData
        guard let entry = try data.entry(id: item.id) else { return .result(dialog: "That journal entry is already gone.") }
        let expected = SiriJournalEntrySnapshot(entry)
        try await requestConfirmation(actionName: .continue,
                                      dialog: "Delete \(expected.nutrition.portionLabel) from \(expected.meal.rawValue.lowercased()) on \(expected.day.formatted(date: .long, time: .omitted))?")
        try data.deleteEntry(expected)
        return .result(dialog: "Removed \(expected.nutrition.label) from the journal.")
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct CreateFoodBankItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Saved Food"
    static let description = IntentDescription("Save a new reusable food to the OpenFoodJournal Food Bank with its known nutrition per saved portion. Requires confirmation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Food Name") var name: String
    @Parameter(title: "Brand") var brand: String?
    @Parameter(title: "Portion Quantity", default: 1) var quantity: Double
    @Parameter(title: "Portion Unit", default: "serving") var unit: String
    @Parameter(title: "Calories", description: "Known calories for this saved portion in kcal.") var calories: Double
    @Parameter(title: "Protein in Grams", default: 0) var protein: Double
    @Parameter(title: "Carbohydrates in Grams", default: 0) var carbs: Double
    @Parameter(title: "Fat in Grams", default: 0) var fat: Double

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriFoodBankRecord> & ProvidesDialog {
        let data = runtime.journalData
        try data.requireUnlock()
        let values = try SiriStoredNutrition.manual(name: name, brand: brand, quantity: quantity, unit: unit,
                                                    calories: calories, protein: protein, carbs: carbs, fat: fat)
        try await requestConfirmation(actionName: .create,
                                      dialog: "Save \(values.label) to your Food Bank with \(values.macrosLabel) per \(values.quantity.formatted()) \(values.unit)?")
        return .result(value: data.foodRecord(try data.createFood(values)), dialog: "Saved \(values.label) to your Food Bank.")
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct SaveJournalFoodToFoodBankIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Journal Food to Food Bank"
    static let description = IntentDescription("Save the exact portion and all nutrition from one journal entry as a reusable OpenFoodJournal Food Bank item. Requires confirmation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Journal Entry", description: "The specific logged portion to save in the Food Bank.") var item: SiriJournalEntryRecord

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriFoodBankRecord> & ProvidesDialog {
        let data = runtime.journalData
        guard let entry = try data.entry(id: item.id) else { throw SiriJournalDataError.itemUnavailable }
        let expected = SiriJournalEntrySnapshot(entry)
        try await requestConfirmation(actionName: .add,
                                      dialog: "Save \(expected.nutrition.portionLabel) from \(expected.day.formatted(date: .long, time: .omitted)) to your Food Bank?")
        let saved = try data.saveEntryToFoodBank(expected)
        return .result(value: data.foodRecord(saved), dialog: "\(saved.name) is saved in your Food Bank.")
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct EditFoodBankItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Edit Saved Food"
    static let description = IntentDescription("Edit a saved food's name, brand, portion, or nutrition, or archive, restore, or change its Food Shelf status. Changes affect the saved item and future logging. Requires confirmation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Saved Food", description: "The specific Food Bank item to change.") var item: SiriFoodBankRecord
    @Parameter(title: "New Name") var name: String?
    @Parameter(title: "New Brand") var brand: String?
    @Parameter(title: "New Quantity") var quantity: Double?
    @Parameter(title: "New Unit") var unit: String?
    @Parameter(title: "New Calories in kcal") var calories: Double?
    @Parameter(title: "New Protein in Grams") var protein: Double?
    @Parameter(title: "New Carbohydrates in Grams") var carbs: Double?
    @Parameter(title: "New Fat in Grams") var fat: Double?
    @Parameter(title: "Micronutrient to Change") var nutrientName: String?
    @Parameter(title: "Micronutrient Amount") var nutrientAmount: Double?
    @Parameter(title: "Micronutrient Unit") var nutrientUnit: String?
    @Parameter(title: "Archived", description: "True archives the food. False restores it to the active Food Bank.")
    var archived: Bool?
    @Parameter(title: "On Food Shelf", description: "True adds the food to the Food Shelf. False removes it from the shelf.")
    var onShelf: Bool?

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriFoodBankRecord> & ProvidesDialog {
        let data = runtime.journalData
        guard let food = try data.food(id: item.id) else { throw SiriJournalDataError.itemUnavailable }
        let expected = SiriSavedFoodSnapshot(food)
        let edit = SiriNutritionEdit(name: name, brand: brand, quantity: quantity, unit: unit, calories: calories,
                                     protein: protein, carbs: carbs, fat: fat, nutrientName: nutrientName,
                                     nutrientAmount: nutrientAmount, nutrientUnit: nutrientUnit)
        if expected.kind != .single && edit.hasNutritionChange {
            throw SiriJournalDataError.derivedNutrition
        }
        let values = try edit.apply(to: expected.nutrition, serving: expected.serving, mappings: expected.mappings)
        guard values != expected.nutrition || archived != nil || onShelf != nil else { throw SiriJournalDataError.invalidEdit }
        let archiveChange = archived.map { $0 ? " Archive the food." : " Restore the food." } ?? ""
        let shelfChange = onShelf.map { $0 ? " Add it to the Food Shelf." : " Remove it from the Food Shelf." } ?? ""
        let nutrientChange = edit.nutrientSummary(in: values)
        try await requestConfirmation(actionName: .continue,
                                      dialog: "Update \(expected.nutrition.label) to \(values.portionLabel) with \(values.macrosLabel)\(nutrientChange)?\(archiveChange)\(shelfChange)")
        let saved = try data.updateFood(expected, values: values, archived: archived, onShelf: onShelf)
        return .result(value: data.foodRecord(saved), dialog: "Updated \(values.label) in your Food Bank.")
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct DeleteFoodBankItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Saved Food"
    static let description = IntentDescription("Permanently remove one specific OpenFoodJournal Food Bank item. Use Edit Saved Food instead when the person asked to archive. Requires confirmation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Saved Food", description: "The specific Food Bank item to permanently delete.") var item: SiriFoodBankRecord

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let data = runtime.journalData
        guard let food = try data.food(id: item.id) else { return .result(dialog: "That saved food is already gone.") }
        let expected = SiriSavedFoodSnapshot(food)
        try await requestConfirmation(actionName: .continue,
                                      dialog: "Permanently delete \(expected.nutrition.label) from your Food Bank? Your previously logged nutrition stays in the journal.")
        try data.deleteFood(expected)
        return .result(dialog: "Removed \(expected.nutrition.label) from your Food Bank.")
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct EditNutritionGoalsIntent: AppIntent {
    static let title: LocalizedStringResource = "Edit OpenFoodJournal Nutrition Goals"
    static let description = IntentDescription("Change specified OpenFoodJournal daily calorie or macro targets. Keep targets whose new values were omitted. Requires confirmation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Daily Calories in kcal") var calories: Double?
    @Parameter(title: "Daily Protein in Grams") var protein: Double?
    @Parameter(title: "Daily Carbohydrates in Grams") var carbs: Double?
    @Parameter(title: "Daily Fat in Grams") var fat: Double?

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriNutritionValues> & ProvidesDialog {
        let data = runtime.journalData
        try data.requireUnlock()
        let goals = data.goals
        let original = [goals.dailyCalories, goals.dailyProtein, goals.dailyCarbs, goals.dailyFat]
        let values = SiriNutritionValues(calories: calories ?? original[0], protein: protein ?? original[1],
                                        carbs: carbs ?? original[2], fat: fat ?? original[3])
        let modified = [values.calories, values.protein, values.carbs, values.fat]
        guard modified != original, values.calories > 0, modified.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw SiriJournalDataError.invalidEdit
        }
        try await requestConfirmation(actionName: .continue,
                                      dialog: "Set your daily goals to \(values.calories) calories, \(values.protein) g protein, \(values.carbs) g carbs, and \(values.fat) g fat?")
        try Task.checkCancellation()
        try data.requireUnlock()
        guard original == [goals.dailyCalories, goals.dailyProtein, goals.dailyCarbs, goals.dailyFat] else {
            throw SiriJournalDataError.recordChanged
        }
        goals.dailyCalories = values.calories
        goals.dailyProtein = values.protein
        goals.dailyCarbs = values.carbs
        goals.dailyFat = values.fat
        return .result(value: values, dialog: "Updated your daily nutrition goals.")
    }
}

extension AppIntent {
    @MainActor
    func confirmJournalAddition(values: SiriStoredNutrition, meal: MealType, day: Date, requestedAt: Date, data: SiriJournalData,
                                dialog: IntentDialog) async throws {
        if try data.hasRecentMatchingEntry(values, meal: meal, day: day, requestedAt: requestedAt) {
            try await requestConfirmation(actionName: .add, dialog: duplicateAdditionDialog(values))
        } else {
            try await requestConfirmation(actionName: .add, dialog: dialog)
            if try data.hasRecentMatchingEntry(values, meal: meal, day: day, requestedAt: requestedAt) {
                try await requestConfirmation(actionName: .add, dialog: duplicateAdditionDialog(values))
            }
        }
    }

    @MainActor
    private func duplicateAdditionDialog(_ values: SiriStoredNutrition) -> IntentDialog {
        "A matching \(values.portionLabel) is already logged around this time. Add another with \(values.macrosLabel)?"
    }
}

private extension SiriStoredNutrition {
    static func manual(name: String, brand: String?, quantity: Double, unit: String, calories: Double,
                       protein: Double, carbs: Double, fat: Double) throws -> Self {
        let brand = brand?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try Self(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        brand: brand?.isEmpty == true ? nil : brand, quantity: quantity, unit: SiriFoodUnits.normalized(unit),
                        calories: calories, protein: protein, carbs: carbs, fat: fat).validated()
    }
}

private extension SiriNutritionEdit {
    func nutrientSummary(in nutrition: SiriStoredNutrition) -> String {
        guard let nutrientName, let value = nutrition.micronutrients[KnownMicronutrients.normalize(nutrientName)] else { return "" }
        return ", and \(value.value.formatted()) \(value.unit) \(nutrientName)"
    }
}
