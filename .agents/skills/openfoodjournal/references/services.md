# Services Reference

## NutritionStore (`OpenFoodJournal/Services/NutritionStore.swift`)

`@Observable @MainActor` — SwiftData persistence layer.

**Init**: Takes `ModelContext` from the app's `ModelContainer` and optional `TursoMirrorService`.

| Method | Signature | Notes |
|--------|-----------|-------|
| `log` | `func log(_ entry: NutritionEntry, to date: Date)` | Aligns `entry.timestamp` to the selected journal date, marks stale HealthKit sync metadata when needed, inserts entry, and appends to DailyLog (creates if needed) |
| `fetchLog` | `func fetchLog(for date: Date) -> DailyLog?` | Matches by startOfDay |
| `fetchLogs` | `func fetchLogs(from: Date, to: Date) -> [DailyLog]` | Sorted reverse chronological |
| `fetchAllLogs` | `func fetchAllLogs() -> [DailyLog]` | All logs |
| `fetchAllEntries` | `func fetchAllEntries() -> [NutritionEntry]` | All nutrition entries sorted by timestamp; used by HealthKit backfill |
| `delete` | `func delete(_ entry: NutritionEntry)` | Removes from context |
| `delete` | `func delete(_ log: DailyLog)` | Cascade deletes entries |
| `repairDailyLogEntryRelationships` | `func repairDailyLogEntryRelationships() -> Int` | Idempotently reattaches direct NutritionEntry rows to canonical DailyLogs so journal days match CSV/export data after CloudKit relationship drift |
| `exportCSV` | `func exportCSV() -> String` | Spreadsheet CSV for analysis. Includes stable IDs, ISO dates, core macros, serving basics, selectionSummary, savedFoodID, scanDurationMs, dynamic micronutrient columns, and quote escaping. Not a restore format. |
| `exportBackup` | `func exportBackup(goals: UserGoals, appSettings: AppSettingsRecord) throws -> Data` | Versioned JSON backup with DailyLog, NutritionEntry, SavedFood, TrackedContainer, Preferences, goals, and non-sensitive app settings. |
| `importBackup` | `func importBackup(_ backup: OpenFoodJournalBackup, goals: UserGoals) throws -> BackupImportSummary` | Idempotent restore path. Upserts by UUID and relinks entries to DailyLogs without duplicating repeated imports. |
| `saveChanges` | `func saveChanges()` | Public save for edit flows |

Successful saves schedule `TursoMirrorService.scheduleMirror(reason:)` when the optional mirror is enabled. Turso failures must not block SwiftData, CloudKit, HealthKit, or UI flows.

## OpenFoodJournalBackup (`OpenFoodJournal/Services/OpenFoodJournalBackup.swift`)

Versioned JSON backup DTOs. Current `schemaVersion` is `1`.

Included:
- `DailyLog` rows with IDs, dates, notes
- `NutritionEntry` rows with IDs, timestamps, full serving data, micronutrients, mappings, savedFoodID, scanDurationMs, selectionSummary, and dailyLogID relationship
- `SavedFood` rows with IDs, nutrition template fields, serving data, mappings, lastUsedAt, archivedAt, kind, composite ingredient snapshots, and calculator ingredient snapshots
- `TrackedContainer` rows with IDs, food snapshots, weights, dates, savedFoodID
- `Preferences`, `UserGoals`, and non-sensitive app settings (`scan.useProModel`, `off.contributeEnabled`)

Not included: Gemini API key, HealthKit authorization state, or HealthKit samples.

## ScanService (`OpenFoodJournal/Services/ScanService.swift`)

`@Observable @MainActor` — direct Gemini REST API client.

**Config**:
- Base URL: `https://generativelanguage.googleapis.com/v1beta/models`
- URLSession: 60s request timeout, 120s resource timeout
- Model aliases stay on `gemini-flash-latest` and `gemini-pro-latest`

