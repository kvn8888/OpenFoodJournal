# Data Models Reference

## DailyLog (`OpenFoodJournal/Models/DailyLog.swift`)

```swift
@Model final class DailyLog {
    @Attribute(.unique) var date: Date  // normalized to midnight
    var id: UUID
    var notes: String?
    @Relationship(deleteRule: .cascade, inverse: \NutritionEntry.dailyLog)
    var entries: [NutritionEntry]

    // Computed (not persisted)
    var totalCalories: Double
    var totalProtein: Double
    var totalCarbs: Double
    var totalFat: Double
    func entries(for mealType: MealType) -> [NutritionEntry]  // filtered & sorted by timestamp
}
```

## NutritionEntry (`OpenFoodJournal/Models/NutritionEntry.swift`)

```swift
@Model final class NutritionEntry {
    var id: UUID
    var timestamp: Date
    var name: String
    var mealType: MealType
    var scanMode: ScanMode
    var confidence: Double?

    // Core macros (always required)
    var calories, protein, carbs, fat: Double

    // Dynamic micronutrients
    var micronutrients: [String: MicronutrientValue]

    // Serving and food-bank linkage
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

    // Apple Health sync metadata
    var healthKitSyncStatus: HealthKitSyncStatus
    var healthKitSyncedAt: Date?
    var healthKitSyncVersion: Int
    var healthKitLastError: String?
    var healthKitLastWriteHash: String?

    var dailyLog: DailyLog?  // inverse
    var confidencePercent: Int?  // computed: confidence * 100
    var healthKitSampleTimestamp: Date  // computed
    var healthKitWriteHash: String  // computed
}
```

`healthKitSampleTimestamp` uses the entry timestamp when it already falls on the linked `DailyLog` day; otherwise it combines the linked journal day with the entry's time. This keeps HealthKit backfill correct for older entries whose timestamp was created on a different day. `healthKitWriteHash` includes the entry ID, effective HealthKit timestamp, macros, and micronutrients. If it differs from `healthKitLastWriteHash`, Settings backfill and edit flows treat the entry as stale for Apple Health.

## HealthKitSyncStatus (`OpenFoodJournal/Models/Enums.swift`)

```swift
enum HealthKitSyncStatus: String, Codable, CaseIterable {
    case notSynced
    case synced
    case failed
    case skipped
}
```

## SavedFood (`OpenFoodJournal/Models/SavedFood.swift`)

```swift
@Model final class SavedFood {
    var id: UUID
    var name: String
    var brand: String?
    var createdAt: Date
    var calories, protein, carbs, fat: Double
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
    var calculatorIngredients: [CalculatorIngredient]

    // Computed/helpers
    var isArchivedInFoodBank: Bool  // archivedAt != nil OR lastUsedAt older than 14 days
    func archiveForFoodBank(now: Date)
    func restoreFromFoodBankArchive(now: Date)
    func markLoggedForFoodBank(now: Date)
    static func compositeTotals(for: [CompositeIngredientSnapshot]) -> CompositeNutritionTotals
    func refreshCompositeNutrition()
    static func calculatorTotals(for: [CalculatorIngredient], selections: [CalculatorSelection]) -> CompositeNutritionTotals
    static func calculatorSelectionSummary(for: [CalculatorIngredient], selections: [CalculatorSelection]) -> String
    static func missingCalculatorSelectionCount(for: [CalculatorIngredient], selections: [CalculatorSelection]) -> Int
    func refreshCalculatorNutrition()
}
```

Food Bank archive is cosmetic only. Archived foods stay in SwiftData, remain searchable, and can still be logged.

Composite foods are also `SavedFood` rows. They store `CompositeIngredientSnapshot` values with copied ingredient nutrition, serving info, selected quantity, and selected unit. They do not store live `SavedFood` references, so editing a composite only changes future logs.

Nutrition calculators are also `SavedFood` rows (`kind == .calculator`). They store a flat `calculatorIngredients` value array, not SwiftData relationships. Logging a calculator writes a normal `NutritionEntry` with copied totals and `selectionSummary`; later calculator edits do not mutate old entries.

## CompositeIngredientSnapshot (`OpenFoodJournal/Models/SavedFood.swift`)

```swift
struct CompositeIngredientSnapshot: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var brand: String?
    var calories, protein, carbs, fat: Double
    var micronutrients: [String: MicronutrientValue]
    var servingSize: String?
    var servingsPerContainer: Double?
    var serving: ServingSize?
    var servingQuantity: Double?
    var servingUnit: String?
    var servingMappings: [ServingMapping]
    var selectedQuantity: Double
    var selectedUnit: String
}
```

## Calculator Value Types (`OpenFoodJournal/Models/SavedFood.swift`)

```swift
struct CalculatorIngredient: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var note: String?
    var portions: [CalculatorPortionOption]
}

struct CalculatorPortionOption: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var label: String
    var calories, protein, carbs, fat: Double
    var micronutrients: [String: MicronutrientValue]
}

struct CalculatorSelection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var ingredientID: UUID
    var portionID: UUID
    var quantity: Double
}
```

