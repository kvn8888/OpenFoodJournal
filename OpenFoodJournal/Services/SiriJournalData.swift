// AGPL-3.0 License

import Foundation
import SwiftData

enum SiriJournalDataError: LocalizedError, Equatable {
    case invalidRange
    case invalidPage
    case itemUnavailable
    case invalidEdit
    case derivedNutrition
    case unsavedChanges
    case recordChanged

    var errorDescription: String? {
        switch self {
        case .invalidRange: "Choose a date range in order, up to one year."
        case .invalidPage: "Choose a page number greater than zero."
        case .itemUnavailable: "That item is no longer available in OpenFoodJournal."
        case .invalidEdit: "Provide a valid name, serving, or nutrition value to change."
        case .derivedNutrition: "Open this food in the Food Bank to change the ingredients that determine its nutrition."
        case .unsavedChanges: "Finish the changes in OpenFoodJournal before making this edit with Siri."
        case .recordChanged: "This item changed while you were reviewing it. Review the current item before trying again."
        }
    }
}

struct SiriStoredNutrition: Equatable {
    let name: String
    let brand: String?
    let quantity: Double
    let unit: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    var micronutrients: [String: MicronutrientValue] = [:]

    var label: String {
        if let brand, !name.localizedCaseInsensitiveContains(brand) { return "\(brand) \(name)" }
        return name
    }

    var portionLabel: String { "\(quantity.formatted()) \(unit) of \(label)" }

    var macrosLabel: String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        return "\(calories.formatted(format)) calories, \(protein.formatted(format)) g protein, \(carbs.formatted(format)) g carbs, \(fat.formatted(format)) g fat"
    }

    func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              quantity.isFinite, quantity > 0,
              [calories, protein, carbs, fat].allSatisfy({ $0.isFinite && $0 >= 0 }),
              micronutrients.values.allSatisfy({ $0.value.isFinite && $0.value >= 0 }) else {
            throw SiriJournalDataError.invalidEdit
        }
        return self
    }

    static func entry(_ entry: NutritionEntry) -> Self {
        Self(name: entry.name, brand: entry.brand, quantity: entry.servingQuantity ?? 1,
             unit: entry.servingUnit ?? "serving", calories: entry.calories, protein: entry.protein,
             carbs: entry.carbs, fat: entry.fat, micronutrients: entry.micronutrients)
    }

    static func food(_ food: SavedFood) -> Self {
        Self(name: food.name, brand: food.brand, quantity: food.servingQuantity ?? 1,
             unit: food.servingUnit ?? "serving", calories: food.calories, protein: food.protein,
             carbs: food.carbs, fat: food.fat, micronutrients: food.micronutrients)
    }

    static func draft(_ draft: SiriNutritionDraft) -> Self {
        Self(name: draft.name, brand: draft.brand, quantity: draft.quantity, unit: draft.unit,
             calories: draft.calories, protein: draft.protein, carbs: draft.carbs, fat: draft.fat,
             micronutrients: draft.micronutrients)
    }

    func scaledServing(_ original: ServingSize?, from previous: Self, mappings: [ServingMapping]) -> ServingSize? {
        guard let original else { return nil }
        let converter = ServingConverter(calories: previous.calories, protein: previous.protein, carbs: previous.carbs,
                                         fat: previous.fat, quantity: previous.quantity, unit: previous.unit,
                                         serving: original, mappings: mappings)
        guard let factor = converter.conversionFactor(for: unit), factor.isFinite, factor > 0 else { return original }
        let ratio = quantity / factor / converter.baseQuantity
        switch original {
        case .mass(let grams): return .mass(grams: grams * ratio)
        case .volume(let ml): return .volume(ml: ml * ratio)
        case .both(let grams, let ml): return .both(grams: grams * ratio, ml: ml * ratio)
        }
    }
}

