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

Assistant web research provider, Tavily depth, and Parallel mode are included as
portable, non-secret settings. Gemini/OpenRouter/Azure/Tavily/Parallel API keys
remain excluded.

## Assistant research (`ChatModelProxy.swift`, `ChatService.swift`)

`ChatWebSearchProviding` is independent from conversation generation. The
`modelProvider` setting adapts the selected Gemini/OpenRouter/Azure proxy's
native search, `tavily` calls `POST https://api.tavily.com/search`, and
`parallel` calls `POST https://api.parallel.ai/v1/search`; external credentials
remain in separate Keychain accounts. Tavily defaults to fast depth, five
structured results, and no provider-generated answer/raw-content download.
Parallel defaults to Basic and receives the objective, up to five keyword
queries, stable agent-run session ID, and consuming model ID. The selected
Assistant model synthesizes either provider's evidence through the ordinary
`web_search` tool loop.

Tavily snippets and Parallel excerpts/citations persist as `ChatSourceArtifact`
records with external provider provenance, so they survive later turns,
compaction, relaunch, and provider switching. `fetch_url` remains a separate
on-device operation guarded by `ChatURLSecurity`. External diagnostics are
metadata-only. Tavily includes request ID, duration, result count, and credits
without fake token cost; Parallel includes search ID, latency, result count, and
a dated local request-price estimate.

## Assistant runtime (`ChatRuntime.swift`, `ChatService.swift`)

`ChatService.submit(...)` is synchronous and must persist the user message,
attachments, and queued `ChatAgentRun` before configuration or network work.
The service owns the single app-wide active-run gate and persisted phases. Do
not move sending back into a view-launched `Task`, because immediate transcript
acknowledgment and duplicate prevention depend on this ordering.

`ChatDeadlinePolicy.fast` is the only shipping deadline profile: local reads 1s,
HealthKit 3s, web search 10s, URL/PDF fetch 15s, first provider event 10s,
stream idle 8s, model turn 90s, active run 180s, and Still waiting after 3s.
Approval waiting has no deadline and is excluded from active runtime. Safe
operations retry only once; writes and ambiguous interrupted operations do not.

Contiguous independent read tools execute concurrently with a maximum of three.
Write/approval calls are barriers. Persist provider results in original model
turn order even when tasks finish out of order. Diagnostics are metadata-only:
never record prompts, answers, arguments/results, journal/HealthKit values,
URLs/source content, or attachments.

## Runtime model metadata (`RuntimeModelCatalog.swift`)

`RuntimeModelCatalog` downloads `https://models.dev/api.json`, retains only the
Google, OpenRouter, and Azure provider records, and writes an ETag-aware cache
under Library/Caches. Production refreshes at app launch and foreground no more
than once per 24 hours. Metadata failure is non-fatal: request construction
continues with the shipped `ChatModelCatalog` limits and `ChatPricingCatalog`
rates.

Gemini `modelVersion`, OpenRouter `model`, and Azure Responses `response.model`
are the concrete accounting IDs. When a provider alias resolves differently,
the catalog saves that mapping immediately and forces a background refresh.
Context limits, attachment/tool flags, pricing, Assistant round/daily usage,
and scan estimates use the concrete record when available. Keep Azure
deployment names separate from the model slug, and retain app-owned behavior
overrides for streaming, parallel calls, native web search, and compaction.

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
- Emits redacted `AIDiagnosticEvent` success/failure telemetry through the configured Turso sink and updates the local `GeminiCostAccumulator` from response `usageMetadata`; it does not insert new detailed logs into SwiftData/CloudKit
- Does NOT insert into SwiftData — caller reviews first

**Error enum**: `ScanError` — `imageEncodingFailed`, `noImages`, `tooManyImages(Int)`, `emptySearchQuery`, `networkError(Error)`, `invalidResponse`, `serverError(Int, String)`, `decodingError(Error)`, `noAPIKey`

## AI diagnostic envelope (`OpenFoodJournal/Models/AIDiagnosticEvent.swift`)

`AIDiagnosticEvent` is the provider-neutral Turso row written by scan, Assistant,
and external-research paths. `GeminiScanLog` and `ChatDiagnosticSpan` remain in
the SwiftData schema only to decode/migrate legacy CloudKit records.

Included: operation/status, provider/base model/deployment, run/thread/turn/call/request IDs, durations, input/cached/output/reasoning usage, known cost, HTTP/error metadata, app/build/OS, and bounded redacted operational metadata.

Excluded: prompts, answers, journal/HealthKit values, source URLs/content, attachments, raw provider bodies/model attempts, thinking summaries/chain-of-thought, API keys/tokens, and image bytes.

`AIDiagnosticOutboxStore` is a local-only 500-event/2-MiB/48-hour delivery
queue. Acknowledged UUIDs are deleted immediately. Settings export flushes the
queue and reads the last 14 days from Turso; it is not a local-log export.

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
- `turso.lastDiagnosticUploadAt`

**API**:
```swift
func testConnection() async throws
func runMigrations() async throws
func mirrorAll(reason: String) async
func scheduleMirror(reason: String)
func recordDiagnostic(_ event: AIDiagnosticEvent)
func flushDiagnosticOutbox() async -> Bool
func migrateLegacyDiagnostics() async
func exportDiagnosticCSV() async throws -> String
func clearAIDiagnostics() async
```

**Transport**:
- `GET /health` for connection tests
- `POST /v2/pipeline` for SQL execution
- Typed SQL args: `null`, `integer`, `float`, `text`, `blob`

**Schema**:
- Namespaced `ofj_*` tables only.
- Normalized core tables for daily logs, entries, saved foods, tracked containers, preferences, user goals, app settings, legacy Gemini scan logs, Gemini cost accumulators, sync runs, and append-only AI diagnostic events.
- Complex Swift value fields (micronutrients, serving, serving mappings, composite ingredients, calculator ingredients, Gemini thinking trace) are mirrored as JSON text.
- Migrations use `CREATE TABLE IF NOT EXISTS`, `PRAGMA table_info(table)`, and `ALTER TABLE ADD COLUMN` only for missing additive columns. Do not use `ALTER TABLE ADD COLUMN IF NOT EXISTS`.

**Mirror contract**:
- SwiftData + CloudKit remain source of truth.
- Turso is never read back into SwiftData in v1.
- Each mirror run writes a `mirror_generation`, upserts current rows, then prunes older rows per mirrored table after that table succeeds.
- `ofj_ai_diagnostic_events` is excluded from generation mirroring. It uses idempotent UUID upserts and `expires_at`; successful diagnostic uploads immediately acknowledge/delete local outbox events.
- Failures update `turso.lastError` and best-effort `ofj_sync_runs`, but never block local app behavior.
- Detailed diagnostics are sent only when `turso.includeDiagnostics` is true. Disabling the toggle clears remote diagnostics and pending delivery events; conversations, run outcomes, and usage/cost aggregates remain.
- On launch/foreground, legacy local diagnostic rows are uploaded in bounded batches and deleted from SwiftData only after acknowledged Turso writes.

**Agent utility**:
- `.agents/skills/openfoodjournal/scripts/turso_debug.py`
- Commands: `summary`, `day YYYY-MM-DD`, `entry UUID`, `food-search TEXT`, `healthkit-pending`, `ai-events` with status/provider/operation/run/request filters, legacy `gemini-failures`, `raw-sql "SELECT ..."`
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
