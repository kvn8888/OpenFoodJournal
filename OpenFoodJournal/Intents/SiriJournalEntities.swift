// AGPL-3.0 License

import AppIntents
import Foundation

// These entities are returned by authenticated reads. They aren't indexed.
nonisolated struct SiriNutrientAmount: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Nutrient Amount"
    @Property(title: "Nutrient") var name: String
    @Property(title: "Amount") var value: Double
    @Property(title: "Unit") var unit: String

    init() { self.init(name: "", value: 0, unit: "") }

    init(name: String, value: Double, unit: String) {
        self.name = name
        self.value = value
        self.unit = unit
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

nonisolated struct SiriNutritionValues: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Nutrition Values"
    @Property(title: "Calories in kcal") var calories: Double
    @Property(title: "Protein in grams") var protein: Double
    @Property(title: "Carbohydrates in grams") var carbs: Double
    @Property(title: "Fat in grams") var fat: Double
    @Property(title: "Micronutrients") var micronutrients: [SiriNutrientAmount]

    init() { self.init(calories: 0, protein: 0, carbs: 0, fat: 0) }

    init(calories: Double, protein: Double, carbs: Double, fat: Double, micronutrients: [SiriNutrientAmount] = []) {
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.micronutrients = micronutrients
    }

    @MainActor init(_ stored: SiriStoredNutrition) {
        self.init(calories: stored.calories, protein: stored.protein, carbs: stored.carbs, fat: stored.fat,
                  micronutrients: stored.micronutrients.sorted { $0.key < $1.key }.map {
                      SiriNutrientAmount(name: $0.key, value: $0.value.value, unit: $0.value.unit)
                  })
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Nutrition Values") }
}

nonisolated struct SiriFoodBankRecord: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved Food"
    static let defaultQuery = SiriFoodBankRecordQuery()
    let id: UUID
    @Property(title: "Food name") var name: String
    @Property(title: "Brand") var brand: String?
    @Property(title: "Food kind") var kind: String
    @Property(title: "Archived") var archived: Bool
    @Property(title: "On Shelf") var onShelf: Bool

    @MainActor init(_ food: SavedFood, archived: Bool) {
        id = food.id
        name = food.name
        brand = food.brand
        kind = food.kind.rawValue
        self.archived = archived
        onShelf = food.isOnShelf
    }

    var label: String {
        if let brand, !name.localizedCaseInsensitiveContains(brand) { return "\(brand) \(name)" }
        return name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }
}

struct SiriFoodBankRecordQuery: EntityStringQuery {
    @Dependency private var runtime: SiriAppRuntime

    @MainActor func entities(for identifiers: [UUID]) async throws -> [SiriFoodBankRecord] {
        try runtime.journalData.requireUnlock()
        return try identifiers.compactMap { id in
            try runtime.journalData.food(id: id).map(runtime.journalData.foodRecord)
        }
    }

    @MainActor func entities(matching string: String) async throws -> [SiriFoodBankRecord] {
        let data = runtime.journalData
        return try data.foods(query: string, includeArchived: true).prefix(SiriJournalData.pageSize).map(data.foodRecord)
    }
}

