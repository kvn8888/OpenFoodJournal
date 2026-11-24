// AGPL-3.0 License

import AppIntents
import Foundation

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct LogFoodBankItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Food Bank Item"
    static let description = IntentDescription("Log a portion of a saved food after reviewing its nutrition.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Food", description: "The exact saved Food Bank item to log, including brand if needed.", requestValueDialog: "Which Food Bank item?")
    var food: SavedFoodEntity

    @Parameter(title: "Quantity", description: "How much the person had in the chosen unit.", requestValueDialog: "How much did you have?")
    var quantity: Double

    @Parameter(title: "Unit")
    var unit: String?

    @Parameter(title: "Meal")
    var meal: MealTypeAppEnum?

    @Parameter(title: "Date")
    var date: Date?

    @Dependency private var runtime: SiriAppRuntime

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$quantity) of \(\.$food)") {
            \.$unit
            \.$meal
            \.$date
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let invocationID = UUID()
        let logging = runtime.foodLogging
        let request = try logging.resolve(
            food.name, quantity: quantity, unit: unit, meal: meal?.meal, date: date, parseSpokenPhrase: false
        )
        let draft = try await foodBankDraft(logging, foodID: food.id, request: request, unitParameter: $unit)
        try await confirmJournalAddition(values: .draft(draft), meal: request.meal, day: request.date,
                                         requestedAt: request.requestedAt, data: runtime.journalData,
                                         dialog: draft.confirmation(in: logging))
        _ = try logging.commit(draft, invocationID: invocationID)
        return .result(dialog: "Logged \(draft.foodLabel) for \(request.meal.rawValue.lowercased()).")
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct LogFoodWithSiriIntent: AppIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "Log Food"
    static let description = IntentDescription("Look up food and review the nutrition before logging it.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Food", description: "The food, amount, brand, meal and date the person asked to log. Search saved foods first, then estimate if allowed.", requestValueDialog: "What did you eat? You can include the amount and meal.")
    var foodQuery: String

    @Parameter(title: "Quantity")
    var quantity: Double?

    @Parameter(title: "Unit")
    var unit: String?

    @Parameter(title: "Meal")
    var meal: MealTypeAppEnum?

    @Parameter(title: "Date")
    var date: Date?

    @Parameter(title: "Food Bank Match")
    var foodBankMatch: SavedFoodEntity?

    @Parameter(title: "Food Bank Reply", description: "Clarification of the saved brand or food name only when several items match.")
    var foodBankReply: String?

    @Dependency private var runtime: SiriAppRuntime

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$foodQuery)") {
            \.$quantity
            \.$unit
            \.$meal
            \.$date
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & OpensIntent {
        let invocationID = UUID()
        let logging = runtime.foodLogging
        let request = try logging.resolve(foodQuery, quantity: quantity, unit: unit, meal: meal?.meal, date: date)
        progress.totalUnitCount = 2
        let match = try logging.search(request.name)
        progress.completedUnitCount = 1

        let draft: SiriNutritionDraft
        switch match {
        case .exact(let food):
            draft = try await foodBankDraft(logging, foodID: food.id, request: request, unitParameter: $unit)
        case .ambiguous(let foods):
            let id = try await selectFood(in: foods, logging: logging)
            draft = try await foodBankDraft(logging, foodID: id, request: request, unitParameter: $unit)
        case .notFound:
            switch try await logging.assistantDraft(for: request) {
            case .estimate(let estimate):
                draft = estimate
            case .needsAppHandoff(let prompt, let reason):
                progress.completedUnitCount = 2
                return .result(opensIntent: OpenAssistantFoodLogIntent(prompt: prompt), dialog: "\(reason) Opening Assistant.")
            }
        }

        progress.completedUnitCount = 2
        try await confirmJournalAddition(values: .draft(draft), meal: request.meal, day: request.date,
                                         requestedAt: request.requestedAt, data: runtime.journalData,
                                         dialog: draft.confirmation(in: logging))
        _ = try logging.commit(draft, invocationID: invocationID)
        return .result(dialog: "Logged \(draft.foodLabel) for \(request.meal.rawValue.lowercased()).")
    }

    @MainActor
    private func selectFood(in foods: [SavedFood], logging: SiriFoodLoggingService) async throws -> UUID {
        let IDs = foods.map(\.id)
        let examples = foods.prefix(3).map { SavedFoodEntity(food: $0).choiceTitle }.formatted(.list(type: .or))
        let reply: String
        if let foodBankReply {
            reply = foodBankReply
        } else {
            reply = try await $foodBankReply.requestValue("Which Food Bank item? Say the brand or full name, such as \(examples).")
        }
        let current = try logging.activeFoods(ids: IDs)
        guard !current.isEmpty else { throw SiriFoodLoggingError.savedFoodUnavailable }
        let matching = SiriFoodLoggingService.matchingChoice(reply, in: current)
        if matching.count == 1 { return matching[0].id }
        let options = matching.isEmpty ? current : matching
        return try await $foodBankMatch.requestDisambiguation(
            among: options.map(SavedFoodEntity.init(food:)), dialog: "Choose the exact saved food to log."
        ).id
    }
}

#if OFJ_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
struct OpenAssistantFoodLogIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Assistant to Log Food"
    static let description = IntentDescription("Continue a food lookup in OpenFoodJournal’s Assistant.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Food Request", description: "The food and portion the person wants to research in the in-app Assistant.", requestValueDialog: "What food should Assistant help you log?")
    var prompt: String

    @Dependency private var runtime: SiriAppRuntime

    init() {}

    init(prompt: String) {
        self.prompt = prompt
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Assistant to log \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try runtime.foodLogging.requireUnlock()
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SiriFoodLoggingError.missingFood }
        runtime.navigation.openAssistant(with: trimmed)
        return .result()
    }
}

@MainActor
private func foodBankDraft(
    _ logging: SiriFoodLoggingService, foodID: UUID, request: SiriFoodLogRequest,
    unitParameter: IntentParameter<String?>
) async throws -> SiriNutritionDraft {
    do {
        return try logging.foodBankDraft(for: foodID, request: request)
    } catch SiriFoodLoggingError.unsupportedUnit(let requested, let units) {
        let chosen = try await unitParameter.requestDisambiguation(
            among: units, dialog: "This food doesn't support \(requested). Which unit should I use?"
        )
        return try logging.foodBankDraft(for: foodID, request: request, unitOverride: chosen)
    }
}

private extension SiriNutritionDraft {
    func confirmation(in logging: SiriFoodLoggingService) -> IntentDialog {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        let portion = "\(quantity.formatted()) \(unit) of \(foodLabel)"
        let macros = "\(calories.formatted(format)) calories, \(protein.formatted(format)) grams protein, \(carbs.formatted(format)) grams carbs, and \(fat.formatted(format)) grams fat"
        let day = logging.formattedDate(request.date)
        let meal = request.meal.rawValue.lowercased()
        if isAssistantEstimate {
            if let sourceSummary, !sourceSummary.isEmpty {
                return "Assistant estimates \(macros) for \(portion). Based on \(sourceSummary). Add to \(meal) on \(day)?"
            }
            return "Assistant estimates \(macros) for \(portion). Add to \(meal) on \(day)?"
        }
        return "Your Food Bank lists \(macros) for \(portion). Add to \(meal) on \(day)?"
    }
}
