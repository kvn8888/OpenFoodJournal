// OpenFoodJournal — Backup DTOs
// Versioned JSON format for restore-grade backup/import.
// AGPL-3.0 License

import Foundation

struct OpenFoodJournalBackup: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var exportedAt: Date
    var appVersion: String
    var dailyLogs: [DailyLogRecord]
    var nutritionEntries: [NutritionEntryRecord]
    var savedFoods: [SavedFoodRecord]
    var trackedContainers: [TrackedContainerRecord]
    var preferences: PreferencesRecord?
    var userGoals: UserGoalsRecord
    var appSettings: AppSettingsRecord

    var importSummaryText: String {
        """
        \(nutritionEntries.count) journal entries
        \(savedFoods.count) saved foods
        \(trackedContainers.count) containers
        Exported \(exportedAt.formatted(date: .abbreviated, time: .shortened))
        """
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> OpenFoodJournalBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(OpenFoodJournalBackup.self, from: data)
        guard backup.schemaVersion <= currentSchemaVersion else {
            throw BackupImportError.unsupportedSchemaVersion(backup.schemaVersion)
        }
        return backup
    }
}

struct BackupImportSummary {
    var insertedDailyLogs = 0
    var updatedDailyLogs = 0
    var insertedEntries = 0
    var updatedEntries = 0
    var insertedSavedFoods = 0
    var updatedSavedFoods = 0
    var insertedContainers = 0
    var updatedContainers = 0

    var message: String {
        """
        Journal logs: \(insertedDailyLogs) added, \(updatedDailyLogs) updated
        Entries: \(insertedEntries) added, \(updatedEntries) updated
        Food Bank: \(insertedSavedFoods) added, \(updatedSavedFoods) updated
        Containers: \(insertedContainers) added, \(updatedContainers) updated
        """
    }
}

enum BackupImportError: LocalizedError {
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "This backup uses schema version \(version), which this app version cannot import."
        }
    }
}

struct DailyLogRecord: Codable {
    var id: UUID
    var date: Date
    var notes: String?

    init(_ log: DailyLog) {
        id = log.id
        date = log.date
        notes = log.notes
    }
}

struct NutritionEntryRecord: Codable {
    var id: UUID
    var timestamp: Date
    var dailyLogID: UUID?
    var name: String
    var mealType: MealType
    var scanMode: ScanMode
    var confidence: Double?
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var micronutrients: [String: MicronutrientValue]
    var servingSize: String?
    var servingsPerContainer: Double?
    var brand: String?
    var serving: ServingSize?
    var servingCount: Double
    var servingQuantity: Double?
    var servingUnit: String?
    var servingMappings: [ServingMapping]
    var savedFoodID: UUID?
    var scanDurationMs: Int?
    var selectionSummary: String?

    init(_ entry: NutritionEntry) {
        id = entry.id
        timestamp = entry.timestamp
        dailyLogID = entry.dailyLog?.id
        name = entry.name
        mealType = entry.mealType
        scanMode = entry.scanMode
        confidence = entry.confidence
        calories = entry.calories
        protein = entry.protein
        carbs = entry.carbs
        fat = entry.fat
        micronutrients = entry.micronutrients
        servingSize = entry.servingSize
        servingsPerContainer = entry.servingsPerContainer
        brand = entry.brand
        serving = entry.serving
        servingCount = entry.servingCount
        servingQuantity = entry.servingQuantity
        servingUnit = entry.servingUnit
        servingMappings = entry.servingMappings
        savedFoodID = entry.savedFoodID
        scanDurationMs = entry.scanDurationMs
        selectionSummary = entry.selectionSummary
    }

    func makeModel() -> NutritionEntry {
        let entry = NutritionEntry(
            id: id,
            timestamp: timestamp,
            name: name,
            mealType: mealType,
            scanMode: scanMode,
            confidence: confidence,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            micronutrients: micronutrients,
            servingSize: servingSize,
            servingsPerContainer: servingsPerContainer,
            brand: brand,
            serving: serving,
            servingCount: servingCount,
            servingQuantity: servingQuantity,
            servingUnit: servingUnit,
            servingMappings: servingMappings,
            savedFoodID: savedFoodID
        )
        entry.scanDurationMs = scanDurationMs
        entry.selectionSummary = selectionSummary
        return entry
    }

    func apply(to entry: NutritionEntry) {
        entry.timestamp = timestamp
        entry.name = name
        entry.mealType = mealType
        entry.scanMode = scanMode
        entry.confidence = confidence
        entry.calories = calories
        entry.protein = protein
        entry.carbs = carbs
        entry.fat = fat
        entry.micronutrients = micronutrients
        entry.servingSize = servingSize
        entry.servingsPerContainer = servingsPerContainer
        entry.brand = brand
        entry.serving = serving
        entry.servingCount = servingCount
        entry.servingQuantity = servingQuantity
        entry.servingUnit = servingUnit
        entry.servingMappings = servingMappings
        entry.savedFoodID = savedFoodID
        entry.scanDurationMs = scanDurationMs
        entry.selectionSummary = selectionSummary
    }
}