struct SiriJournalEntrySnapshot: Equatable {
    let id: UUID
    let timestamp: Date
    let day: Date
    let meal: MealType
    let nutrition: SiriStoredNutrition
    let foodID: UUID?
    let serving: ServingSize?
    let servingsPerContainer: Double?
    let mappings: [ServingMapping]
    let servingDescription: String?
    let selection: String?

    init(_ entry: NutritionEntry) {
        id = entry.id
        timestamp = entry.timestamp
        day = entry.dailyLog?.date ?? entry.timestamp
        meal = entry.mealType
        nutrition = .entry(entry)
        foodID = entry.savedFoodID
        serving = entry.serving
        servingsPerContainer = entry.servingsPerContainer
        mappings = entry.servingMappings
        servingDescription = entry.servingSize
        selection = entry.selectionSummary
    }
}

struct SiriSavedFoodSnapshot: Equatable {
    let id: UUID
    let kind: SavedFoodKind
    let nutrition: SiriStoredNutrition
    let archivedAt: Date?
    let lastUsedAt: Date
    let isOnShelf: Bool
    let serving: ServingSize?
    let servingDescription: String?
    let servingsPerContainer: Double?
    let mappings: [ServingMapping]
    let compositeIngredients: [CompositeIngredientSnapshot]
    let calculatorIngredients: [CalculatorIngredient]

    init(_ food: SavedFood) {
        id = food.id
        kind = food.kind
        nutrition = .food(food)
        archivedAt = food.archivedAt
        lastUsedAt = food.lastUsedAt
        isOnShelf = food.isOnShelf
        serving = food.serving
        servingDescription = food.servingSize
        servingsPerContainer = food.servingsPerContainer
        mappings = food.servingMappings
        compositeIngredients = food.compositeIngredients
        calculatorIngredients = food.calculatorIngredients
    }
}

@MainActor
final class SiriJournalData {
    static let pageSize = 25
    let store: NutritionStore
    let goals: UserGoals
    let mealTimes: MealTimeSettings
    let calendar: Calendar
    let now: () -> Date
    private let foodLogging: SiriFoodLoggingService
    private let context: ModelContext

    init(store: NutritionStore, goals: UserGoals, mealTimes: MealTimeSettings, foodLogging: SiriFoodLoggingService,
         calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = { .now }) {
        self.store = store
        self.context = store.modelContext
        self.goals = goals
        self.mealTimes = mealTimes
        self.foodLogging = foodLogging
        self.calendar = calendar
        self.now = now
    }

    func requireUnlock() throws {
        try foodLogging.requireUnlock()
    }

