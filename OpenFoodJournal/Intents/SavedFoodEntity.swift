// AGPL-3.0 License

import AppIntents
import Foundation

nonisolated enum MealTypeAppEnum: String, AppEnum {
    case breakfast, lunch, dinner, snack

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meal"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .breakfast: "Breakfast", .lunch: "Lunch", .dinner: "Dinner", .snack: "Snack"
    ]

    @MainActor var meal: MealType {
        switch self {
        case .breakfast: .breakfast
        case .lunch: .lunch
        case .dinner: .dinner
        case .snack: .snack
        }
    }
}

struct SavedFoodEntity: AppEntity {
    let id: UUID
    @Property(title: "Food name") var name: String
    @Property(title: "Brand") var brand: String?
    let subtitle: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Food Bank Item"
    static let defaultQuery = SavedFoodEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(choiceTitle)", subtitle: "\(subtitle)", synonyms: ["\(name)"])
    }

    var choiceTitle: String {
        if let brand, !name.localizedCaseInsensitiveContains(brand) { return "\(brand) \(name)" }
        return name
    }

    @MainActor init(food: SavedFood) {
        id = food.id
        #if OFJ_SIRI_AI_PREVIEW
        subtitle = ""
        #else
        let portion = food.servingSize ??
            "\((food.servingQuantity ?? 1).formatted()) \(food.servingUnit ?? "serving")"
        let nutrition = food.kind == .calculator ? "Nutrition calculator" :
            "\(food.calories.formatted(.number.precision(.fractionLength(0...1)))) kcal per \(portion)"
        subtitle = [food.brand, nutrition].compactMap { $0 }.joined(separator: " · ")
        #endif
        name = food.name
        brand = food.brand
    }
}

struct SavedFoodEntityQuery: EntityStringQuery {
    @Dependency private var runtime: SiriAppRuntime

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SavedFoodEntity] {
        try runtime.foodLogging.activeFoods(ids: identifiers).map(SavedFoodEntity.init(food:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [SavedFoodEntity] {
        try runtime.foodLogging.search(string).foods.map(SavedFoodEntity.init(food:))
    }

    @MainActor
    func suggestedEntities() async throws -> [SavedFoodEntity] {
        try runtime.foodLogging.activeFoods(limit: 20).map(SavedFoodEntity.init(food:))
    }
}