struct SavedFoodRecord: Codable {
    var id: UUID
    var name: String
    var brand: String?
    var createdAt: Date
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var micronutrients: [String: MicronutrientValue]
    var servingSize: String?
    var servingsPerContainer: Double?
    var serving: ServingSize?
    var servingQuantity: Double?
    var servingUnit: String?
    var servingMappings: [ServingMapping]
    var originalScanMode: ScanMode
    var lastUsedAt: Date
    var archivedAt: Date?
    var kind: SavedFoodKind
    var compositeIngredients: [CompositeIngredientSnapshot]
    var calculatorGroups: [CalculatorGroup]
    var calculatorPresets: [CalculatorPreset]

    init(_ food: SavedFood) {
        id = food.id
        name = food.name
        brand = food.brand
        createdAt = food.createdAt
        calories = food.calories
        protein = food.protein
        carbs = food.carbs
        fat = food.fat
        micronutrients = food.micronutrients
        servingSize = food.servingSize
        servingsPerContainer = food.servingsPerContainer
        serving = food.serving
        servingQuantity = food.servingQuantity
        servingUnit = food.servingUnit
        servingMappings = food.servingMappings
        originalScanMode = food.originalScanMode
        lastUsedAt = food.lastUsedAt
        archivedAt = food.archivedAt
        kind = food.kind
        compositeIngredients = food.compositeIngredients
        calculatorGroups = food.calculatorGroups
        calculatorPresets = food.calculatorPresets
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case brand
        case createdAt
        case calories
        case protein
        case carbs
        case fat
        case micronutrients
        case servingSize
        case servingsPerContainer
        case serving
        case servingQuantity
        case servingUnit
        case servingMappings
        case originalScanMode
        case lastUsedAt
        case archivedAt
        case kind
        case compositeIngredients
        case calculatorGroups
        case calculatorPresets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        brand = try container.decodeIfPresent(String.self, forKey: .brand)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        calories = try container.decode(Double.self, forKey: .calories)
        protein = try container.decode(Double.self, forKey: .protein)
        carbs = try container.decode(Double.self, forKey: .carbs)
        fat = try container.decode(Double.self, forKey: .fat)
        micronutrients = try container.decode([String: MicronutrientValue].self, forKey: .micronutrients)
        servingSize = try container.decodeIfPresent(String.self, forKey: .servingSize)
        servingsPerContainer = try container.decodeIfPresent(Double.self, forKey: .servingsPerContainer)
        serving = try container.decodeIfPresent(ServingSize.self, forKey: .serving)
        servingQuantity = try container.decodeIfPresent(Double.self, forKey: .servingQuantity)
        servingUnit = try container.decodeIfPresent(String.self, forKey: .servingUnit)
        servingMappings = try container.decode([ServingMapping].self, forKey: .servingMappings)
        originalScanMode = try container.decode(ScanMode.self, forKey: .originalScanMode)
        lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        kind = try container.decodeIfPresent(SavedFoodKind.self, forKey: .kind) ?? .single
        compositeIngredients = try container.decodeIfPresent(
            [CompositeIngredientSnapshot].self,
            forKey: .compositeIngredients
        ) ?? []
        calculatorGroups = try container.decodeIfPresent(
            [CalculatorGroup].self,
            forKey: .calculatorGroups
        ) ?? []
        calculatorPresets = try container.decodeIfPresent(
            [CalculatorPreset].self,
            forKey: .calculatorPresets
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(brand, forKey: .brand)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(calories, forKey: .calories)
        try container.encode(protein, forKey: .protein)
        try container.encode(carbs, forKey: .carbs)
        try container.encode(fat, forKey: .fat)
        try container.encode(micronutrients, forKey: .micronutrients)
        try container.encodeIfPresent(servingSize, forKey: .servingSize)
        try container.encodeIfPresent(servingsPerContainer, forKey: .servingsPerContainer)
        try container.encodeIfPresent(serving, forKey: .serving)
        try container.encodeIfPresent(servingQuantity, forKey: .servingQuantity)
        try container.encodeIfPresent(servingUnit, forKey: .servingUnit)
        try container.encode(servingMappings, forKey: .servingMappings)
        try container.encode(originalScanMode, forKey: .originalScanMode)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try container.encode(kind, forKey: .kind)
        try container.encode(compositeIngredients, forKey: .compositeIngredients)
        try container.encode(calculatorGroups, forKey: .calculatorGroups)
        try container.encode(calculatorPresets, forKey: .calculatorPresets)
    }

    func makeModel() -> SavedFood {
        let food = SavedFood(
            id: id,
            name: name,
            brand: brand,
            createdAt: createdAt,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            micronutrients: micronutrients,
            servingSize: servingSize,
            servingsPerContainer: servingsPerContainer,
            serving: serving,
            servingQuantity: servingQuantity,
            servingUnit: servingUnit,
            servingMappings: servingMappings,
            originalScanMode: originalScanMode,
            archivedAt: archivedAt,
            kind: kind,
            compositeIngredients: compositeIngredients,
            calculatorGroups: calculatorGroups,
            calculatorPresets: calculatorPresets
        )
        food.lastUsedAt = lastUsedAt
        food.refreshCompositeNutrition()
        food.refreshCalculatorNutrition()
        return food
    }

    func apply(to food: SavedFood) {
        food.name = name
        food.brand = brand
        food.createdAt = createdAt
        food.calories = calories
        food.protein = protein
        food.carbs = carbs
        food.fat = fat
        food.micronutrients = micronutrients
        food.servingSize = servingSize
        food.servingsPerContainer = servingsPerContainer
        food.serving = serving
        food.servingQuantity = servingQuantity
        food.servingUnit = servingUnit
        food.servingMappings = servingMappings
        food.originalScanMode = originalScanMode
        food.lastUsedAt = lastUsedAt
        food.archivedAt = archivedAt
        food.kind = kind
        food.compositeIngredients = compositeIngredients
        food.calculatorGroups = calculatorGroups
        food.calculatorPresets = calculatorPresets
        food.refreshCompositeNutrition()
        food.refreshCalculatorNutrition()
    }
}

struct TrackedContainerRecord: Codable {
    var id: UUID
    var foodName: String
    var foodBrand: String?
    var caloriesPerServing: Double
    var proteinPerServing: Double
    var carbsPerServing: Double
    var fatPerServing: Double
    var micronutrientsPerServing: [String: MicronutrientValue]
    var gramsPerServing: Double
    var startWeight: Double
    var finalWeight: Double?
    var startDate: Date
    var completedDate: Date?
    var savedFoodID: UUID?