nonisolated struct SiriFoodNutritionResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved Food Nutrition"
    @Property(title: "Food name") var name: String
    @Property(title: "Brand") var brand: String?
    @Property(title: "Quantity") var quantity: Double
    @Property(title: "Serving unit") var unit: String
    @Property(title: "Nutrition for this portion") var nutrition: SiriNutritionValues
    @Property(title: "Supported units") var supportedUnits: [String]

    init() {
        name = ""
        brand = nil
        quantity = 1
        unit = "serving"
        nutrition = SiriNutritionValues()
        supportedUnits = []
    }

    @MainActor init(values: SiriStoredNutrition, supportedUnits: [String]) {
        name = values.name
        brand = values.brand
        quantity = values.quantity
        unit = values.unit
        nutrition = SiriNutritionValues(values)
        self.supportedUnits = supportedUnits
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

nonisolated struct SiriFoodComponent: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Food Ingredient Portion"
    @Property(title: "Ingredient") var ingredient: String
    @Property(title: "Portion") var portion: String
    @Property(title: "Notes") var notes: String?
    @Property(title: "Nutrition for this portion") var nutrition: SiriNutritionValues

    init() { self.init(ingredient: "", portion: "", notes: nil, nutrition: SiriNutritionValues()) }

    init(ingredient: String, portion: String, notes: String?, nutrition: SiriNutritionValues) {
        self.ingredient = ingredient
        self.portion = portion
        self.notes = notes
        self.nutrition = nutrition
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(ingredient) \(portion)") }
}

nonisolated struct SiriFoodDetailsResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Food Bank Details"
    @Property(title: "Food name") var name: String
    @Property(title: "Kind") var kind: String
    @Property(title: "Saved portion") var savedPortion: SiriFoodNutritionResult?
    @Property(title: "Servings per container") var servingsPerContainer: Double?
    @Property(title: "Unit conversions") var conversions: [String]
    @Property(title: "Ingredients and portions on this page") var components: [SiriFoodComponent]
    @Property(title: "Total ingredient portions") var totalComponents: Int

    init() {
        name = ""
        kind = ""
        savedPortion = nil
        servingsPerContainer = nil
        conversions = []
        components = []
        totalComponents = 0
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

nonisolated struct SiriJournalEntryRecord: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Journal Entry"
    static let defaultQuery = SiriJournalEntryRecordQuery()
    let id: UUID
    @Property(title: "Food name") var name: String
    @Property(title: "Brand") var brand: String?
    @Property(title: "Logged date and time") var timestamp: Date
    @Property(title: "Journal day") var day: Date
    @Property(title: "Meal") var meal: String
    @Property(title: "Quantity") var quantity: Double
    @Property(title: "Serving unit") var unit: String
    @Property(title: "Portion description") var servingDescription: String?
    @Property(title: "Nutrition for the logged portion") var nutrition: SiriNutritionValues
    @Property(title: "Selected calculator ingredients") var ingredients: String?

    @MainActor init(_ entry: NutritionEntry) {
        let value = SiriJournalEntrySnapshot(entry)
        id = value.id
        name = value.nutrition.name
        brand = value.nutrition.brand
        timestamp = value.timestamp
        day = value.day
        meal = value.meal.rawValue
        quantity = value.nutrition.quantity
        unit = value.nutrition.unit
        servingDescription = value.servingDescription
        nutrition = SiriNutritionValues(value.nutrition)
        ingredients = value.selection
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name) for \(meal) on \(day.formatted(date: .abbreviated, time: .omitted))") }
}

struct SiriJournalEntryRecordQuery: EntityStringQuery {
    @Dependency private var runtime: SiriAppRuntime

    @MainActor func entities(for identifiers: [UUID]) async throws -> [SiriJournalEntryRecord] {
        try runtime.journalData.requireUnlock()
        return try identifiers.compactMap { id in
            try runtime.journalData.entry(id: id).map(SiriJournalEntryRecord.init)
        }
    }

    @MainActor func entities(matching string: String) async throws -> [SiriJournalEntryRecord] {
        try runtime.journalData.recentEntries(matching: string).prefix(SiriJournalData.pageSize).map(SiriJournalEntryRecord.init)
    }
}

nonisolated struct SiriJournalPage: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Journal Entry Results"
    @Property(title: "Matching entries on this page") var entries: [SiriJournalEntryRecord]
    @Property(title: "Total matching entries") var totalCount: Int
    @Property(title: "Page number") var page: Int

    init() { self.init(entries: [], totalCount: 0, page: 1) }

    init(entries: [SiriJournalEntryRecord], totalCount: Int, page: Int) {
        self.entries = entries
        self.totalCount = totalCount
        self.page = page
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Journal Entry Results") }
}

nonisolated struct SiriJournalSummary: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Journal Nutrition Summary"
    @Property(title: "First day") var start: Date
    @Property(title: "Last day") var end: Date
    @Property(title: "Calendar days") var days: Int
    @Property(title: "Days with entries") var trackedDays: Int
    @Property(title: "Number of entries") var entryCount: Int
    @Property(title: "Total nutrition") var total: SiriNutritionValues
    @Property(title: "Average nutrition per calendar day") var dailyAverage: SiriNutritionValues
    @Property(title: "Current daily goals") var dailyGoals: SiriNutritionValues
    @Property(title: "Remaining for a single day through the current goal") var remaining: SiriNutritionValues?

    init() {
        start = .distantPast
        end = .distantPast
        days = 0
        trackedDays = 0
        entryCount = 0
        total = SiriNutritionValues()
        dailyAverage = SiriNutritionValues()
        dailyGoals = SiriNutritionValues()
        remaining = nil
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Journal Nutrition Summary") }
}

nonisolated struct SiriContainerResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tracked Container"
    @Property(title: "Food name") var name: String
    @Property(title: "Brand") var brand: String?
    @Property(title: "Active") var active: Bool
    @Property(title: "Started at") var startedAt: Date
    @Property(title: "Completed at") var completedAt: Date?
    @Property(title: "Starting gross weight in grams") var startWeight: Double
    @Property(title: "Tare weight in grams") var tareWeight: Double?
    @Property(title: "Final gross weight in grams") var finalWeight: Double?
    @Property(title: "Food remaining in grams") var remainingGrams: Double?
    @Property(title: "Food consumed in grams") var consumedGrams: Double?
    @Property(title: "Consumed nutrition") var consumedNutrition: SiriNutritionValues?

    init() {
        name = ""
        brand = nil
        active = false
        startedAt = .distantPast
        completedAt = nil
        startWeight = 0
        tareWeight = nil
        finalWeight = nil
        remainingGrams = nil
        consumedGrams = nil
        consumedNutrition = nil
    }

    @MainActor init(_ container: TrackedContainer) {
        self.init()
        name = container.foodName
        brand = container.foodBrand
        active = container.isActive
        startedAt = container.startDate
        completedAt = container.completedDate
        startWeight = container.startWeight
        tareWeight = container.tareWeight
        finalWeight = container.finalWeight
        remainingGrams = container.remainingFoodGrams
        consumedGrams = container.consumedGrams
        if let calories = container.consumedCalories {
            let nutrients = (container.consumedMicronutrients ?? [:]).sorted { $0.key < $1.key }.map {
                SiriNutrientAmount(name: $0.key, value: $0.value.value, unit: $0.value.unit)
            }
            consumedNutrition = SiriNutritionValues(calories: calories, protein: container.consumedProtein ?? 0,
                                                    carbs: container.consumedCarbs ?? 0, fat: container.consumedFat ?? 0,
                                                    micronutrients: nutrients)
        }
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

nonisolated struct SiriAssistantConversationRecord: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Assistant Conversation"
    static let defaultQuery = SiriAssistantConversationQuery()
    let id: UUID
    @Property(title: "Conversation title") var title: String
    @Property(title: "Last updated") var updatedAt: Date

    @MainActor init(_ thread: ChatThread) {
        id = thread.id
        title = thread.displayTitle
        updatedAt = thread.updatedAt
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct SiriAssistantConversationQuery: EntityStringQuery {
    @Dependency private var runtime: SiriAppRuntime

    @MainActor func entities(for identifiers: [UUID]) async throws -> [SiriAssistantConversationRecord] {
        try runtime.journalData.requireUnlock()
        return try identifiers.compactMap { id in
            try runtime.journalData.conversation(id: id).map(SiriAssistantConversationRecord.init)
        }
    }

    @MainActor func entities(matching string: String) async throws -> [SiriAssistantConversationRecord] {
        try runtime.journalData.conversations(matching: string).prefix(SiriJournalData.pageSize)
            .map(SiriAssistantConversationRecord.init)
    }
}

nonisolated struct SiriAssistantMessageResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Assistant Conversation Message"
    @Property(title: "Sender") var sender: String
    @Property(title: "Time") var timestamp: Date
    @Property(title: "Message text") var text: String

    init() { self.init(sender: "", timestamp: .distantPast, text: "") }

    init(sender: String, timestamp: Date, text: String) {
        self.sender = sender
        self.timestamp = timestamp
        self.text = text
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(sender) message") }
}
