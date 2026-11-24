// OpenFoodJournal — Siri food logging
// AGPL-3.0 License

import Foundation
import SwiftData

enum SiriFoodLoggingError: LocalizedError, Equatable {
    case deviceLocked
    case missingFood
    case savedFoodUnavailable
    case invalidQuantity
    case calculatorRequiresIngredients
    case unsupportedUnit(requested: String, availableUnits: [String])
    case invalidNutrition
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .deviceLocked: "Unlock your device to log food in OpenFoodJournal."
        case .missingFood: "Tell me which food to log."
        case .savedFoodUnavailable: "This food is no longer available in your Food Bank."
        case .invalidQuantity: "Enter an amount greater than zero."
        case .calculatorRequiresIngredients: "Open this nutrition calculator in the Food Bank to choose ingredients."
        case .unsupportedUnit(let requested, let units):
            "This food doesn't support \(requested). Choose from \(units.formatted(.list(type: .or)))."
        case .invalidNutrition: "I couldn't calculate nutrition for this amount."
        case .saveFailed: "OpenFoodJournal couldn't save your food. Please try again."
        }
    }
}

enum SiriFoodBankMatch {
    case exact(SavedFood)
    case ambiguous([SavedFood])
    case notFound

    var foods: [SavedFood] {
        switch self {
        case .exact(let food): [food]
        case .ambiguous(let foods): foods
        case .notFound: []
        }
    }
}

struct SiriFoodLogRequest {
    let name: String
    let quantity: Double?
    let unit: String?
    let meal: MealType
    let date: Date
    let requestedAt: Date
}

struct SiriNutritionDraft {
    let request: SiriFoodLogRequest
    let name: String
    let brand: String?
    let quantity: Double
    let unit: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    var micronutrients: [String: MicronutrientValue] = [:]
    var savedFoodID: UUID?
    var servingDescription: String?
    var scanMode: ScanMode = .manual
    var serving: ServingSize?
    var servingsPerContainer: Double?
    var servingMappings: [ServingMapping] = []
    var isAssistantEstimate = false
    var sourceSummary: String?
    var confidence: Double?

    var foodLabel: String {
        brand.map { "\(name) (\($0))" } ?? name
    }

    var hasValidNutrition: Bool {
        [calories, protein, carbs, fat].allSatisfy { $0.isFinite && $0 >= 0 } &&
            micronutrients.values.allSatisfy { $0.value.isFinite && $0.value >= 0 }
    }

    func makeEntry(id: UUID) -> NutritionEntry {
        NutritionEntry(
            id: id, timestamp: request.requestedAt, name: name, mealType: request.meal,
            scanMode: scanMode, confidence: confidence, calories: calories, protein: protein,
            carbs: carbs, fat: fat, micronutrients: micronutrients,
            servingSize: servingDescription ?? "\(quantity.formatted()) \(unit)",
            servingsPerContainer: servingsPerContainer, brand: brand, serving: serving,
            servingQuantity: quantity, servingUnit: unit, servingMappings: servingMappings,
            savedFoodID: savedFoodID
        )
    }
}

enum SiriAssistantLookupResult {
    case estimate(SiriNutritionDraft)
    case needsAppHandoff(prompt: String, reason: String)
}

@MainActor
final class SiriFoodLoggingService {
    typealias AssistantLookup = @MainActor (SiriFoodLogRequest, Double, String) async throws -> SiriAssistantNutritionLookup.Estimate

    private let modelContext: ModelContext
    private let nutritionStore: NutritionStore
    private let mealTimeSettings: MealTimeSettings
    private let now: () -> Date
    private let calendar: Calendar
    private let isProtectedDataAvailable: () -> Bool
    private let assistantLookup: AssistantLookup

    init(
        modelContext: ModelContext,
        nutritionStore: NutritionStore,
        mealTimeSettings: MealTimeSettings,
        now: @escaping () -> Date = { .now },
        calendar: Calendar = .autoupdatingCurrent,
        isProtectedDataAvailable: @escaping () -> Bool,
        assistantLookup: @escaping AssistantLookup
    ) {
        self.modelContext = modelContext
        self.nutritionStore = nutritionStore
        self.mealTimeSettings = mealTimeSettings
        self.now = now
        self.calendar = calendar
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.assistantLookup = assistantLookup
    }

