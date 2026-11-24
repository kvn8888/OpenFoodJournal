// AGPL-3.0 License

import AppIntents
import Foundation

#if OFJ_SIRI_AI_PREVIEW
@AppEntity(.generable)
nonisolated struct SiriNutritionInput: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Food Portion and Nutrition"

    @Property(title: "Name", description: "Food name. Required when creating a food or entry. Omit when keeping the name.")
    var name: String?
    @Property(title: "Brand", description: "Brand or manufacturer, such as Kirkland Signature. Omit when unchanged.")
    var brand: String?
    @Property(title: "Quantity", description: "Positive amount in the supplied unit. For a new food, the default is one.")
    var quantity: Double?
    @Property(title: "Unit", description: "Serving unit, such as grams, cups, or servings. Omit when unchanged.")
    var unit: String?
    @Property(title: "Calories", description: "Known energy for the entire portion, in kilocalories. Required for a new food.")
    var calories: Double?
    @Property(title: "Protein", description: "Grams of protein in the entire portion. Omit if the person did not specify.")
    var protein: Double?
    @Property(title: "Carbohydrates", description: "Grams of carbohydrates in the entire portion. Omit when unspecified.")
    var carbs: Double?
    @Property(title: "Fat", description: "Grams of fat in the entire portion. Omit when unspecified.")
    var fat: Double?
    @Property(title: "Micronutrient", description: "Name of a micronutrient to set, such as sodium. Supply its amount as well.")
    var nutrientName: String?
    @Property(title: "Micronutrient Amount", description: "Amount of the named micronutrient in the supplied or standard unit.")
    var nutrientAmount: Double?
    @Property(title: "Micronutrient Unit", description: "Unit of the supplied micronutrient amount, such as mg or mcg.")
    var nutrientUnit: String?

    init() {}

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Food Portion and Nutrition")
    }

    @MainActor var edit: SiriNutritionEdit {
        SiriNutritionEdit(name: name, brand: brand, quantity: quantity, unit: unit, calories: calories,
                         protein: protein, carbs: carbs, fat: fat, nutrientName: nutrientName,
                         nutrientAmount: nutrientAmount, nutrientUnit: nutrientUnit)
    }

    @MainActor func manualValues() throws -> SiriStoredNutrition {
        guard let name, let calories else { throw SiriJournalDataError.invalidEdit }
        let original = try SiriStoredNutrition.manual(name: name, brand: brand, quantity: quantity ?? 1,
                                                     unit: unit ?? "serving", calories: calories,
                                                     protein: protein ?? 0, carbs: carbs ?? 0, fat: fat ?? 0)
        let micronutrient = SiriNutritionEdit(nutrientName: nutrientName, nutrientAmount: nutrientAmount, nutrientUnit: nutrientUnit)
        return try micronutrient.apply(to: original, serving: nil, mappings: [])
    }
}

@AppIntent(.tool)
struct LogMeasuredFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Food With Known Nutrition"
    static let description = IntentDescription("Log a food in OpenFoodJournal when the person supplies its actual nutrition. Calories and macros describe the entire portion. Ask for confirmation before saving.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Portion and Nutrition", description: "Food name, portion, and known calories and macronutrients supplied by the person.")
    var portion: SiriNutritionInput
    @Parameter(title: "Meal", description: "Meal to log. Omit to use the current meal schedule.") var meal: MealTypeAppEnum?
    @Parameter(title: "Journal Day", description: "Local day to log. Omit for today.") var date: Date?

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriJournalEntryRecord> & ProvidesDialog {
        let data = runtime.journalData
        try data.requireUnlock()
        let now = data.now()
        let day = data.calendar.startOfDay(for: date ?? now)
        let meal = meal?.meal ?? data.mealTimes.mealType(for: now, calendar: data.calendar)
        let values = try portion.manualValues()
        try await confirmJournalAddition(values: values, meal: meal, day: day, requestedAt: now, data: data,
                                         dialog: "Add \(values.portionLabel) for \(meal.rawValue.lowercased()) on \(day.formatted(date: .long, time: .omitted))? It has \(values.macrosLabel).")
        let saved = try data.createEntry(values, meal: meal, day: day, requestedAt: now)
        return .result(value: SiriJournalEntryRecord(saved), dialog: "Logged \(values.label) for \(meal.rawValue.lowercased()).")
    }
}

