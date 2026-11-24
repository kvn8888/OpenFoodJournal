// AGPL-3.0 License

import AppIntents
import Foundation

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct FindFoodBankItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Saved Foods"
    static let description = IntentDescription("Find foods saved in the OpenFoodJournal Food Bank by name or brand. Use this to list items, compare brands, or find a saved item to read or edit.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Food or Brand", description: "A name or brand to find, such as Amazon milk. Leave empty to list saved foods.")
    var query: String?
    @Parameter(title: "Include Archived Foods", description: "Include manually and automatically archived Food Bank items in the search.", default: false)
    var includeArchived: Bool
    @Parameter(title: "Page", description: "Results are returned 25 at a time. Start at page 1.", default: 1) var page: Int

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[SiriFoodBankRecord]> {
        let data = runtime.journalData
        let matches = try data.foods(query: query, includeArchived: includeArchived)
        return .result(value: try data.page(matches, number: page).map(data.foodRecord))
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct ReadSavedFoodNutritionIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Saved Food Nutrition"
    static let description = IntentDescription("Read actual calories, macros, and stored micronutrients for an OpenFoodJournal Food Bank item. Can convert the saved values to the requested amount and unit.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Saved Food", description: "The Food Bank item to read. Use the brand to distinguish foods with similar names.")
    var food: SiriFoodBankRecord
    @Parameter(title: "Quantity", description: "Amount in the requested unit. Omit to use the saved portion.")
    var quantity: Double?
    @Parameter(title: "Unit", description: "Serving unit, such as grams, cups, slices, or servings.")
    var unit: String?

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriFoodNutritionResult> {
        guard let item = try runtime.journalData.food(id: food.id) else { throw SiriJournalDataError.itemUnavailable }
        let logging = runtime.foodLogging
        let request = try logging.resolve(item.name, quantity: quantity ?? unit.map { _ in 1 },
                                          unit: unit, parseSpokenPhrase: false)
        let draft = try logging.foodBankDraft(for: item, request: request)
        return .result(value: SiriFoodNutritionResult(values: .draft(draft), supportedUnits: runtime.journalData.units(for: item)))
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct ReadFoodBankDetailsIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Food Bank Details"
    static let description = IntentDescription("Read the stored portion, unit conversions, composite food ingredients, or calculator ingredient and portion options of a saved food.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Saved Food", description: "The saved food, composite, or nutrition calculator to inspect.")
    var food: SiriFoodBankRecord
    @Parameter(title: "Ingredient Page", description: "Ingredients and calculator portions are shown 25 at a time, starting at page 1.", default: 1)
    var page: Int

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriFoodDetailsResult> {
        let data = runtime.journalData
        guard let item = try data.food(id: food.id) else { throw SiriJournalDataError.itemUnavailable }
        return .result(value: try data.foodDetails(item, page: page))
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct FindJournalEntriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Journal Entries"
    static let description = IntentDescription("Read foods and exact nutrition logged in the OpenFoodJournal journal for a day or date range. Optionally filter by meal or food name.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Start Date", description: "First journal day to include. With no dates, use today.") var start: Date?
    @Parameter(title: "End Date", description: "Last journal day to include. Omit for a single day.") var end: Date?
    @Parameter(title: "Meal", description: "Only include this meal if provided.") var meal: MealTypeAppEnum?
    @Parameter(title: "Food or Brand", description: "Only include matching foods if provided.") var query: String?
    @Parameter(title: "Page", description: "Entries are returned 25 at a time, newest first. Start at page 1.", default: 1) var page: Int

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriJournalPage> {
        let data = runtime.journalData
        let result = try data.entries(from: start, through: end, meal: meal?.meal, query: query)
        let entries = try data.page(result.entries, number: page).map(SiriJournalEntryRecord.init)
        return .result(value: SiriJournalPage(entries: entries, totalCount: result.entries.count, page: page))
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct ReadJournalSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Journal Nutrition Summary"
    static let description = IntentDescription("Read calories, macros, and micronutrients logged in OpenFoodJournal, including totals and daily averages over a date range, current goals, and remaining nutrition for one day.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Start Date", description: "First day to summarize. With no dates, use today.") var start: Date?
    @Parameter(title: "End Date", description: "Last day in the range. Omit for a single day.") var end: Date?
    @Parameter(title: "Meal", description: "Limit totals to the specified meal if supplied.") var meal: MealTypeAppEnum?

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriJournalSummary> {
        .result(value: try runtime.journalData.summary(from: start, through: end, meal: meal?.meal))
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct ReadNutritionGoalsIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Nutrition Goals"
    static let description = IntentDescription("Read the user's current daily calorie and macronutrient targets configured in OpenFoodJournal.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriNutritionValues> {
        let data = runtime.journalData
        try data.requireUnlock()
        return .result(value: data.goalValues)
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct ReadTrackedFoodContainersIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Tracked Food Containers"
    static let description = IntentDescription("Read measured weights, remaining weight, and consumed nutrition for OpenFoodJournal's active or completed tracked food containers.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Active Containers Only", description: "Include only containers that are still being tracked.", default: false)
    var activeOnly: Bool
    @Parameter(title: "Page", description: "Containers are returned 25 at a time, newest first. Start at page 1.", default: 1)
    var page: Int

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[SiriContainerResult]> {
        let data = runtime.journalData
        let containers = try data.containers(activeOnly: activeOnly)
        return .result(value: try data.page(containers, number: page).map(SiriContainerResult.init))
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct FindAssistantConversationsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find OpenFoodJournal Assistant Conversations"
    static let description = IntentDescription("Find saved chats in OpenFoodJournal Assistant. Return conversation titles and dates so a specific conversation can be read.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Title", description: "Optional words in the saved conversation title.") var titleQuery: String?
    @Parameter(title: "Page", description: "Conversations are listed 25 at a time. Start at page 1.", default: 1) var page: Int

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[SiriAssistantConversationRecord]> {
        let data = runtime.journalData
        let matches = try data.conversations(matching: titleQuery)
        return .result(value: try data.page(matches, number: page).map(SiriAssistantConversationRecord.init))
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct ReadAssistantConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Read OpenFoodJournal Assistant Conversation"
    static let description = IntentDescription("Read the visible messages in one saved OpenFoodJournal Assistant conversation. Messages are returned in order.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Conversation", description: "The saved Assistant conversation to read.") var conversation: SiriAssistantConversationRecord
    @Parameter(title: "Page", description: "Messages are returned 25 at a time. Start at page 1.", default: 1) var page: Int

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[SiriAssistantMessageResult]> {
        let data = runtime.journalData
        guard let thread = try data.conversation(id: conversation.id) else { throw SiriJournalDataError.itemUnavailable }
        let messages = thread.safeMessages.filter {
            ($0.roleRaw == ChatRole.user.rawValue || $0.roleRaw == ChatRole.model.rawValue) && !$0.text.isEmpty
        }
        return .result(value: try data.page(messages, number: page).map {
            SiriAssistantMessageResult(sender: $0.roleRaw == ChatRole.user.rawValue ? "You" : "Assistant",
                                       timestamp: $0.timestamp, text: $0.text)
        })
    }
}

struct SiriNutritionSettings: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "OpenFoodJournal Nutrition Settings"
    @Property(title: "Breakfast starts at local minutes after midnight") var breakfast: Int
    @Property(title: "Lunch starts at local minutes after midnight") var lunch: Int
    @Property(title: "Dinner starts at local minutes after midnight") var dinner: Int
    @Property(title: "Apple Health sync enabled") var healthSync: Bool
    @Property(title: "Food Shelf recommendations enabled") var shelfEnabled: Bool
    @Property(title: "Number of Food Shelf suggestions") var shelfCount: Int
    @Property(title: "Food Shelf energy goal") var shelfEnergy: String
    @Property(title: "Food Shelf nutrition emphasis") var shelfEmphasis: String

    init() {
        breakfast = 0
        lunch = 0
        dinner = 0
        healthSync = false
        shelfEnabled = false
        shelfCount = 0
        shelfEnergy = ""
        shelfEmphasis = ""
    }

    var displayRepresentation: DisplayRepresentation { "OpenFoodJournal Nutrition Settings" }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct ReadNutritionSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Read OpenFoodJournal Nutrition Settings"
    static let description = IntentDescription("Read meal schedule, health sync status, and Food Shelf preferences from OpenFoodJournal.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriNutritionSettings> {
        let data = runtime.journalData
        let preferences = try data.preferences()
        var result = SiriNutritionSettings()
        result.breakfast = data.mealTimes.breakfastStartMinutes
        result.lunch = data.mealTimes.lunchStartMinutes
        result.dinner = data.mealTimes.dinnerStartMinutes
        result.healthSync = UserDefaults.standard.bool(forKey: "healthkit.enabled")
        result.shelfEnabled = preferences.shelfRecommendationsEnabled
        result.shelfCount = preferences.clampedShelfSuggestionCount
        result.shelfEnergy = preferences.shelfEnergyIntent.label
        result.shelfEmphasis = preferences.shelfNutritionEmphasis.label
        return .result(value: result)
    }
}

extension SiriJournalData {
    func foodRecord(_ food: SavedFood) -> SiriFoodBankRecord {
        let cutoff = SavedFood.foodBankArchiveCutoff(now: now(), calendar: calendar)
        return SiriFoodBankRecord(food, archived: food.archivedAt != nil || (!food.isOnShelf && food.lastUsedAt < cutoff))
    }

    var goalValues: SiriNutritionValues {
        SiriNutritionValues(calories: goals.dailyCalories, protein: goals.dailyProtein, carbs: goals.dailyCarbs, fat: goals.dailyFat)
    }

    func units(for food: SavedFood) -> [String] {
        let values = SiriStoredNutrition.food(food)
        let converter = ServingConverter(calories: values.calories, protein: values.protein, carbs: values.carbs, fat: values.fat,
                                         quantity: values.quantity, unit: values.unit, serving: food.serving, mappings: food.servingMappings)
        return Array(Set(converter.availableUnits.filter { unit in
            guard let factor = converter.conversionFactor(for: unit) else { return false }
            return factor.isFinite && factor > 0
        } + ["serving"])).sorted()
    }

    func foodDetails(_ food: SavedFood, page: Int) throws -> SiriFoodDetailsResult {
        try requireUnlock()
        var result = SiriFoodDetailsResult()
        result.name = SiriStoredNutrition.food(food).label
        result.kind = food.kind.rawValue
        result.servingsPerContainer = food.servingsPerContainer
        result.conversions = food.servingMappings.map {
            "\($0.from.value.formatted()) \($0.from.unit) equals \($0.to.value.formatted()) \($0.to.unit)"
        }
        if food.kind != .calculator {
            result.savedPortion = SiriFoodNutritionResult(values: .food(food), supportedUnits: units(for: food))
        }

        let components: [SiriFoodComponent]
        switch food.kind {
        case .single:
            components = []
        case .composite:
            components = food.compositeIngredients.map {
                let totals = $0.scaledNutrition
                return SiriFoodComponent(
                    ingredient: $0.name, portion: "\($0.selectedQuantity.formatted()) \($0.selectedUnit)", notes: $0.brand,
                    nutrition: Self.nutritionValues(calories: totals.calories, protein: totals.protein, carbs: totals.carbs,
                                                    fat: totals.fat, micronutrients: totals.micronutrients)
                )
            }
        case .calculator:
            components = food.calculatorIngredients.flatMap { ingredient in
                ingredient.portions.map {
                    SiriFoodComponent(ingredient: ingredient.name, portion: $0.label, notes: ingredient.note,
                                      nutrition: Self.nutritionValues(calories: $0.calories, protein: $0.protein,
                                                                      carbs: $0.carbs, fat: $0.fat, micronutrients: $0.micronutrients))
                }
            }
        }
        result.totalComponents = components.count
        result.components = try self.page(components, number: page)
        return result
    }

    func summary(from start: Date?, through end: Date?, meal: MealType?) throws -> SiriJournalSummary {
        let result = try entries(from: start, through: end, meal: meal)
        let totals = JournalDayTotals(entries: result.entries)
        let nutrients = Self.summedMicronutrients(result.entries)
        var summary = SiriJournalSummary()
        summary.start = result.start
        summary.end = result.end
        summary.days = result.days
        summary.trackedDays = Set(result.entries.map { calendar.startOfDay(for: $0.dailyLog?.date ?? $0.timestamp) }).count
        summary.entryCount = result.entries.count
        summary.total = SiriNutritionValues(calories: totals.calories, protein: totals.protein, carbs: totals.carbs, fat: totals.fat,
                                            micronutrients: nutrients)
        let days = Double(result.days)
        summary.dailyAverage = SiriNutritionValues(calories: totals.calories / days, protein: totals.protein / days,
                                                   carbs: totals.carbs / days, fat: totals.fat / days, micronutrients: nutrients.map {
            SiriNutrientAmount(name: $0.name, value: $0.value / days, unit: $0.unit)
        })
        summary.dailyGoals = goalValues
        if result.days == 1, meal == nil {
            summary.remaining = SiriNutritionValues(calories: goals.dailyCalories - totals.calories,
                                                    protein: goals.dailyProtein - totals.protein,
                                                    carbs: goals.dailyCarbs - totals.carbs, fat: goals.dailyFat - totals.fat)
        }
        return summary
    }

    private struct NutrientKey: Hashable {
        let name: String
        let unit: String
    }

    private static func summedMicronutrients(_ entries: [NutritionEntry]) -> [SiriNutrientAmount] {
        var totals: [NutrientKey: Double] = [:]
        for entry in entries {
            for (name, nutrient) in entry.micronutrients {
                let key = NutrientKey(name: KnownMicronutrients.normalize(name), unit: nutrient.unit)
                totals[key, default: 0] += nutrient.value
            }
        }
        return totals.sorted { ($0.key.name, $0.key.unit) < ($1.key.name, $1.key.unit) }.map {
            SiriNutrientAmount(name: $0.key.name, value: $0.value, unit: $0.key.unit)
        }
    }

    private static func nutritionValues(calories: Double, protein: Double, carbs: Double, fat: Double,
                                        micronutrients: [String: MicronutrientValue]) -> SiriNutritionValues {
        SiriNutritionValues(calories: calories, protein: protein, carbs: carbs, fat: fat,
                            micronutrients: micronutrients.sorted { $0.key < $1.key }.map {
            SiriNutrientAmount(name: $0.key, value: $0.value.value, unit: $0.value.unit)
        })
    }
}

struct SiriActivityEnergyResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Apple Health Active Energy"
    @Property(title: "Day") var day: Date
    @Property(title: "Available active energy in kcal") var calories: Double?

    init() { self.init(day: .distantPast, calories: nil) }

    init(day: Date, calories: Double?) {
        self.day = day
        self.calories = calories
    }

    var displayRepresentation: DisplayRepresentation { "Apple Health Active Energy" }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct ReadActiveEnergyInFoodJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Active Energy in OpenFoodJournal"
    static let description = IntentDescription("Read one day's active energy through OpenFoodJournal's linked Apple Health access. An absent value means no accessible sample, not zero.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Date", description: "The local day to read. Omit for today.") var date: Date?

    @Dependency private var runtime: SiriAppRuntime

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SiriActivityEnergyResult> {
        let data = runtime.journalData
        try data.requireUnlock()
        let day = data.calendar.startOfDay(for: date ?? data.now())
        guard UserDefaults.standard.bool(forKey: "healthkit.enabled") else {
            return .result(value: SiriActivityEnergyResult(day: day, calories: nil))
        }
        let value = await runtime.healthKit.activeEnergySample(for: day)
        try Task.checkCancellation()
        try data.requireUnlock()
        return .result(value: SiriActivityEnergyResult(day: day, calories: value))
    }
}
