# Services Reference

## NutritionStore (`OpenFoodJournal/Services/NutritionStore.swift`)

`@Observable @MainActor` — SwiftData persistence layer.

**Init**: Takes `ModelContext` from the app's `ModelContainer`.

| Method | Signature | Notes |
|--------|-----------|-------|
| `log` | `func log(_ entry: NutritionEntry, to date: Date)` | Inserts entry, appends to DailyLog (creates if needed) |
| `fetchLog` | `func fetchLog(for date: Date) -> DailyLog?` | Matches by startOfDay |
| `fetchLogs` | `func fetchLogs(from: Date, to: Date) -> [DailyLog]` | Sorted reverse chronological |
| `fetchAllLogs` | `func fetchAllLogs() -> [DailyLog]` | All logs |
| `delete` | `func delete(_ entry: NutritionEntry)` | Removes from context |
| `delete` | `func delete(_ log: DailyLog)` | Cascade deletes entries |
| `exportCSV` | `func exportCSV() -> String` | Columns: Date,Meal,Name,ScanMode,Confidence,Cal,P,C,F,Fiber,Sugar,Sodium |
| `saveChanges` | `func saveChanges()` | Public save for edit flows |

## ScanService (`OpenFoodJournal/Services/ScanService.swift`)

`@Observable @MainActor` — Gemini Vision API client.

**Config**:
- Proxy URL from `Bundle.main` key `RENDER_PROXY_URL`, fallback: `https://macros-proxy.onrender.com`
- URLSession: 30s request timeout, 60s resource timeout

**API**:
```swift
func scan(image: UIImage, mode: ScanMode) async throws -> NutritionEntry
```
- Builds multipart/form-data with JPEG (0.85 quality) + mode string
- POSTs to `/scan` endpoint
- Parses `GeminiNutritionResponse` (Codable) into `NutritionEntry`
- Does NOT insert into SwiftData — caller reviews first

**Error enum**: `ScanError` — `imageEncodingFailed`, `networkError(Error)`, `invalidResponse`, `serverError(Int, String)`, `decodingError(Error)`

## HealthKitService (`OpenFoodJournal/Services/HealthKitService.swift`)

`@Observable @MainActor` — Apple Health integration.

**Write types**: dietaryEnergyConsumed, dietaryProtein, dietaryCarbohydrates, dietaryFatTotal, dietaryFiber, dietarySugar, dietarySodium, dietaryCholesterol

**Read types**: activeEnergyBurned

| Method | Signature | Notes |
|--------|-----------|-------|
| `requestAuthorization` | `func requestAuthorization() async` | System permission dialog |
| `write` | `func write(_ entry: NutritionEntry) async` | One HKQuantitySample per macro, metadata: FoodType = entry.name |
| `fetchActiveEnergy` | `func fetchActiveEnergy(for date: Date) async -> Double` | kcal burned that day |

**Opt-in**: Controlled by `@AppStorage("healthkit.enabled")` in SettingsView. Auth restored on app launch if flag is true.

## UserGoals (`OpenFoodJournal/Models/UserGoals.swift`)

Not a "service" per se, but injected the same way. Holds daily macro targets in `@AppStorage`. See [models.md](models.md).