    func foods(query: String? = nil, includeArchived: Bool) throws -> [SavedFood] {
        try requireUnlock()
        let descriptor = FetchDescriptor<SavedFood>(
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse), SortDescriptor(\.id)]
        )
        let cutoff = SavedFood.foodBankArchiveCutoff(now: now(), calendar: calendar)
        let foods = try context.fetch(descriptor).filter {
            includeArchived || ($0.archivedAt == nil && ($0.isOnShelf || $0.lastUsedAt >= cutoff))
        }
        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return foods }
        return SiriFoodLoggingService.matches(query, in: foods).candidates
    }

    func food(id: UUID) throws -> SavedFood? {
        try requireUnlock()
        var descriptor = FetchDescriptor<SavedFood>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func entry(id: UUID) throws -> NutritionEntry? {
        try requireUnlock()
        var descriptor = FetchDescriptor<NutritionEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func entries(from start: Date?, through end: Date?, meal: MealType? = nil, query: String? = nil)
        throws -> (start: Date, end: Date, days: Int, entries: [NutritionEntry]) {
        try requireUnlock()
        let startDay = calendar.startOfDay(for: start ?? end ?? now())
        let endDay = calendar.startOfDay(for: end ?? start ?? now())
        guard let difference = calendar.dateComponents([.day], from: startDay, to: endDay).day,
              (0..<366).contains(difference) else { throw SiriJournalDataError.invalidRange }
        let logs = try context.fetch(FetchDescriptor<DailyLog>(
            predicate: #Predicate { $0.date >= startDay && $0.date <= endDay }
        ))
        let preferredLogs = JournalDayData.preferredLogs(from: logs, calendar: calendar)
        let text = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let entries = preferredLogs.values.flatMap(\.safeEntries).filter { entry in
            (meal == nil || entry.mealType == meal) &&
            (text.isEmpty || entry.name.localizedStandardContains(text) ||
             entry.brand?.localizedStandardContains(text) == true)
        }.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return (startDay, endDay, difference + 1, entries)
    }

    func recentEntries(matching text: String? = nil) throws -> [NutritionEntry] {
        let end = now()
        let start = calendar.date(byAdding: .day, value: -30, to: end)
        return try entries(from: start, through: end, query: text).entries
    }

    func containers(activeOnly: Bool) throws -> [TrackedContainer] {
        try requireUnlock()
        let values = try context.fetch(FetchDescriptor<TrackedContainer>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse), SortDescriptor(\.id)]
        ))
        return activeOnly ? values.filter(\.isActive) : values
    }

    func preferences() throws -> Preferences {
        try requireUnlock()
        var descriptor = FetchDescriptor<Preferences>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        // Unlike Preferences.current, the read path never inserts a default row.
        return try context.fetch(descriptor).first ?? Preferences()
    }

    func conversations(matching text: String?) throws -> [ChatThread] {
        try requireUnlock()
        let values = try context.fetch(FetchDescriptor<ChatThread>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse), SortDescriptor(\.id)]
        ))
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return values }
        return values.filter { $0.displayTitle.localizedStandardContains(text) }
    }

    func conversation(id: UUID) throws -> ChatThread? {
        try requireUnlock()
        var descriptor = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func page<T>(_ values: [T], number: Int) throws -> [T] {
        guard number > 0 else { throw SiriJournalDataError.invalidPage }
        let (offset, overflow) = (number - 1).multipliedReportingOverflow(by: Self.pageSize)
        guard !overflow else { throw SiriJournalDataError.invalidPage }
        return Array(values.dropFirst(offset).prefix(Self.pageSize))
    }

    func createFood(_ values: SiriStoredNutrition) throws -> SavedFood {
        let values = try values.validated()
        let food = SavedFood(name: values.name, brand: values.brand, createdAt: now(),
                             calories: values.calories, protein: values.protein, carbs: values.carbs,
                             fat: values.fat, micronutrients: values.micronutrients,
                             servingSize: "\(values.quantity.formatted()) \(values.unit)",
                             servingQuantity: values.quantity, servingUnit: values.unit)
        try write { store.addSavedFood(food) }
        return food
    }

    func createEntry(_ values: SiriStoredNutrition, meal: MealType, day: Date, requestedAt: Date? = nil) throws -> NutritionEntry {
        let values = try values.validated()
        let entry = NutritionEntry(timestamp: requestedAt ?? now(), name: values.name, mealType: meal, scanMode: .manual,
                                   calories: values.calories, protein: values.protein, carbs: values.carbs,
                                   fat: values.fat, micronutrients: values.micronutrients,
                                   servingSize: "\(values.quantity.formatted()) \(values.unit)", brand: values.brand,
                                   servingQuantity: values.quantity, servingUnit: values.unit)
        try write { store.log(entry, to: day, calendar: calendar) }
        return entry
    }

    func hasRecentMatchingEntry(_ values: SiriStoredNutrition, meal: MealType, day: Date, requestedAt: Date) throws -> Bool {
        let existing = try entries(from: day, through: day, meal: meal).entries
        let expectedTime = NutritionStore.timestamp(on: day, preservingTimeFrom: requestedAt, calendar: calendar)
        return existing.contains { entry in
            let current = SiriStoredNutrition.entry(entry)
            return abs(entry.timestamp.timeIntervalSince(expectedTime)) <= 120 &&
                current.name.localizedCaseInsensitiveCompare(values.name) == .orderedSame &&
                (current.brand ?? "").localizedCaseInsensitiveCompare(values.brand ?? "") == .orderedSame &&
                current.quantity == values.quantity && SiriFoodUnits.matches(current.unit, values.unit)
        }
    }

    func updateEntry(_ expected: SiriJournalEntrySnapshot, values: SiriStoredNutrition, meal: MealType, day: Date)
        throws -> NutritionEntry {
        let values = try values.validated()
        guard let entry = try entry(id: expected.id) else { throw SiriJournalDataError.itemUnavailable }
        guard SiriJournalEntrySnapshot(entry) == expected else { throw SiriJournalDataError.recordChanged }
        try write {
            entry.name = values.name
            entry.brand = values.brand
            entry.mealType = meal
            entry.calories = values.calories
            entry.protein = values.protein
            entry.carbs = values.carbs
            entry.fat = values.fat
            entry.micronutrients = values.micronutrients
            if expected.nutrition.quantity != values.quantity || expected.nutrition.unit != values.unit {
                entry.servingQuantity = values.quantity
                entry.servingUnit = values.unit
                entry.servingSize = "\(values.quantity.formatted()) \(values.unit)"
                entry.serving = values.scaledServing(expected.serving, from: expected.nutrition, mappings: expected.mappings)
            }
            let newDay = calendar.isDate(day, inSameDayAs: expected.day) ? nil : day
            return store.saveEntry(entry, movingTo: newDay, calendar: calendar)
        }
        return entry
    }

    func updateFood(_ expected: SiriSavedFoodSnapshot, values: SiriStoredNutrition, archived: Bool?, onShelf: Bool?)
        throws -> SavedFood {
        let values = try values.validated()
        guard let food = try food(id: expected.id) else { throw SiriJournalDataError.itemUnavailable }
        guard SiriSavedFoodSnapshot(food) == expected else { throw SiriJournalDataError.recordChanged }
        try write {
            food.name = values.name
            food.brand = values.brand
            food.calories = values.calories
            food.protein = values.protein
            food.carbs = values.carbs
            food.fat = values.fat
            food.micronutrients = values.micronutrients
            if expected.nutrition.quantity != values.quantity || expected.nutrition.unit != values.unit {
                food.servingQuantity = values.quantity
                food.servingUnit = values.unit
                food.servingSize = "\(values.quantity.formatted()) \(values.unit)"
                food.serving = values.scaledServing(expected.serving, from: expected.nutrition, mappings: expected.mappings)
            }
            if let onShelf { food.isOnShelf = onShelf }
            if let archived {
                if archived {
                    food.archiveForFoodBank(now: now())
                } else {
                    food.restoreFromFoodBankArchive(now: now())
                }
            }
            return store.saveChanges(mirrorReason: "saved_food_updated")
        }
        return food
    }

    func deleteEntry(_ expected: SiriJournalEntrySnapshot) throws {
        guard let entry = try entry(id: expected.id) else { return }
        guard SiriJournalEntrySnapshot(entry) == expected else { throw SiriJournalDataError.recordChanged }
        try write { store.delete(entry) }
    }

    func deleteFood(_ expected: SiriSavedFoodSnapshot) throws {
        guard let food = try food(id: expected.id) else { return }
        guard SiriSavedFoodSnapshot(food) == expected else { throw SiriJournalDataError.recordChanged }
        try write { store.deleteSavedFood(food) }
    }

    func saveEntryToFoodBank(_ expected: SiriJournalEntrySnapshot) throws -> SavedFood {
        guard let entry = try entry(id: expected.id) else { throw SiriJournalDataError.itemUnavailable }
        guard SiriJournalEntrySnapshot(entry) == expected else { throw SiriJournalDataError.recordChanged }
        var saved: SavedFood?
        try write {
            switch store.saveJournalEntryToFoodBank(entry) {
            case .saved(let food), .alreadySaved(let food): saved = food
            case .failed: break
            }
            return saved != nil
        }
        guard let saved else { throw SiriFoodLoggingError.saveFailed }
        return saved
    }

    private func write(_ operation: () -> Bool) throws {
        try Task.checkCancellation()
        try requireUnlock()
        guard !context.hasChanges else { throw SiriJournalDataError.unsavedChanges }
        guard operation() else {
            // This synchronous main-actor operation started with a clean
            // context. A rollback here can discard only the failed Siri write.
            context.rollback()
            throw SiriFoodLoggingError.saveFailed
        }
    }
}