**API**:
```swift
func scan(image: UIImage, mode: ScanMode, prompt: String? = nil, useProModel: Bool = false) async throws -> NutritionEntry
func scan(images: [UIImage], mode: ScanMode, prompt: String? = nil, useProModel: Bool = false) async throws -> NutritionEntry
func searchNutrition(query: String, useProModel: Bool = false) async throws -> NutritionEntry
func extractCalculatorIngredient(named name: String, from images: [UIImage], useProModel: Bool = false) async throws -> CalculatorIngredientDraft
```
- Encodes 1-4 resized JPEG photos as Gemini `inline_data` parts for label/food scans
- Uses Gemini `google_search` grounding for Food Bank AI Search
- Extracts portions for one user-named restaurant/brand calculator ingredient from images; the typed ingredient name anchors Gemini so it does not invent a whole calculator structure
- Parses `GeminiNutritionResponse` (Codable) into `NutritionEntry`
- Streams Gemini thought-summary parts into `thinkingTrace`
- Writes comprehensive `GeminiScanLog` success/failure diagnostics, updates `GeminiCostAccumulator` from response `usageMetadata`, and prunes logs older than 30 days
- Does NOT insert into SwiftData — caller reviews first

**Error enum**: `ScanError` — `imageEncodingFailed`, `noImages`, `tooManyImages(Int)`, `emptySearchQuery`, `networkError(Error)`, `invalidResponse`, `serverError(Int, String)`, `decodingError(Error)`, `noAPIKey`

## GeminiScanLog Export (`OpenFoodJournal/Models/GeminiScanLog.swift`)

`GeminiScanLog.exportCSV(from:)` returns a CSV for Settings → Data → Export Gemini Logs.

Included: operation, status, scan mode, model metadata, fallback use, photo count, duration, prompt/query, full text prompt, request metadata, image dimensions/JPEG sizes, request byte count, HTTP status, parse stage, raw non-image response text, raw SSE event payload JSON, per-model attempt JSON, usage tokens, estimated token cost, parsed nutrition summary, error code/message, thinking trace, app/build/iOS version, and parsed response JSON.

Excluded: Gemini API key, URL key query parameter, base64 image payloads, and raw image bytes.

## GeminiCostAccumulator (`OpenFoodJournal/Models/GeminiCostAccumulator.swift`)

Settings → Gemini Usage reads this SwiftData model through `@Query`.

Cost estimate rules:
- Uses Gemini `usageMetadata.promptTokenCount`, `candidatesTokenCount`, `thoughtsTokenCount`, and `totalTokenCount`.
- Prices by returned `modelVersion` when available, falling back to the endpoint alias.
- Uses Google Gemini API Standard paid-tier rates checked 2026-06-19.
- Does not include Google Search grounding fees because Gemini returns grounded prompt count locally but not the number of billable search queries.

## TursoMirrorService (`OpenFoodJournal/Services/TursoMirrorService.swift`)

`@Observable @MainActor` — optional push-only mirror to a user-provided Turso database.

**Credentials**:
- Keychain accounts: `turso-database-url`, `turso-auth-token`
- Accepts `libsql://...` or `https://...`; normalizes `libsql://` to HTTPS for SQL-over-HTTP.
- Never stores database tokens in UserDefaults, status strings, logs, or mirrored rows.

**AppStorage/UserDefaults keys**:
- `turso.enabled`
- `turso.includeDiagnostics` (defaults true)
- `turso.lastSyncAt`
- `turso.lastError`
- `turso.lastRowCount`

**API**:
```swift
func testConnection() async throws
func runMigrations() async throws
func mirrorAll(reason: String) async
func scheduleMirror(reason: String)
```

**Transport**:
- `GET /health` for connection tests
- `POST /v2/pipeline` for SQL execution
- Typed SQL args: `null`, `integer`, `float`, `text`, `blob`

**Schema**:
- Namespaced `ofj_*` tables only.
- Normalized core tables for daily logs, entries, saved foods, tracked containers, preferences, user goals, app settings, Gemini scan logs, Gemini cost accumulators, and sync runs.
- Complex Swift value fields (micronutrients, serving, serving mappings, composite ingredients, calculator ingredients, Gemini thinking trace) are mirrored as JSON text.
- Migrations use `CREATE TABLE IF NOT EXISTS`, `PRAGMA table_info(table)`, and `ALTER TABLE ADD COLUMN` only for missing additive columns. Do not use `ALTER TABLE ADD COLUMN IF NOT EXISTS`.

