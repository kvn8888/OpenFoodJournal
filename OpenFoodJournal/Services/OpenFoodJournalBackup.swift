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
    var emoji: String?
    var generatedIconImageData: Data?
    var generatedIconImageMimeType: String?
    var generatedIconImageUpdatedAt: Date?
    var generatedIconImagePrompt: String?
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
    var isOnShelf: Bool
    var kind: SavedFoodKind
    var compositeIngredients: [CompositeIngredientSnapshot]
    var calculatorIngredients: [CalculatorIngredient]

    init(_ food: SavedFood) {
        id = food.id
        name = food.name
        brand = food.brand
        emoji = food.emoji
        generatedIconImageData = food.generatedIconImageData
        generatedIconImageMimeType = food.generatedIconImageMimeType
        generatedIconImageUpdatedAt = food.generatedIconImageUpdatedAt
        generatedIconImagePrompt = food.generatedIconImagePrompt
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
        isOnShelf = food.isOnShelf
        kind = food.kind
        compositeIngredients = food.compositeIngredients
        calculatorIngredients = food.calculatorIngredients
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case brand
        case emoji
        case generatedIconImageData
        case generatedIconImageMimeType
        case generatedIconImageUpdatedAt
        case generatedIconImagePrompt
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
        case isOnShelf
        case kind
        case compositeIngredients
        case calculatorIngredients
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        brand = try container.decodeIfPresent(String.self, forKey: .brand)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
        generatedIconImageData = try container.decodeIfPresent(Data.self, forKey: .generatedIconImageData)
        generatedIconImageMimeType = try container.decodeIfPresent(String.self, forKey: .generatedIconImageMimeType)
        generatedIconImageUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedIconImageUpdatedAt)
        generatedIconImagePrompt = try container.decodeIfPresent(String.self, forKey: .generatedIconImagePrompt)
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
        if let decodedMode = try? container.decode(ScanMode.self, forKey: .originalScanMode) {
            originalScanMode = decodedMode
        } else if let legacyMode = try? container.decode(String.self, forKey: .originalScanMode) {
            let normalized = legacyMode.lowercased().filter(\.isLetter)
            originalScanMode = switch normalized {
            case "label", "labelscan": .label
            case "foodphoto": .foodPhoto
            case "barcode": .barcode
            case "manual": .manual
            default: .manual
            }
        } else {
            originalScanMode = .manual
        }
        lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        isOnShelf = try container.decodeIfPresent(Bool.self, forKey: .isOnShelf) ?? false
        kind = try container.decodeIfPresent(SavedFoodKind.self, forKey: .kind) ?? .single
        compositeIngredients = try container.decodeIfPresent(
            [CompositeIngredientSnapshot].self,
            forKey: .compositeIngredients
        ) ?? []
        calculatorIngredients = try container.decodeIfPresent(
            [CalculatorIngredient].self,
            forKey: .calculatorIngredients
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(brand, forKey: .brand)
        try container.encodeIfPresent(emoji, forKey: .emoji)
        try container.encodeIfPresent(generatedIconImageData, forKey: .generatedIconImageData)
        try container.encodeIfPresent(generatedIconImageMimeType, forKey: .generatedIconImageMimeType)
        try container.encodeIfPresent(generatedIconImageUpdatedAt, forKey: .generatedIconImageUpdatedAt)
        try container.encodeIfPresent(generatedIconImagePrompt, forKey: .generatedIconImagePrompt)
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
        try container.encode(isOnShelf, forKey: .isOnShelf)
        try container.encode(kind, forKey: .kind)
        try container.encode(compositeIngredients, forKey: .compositeIngredients)
        try container.encode(calculatorIngredients, forKey: .calculatorIngredients)
    }

    func makeModel() -> SavedFood {
        let food = SavedFood(
            id: id,
            name: name,
            brand: brand,
            emoji: emoji,
            generatedIconImageData: generatedIconImageData,
            generatedIconImageMimeType: generatedIconImageMimeType,
            generatedIconImageUpdatedAt: generatedIconImageUpdatedAt,
            generatedIconImagePrompt: generatedIconImagePrompt,
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
            isOnShelf: isOnShelf,
            kind: kind,
            compositeIngredients: compositeIngredients,
            calculatorIngredients: calculatorIngredients
        )
        food.lastUsedAt = lastUsedAt
        food.refreshCompositeNutrition()
        food.refreshCalculatorNutrition()
        return food
    }

    func apply(to food: SavedFood) {
        food.name = name
        food.brand = brand
        food.emoji = emoji
        food.generatedIconImageData = generatedIconImageData
        food.generatedIconImageMimeType = generatedIconImageMimeType
        food.generatedIconImageUpdatedAt = generatedIconImageUpdatedAt
        food.generatedIconImagePrompt = generatedIconImagePrompt
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
        food.isOnShelf = isOnShelf
        food.kind = kind
        food.compositeIngredients = compositeIngredients
        food.calculatorIngredients = calculatorIngredients
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
    var tareWeight: Double?
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
        tareWeight = container.tareWeight
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
            tareWeight: tareWeight,
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
        container.tareWeight = tareWeight
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
    var shelfRecommendationsEnabled: Bool?
    var shelfSuggestionCount: Int?
    var shelfRecommendationStyleRawValue: String?
    var shelfTriggerFraction: Double?
    var shelfCalorieFlexibilityRawValue: String?
    var shelfIncompleteNutritionPolicyRawValue: String?
    var shelfEnergyIntentRawValue: String?
    var shelfNutritionEmphasisRawValue: String?
    var shelfUseRollingWeekContext: Bool?
    var shelfHardCapCalories: Bool?
    var shelfHardCapSodium: Bool?
    var shelfCustomCaloriesPolicyRawValue: String?
    var shelfCustomProteinPolicyRawValue: String?
    var shelfCustomFiberPolicyRawValue: String?
    var shelfCustomCarbsPolicyRawValue: String?
    var shelfCustomFatPolicyRawValue: String?
    var shelfCustomSodiumPolicyRawValue: String?
    var shelfCustomCaloriesStrengthRawValue: String?
    var shelfCustomProteinStrengthRawValue: String?
    var shelfCustomFiberStrengthRawValue: String?
    var shelfCustomCarbsStrengthRawValue: String?
    var shelfCustomFatStrengthRawValue: String?
    var shelfCustomSodiumStrengthRawValue: String?
    var shelfCustomCaloriesRoleRawValue: String?
    var shelfCustomProteinRoleRawValue: String?
    var shelfCustomFiberRoleRawValue: String?
    var shelfCustomCarbsRoleRawValue: String?
    var shelfCustomFatRoleRawValue: String?
    var shelfCustomSodiumRoleRawValue: String?
    var createdAt: Date
    var updatedAt: Date

    init(_ preferences: Preferences) {
        ringSlot1 = preferences.ringSlot1
        ringSlot2 = preferences.ringSlot2
        ringSlot3 = preferences.ringSlot3
        ringSlot4 = preferences.ringSlot4
        ringSlot5 = preferences.ringSlot5
        shelfRecommendationsEnabled = preferences.shelfRecommendationsEnabled
        shelfSuggestionCount = preferences.clampedShelfSuggestionCount
        shelfRecommendationStyleRawValue = preferences.shelfRecommendationStyleRawValue
        shelfTriggerFraction = preferences.shelfTriggerFraction
        shelfCalorieFlexibilityRawValue = preferences.shelfCalorieFlexibilityRawValue
        shelfIncompleteNutritionPolicyRawValue = preferences.shelfIncompleteNutritionPolicyRawValue
        shelfEnergyIntentRawValue = preferences.shelfEnergyIntentRawValue
        shelfNutritionEmphasisRawValue = preferences.shelfNutritionEmphasisRawValue
        shelfUseRollingWeekContext = preferences.shelfUseRollingWeekContext
        shelfHardCapCalories = preferences.shelfHardCapCalories
        shelfHardCapSodium = preferences.shelfHardCapSodium
        shelfCustomCaloriesPolicyRawValue = preferences.shelfCustomCaloriesPolicyRawValue
        shelfCustomProteinPolicyRawValue = preferences.shelfCustomProteinPolicyRawValue
        shelfCustomFiberPolicyRawValue = preferences.shelfCustomFiberPolicyRawValue
        shelfCustomCarbsPolicyRawValue = preferences.shelfCustomCarbsPolicyRawValue
        shelfCustomFatPolicyRawValue = preferences.shelfCustomFatPolicyRawValue
        shelfCustomSodiumPolicyRawValue = preferences.shelfCustomSodiumPolicyRawValue
        shelfCustomCaloriesStrengthRawValue = preferences.shelfCustomCaloriesStrengthRawValue
        shelfCustomProteinStrengthRawValue = preferences.shelfCustomProteinStrengthRawValue
        shelfCustomFiberStrengthRawValue = preferences.shelfCustomFiberStrengthRawValue
        shelfCustomCarbsStrengthRawValue = preferences.shelfCustomCarbsStrengthRawValue
        shelfCustomFatStrengthRawValue = preferences.shelfCustomFatStrengthRawValue
        shelfCustomSodiumStrengthRawValue = preferences.shelfCustomSodiumStrengthRawValue
        shelfCustomCaloriesRoleRawValue = preferences.shelfCustomCaloriesRoleRawValue
        shelfCustomProteinRoleRawValue = preferences.shelfCustomProteinRoleRawValue
        shelfCustomFiberRoleRawValue = preferences.shelfCustomFiberRoleRawValue
        shelfCustomCarbsRoleRawValue = preferences.shelfCustomCarbsRoleRawValue
        shelfCustomFatRoleRawValue = preferences.shelfCustomFatRoleRawValue
        shelfCustomSodiumRoleRawValue = preferences.shelfCustomSodiumRoleRawValue
        createdAt = preferences.createdAt
        updatedAt = preferences.updatedAt
    }

    func apply(to preferences: Preferences) {
        preferences.ringSlot1 = ringSlot1
        preferences.ringSlot2 = ringSlot2
        preferences.ringSlot3 = ringSlot3
        preferences.ringSlot4 = ringSlot4
        preferences.ringSlot5 = ringSlot5
        if let shelfRecommendationsEnabled { preferences.shelfRecommendationsEnabled = shelfRecommendationsEnabled }
        if let shelfSuggestionCount { preferences.shelfSuggestionCount = min(max(shelfSuggestionCount, 1), 5) }
        if let shelfRecommendationStyleRawValue { preferences.shelfRecommendationStyleRawValue = shelfRecommendationStyleRawValue }
        if let shelfTriggerFraction { preferences.shelfTriggerFraction = min(max(shelfTriggerFraction, 0), 1) }
        if let shelfCalorieFlexibilityRawValue { preferences.shelfCalorieFlexibilityRawValue = shelfCalorieFlexibilityRawValue }
        if let shelfIncompleteNutritionPolicyRawValue { preferences.shelfIncompleteNutritionPolicyRawValue = shelfIncompleteNutritionPolicyRawValue }
        if let shelfEnergyIntentRawValue { preferences.shelfEnergyIntentRawValue = shelfEnergyIntentRawValue }
        if let shelfNutritionEmphasisRawValue { preferences.shelfNutritionEmphasisRawValue = shelfNutritionEmphasisRawValue }
        if let shelfUseRollingWeekContext { preferences.shelfUseRollingWeekContext = shelfUseRollingWeekContext }
        if let shelfHardCapCalories { preferences.shelfHardCapCalories = shelfHardCapCalories }
        if let shelfHardCapSodium { preferences.shelfHardCapSodium = shelfHardCapSodium }
        if let shelfCustomCaloriesPolicyRawValue { preferences.shelfCustomCaloriesPolicyRawValue = shelfCustomCaloriesPolicyRawValue }
        if let shelfCustomProteinPolicyRawValue { preferences.shelfCustomProteinPolicyRawValue = shelfCustomProteinPolicyRawValue }
        if let shelfCustomFiberPolicyRawValue { preferences.shelfCustomFiberPolicyRawValue = shelfCustomFiberPolicyRawValue }
        if let shelfCustomCarbsPolicyRawValue { preferences.shelfCustomCarbsPolicyRawValue = shelfCustomCarbsPolicyRawValue }
        if let shelfCustomFatPolicyRawValue { preferences.shelfCustomFatPolicyRawValue = shelfCustomFatPolicyRawValue }
        if let shelfCustomSodiumPolicyRawValue { preferences.shelfCustomSodiumPolicyRawValue = shelfCustomSodiumPolicyRawValue }
        if let shelfCustomCaloriesStrengthRawValue { preferences.shelfCustomCaloriesStrengthRawValue = shelfCustomCaloriesStrengthRawValue }
        if let shelfCustomProteinStrengthRawValue { preferences.shelfCustomProteinStrengthRawValue = shelfCustomProteinStrengthRawValue }
        if let shelfCustomFiberStrengthRawValue { preferences.shelfCustomFiberStrengthRawValue = shelfCustomFiberStrengthRawValue }
        if let shelfCustomCarbsStrengthRawValue { preferences.shelfCustomCarbsStrengthRawValue = shelfCustomCarbsStrengthRawValue }
        if let shelfCustomFatStrengthRawValue { preferences.shelfCustomFatStrengthRawValue = shelfCustomFatStrengthRawValue }
        if let shelfCustomSodiumStrengthRawValue { preferences.shelfCustomSodiumStrengthRawValue = shelfCustomSodiumStrengthRawValue }
        if let shelfCustomCaloriesRoleRawValue { preferences.shelfCustomCaloriesRoleRawValue = shelfCustomCaloriesRoleRawValue }
        if let shelfCustomProteinRoleRawValue { preferences.shelfCustomProteinRoleRawValue = shelfCustomProteinRoleRawValue }
        if let shelfCustomFiberRoleRawValue { preferences.shelfCustomFiberRoleRawValue = shelfCustomFiberRoleRawValue }
        if let shelfCustomCarbsRoleRawValue { preferences.shelfCustomCarbsRoleRawValue = shelfCustomCarbsRoleRawValue }
        if let shelfCustomFatRoleRawValue { preferences.shelfCustomFatRoleRawValue = shelfCustomFatRoleRawValue }
        if let shelfCustomSodiumRoleRawValue { preferences.shelfCustomSodiumRoleRawValue = shelfCustomSodiumRoleRawValue }
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
    var accentTheme: String
    var aiProvider: String
    var assistantProvider: String
    var assistantResearchProvider: String
    var tavilySearchDepth: String
    var parallelSearchMode: String
    var useProModel: Bool
    var openRouterLiteModel: String
    var openRouterProModel: String
    var openRouterEmojiModel: String
    var openRouterRoutingMode: String
    var azureEndpoint: String
    var azureSolDeployment: String
    var azureTerraDeployment: String
    var azureDefaultModel: String
    var chatContextBudget: String
    var useGeneratedFoodIconImages: Bool
    var offContributeEnabled: Bool
    var breakfastStartMinutes: Int
    var lunchStartMinutes: Int
    var dinnerStartMinutes: Int

    init(
        accentTheme: String = OFJAccentTheme.defaultTheme.rawValue,
        aiProvider: String = AIProviderSettings.defaultProvider.rawValue,
        assistantProvider: String? = nil,
        assistantResearchProvider: String = AssistantResearchProvider.modelProvider.rawValue,
        tavilySearchDepth: String = TavilySearchDepth.fast.rawValue,
        parallelSearchMode: String = ParallelSearchMode.basic.rawValue,
        useProModel: Bool,
        openRouterLiteModel: String = AIProviderSettings.defaultOpenRouterLiteModel,
        openRouterProModel: String = AIProviderSettings.defaultOpenRouterProModel,
        openRouterEmojiModel: String = AIProviderSettings.defaultOpenRouterEmojiModel,
        openRouterRoutingMode: String = OpenRouterRoutingMode.automatic.rawValue,
        azureEndpoint: String = "",
        azureSolDeployment: String = "",
        azureTerraDeployment: String = "",
        azureDefaultModel: String = AIProviderSettings.defaultAzureModel.rawValue,
        chatContextBudget: String = ChatContextBudget.balanced.rawValue,
        useGeneratedFoodIconImages: Bool = false,
        offContributeEnabled: Bool,
        breakfastStartMinutes: Int = MealScheduleDefaults.breakfastStartMinutes,
        lunchStartMinutes: Int = MealScheduleDefaults.lunchStartMinutes,
        dinnerStartMinutes: Int = MealScheduleDefaults.dinnerStartMinutes
    ) {
        self.accentTheme = OFJAccentTheme.resolved(from: accentTheme).rawValue
        self.aiProvider = aiProvider
        self.assistantProvider = assistantProvider ?? aiProvider
        self.assistantResearchProvider = assistantResearchProvider
        self.tavilySearchDepth = tavilySearchDepth
        self.parallelSearchMode = parallelSearchMode
        self.useProModel = useProModel
        self.openRouterLiteModel = openRouterLiteModel
        self.openRouterProModel = openRouterProModel
        self.openRouterEmojiModel = openRouterEmojiModel
        self.openRouterRoutingMode = openRouterRoutingMode
        self.azureEndpoint = azureEndpoint
        self.azureSolDeployment = azureSolDeployment
        self.azureTerraDeployment = azureTerraDeployment
        self.azureDefaultModel = azureDefaultModel
        self.chatContextBudget = chatContextBudget
        self.useGeneratedFoodIconImages = useGeneratedFoodIconImages
        self.offContributeEnabled = offContributeEnabled
        self.breakfastStartMinutes = breakfastStartMinutes
        self.lunchStartMinutes = lunchStartMinutes
        self.dinnerStartMinutes = dinnerStartMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case accentTheme
        case aiProvider
        case assistantProvider
        case assistantResearchProvider
        case tavilySearchDepth
        case parallelSearchMode
        case useProModel
        case openRouterLiteModel
        case openRouterProModel
        case openRouterEmojiModel
        case openRouterRoutingMode
        case azureEndpoint
        case azureSolDeployment
        case azureTerraDeployment
        case azureDefaultModel
        case chatContextBudget
        case useGeneratedFoodIconImages
        case offContributeEnabled
        case breakfastStartMinutes
        case lunchStartMinutes
        case dinnerStartMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accentTheme = OFJAccentTheme.resolved(
            from: try container.decodeIfPresent(String.self, forKey: .accentTheme)
                ?? OFJAccentTheme.defaultTheme.rawValue
        ).rawValue
        aiProvider = try container.decodeIfPresent(String.self, forKey: .aiProvider) ?? AIProviderSettings.defaultProvider.rawValue
        assistantProvider = try container.decodeIfPresent(String.self, forKey: .assistantProvider) ?? aiProvider
        assistantResearchProvider = try container.decodeIfPresent(String.self, forKey: .assistantResearchProvider) ?? AssistantResearchProvider.modelProvider.rawValue
        tavilySearchDepth = try container.decodeIfPresent(String.self, forKey: .tavilySearchDepth) ?? TavilySearchDepth.fast.rawValue
        parallelSearchMode = try container.decodeIfPresent(String.self, forKey: .parallelSearchMode) ?? ParallelSearchMode.basic.rawValue
        useProModel = try container.decodeIfPresent(Bool.self, forKey: .useProModel) ?? false
        openRouterLiteModel = try container.decodeIfPresent(String.self, forKey: .openRouterLiteModel) ?? AIProviderSettings.defaultOpenRouterLiteModel
        openRouterProModel = try container.decodeIfPresent(String.self, forKey: .openRouterProModel) ?? AIProviderSettings.defaultOpenRouterProModel
        openRouterEmojiModel = try container.decodeIfPresent(String.self, forKey: .openRouterEmojiModel) ?? AIProviderSettings.defaultOpenRouterEmojiModel
        openRouterRoutingMode = try container.decodeIfPresent(String.self, forKey: .openRouterRoutingMode) ?? OpenRouterRoutingMode.automatic.rawValue
        azureEndpoint = try container.decodeIfPresent(String.self, forKey: .azureEndpoint) ?? ""
        azureSolDeployment = try container.decodeIfPresent(String.self, forKey: .azureSolDeployment) ?? ""
        azureTerraDeployment = try container.decodeIfPresent(String.self, forKey: .azureTerraDeployment) ?? ""
        azureDefaultModel = try container.decodeIfPresent(String.self, forKey: .azureDefaultModel) ?? AIProviderSettings.defaultAzureModel.rawValue
        chatContextBudget = try container.decodeIfPresent(String.self, forKey: .chatContextBudget) ?? ChatContextBudget.balanced.rawValue
        useGeneratedFoodIconImages = try container.decodeIfPresent(Bool.self, forKey: .useGeneratedFoodIconImages) ?? false
        offContributeEnabled = try container.decodeIfPresent(Bool.self, forKey: .offContributeEnabled) ?? false
        breakfastStartMinutes = try container.decodeIfPresent(Int.self, forKey: .breakfastStartMinutes) ?? MealScheduleDefaults.breakfastStartMinutes
        lunchStartMinutes = try container.decodeIfPresent(Int.self, forKey: .lunchStartMinutes) ?? MealScheduleDefaults.lunchStartMinutes
        dinnerStartMinutes = try container.decodeIfPresent(Int.self, forKey: .dinnerStartMinutes) ?? MealScheduleDefaults.dinnerStartMinutes
    }
}