struct SiriNutritionEdit {
    var name: String?
    var brand: String?
    var quantity: Double?
    var unit: String?
    var calories: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var nutrientName: String?
    var nutrientAmount: Double?
    var nutrientUnit: String?

    var hasNutritionChange: Bool {
        quantity != nil || unit != nil || calories != nil || protein != nil || carbs != nil || fat != nil ||
            nutrientName != nil || nutrientAmount != nil || nutrientUnit != nil
    }

    func apply(to original: SiriStoredNutrition, serving: ServingSize?, mappings: [ServingMapping]) throws -> SiriStoredNutrition {
        let converter = ServingConverter(calories: original.calories, protein: original.protein, carbs: original.carbs,
                                         fat: original.fat, quantity: original.quantity, unit: original.unit,
                                         serving: serving, mappings: mappings)
        var resultQuantity = original.quantity
        var resultUnit = original.unit
        if let unit {
            if let matched = converter.availableUnits.first(where: { $0 == unit }) ??
                converter.availableUnits.first(where: { SiriFoodUnits.matches($0, unit) }),
               let factor = converter.conversionFactor(for: matched), factor.isFinite, factor > 0 {
                resultQuantity = quantity ?? converter.baseQuantity * factor
                resultUnit = matched
            } else if SiriFoodUnits.normalized(unit) == "serving" {
                resultQuantity = (quantity ?? 1) * converter.baseQuantity
            } else {
                throw SiriFoodLoggingError.unsupportedUnit(requested: unit, availableUnits: converter.availableUnits)
            }
        } else if let quantity {
            resultQuantity = quantity
        }
        let changedPortion = quantity != nil || unit != nil
        var micronutrients = changedPortion
            ? converter.scaledMicronutrients(original.micronutrients, quantity: resultQuantity, unit: resultUnit)
            : original.micronutrients
        if nutrientName != nil || nutrientAmount != nil || nutrientUnit != nil {
            guard let nutrient = nutrientName?.trimmingCharacters(in: .whitespacesAndNewlines), !nutrient.isEmpty,
                  let value = nutrientAmount, value.isFinite, value >= 0 else { throw SiriJournalDataError.invalidEdit }
            let key = KnownMicronutrients.normalize(nutrient)
            let unit = nutrientUnit ?? micronutrients.first(where: { KnownMicronutrients.normalize($0.key) == key })?.value.unit
                ?? KnownMicronutrients.find(nutrient)?.unit
            guard let unit, !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SiriJournalDataError.invalidEdit
            }
            micronutrients = micronutrients.filter { KnownMicronutrients.normalize($0.key) != key }
            micronutrients[key] = MicronutrientValue(value: value, unit: unit)
        }
        let brand = self.brand.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? original.brand
        return try SiriStoredNutrition(
            name: name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? original.name,
            brand: brand?.isEmpty == true ? nil : brand,
            quantity: resultQuantity, unit: resultUnit,
            calories: calories ?? (changedPortion ? converter.scaledCalories(quantity: resultQuantity, unit: resultUnit) : original.calories),
            protein: protein ?? (changedPortion ? converter.scaledProtein(quantity: resultQuantity, unit: resultUnit) : original.protein),
            carbs: carbs ?? (changedPortion ? converter.scaledCarbs(quantity: resultQuantity, unit: resultUnit) : original.carbs),
            fat: fat ?? (changedPortion ? converter.scaledFat(quantity: resultQuantity, unit: resultUnit) : original.fat),
            micronutrients: micronutrients
        ).validated()
    }
}