**Mirror contract**:
- SwiftData + CloudKit remain source of truth.
- Turso is never read back into SwiftData in v1.
- Each mirror run writes a `mirror_generation`, upserts current rows, then prunes older rows per mirrored table after that table succeeds.
- Failures update `turso.lastError` and best-effort `ofj_sync_runs`, but never block local app behavior.
- Diagnostics include Gemini logs/cost counters only when `turso.includeDiagnostics` is true. Excluded: Gemini API keys, Turso tokens, raw image bytes/photos, HealthKit tokens.

**Agent utility**:
- `.agents/skills/openfoodjournal/scripts/turso_debug.py`
- Commands: `summary`, `day YYYY-MM-DD`, `entry UUID`, `food-search TEXT`, `healthkit-pending`, `gemini-failures --days 30`, `raw-sql "SELECT ..."`
- `raw-sql` is SELECT-only unless `--allow-write` is explicitly passed.

## HealthKitService (`OpenFoodJournal/Services/HealthKitService.swift`)

`@Observable @MainActor` — Apple Health integration.

**Write types**: dietaryEnergyConsumed, dietaryProtein, dietaryCarbohydrates, dietaryFatTotal, dietaryFiber, dietarySugar, dietarySodium, dietaryCholesterol, dietaryFatSaturated, dietaryVitaminA, dietaryVitaminC, dietaryCalcium, dietaryIron, dietaryPotassium

**Read types**: activeEnergyBurned

| Method | Signature | Notes |
|--------|-----------|-------|
| `requestAuthorization` | `func requestAuthorization() async` | System permission dialog |
| `sync` | `func sync(_ entry: NutritionEntry, in modelContext: ModelContext? = nil, force: Bool = false) async -> SyncResult` | Idempotent entry sync. Skips if the stored write hash is current; otherwise deletes OpenFoodJournal-owned samples for that entry and saves replacements. |
| `deleteSamples` | `func deleteSamples(for entry: NutritionEntry) async -> SyncResult` | Deletes only samples with this app's deterministic sync identifiers for the entry. Use before deleting a `NutritionEntry`. |
| `syncMissingEntries` | `func syncMissingEntries(_ entries: [NutritionEntry], in modelContext: ModelContext) async -> SyncSummary` | Settings backfill path for unsynced/stale entries. |
| `write` | `func write(_ entry: NutritionEntry) async` | Backward-compatible wrapper that calls `sync(..., force: true)`; prefer `sync` with a `ModelContext`. |
| `fetchActiveEnergy` | `func fetchActiveEnergy(for date: Date) async -> Double` | kcal burned that day |

**Opt-in**: Controlled by `@AppStorage("healthkit.enabled")` in SettingsView. Auth restored on app launch if flag is true.

**Sync contract**:
- OpenFoodJournal remains the source of truth; HealthKit is a derived export target.
- Each nutrient sample uses `HKMetadataKeySyncIdentifier = "k3vnc.OpenFoodJournal.\(entry.id).\(nutrientKey)"`.
- Edits replace samples by deleting app-owned samples first, then saving the current values.
- Deletes should call `deleteSamples(for:)` before removing the SwiftData entry.
- HealthKit samples use `entry.healthKitSampleTimestamp`, which prefers the linked journal day when an older entry's stored timestamp falls on a different creation day.
- Settings → Integrations → "Sync Missing Nutrition to Apple Health" backfills entries where `healthKitSyncStatus != .synced` or `healthKitLastWriteHash` differs from `entry.healthKitWriteHash`.

## UserGoals (`OpenFoodJournal/Models/UserGoals.swift`)

Not a "service" per se, but injected the same way. Holds daily macro targets in `@AppStorage`. See [models.md](models.md).