    func requireUnlock() throws {
        guard isProtectedDataAvailable() else { throw SiriFoodLoggingError.deviceLocked }
    }

    func activeFoods(limit: Int? = nil) throws -> [SavedFood] {
        try requireUnlock()
        let descriptor = FetchDescriptor<SavedFood>(
            predicate: #Predicate { $0.archivedAt == nil },
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse), SortDescriptor(\.id)]
        )
        let foods = try modelContext.fetch(descriptor)
        let cutoff = SavedFood.foodBankArchiveCutoff(now: now(), calendar: calendar)
        return Array(foods.lazy.filter { $0.isOnShelf || $0.lastUsedAt >= cutoff }.prefix(limit ?? foods.count))
    }

    func activeFoods(ids: [UUID]) throws -> [SavedFood] {
        try requireUnlock()
        let descriptor = FetchDescriptor<SavedFood>(
            predicate: #Predicate { ids.contains($0.id) && $0.archivedAt == nil }
        )
        let cutoff = SavedFood.foodBankArchiveCutoff(now: now(), calendar: calendar)
        let foods = try modelContext.fetch(descriptor).filter { $0.isOnShelf || $0.lastUsedAt >= cutoff }
        return ids.compactMap { id in foods.first { $0.id == id } }
    }

    func search(_ query: String) throws -> SiriFoodBankMatch {
        let foods = try activeFoods()
        let needed = Self.tokens(query)
        guard !needed.isEmpty else { return .notFound }
        let matches = foods.compactMap { food -> (food: SavedFood, title: Set<String>)? in
            let title = Self.tokens([food.name, food.brand].compactMap { $0 }.joined(separator: " "))
            return needed.isSubset(of: title) ? (food, title) : nil
        }
        let exact = matches.filter { $0.title == needed }
        if exact.count == 1 { return .exact(exact[0].food) }
        if matches.count == 1 { return .exact(matches[0].food) }
        if matches.isEmpty { return .notFound }
        return .ambiguous(matches.map(\.food))
    }

    func resolve(
        _ query: String,
        quantity: Double? = nil,
        unit: String? = nil,
        meal: MealType? = nil,
        date: Date? = nil,
        parseSpokenPhrase: Bool = true
    ) throws -> SiriFoodLogRequest {
        try requireUnlock()
        let requestedAt = now()
        let parsed = parseSpokenPhrase ? SiriSpokenFoodQuery(query) : SiriSpokenFoodQuery(name: query)
        guard !parsed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SiriFoodLoggingError.missingFood
        }
        let quantity = quantity ?? parsed.quantity
        if let quantity { try Self.validateQuantity(quantity) }
        let day = calendar.date(byAdding: .day, value: parsed.dayOffset ?? 0, to: requestedAt) ?? requestedAt
        return SiriFoodLogRequest(
            name: parsed.name, quantity: quantity, unit: unit ?? parsed.unit,
            meal: meal ?? parsed.meal ?? mealTimeSettings.mealType(for: requestedAt, calendar: calendar),
            date: calendar.startOfDay(for: date ?? day), requestedAt: requestedAt
        )
    }

    func foodBankDraft(for id: UUID, request: SiriFoodLogRequest, unitOverride: String? = nil) throws -> SiriNutritionDraft {
        guard let food = try activeFoods(ids: [id]).first else {
            throw SiriFoodLoggingError.savedFoodUnavailable
        }
        guard food.kind != .calculator else { throw SiriFoodLoggingError.calculatorRequiresIngredients }
        let converter = ServingConverter(
            calories: food.calories, protein: food.protein, carbs: food.carbs, fat: food.fat,
            quantity: food.servingQuantity ?? 1, unit: food.servingUnit ?? "serving",
            serving: food.serving, mappings: food.servingMappings
        )
        let quantity = request.quantity ?? food.servingQuantity ?? 1
        try Self.validateQuantity(quantity)
        let requested = unitOverride ?? request.unit ?? converter.baseUnit
        let available = converter.availableUnits.filter { unit in
            guard let factor = converter.conversionFactor(for: unit) else { return false }
            return factor.isFinite && factor > 0
        }
        let matchedUnit = available.first { $0 == requested } ??
            available.first { SiriFoodUnits.matches($0, requested) }
        guard let unit = matchedUnit else {
            throw SiriFoodLoggingError.unsupportedUnit(requested: requested, availableUnits: available)
        }
        let draft = SiriNutritionDraft(
            request: request, name: food.name, brand: food.brand, quantity: quantity, unit: unit,
            calories: converter.scaledCalories(quantity: quantity, unit: unit),
            protein: converter.scaledProtein(quantity: quantity, unit: unit),
            carbs: converter.scaledCarbs(quantity: quantity, unit: unit),
            fat: converter.scaledFat(quantity: quantity, unit: unit),
            micronutrients: converter.scaledMicronutrients(food.micronutrients, quantity: quantity, unit: unit),
            savedFoodID: id, scanMode: food.originalScanMode, serving: food.serving,
            servingsPerContainer: food.servingsPerContainer, servingMappings: food.servingMappings
        )
        guard draft.hasValidNutrition else { throw SiriFoodLoggingError.invalidNutrition }
        return draft
    }

    func assistantDraft(for request: SiriFoodLogRequest) async throws -> SiriAssistantLookupResult {
        try requireUnlock()
        let quantity = request.quantity ?? 1
        let unit = SiriFoodUnits.normalized(request.unit ?? "serving")
        try Self.validateQuantity(quantity)
        do {
            let estimate = try await assistantLookup(request, quantity, unit)
            try Task.checkCancellation()
            try requireUnlock()
            let draft = SiriNutritionDraft(
                request: request, name: estimate.name, brand: estimate.brand, quantity: quantity, unit: unit,
                calories: estimate.calories, protein: estimate.protein, carbs: estimate.carbs, fat: estimate.fat,
                servingDescription: estimate.servingDescription, isAssistantEstimate: true,
                sourceSummary: estimate.sourceSummary, confidence: estimate.confidence
            )
            guard estimate.isValid, draft.hasValidNutrition else { throw SiriFoodLoggingError.invalidNutrition }
            return .estimate(draft)
        } catch {
            try Task.checkCancellation()
            try requireUnlock()
            let reason: String
            switch error {
            case ChatError.noAPIKey:
                reason = "Set up your Assistant API key in OpenFoodJournal to look up this food."
            case SiriAssistantNutritionLookup.LookupError.timedOut:
                reason = "The nutrition lookup took too long."
            default:
                reason = "I couldn't get a reliable nutrition estimate through Siri."
            }
            let day = formattedDate(request.date)
            let prompt = "Help me log \(quantity.formatted()) \(unit) of \(request.name) for \(request.meal.rawValue.lowercased()) on \(day). Show me the nutrition and ask for confirmation before saving."
            return .needsAppHandoff(prompt: prompt, reason: reason)
        }
    }

    func commit(_ draft: SiriNutritionDraft, invocationID: UUID) throws -> UUID {
        try Task.checkCancellation()
        try requireUnlock()
        // The journal entry's ID is the durable idempotency key. It is saved
        // atomically with the entry, including across process restarts.
        var descriptor = FetchDescriptor<NutritionEntry>(predicate: #Predicate { $0.id == invocationID })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first { return existing.id }
        if let foodID = draft.savedFoodID, try activeFoods(ids: [foodID]).isEmpty {
            throw SiriFoodLoggingError.savedFoodUnavailable
        }
        guard nutritionStore.log(draft.makeEntry(id: invocationID), to: draft.request.date, calendar: calendar) else {
            throw SiriFoodLoggingError.saveFailed
        }
        return invocationID
    }

    func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .long
        return formatter.string(from: date)
    }

    private static func validateQuantity(_ quantity: Double) throws {
        guard quantity.isFinite, quantity > 0 else { throw SiriFoodLoggingError.invalidQuantity }
    }

    private static func tokens(_ text: String) -> Set<String> {
        let ignored: Set<Substring> = ["from", "by", "at", "of", "the", "a", "an"]
        return Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .filter { !ignored.contains($0) }
            .map(String.init))
    }
}