    init(_ container: TrackedContainer) {
        id = container.id
        foodName = container.foodName
        foodBrand = container.foodBrand
        caloriesPerServing = container.caloriesPerServing
        proteinPerServing = container.proteinPerServing
        carbsPerServing = container.carbsPerServing
        fatPerServing = container.fatPerServing
        micronutrientsPerServing = container.micronutrientsPerServing
        gramsPerServing = container.gramsPerServing
        startWeight = container.startWeight
        finalWeight = container.finalWeight
        startDate = container.startDate
        completedDate = container.completedDate
        savedFoodID = container.savedFoodID
    }

    func makeModel() -> TrackedContainer {
        let container = TrackedContainer(
            id: id,
            foodName: foodName,
            foodBrand: foodBrand,
            caloriesPerServing: caloriesPerServing,
            proteinPerServing: proteinPerServing,
            carbsPerServing: carbsPerServing,
            fatPerServing: fatPerServing,
            micronutrientsPerServing: micronutrientsPerServing,
            gramsPerServing: gramsPerServing,
            startWeight: startWeight,
            startDate: startDate,
            savedFoodID: savedFoodID
        )
        container.finalWeight = finalWeight
        container.completedDate = completedDate
        return container
    }

    func apply(to container: TrackedContainer) {
        container.foodName = foodName
        container.foodBrand = foodBrand
        container.caloriesPerServing = caloriesPerServing
        container.proteinPerServing = proteinPerServing
        container.carbsPerServing = carbsPerServing
        container.fatPerServing = fatPerServing
        container.micronutrientsPerServing = micronutrientsPerServing
        container.gramsPerServing = gramsPerServing
        container.startWeight = startWeight
        container.finalWeight = finalWeight
        container.startDate = startDate
        container.completedDate = completedDate
        container.savedFoodID = savedFoodID
    }
}

struct PreferencesRecord: Codable {
    var ringSlot1: String
    var ringSlot2: String
    var ringSlot3: String
    var ringSlot4: String
    var ringSlot5: String
    var createdAt: Date
    var updatedAt: Date

    init(_ preferences: Preferences) {
        ringSlot1 = preferences.ringSlot1
        ringSlot2 = preferences.ringSlot2
        ringSlot3 = preferences.ringSlot3
        ringSlot4 = preferences.ringSlot4
        ringSlot5 = preferences.ringSlot5
        createdAt = preferences.createdAt
        updatedAt = preferences.updatedAt
    }

    func apply(to preferences: Preferences) {
        preferences.ringSlot1 = ringSlot1
        preferences.ringSlot2 = ringSlot2
        preferences.ringSlot3 = ringSlot3
        preferences.ringSlot4 = ringSlot4
        preferences.ringSlot5 = ringSlot5
        preferences.createdAt = createdAt
        preferences.updatedAt = updatedAt
    }
}

struct UserGoalsRecord: Codable {
    var dailyCalories: Double
    var dailyProtein: Double
    var dailyCarbs: Double
    var dailyFat: Double

    init(goals: UserGoals) {
        dailyCalories = goals.dailyCalories
        dailyProtein = goals.dailyProtein
        dailyCarbs = goals.dailyCarbs
        dailyFat = goals.dailyFat
    }

    func apply(to goals: UserGoals) {
        goals.dailyCalories = dailyCalories
        goals.dailyProtein = dailyProtein
        goals.dailyCarbs = dailyCarbs
        goals.dailyFat = dailyFat
    }
}

struct AppSettingsRecord: Codable {
    var useProModel: Bool
    var offContributeEnabled: Bool
}
