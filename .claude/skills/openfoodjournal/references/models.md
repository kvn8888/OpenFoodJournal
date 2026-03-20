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
    @Attribute(.externalStorage) var sourceImage: Data?
    
    // Core macros (always required)
    var calories, protein, carbs, fat: Double
    
    // Extended macros (optional, mainly from label scans)
    var fiber, sugar, sodium, cholesterol, saturatedFat, transFat: Double?
    var servingSize: String?
    var servingsPerContainer: Double?
    
    var dailyLog: DailyLog?  // inverse
    var confidencePercent: Int?  // computed: confidence * 100
}
```

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
| `ScanMode` | `.label`, `.foodPhoto`, `.manual` | `String, Codable, CaseIterable` |

`MealType.systemImage` returns SF Symbol names: sunrise, sun.max, moon.stars, leaf.
`ScanMode.isEstimate` returns `true` only for `.foodPhoto`.

## MockData (`OpenFoodJournal/Models/MockData.swift`)

- `ModelContainer.preview` — in-memory container with seeded data
- `NutritionEntry.samples` — 5 sample entries across meal types
- `NutritionEntry.preview` — first sample
- `DailyLog.preview` — single day with all samples
- `DailyLog.weekSamples` — 7 days with randomized calorie multipliers