@AppIntent(.tool)
struct EditJournalFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Edit Journal Food"
    static let description = IntentDescription("Edit one identified OpenFoodJournal entry. Only fields supplied are changed. Amount changes scale the saved nutrition unless replacement values are supplied. Requires confirmation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Entry", description: "A specific entry from the journal. Resolve the correct day and meal first.")
    var item: SiriJournalEntryRecord
    @Parameter(title: "Food and Nutrition Changes", description: "Only the updated food, portion, and nutrition fields the person specified.")
    var changes: SiriNutritionInput?
    @Parameter(title: "New Meal", description: "The replacement meal to use. Omit to keep the current meal.") var meal: MealTypeAppEnum?
    @Parameter(title: "New Journal Day", description: "The replacement local date. Omit to keep the current day.") var date: Date?

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriJournalEntryRecord> & ProvidesDialog {
        let data = runtime.journalData
        guard let entry = try data.entry(id: item.id) else { throw SiriJournalDataError.itemUnavailable }
        let expected = SiriJournalEntrySnapshot(entry)
        let edit = changes?.edit ?? SiriNutritionEdit()
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

@AppIntent(.tool)
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

@AppIntent(.tool)
struct CreateFoodBankItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Saved Food"
    static let description = IntentDescription("Save a new reusable food to the OpenFoodJournal Food Bank with its known nutrition per saved portion. Requires confirmation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Portion and Nutrition", description: "Food name, saved portion, and known nutrition the person provided.")
    var portion: SiriNutritionInput

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriFoodBankRecord> & ProvidesDialog {
        let data = runtime.journalData
        try data.requireUnlock()
        let values = try portion.manualValues()
        try await requestConfirmation(actionName: .create,
                                      dialog: "Save \(values.label) to your Food Bank with \(values.macrosLabel) per \(values.quantity.formatted()) \(values.unit)?")
        return .result(value: data.foodRecord(try data.createFood(values)), dialog: "Saved \(values.label) to your Food Bank.")
    }
}

@AppIntent(.tool)
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

@AppIntent(.tool)
struct EditFoodBankItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Edit Saved Food"
    static let description = IntentDescription("Edit a saved food's name, brand, portion, or nutrition, or archive, restore, or change its Food Shelf status. Changes affect the saved item and future logging. Requires confirmation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Saved Food", description: "The specific Food Bank item to change.") var item: SiriFoodBankRecord
    @Parameter(title: "Food and Nutrition Changes", description: "Only the replacement fields the person specified for this saved food.")
    var changes: SiriNutritionInput?
    @Parameter(title: "Archived", description: "True archives the food. False restores it to the active Food Bank.")
    var archived: Bool?
    @Parameter(title: "On Food Shelf", description: "True adds the food to the Food Shelf. False removes it from the shelf.")
    var onShelf: Bool?

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriFoodBankRecord> & ProvidesDialog {
        let data = runtime.journalData
        guard let food = try data.food(id: item.id) else { throw SiriJournalDataError.itemUnavailable }
        let expected = SiriSavedFoodSnapshot(food)
        let edit = changes?.edit ?? SiriNutritionEdit()
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

@AppIntent(.tool)
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

@AppIntent(.tool)
struct EditNutritionGoalsIntent: AppIntent {
    static let title: LocalizedStringResource = "Edit OpenFoodJournal Nutrition Goals"
    static let description = IntentDescription("Change specified OpenFoodJournal daily calorie or macro targets. Keep targets whose new values were omitted. Requires confirmation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Daily Calories", description: "New daily energy goal in kcal. Omit to keep the current goal.") var calories: Double?
    @Parameter(title: "Daily Protein", description: "New daily grams of protein. Omit to keep the current goal.") var protein: Double?
    @Parameter(title: "Daily Carbohydrates", description: "New daily grams of carbohydrates. Omit when unchanged.") var carbs: Double?
    @Parameter(title: "Daily Fat", description: "New daily grams of fat. Omit when unchanged.") var fat: Double?

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
#endif

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