Portion labels are runtime user data. The app must not hard-code a fixed list such as "little/normal/extra"; users can enter whatever labels a restaurant or brand exposes, and build-time quantity multipliers handle double portions or multiple scoops.

## GeminiScanLog (`OpenFoodJournal/Models/GeminiScanLog.swift`)

```swift
@Model final class GeminiScanLog {
    static let exportWindowDays = 30

    var id: UUID
    var createdAt: Date
    var operation: GeminiScanLogOperation  // scan or aiSearch
    var status: GeminiScanLogStatus        // success or failure
    var scanMode: String?
    var primaryModel: String?
    var fallbackModel: String?
    var resolvedModel: String?
    var resolvedModelVersion: String?
    var usedFallback: Bool
    var photoCount: Int
    var durationMs: Int?
    var userPrompt: String?
    var requestPrompt: String?
    var requestPromptCharacterCount: Int
    var requestMetadataJSON: String?
    var requestImageMetadataJSON: String?
    var requestPayloadBytes: Int?
    var responseHTTPStatus: Int?
    var parseStage: String?
    var responseText: String?
    var responseTextCharacterCount: Int
    var rawResponseJSON: String?
    var modelAttemptsJSON: String?
    var inputTokenCount: Int
    var outputTokenCount: Int
    var thinkingTokenCount: Int
    var totalTokenCount: Int
    var estimatedTokenCostUSD: Double
    var pricingModel: String?
    var searchGroundingUsed: Bool
    var streamEventCount: Int
    var thoughtPartCount: Int
    var nonThoughtPartCount: Int
    var resultName: String?
    var calories, protein, carbs, fat: Double?
    var errorCode: Int?
    var errorMessage: String?
    var responseJSON: String?
    var thinkingTrace: [String]
    var appVersion: String?
    var appBuild: String?
    var osVersion: String?
}
```

Gemini logs are diagnostics for scan and AI Search calls. They are pruned/exported on a 30-day window and intentionally exclude API keys, URL keys, base64 image payloads, and raw image bytes. Image logging is limited to dimensions, JPEG quality, and byte counts.

## GeminiCostAccumulator (`OpenFoodJournal/Models/GeminiCostAccumulator.swift`)

```swift
@Model final class GeminiCostAccumulator {
    var totalEstimatedTokenCostUSD: Double
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var totalThinkingTokens: Int
    var totalRequests: Int
    var successfulRequests: Int
    var failedRequests: Int
    var groundedSearchPrompts: Int
    var lastEstimatedTokenCostUSD: Double
    var lastInputTokens: Int
    var lastOutputTokens: Int
    var lastThinkingTokens: Int
    var lastModel: String?
    var lastPricingModel: String?
    var lastRecordedAt: Date?
    var pricingSource: String
}
```

Singleton-style local accumulator for estimated Gemini token cost. It is updated by `ScanService` from Gemini `usageMetadata`, using local Standard paid-tier rates checked 2026-06-19. It intentionally does not include Google Search grounding fees because the API response does not expose the actual billable search query count.

## UserGoals (`OpenFoodJournal/Models/UserGoals.swift`)

```swift
@Observable @MainActor final class UserGoals {
    @ObservationIgnored @AppStorage("goals.calories") var dailyCalories: Double = 2000
    @ObservationIgnored @AppStorage("goals.protein") var dailyProtein: Double = 150
    @ObservationIgnored @AppStorage("goals.carbs") var dailyCarbs: Double = 200
    @ObservationIgnored @AppStorage("goals.fat") var dailyFat: Double = 65
}
```

## Enums (`OpenFoodJournal/Models/Enums.swift`)

| Enum | Cases | Protocols |
|------|-------|-----------|
| `MealType` | `.breakfast`, `.lunch`, `.dinner`, `.snack` | `String, Codable, CaseIterable, Identifiable` |
| `ScanMode` | `.label`, `.foodPhoto`, `.barcode`, `.manual` | `String, Codable, CaseIterable` |
| `SavedFoodKind` | `.single`, `.composite` | `String, Codable, CaseIterable, Sendable` |
| `GeminiScanLogOperation` | `.scan`, `.aiSearch` | `String, Codable, CaseIterable, Sendable` |
| `GeminiScanLogStatus` | `.success`, `.failure` | `String, Codable, CaseIterable, Sendable` |

`MealType.systemImage` returns SF Symbol names: sunrise, sun.max, moon.stars, leaf.
`ScanMode.isEstimate` returns `true` only for `.foodPhoto`.

## MockData (`OpenFoodJournal/Models/MockData.swift`)

- `ModelContainer.preview` — in-memory container with seeded data
- `NutritionEntry.samples` — 5 sample entries across meal types
- `NutritionEntry.preview` — first sample
- `DailyLog.preview` — single day with all samples
- `DailyLog.weekSamples` — 7 days with randomized calorie multipliers
