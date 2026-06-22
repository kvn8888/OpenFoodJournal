---
name: openfoodjournal
description: Living project knowledge for OpenFoodJournal — an iOS 26 food journaling app with AI-powered nutrition scanning. Consult this skill FIRST when starting any work on this project. Contains architecture decisions, data models, service contracts, current state, known issues, and conventions. Update this skill whenever requirements, architecture, or project state changes so it stays accurate across sessions.
---

# OpenFoodJournal — Project Knowledge

This is the single source of truth for any LLM agent working on this project. Read this before writing code. Update it when things change.

## Quick Facts

| Key | Value |
|-----|-------|
| Platform | iOS 26.2+ (iPhone) |
| UI Framework | SwiftUI + Liquid Glass (no `#available` gating needed) |
| Data Layer | SwiftData (`@Model`) + CloudKit Private Database (`iCloud.k3vnc.OpenFoodJournal`) + optional push-only Turso mirror |
| State Pattern | `@Observable` + `@Environment` injection (no singletons) |
| Bundle ID | `k3vnc.OpenFoodJournal` |
| Build System | Xcode (xcodebuild), no SPM dependencies |
| Build Verify Command | `xcodebuild -project OpenFoodJournal.xcodeproj -scheme OpenFoodJournal -destination generic/platform=iOS build` |
| Build Notes | No iOS simulators installed. Use `generic/platform=iOS` for compile-only verification. Physical device (iPhone 18,3) available when connected. Device support symbols at `/Volumes/DevDisk/Developer/Xcode/iOS DeviceSupport/`. |
| AI Backend | Direct Gemini REST API (BYOK — user provides own API key, stored in Keychain) |
| App Entry | `MacrosApp` in `OpenFoodJournalApp.swift` |

## Architecture Overview

```
MacrosApp (creates ModelContainer w/ CloudKit + @Observable services)
  └─ ContentView (4-tab TabView)
       ├─ Journal tab → DailyLogView (WeeklyCalendarStrip, macro summary, meal sections, RadialMenuButton)
       ├─ Food Bank tab → FoodBankView (searchable, sortable active saved food list, swipe-to-archive/edit, "+" menu: AI Search/Composite/Nutrition Calculator/Search OFF/Manual/Archive)
       ├─ History tab → HistoryView (CalendarGridView with progress rings, MacroChartView, macro cards → NutritionDetailView)
       └─ Settings tab → SettingsView (goals, health, data export)
```

**Radial FAB**: DailyLogView uses `RadialMenuButton` — a "+" icon at bottom center that fans out Scan / Manual / Containers / Food Bank in an upper semicircle (210°–330°). Supports tap-to-toggle and drag-to-action. Containers are accessed from here instead of a separate tab.

**Service injection**: All services (`NutritionStore`, `ScanService`, `TursoMirrorService`, `HealthKitService`, `UserGoals`, `OpenFoodFactsService`) are created in `MacrosApp.init()` and passed via `.environment()`. Views consume them with `@Environment(ServiceType.self)`. `SyncService` was removed — CloudKit handles sync natively via `ModelConfiguration(cloudKitDatabase:)`; Turso is an optional push-only mirror, not a source of truth.

**Sheet management**: `DailyLogView` uses a single `DailyLogSheet` enum with `.sheet(item:)` — never multiple booleans.

## Data Models

See [references/models.md](references/models.md) for full property lists.

- **`DailyLog`** — `@Model`, keyed by `date` normalized to midnight (no `@Attribute(.unique)` — CloudKit can't enforce uniqueness; app-level dedup in `fetchOrCreateLog(for:)`). Owns `[NutritionEntry]?` (optional for CloudKit) via cascade delete. Uses `safeEntries` computed property for reads.
- **`NutritionEntry`** — `@Model`, stores core macros (cal/protein/carbs/fat) + dynamic `micronutrients: [String: MicronutrientValue]` + brand/serving/servingCount/servingQuantity/servingUnit/servingMappings + optional `selectionSummary` for generated calculator builds. Includes HealthKit sync metadata (`healthKitSyncStatus`, `healthKitSyncedAt`, `healthKitSyncVersion`, `healthKitLastError`, `healthKitLastWriteHash`) so Apple Health writes are idempotent.
- **`SavedFood`** — `@Model`, reusable food template in Food Bank. Same fields as NutritionEntry minus meal/log context. Includes `kind: SavedFoodKind` (`.single`/`.composite`/`.calculator`), `compositeIngredients: [CompositeIngredientSnapshot]`, `calculatorIngredients: [CalculatorIngredient]`, `lastUsedAt: Date` (defaults to `createdAt`) for "Last Used" sorting, and `archivedAt: Date?` for manual cosmetic archive state. Composite ingredients are copied snapshots, never live `SavedFood` references, so editing a composite only affects future logs. Nutrition calculators are also saved-food rows: flat ingredient/portion value snapshots, not SwiftData relationship trees. Foods auto-archive cosmetically when `lastUsedAt` is more than 14 days old; archived foods stay in SwiftData, remain searchable, and can be browsed from Food Bank "+" → Archive.
- **`TrackedContainer`** — `@Model`, weight-based container tracking. Snapshots food nutrition at creation time. Start weight → final weight → derived consumption via `consumedServings` math.
  - `NewContainerSheet` shows the last completed `finalWeight` for the same `SavedFood` as the next container weight placeholder, so users continuing an open container can type/confirm the last end weight instead of re-entering it from memory.
  - The container food picker sorts all saved foods by most recent container activity first, then alphabetically for foods that have never been tracked.
- **`GeminiScanLog`** — `@Model`, local diagnostic log for Gemini scan and AI Search calls. Stores operation/status, model selection, fallback use, scan mode, photo count, duration, user prompt/query, full text prompt, request metadata, image dimensions/JPEG sizes, request byte count, HTTP status, parse stage, raw non-image response text, raw SSE event payload JSON, per-model attempt JSON, parsed nutrition summary, response JSON, thinking trace, app/build/iOS version, and error details. Never stores API keys or raw image bytes. Export/prune window is 30 days.
- **`GeminiCostAccumulator`** — `@Model`, singleton-style local running total of estimated Gemini token cost. Accumulates input/output/thinking tokens, request counts, success/failure counts, grounded AI Search prompt count, last model/cost, and total estimated USD. Estimates use Gemini `usageMetadata` plus local Google Standard paid-tier rates checked 2026-06-19. Google Search grounding fees are not included because Gemini does not return billable search-query count.
- **`UserGoals`** — `@Observable @MainActor`, uses `@ObservationIgnored @AppStorage` for each goal property to avoid property-wrapper conflicts.
- **`Preferences`** — `@Model`, singleton row for UI customization. Stores `ringSlot1..5` (nutrient IDs for MacroSummaryBar configurable rings). `Preferences.current(in:)` static factory fetches-or-creates the singleton. Included in optional Turso mirroring as the `ofj_preferences` row. Added to `ModelContainer` in app init. Sheets use `@Bindable var prefs: Preferences` for direct binding.
- **`MealType`** — enum: `.breakfast`, `.lunch`, `.dinner`, `.snack`
- **`ScanMode`** — enum: `.label`, `.foodPhoto`, `.barcode`, `.manual`
- **`ServingSize`** — enum: `.mass(grams:)`, `.volume(ml:)`, `.both(grams:ml:)`. Stores canonical SI values. Has `availableUnits: [String]` (dimension-appropriate unit list), `convert(_:from:to:) -> Double?` (handles same-dimension and cross-dimension via density for `.both`). Static tables: `massConversions` (g/oz/kg/lb), `volumeConversions` (mL/cup/tbsp/tsp/fl oz/L). `type: String` returns "mass"/"volume"/"both" for JSON serialization.
- **`ServingMapping`** — Codable struct with `from: ServingAmount` / `to: ServingAmount` for per-food unit conversions (e.g. 1 cup = 244g). Legacy field kept alongside `ServingSize`.
- **`MicronutrientValue`** — Codable struct with `value: Double` / `unit: String` for dynamic micronutrient storage

## Services

See [references/services.md](references/services.md) for full API contracts.

- **`NutritionStore`** — SwiftData CRUD. `log()`, `fetchLog()`, `fetchLogs()`, `delete()`, `saveEntry()`, `repairDailyLogEntryRelationships()`, `exportCSV()`, `exportBackup()`, `importBackup()`. CSV is spreadsheet/analytics only. Restore-grade backup uses versioned JSON DTOs in `OpenFoodJournalBackup.swift` and imports idempotently by UUID. Local/iCloud remain source of truth; successful saves schedule the optional Turso mirror when enabled.
- **`ScanService`** — Accepts 1-4 photos for label and food-photo scans. Resizes each image to max 1200px (UIGraphicsImageRenderer), encodes label JPEGs at 0.50 and food-photo JPEGs at 0.80, then sends each photo as a separate Gemini `inline_data` part in one direct REST API call (`generativelanguage.googleapis.com`) → `NutritionEntry` (not yet inserted). Uses `streamGenerateContent?alt=sse` with Gemini `includeThoughts` so thought-summary parts update `thinkingTrace` in the loading overlay while the scan/search is in flight; only non-thinking parts are accumulated as final nutrition JSON. Also supports Food Bank AI Search via Gemini `google_search` grounding and returns a reviewable `NutritionEntry`, plus nutrition-calculator OCR import via `extractCalculatorIngredient(named:from:useProModel:)` which fills portions for one user-named ingredient at a time. Uses `ModelConfig` static configs with latest Gemini aliases only: `gemini-flash-latest` for label/lite scans and `gemini-pro-latest` for Pro food photo scans/search. Do not replace these with concrete preview/versioned model slugs unless Google removes the latest endpoints. Loads API key from `KeychainService`. User reviews in `ScanResultCard`, `ManualEntryView`, or `NutritionCalculatorEditorView` before committing. Logs scan/search/OCR duration via `ContinuousClock` and stores standard scan durations on `NutritionEntry.scanDurationMs`. Also writes comprehensive `GeminiScanLog` rows for success and failure diagnostics, including model-attempt history, usage metadata, estimated token cost, and raw non-image response text for parse failures; updates `GeminiCostAccumulator`; prunes logs older than 30 days; and keeps API keys/raw photos out of logs. Stores `lastSubmittedScan` for scan-page/result-sheet redo without recapturing photos.
- **`TursoMirrorService`** — Optional `@Observable @MainActor` direct SQL-over-HTTP mirror to a user-provided Turso database. Credentials are Keychain-only (`turso-database-url`, `turso-auth-token`); non-secret state uses `turso.enabled`, `turso.includeDiagnostics`, `turso.lastSyncAt`, `turso.lastError`, and `turso.lastRowCount`. Uses `/health` for connection tests and `/v2/pipeline` for migrations/mirroring. It is push-only, generation-pruned, non-blocking, and never reads Turso back into SwiftData.
- **`KeychainService`** — Static helper for secure Keychain storage (Security framework). Stores Gemini API key under service `k3vnc.OpenFoodJournal`, account `gemini-api-key`, and optional Turso mirror credentials under `turso-database-url` / `turso-auth-token`. Methods: `save(_:for:)`, `load(for:)`, `delete(for:)`, `hasGeminiAPIKey`, `geminiAPIKey`, `hasTursoCredentials`, `tursoDatabaseURL`, `tursoAuthToken`.
- **`ServingConverter`** — Pure-value struct encapsulating all serving-unit conversion math. 4-strategy `factorFor(_:)` (ServingSize tables → direct mapping → chain → SI bridge), `availableUnits`, and `scaledCalories/Protein/Carbs/Fat`. Used by both `EditEntryView` and `LogFoodSheet` to eliminate duplicate conversion logic.
- **`HealthKitService`** — Opt-in Apple Health sync. Writes calories/macros/select micronutrients as separate `HKQuantitySample`s using deterministic `HKMetadataKeySyncIdentifier` values (`entry.id + nutrient key`). Sync deletes only OpenFoodJournal-owned samples for an entry before saving replacements, so retries/edits are idempotent. Settings includes "Sync Missing Nutrition to Apple Health" for backfill. Reads `activeEnergyBurned`.
- **`OpenFoodFactsService`** — Text search and barcode lookup against the Open Food Facts REST API. Search uses `search.openfoodfacts.org` (Elasticsearch-backed, the v1 CGI endpoint returns 503). Barcode lookup uses `world.openfoodfacts.org/api/v2/product/{code}`. `OFFProduct` model stores full nutrition and exposes `hasUsableNutrition`; text search and barcode lookup filter out zero-calorie/no-nutrition placeholder rows before showing or prefilling them. `lookupBarcode()` manages UI state (isLoading/errorMessage); internal `fetchProductByBarcode()` is stateless for batch use. Used by both `OpenFoodFactsSearchView` (text search) and `ScanCaptureView` (barcode camera scan). Settings has an Open Food Facts contribution status row backed by `off.contributionSuccessCount` and `off.lastContributionAt`; do not treat the contribution toggle itself as proof that a DB write happened.
- **`UserGoals`** — Daily targets for cal/protein/carbs/fat, persisted in UserDefaults.

## View Map

See [references/views.md](references/views.md) for detailed view hierarchy and notable patterns.

## Scan Flow (Core Value Prop)

```
User taps Scan → CameraController (AVCaptureSession) → 1-4 photos
  → Camera view offers 0.5x / 1x / 2x zoom (0.5x uses ultra-wide when available; 1x/2x use wide camera)
  → Prompt overlay: review thumbnails, optionally add another angle or library photos
  → Food photo shows text input, label scan skips prompt
  → ScanService.scan(images, mode) → loads API key from KeychainService
  → Resizes/JPEG-encodes each image and builds JSON request with one inline_data part per photo + prompt
  → POST to https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent?key={key}&alt=sse
  → Loading overlay shows scan stage plus recent Gemini thought-summary parts (`part.thought == true`)
  → ContinuousClock measures full round-trip duration
  → Label mode: gemini-flash-latest (fast, minimal thinking)
  → Food photo mode: gemini-pro-latest (high thinking for estimation)
  → Fallback on 500/503: gemini-flash-latest
  → Accumulates non-thinking text parts only → JSON → GeminiNutritionResponse
  → GeminiNutritionResponse → NutritionEntry (NOT inserted yet)
  → Entry gets scanDurationMs set from ContinuousClock measurement
  → ScanResultCard (editable, shows duration badge, can redo previous photos) → User taps "Add to Journal"
  → NutritionStore.log(entry, to: date) → SwiftData insert (CloudKit syncs automatically)
  → Auto-creates SavedFood in Food Bank
  → HealthKitService.sync(entry) if enabled (replaces OpenFoodJournal-owned HealthKit samples by sync identifier)
```

## Barcode Scan Flow

```
User taps "Scan Barcode" card → CameraController (AVCaptureSession) → JPEG
  → promptOverlay: "Look Up" button (no text prompt for barcode mode)
  → Vision VNDetectBarcodesRequest detects barcode from photo
  → OpenFoodFactsService.lookupBarcode(barcodeValue)
  → GET https://world.openfoodfacts.org/api/v2/product/{code}?fields=...
  → OFFProduct (requires calories > 0 and usable nutrition) → ManualEntryView(defaultDate:, prefillProduct:)
  → User reviews/edits pre-filled nutrition data → saves to journal
```

## Open Food Facts Search Flow

```
User taps "Search Open Food Facts" in Food Bank "+" menu
  → OpenFoodFactsSearchView (searchable, Enter-only via .onSubmit)
  → GET https://search.openfoodfacts.org/search?q={query}&fields=...&page_size=25
  → Converts hits to OFFProduct and filters out zero-calorie/no-usable-nutrition rows
  → OFFProductRow (styled like SavedFoodRowView — macros, calories, serving)
  → Tap row → ManualEntryView(defaultDate:, prefillProduct: product)
  → User reviews/edits pre-filled data → saves to journal
```

## AI Search Flow

```
User taps "AI Search" in Food Bank "+" menu
  → AIFoodSearchView with a search-style prompt row and arrow submit button
  → ScanService.searchNutrition(query, useProModel) loads API key from KeychainService
  → Builds Gemini JSON request with tools: [{"google_search": {}}]
  → Uses gemini-flash-latest by default or gemini-pro-latest when Settings "Use Gemini Pro for AI" is enabled
  → Parses JSON nutrition response → NutritionEntry (NOT inserted yet)
  → ManualEntryView(defaultDate:, prefill:) opens for editable review
  → User chooses "Add to Journal" or "Add to Journal & Food Bank"
```

## Food Bank Archive Flow

```
Default Food Bank list
  → Shows active foods only (`!SavedFood.isArchivedInFoodBank`)
  → Empty search filters active foods; non-empty search filters all saved foods so archived matches still appear
  → Trailing swipe: Archive/Unarchive + Edit
  → Leading swipe or tap: LogFoodSheet
  → `NutritionStore.log()` refreshes linked SavedFood usage via `savedFoodID` so logged foods update `lastUsedAt` and leave the archive

Food Bank "+" → Archive
  → FoodBankArchiveView lists foods with `archivedAt != nil` or `lastUsedAt` older than 14 days
  → Users can search archived foods, log them, edit them, or unarchive them
  → Unarchive clears `archivedAt` and refreshes `lastUsedAt` so the item becomes visible in the active list
```

## Composite Food Flow

```
Food Bank "+" → Composite Food
  → CompositeFoodBuilderView
  → User names the composite and adds Food Bank ingredients
  → Each ingredient is stored as CompositeIngredientSnapshot with copied nutrition, serving info, selected quantity, and selected unit
  → SavedFood.refreshCompositeNutrition() sums the selected ingredient portions into a SavedFood(kind: .composite)
  → Editing the composite changes its ingredient snapshots and recalculates future saved-food nutrition only
  → Existing NutritionEntry rows remain unchanged because logging still snapshots SavedFood.toNutritionEntry()
```

## Nutrition Calculator Flow

```
Food Bank "+" → Nutrition Calculator
  → NutritionCalculatorLibraryView lists SavedFood(kind: .calculator) rows by last used
  → New/Edit opens NutritionCalculatorEditorView
  → User defines restaurant/brand identity and a flat list of ingredients with portion names
  → Ingredient editor can call Gemini OCR on images for the user-named ingredient only
  → Image import stays visibly disabled until the ingredient has a name and at least one image is selected
  → OCR fills nutrition first; imported portions keep source labels when available, otherwise default to "normal"
  → Manually added portions also default to "normal" as actual field text instead of opening with a blank placeholder
  → Calculator ingredients are stored as Codable value arrays on SavedFood, not relationships
  → Build opens NutritionCalculatorBuildView
  → User chooses one portion per ingredient, adjusts quantities, and sees live macro totals
  → Add to Journal writes a NutritionEntry with copied macros/micros, savedFoodID, servingUnit "build", and selectionSummary
  → Later calculator edits affect future builds only; previous NutritionEntry rows keep their logged nutrition snapshot
```

## CloudKit Sync Architecture (app-store branch)

```
iOS App (SwiftData + CloudKit)
  ←→ iCloud Private Database (automatic, free, multi-device)

  → ScanService → Direct Gemini REST API (BYOK, zero server dependency)
  → API key stored in iOS Keychain via KeychainService
  → Optional TursoMirrorService → user-owned Turso DB via SQL-over-HTTP
```

**Strategy**: SwiftData's `ModelConfiguration(cloudKitDatabase: .private("iCloud.k3vnc.OpenFoodJournal"))` handles Apple-device sync automatically. Optional Turso mirroring is a debuggable external copy for SQL inspection; it does not replace SwiftData/iCloud and does not restore data.

**CloudKit requirements enforced on all models**:
- All stored properties have defaults (including fully qualified enum defaults: `MealType.snack` not `.snack`)
- No `@Attribute(.unique)` (CloudKit can't enforce uniqueness)
- Relationships are optional (`var entries: [NutritionEntry]? = []`)
- No `.deny` delete rules

**Entitlements**: `OpenFoodJournal.entitlements` includes iCloud (CloudKit), Push Notifications (aps-environment), background mode (remote-notification).

**Data migration**: TursoMigrationView was deleted — CloudKit replaced the old Turso source-of-truth path. Current Turso support is optional push-only mirroring through `TursoMirrorService`, with normalized `ofj_*` tables and JSON columns for complex Swift value fields.

## Turso Agent Debugging

When a user has enabled Turso mirroring and provides credentials, use `.agents/skills/openfoodjournal/scripts/turso_debug.py` for read-only SQL inspection. It accepts `TURSO_DATABASE_URL` / `TURSO_AUTH_TOKEN`, common `LIBSQL_*` aliases, `.env` by default, or `--url` / `--token`. It supports: `summary`, `day YYYY-MM-DD`, `entry UUID`, `food-search TEXT`, `healthkit-pending`, `gemini-failures --days 30`, `typed-args-smoke-test`, and `raw-sql "SELECT ..."` (SELECT-only unless `--allow-write` is passed).

## GitHub Project Board

Use `.agents/skills/openfoodjournal/scripts/github_project_board.py` to inspect
or update the OpenFoodJournal GitHub Projects v2 kanban board. The helper wraps
`gh project` with repo defaults so agents can avoid retyping owner/repo/project
arguments.

Requirements:
- `gh auth status` must show `repo` and `project` scopes.
- Default owner/repo: `kvn8888/OpenFoodJournal`.
- Default project title lookup: `OpenFoodJournal`.
- After each work session, update relevant GitHub issues and board fields
  (`Status`, `Priority`, `Size`) so the board reflects the latest state.
  At minimum, move actively worked issues to `In Progress`, move verified
  completed issues to `Done`, and add notes/links for blockers or validation.

Common commands:
```bash
python .agents/skills/openfoodjournal/scripts/github_project_board.py create
python .agents/skills/openfoodjournal/scripts/github_project_board.py projects
python .agents/skills/openfoodjournal/scripts/github_project_board.py columns
python .agents/skills/openfoodjournal/scripts/github_project_board.py list
python .agents/skills/openfoodjournal/scripts/github_project_board.py list --status Todo
python .agents/skills/openfoodjournal/scripts/github_project_board.py add-issue 4 --status Todo --priority P0 --size M
python .agents/skills/openfoodjournal/scripts/github_project_board.py move 4 "In Progress"
python .agents/skills/openfoodjournal/scripts/github_project_board.py create-issue --title "Bug title" --body-file /tmp/body.md --label area:healthkit,type:bug,priority:p0 --status Todo --priority P0 --size M
python .agents/skills/openfoodjournal/scripts/github_project_board.py edit-issue 10 --body-file /tmp/body.md --add-label area:healthkit --status Todo --priority P0
python .agents/skills/openfoodjournal/scripts/github_project_board.py set-fields 10 --status "In Progress" --priority P0 --size M
```

## Backup / Export Flow

```
Settings → Data → Export Spreadsheet CSV
  → NutritionStore.exportCSV()
  → Human-readable analytics CSV with stable IDs, ISO dates, escaped fields, core macros, serving basics, savedFoodID, scanDurationMs, and dynamic micronutrient columns
  → Not intended for restoring app state

Settings → Data → Export Backup
  → NutritionStore.exportBackup(goals, appSettings)
  → Versioned JSON (`schemaVersion: 1`) with DailyLog, NutritionEntry, SavedFood (including composite ingredient snapshots and calculator ingredient snapshots), TrackedContainer, Preferences, UserGoals, and non-sensitive app settings
  → Does not include Gemini API key, HealthKit authorization state, or HealthKit samples

Settings → Data → Import Backup
  → Decodes `OpenFoodJournalBackup`
  → Confirms with the user before import
  → NutritionStore.importBackup(...) upserts by stable UUID and relinks entries to DailyLogs by ID
  → Re-importing the same backup updates existing records instead of duplicating them

Settings → Data → Export Gemini Logs
  → GeminiScanLog.exportCSV()
  → CSV of local Gemini scan and AI Search diagnostics from the last 30 days
  → Includes prompt/query, full text prompt, request metadata, image dimensions/JPEG sizes, request byte count, model-attempt history, HTTP status, parse stage, timing, status/error details, thinking trace, raw non-image response text, raw SSE event payload JSON, and parsed response JSON
  → Does not include API keys, Gemini URL keys, base64 image payloads, or raw image bytes
```

**Server**: The current app path has no proxy server. The iOS app calls Gemini REST directly, CloudKit handles Apple-device sync, and optional Turso mirroring talks directly to Turso SQL-over-HTTP. The legacy Express/Turso source-of-truth architecture lives only in old branch history.

**Turso mirror schema**: `TursoMirrorService` creates namespaced `ofj_*` tables: `ofj_sync_runs`, `ofj_daily_logs`, `ofj_nutrition_entries`, `ofj_saved_foods`, `ofj_tracked_containers`, `ofj_preferences`, `ofj_user_goals`, `ofj_app_settings`, `ofj_gemini_scan_logs`, and `ofj_gemini_cost_accumulators`.

**Turso migration pattern**: Use `CREATE TABLE IF NOT EXISTS` for full table creation. For additive columns, query `PRAGMA table_info(table_name)` and only then run plain `ALTER TABLE table ADD COLUMN column TYPE`. SQLite/libSQL does not support `ALTER TABLE ADD COLUMN IF NOT EXISTS`.

**Turso sync integration points**: SwiftData + CloudKit remain source of truth. Local writes call `TursoMirrorService.scheduleMirror(reason:)` when enabled; each mirror run upserts current rows with a `mirror_generation` and prunes older generations per table only after that table succeeds. Turso is not read back into SwiftData in v1.

## Known Gotchas

1. **`xcodebuild` is stricter than Xcode IDE** — missing `import SwiftData` may compile in previews but fail in CLI builds. Always verify with `xcodebuild`.
2. **`.easeInOut` is a static property** — don't write `.easeInOut(value:)`. The `value:` belongs to `.animation(_:value:)`.
3. **Ternary type mismatch** — `.primary` is `HierarchicalShapeStyle`, `.orange` is `Color`. Use `Color.primary` to unify.
4. **`@ObservationIgnored` on `@AppStorage`** — required in `UserGoals` to avoid double-wrapper conflict. Every new `@AppStorage` property needs it.
5. **`private` enum across structs** — `private` scopes to the type, not the file. Use `fileprivate` for shared-file enums.
6. **`ModelContainer(for:configurations:)`** — not `schema:`. The `Schema` wrapper is only for migrations.
7. **Swift named parameters must be in declaration order** — adding a new `init` parameter doesn't let you put it anywhere in call sites. Reorder both the declaration *and* all call sites to match. Build will catch mismatches.
8. **`PRAGMA table_info()` not `IF NOT EXISTS` for ALTER TABLE** — SQLite doesn't support `ALTER TABLE ADD COLUMN IF NOT EXISTS`. Use PRAGMA to check first.
9. **`servingQuantity`/`servingUnit` must be set after scaling in LogFoodSheet** — `toNutritionEntry()` copies the food template's serving values; after scaling macros in logButton, write `entry.servingQuantity = quantity` and `entry.servingUnit = selectedUnit` so EditEntryView opens with the correct baseline.
10. **`.swipeActions` is silently ignored outside a `List`** — it does nothing in `LazyVStack`, `ScrollView`, or `VStack`. If swipe actions don't fire, check that the `ForEach` is inside a `List`. The modifier compiles without error regardless of container.
11. **Smooth tappable List rows with swipeActions: use `Button + .buttonStyle(.plain)`** — Default `Button` style causes ~150ms tap disambiguation delay. `onTapGesture + contentShape(Rectangle())` eliminates tap delay but makes swipes choppy (TapGesture blocks swipe tracking). The correct pattern is `Button { } label: { YourRowView() }.buttonStyle(.plain)` — UIKit-optimized for List swipe coexistence, smooth on both taps and swipes.
12. **ZStack gesture priority** — in a `ZStack`, the **last** (top) view receives gestures first. Put a `Color.clear.contentShape(Rectangle()).onTapGesture { dismiss() }` layer **before** the overlay content to create an outside-tap dismiss. Views on top intercept taps; the clear layer catches everything that falls through.
13. **`Color.clear` needs `.contentShape(Rectangle())`** — transparent views have no hit-test area by default. Without `contentShape`, taps pass through as if the view doesn't exist.
14. **`@Model` enum defaults must be fully qualified** — `var mealType: MealType = .snack` fails during macro expansion. Use `MealType.snack`. The error message is unhelpful (just says macro expansion failed).
15. **CloudKit optional relationships need `safeEntries` pattern** — `var entries: [NutritionEntry]? = []` requires unwrapping everywhere. Add `var safeEntries: [NutritionEntry] { entries ?? [] }` and use that for reads. Use `NutritionStore.link(_:to:)` for entry/log writes so nil arrays, moved entries, and duplicate references are normalized.
16. **Day UI depends on `DailyLog.entries`; CSV export fetches `NutritionEntry` directly** — if entries export but older days look empty, suspect orphaned or duplicate `DailyLog` relationships, not deleted food data. `repairDailyLogEntryRelationships()` runs on launch and is intentionally idempotent so it can reattach entries after CloudKit sync catches up.
17. **`KnownMicronutrient.Category` cases are `.vitamin`/`.mineral`** — not `.vitamins`/`.minerals`. The enum raw values are plural ("Vitamins"/"Minerals") but the Swift case names are singular.
18. **`@Observable` should only track UI state** — mark framework infrastructure with `@ObservationIgnored` (`ModelContext`, `URLSession`, `HKHealthStore`, `AVCaptureSession`, `AVCaptureDevice/Input`, continuations). Leaving dispatch/AVFoundation/HealthKit internals observable can surface runtime-only Objective-C selector crashes such as `_setContext:` on dispatch-backed objects. For `NSObject` delegate controllers like `CameraController`, prefer `ObservableObject` + `@StateObject` with `@Published` UI state instead of `@Observable`.
19. **Gemini SSE payloads may batch multiple JSON objects** — `streamGenerateContent?alt=sse` can deliver several `data:` JSON objects before a blank event separator. `ScanService.consumeGeminiStreamEvent` must handle both a single JSON object and newline-separated JSON fragments; otherwise logs show `parseStage=stream_event_decode`, HTTP 200, and raw response JSON containing multiple valid objects.

## What's New Sheet Pattern

`WhatsNewSheet` is version-gated via `@AppStorage("lastSeenVersion")` in `ContentView`. On appear, if `lastSeenVersion != currentVersion` (from `CFBundleShortVersionString`), the sheet is presented. On dismiss, `lastSeenVersion` is updated. To add features for a new version, edit `WhatsNewSheet.swift` and bump the version header text. Each feature is a `FeatureRow(icon:, color:, title:, description:)`.

**v1.1 features**: Open Food Facts search, barcode scanning, faster food photo scans (lite model default), reorderable nutrient rings, nutrition history navigation (day/week/month with date picker).

## Entitlements (app-store branch)

Already configured in `OpenFoodJournal.entitlements`:
- `com.apple.developer.icloud-services`: CloudKit
- `com.apple.developer.icloud-container-identifiers`: iCloud.k3vnc.OpenFoodJournal
- `aps-environment`: development (auto-switches to production on Archive)
- `UIBackgroundModes`: remote-notification

**Still needed** (must add to entitlements):
- `com.apple.developer.healthkit` (HealthKit usage compiles but entitlement missing)

**Still needed** (provisioning profile):
- Enable iCloud + Push Notifications capabilities in Apple Developer portal
- Regenerate provisioning profile

## Branches

- **`main`** — Original Turso sync architecture. `SyncService.swift` present, all views have fire-and-forget sync Tasks. Treat this as legacy branch history, not the current app-store architecture.
- **`app-store`** — CloudKit sync plus optional push-only Turso mirror. `SyncService.swift` deleted, old fire-and-forget sync Tasks removed, and `TursoMigrationView` is gone. This is the App Store submission branch.

## Conventions

- **Comments**: Explain *why*, not *what*. Entry-level devs should understand each function's purpose.
- **File creation**: Build large files in small chunks to avoid network errors.
- **Retrospectives**: Live in `docs/`. Update when later fixes change the story.
- **Skills**: This file is the project skill. Update it when architecture or requirements change.
- **Commits**: Descriptive messages. Push after every significant change.

**DailyLogView container**: Uses a `List` (not ScrollView+LazyVStack) with `.listStyle(.plain)` + `.scrollContentBackground(.hidden)`. `WeeklyCalendarStrip` and `MacroSummaryBar` are plain List rows with `listRowBackground(Color.clear)` + `listRowSeparator(.hidden)`. Meal sections use `MealSectionView` which returns a `Section{}` that becomes a proper sticky List section header in a List context. All swipe actions are on the `MealSectionView` Button wrapper (not on `EntryRowView`).

**RadialMenuButton**: Option bubbles support direct `.onTapGesture` (as well as drag-to-select). A `Color.clear.contentShape(Rectangle()).ignoresSafeArea()` layer behind `GlassEffectContainer` dismisses the menu when tapping outside. The layer is only inserted into the ZStack when `isOpen == true`. Option label text has a subtle drop shadow for legibility over light/glass backgrounds.

**Swipe mappings**:
- `FoodBankView` row: trailing (swipe left) = Archive/Unarchive (gray/green) + Edit (blue); leading (swipe right) = Add to journal (green)
- `MealSectionView` row: trailing (swipe left) = Delete; leading (swipe right) = Edit — both on the outer Button wrapper (never on `EntryRowView` to avoid double-registration gesture lag)

**FoodNutrientBreakdownView**: Inverse of `NutrientBreakdownView` — shows all nutrients (macros + micros) for a specific food across the selected period. Accessed by tapping a food row in NutrientBreakdownView's "By Food" section.

**EditEntryView**: Has full serving-mappings section (same as LogFoodSheet). Uses shared `AddServingMappingSheet` (defined in LogFoodSheet.swift, internal not private). `addMapping()` calls `nutritionStore.saveEntry(entry)`.

**CursorEndModifier**: Applied once at the app root with `.cursorAtEnd()`. It keeps `UITextField` cursors at the end on focus and installs a non-canceling window tap recognizer that dismisses the keyboard when tapping outside text inputs. Keep this centralized instead of adding competing per-view whitespace tap gestures.

## Current State (Last Updated: 2026-06-22)

- **Branch: `app-store`** — CloudKit is the primary sync path, with optional push-only Turso mirror for user-owned SQL debugging
- App structure complete: all models, services, and views implemented
- 4-tab layout: Journal, Food Bank, History, Settings (Containers accessed via RadialMenuButton)
- Builds successfully with `xcodebuild -destination generic/platform=iOS` (no simulators installed; compile-only verification)
- SwiftData + CloudKit Private Database for data persistence and sync
- Gemini scans/searches call the Gemini REST API directly from the device using the user's BYOK key; no Render proxy is used by the current app path
- Food Bank: save foods from scan/manual entry, build composite foods from snapshot ingredient portions, browse/search/sort active foods, auto-hide foods unused for over 14 days, manually archive/unarchive foods, log archived foods from search or Archive
- Nutrition Calculator: calculators are `SavedFood(kind: .calculator)` rows with flat ingredient/portion snapshots. OCR import is name-first per ingredient: type an ingredient name, choose an image from the library or camera, Gemini fills nutrients, and portion rows default to visible `normal` field text when no source label exists.
- Keyboard UX: tapping outside a text input dismisses the keyboard app-wide via `CursorEndModifier`, while taps still pass through to buttons/lists.
- Settings Data: spreadsheet CSV export plus versioned JSON backup export/import. JSON import is idempotent by UUID.
- **Gemini scan UX**: loading overlay can show streamed thought-summary trace, result sheet and scan page can redo the last submitted photo set, and camera view has 0.5x/1x/2x zoom controls
- **Open Food Facts integration**: Enter-only search, zero-calorie/no-usable-nutrition rows filtered out, add to journal/food bank, per-serving nutrition
- **Food Bank "+" toolbar menu**: AI Search, Composite Food, Nutrition Calculator, Search Open Food Facts, Manual Entry, Archive (replaces empty-state-only guidance)
- **Settings: OFF contribute toggle/status** (`off.contributeEnabled`, default off; `off.contributionSuccessCount` and `off.lastContributionAt` show confirmed on-device upload history)
- Container Tracking: create from Food Bank food, enter start weight, complete with final weight
- Serving Mappings: per-food unit conversions, editable in EditEntryView
- **NutritionDetailView macro cards**: circular progress rings (not linear ProgressView), showing value inside ring + percentage below
- **FoodNutrientBreakdownView**: inverse of NutrientBreakdownView — food → all nutrients. NavigationLink from NutrientBreakdownView "By Food" rows
- **LogFoodSheet editable micronutrients**: collapsible DisclosureGroup with editable text fields for each micronutrient, values applied at log time
- **Radial menu text shadow**: option labels have `.shadow()` for legibility over glass
- **Swipe gesture lag fix**: swipe actions consolidated on MealSectionView Button wrapper (removed from EntryRowView), SavedFoodRowView has `.contentShape(Rectangle())`, EntryRowView uses static DateFormatter
- WeeklyCalendarStrip: horizontally scrollable week strip with momentum snapping
- Comprehensive micronutrient tracking: 30 FDA nutrients with daily values
- Entitlements configured: iCloud (CloudKit), Push Notifications, Camera, HealthKit descriptions
- BYOK Gemini integration: direct REST API calls, no server proxy needed
- KeychainService for secure API key storage
- Onboarding flow: 6 pages (Welcome → API Key → Goals → Camera → Radial Menu Tutorial → HealthKit)
- RadialMenuDemo: pure SwiftUI phase-based animation teaching press-and-drag gesture (in onboarding page 4)
- Settings: API key management section (save/delete/change key), "Show Onboarding" replay button, "Sources & Disclaimers" link
- **App Store Guideline 1.4.1 compliance**: HealthDisclaimerView with FDA citations (21 CFR §101.9), AI estimation disclaimers, Atwater system citation, and general medical disclaimer. Inline citations on NutritionDetailView, ScanResultCard, and GoalsEditorView.
- App Store audit complete: HealthKit entitlement, Privacy Policy, PrivacyInfo.xcprivacy, AGPL→MIT licensing
- sourceImage removed from NutritionEntry and SavedFood (was stored but never displayed)
- TursoMigrationView deleted — old restore/source-of-truth Turso migration path is dead code
- Optional Turso mirror added in Settings → Data → Turso Integration. It stores URL/token in Keychain, supports `/health`, migrations, full mirror, generation pruning, Gemini diagnostics/cost counters, and an agent read-only debug script.
- Unit tests cover Turso URL normalization, SQL typed arg encoding, migration statement coverage, and upsert construction

## App Store Submission Notes

**First submission rejected (Guideline 1.4.1 — Physical Harm)**: App provided health/nutrition data without citations. Fixed by adding `HealthDisclaimerView` (Settings → Sources & Disclaimers) with FDA Daily Values links, Atwater system reference, AI estimation disclaimer, and general medical disclaimer. Inline citations added to NutritionDetailView, ScanResultCard, and GoalsEditorView.

**Other audit findings to address before next submission:**
- README.md has been updated for the current app-store architecture, including optional Turso mirroring. Re-check before submission if branch contents change again.
- Reviewer notes previously contained false HealthKit claim ("data is never read") — corrected to list all read/write types.
- `server/` directory and `render.yaml` are dead code on `app-store` branch — reviewers clicking the GitHub link may be confused.
- AGPL-3.0 license has App Store exception in LICENSE_NOTICE.md — Apple may or may not flag this.
- Privacy policy is web-only (GitHub link) — fails offline. Consider embedding a copy in-app.

## Planned Work (Backlog)

### UX / Feature Improvements

- **Weekly/monthly view should display daily averages** — In `NutritionDetailView`, when `selectedPeriod` is `.weekly` or `.monthly`, `macroTotals` currently accumulates totals. For multi-day periods, display the **daily average** (total ÷ days in period) so "14,000 kcal this week" becomes "2,000 kcal/day avg". The period picker label should reflect this ("Weekly Avg", "Monthly Avg"). Same applies to the `comparisonCard` values in `HistoryView.weekComparisonSection` (already divides by 7 — verify `.monthly` path does the same).

### Open Food Facts Integration

- **Open Food Facts (OFF)** is a free, open database of 4M+ food products. Integrated into the Food Bank for searching and adding foods without scanning.
- **Service**: `OpenFoodFactsService` — `@Observable @MainActor` service for OFF REST API calls (text search + barcode lookup). Injected via `.environment()` from `MacrosApp`.
- **API endpoints used**:
  - **Text search**: `GET https://search.openfoodfacts.org/search?q={query}&fields=product_name,brands,code,nutriments,serving_size,serving_quantity&page_size=25` — dedicated Elasticsearch-backed search service (the legacy v1 CGI endpoint returns 503)
  - **Barcode/product lookup (v2)**: `GET https://world.openfoodfacts.org/api/v2/product/{barcode}?fields=...` — full nutrition data
  - **Filtering**: `OFFProduct.hasUsableNutrition` requires calories > 0 plus at least one macro or micronutrient. Text search and barcode lookup reject zero-calorie/no-nutrition placeholder rows before UI prefill.
  - **Fields requested** (for product detail): `product_name,brands,nutriments,serving_size,serving_quantity,code`
  - **Nutriments mapping**: `energy-kcal_100g` → calories, `proteins_100g` → protein, `carbohydrates_100g` → carbs, `fat_100g` → fat, plus micronutrients (fiber, sugar, sodium, etc.)
  - **User-Agent**: `OpenFoodJournal/1.0 (openfoodjournal@example.com)` — required by OFF API policy
  - **Rate limits**: 10 req/min for search, 100 req/min for product reads
  - **No auth required** for reads; writes (contribute) require OFF account credentials
- **UI access points**:
  - **FoodBankView toolbar**: "+" button (leading of sort button) → Menu with 3 options: Scan, Manual Entry, Search Open Food Facts
  - **Scan** and **Manual Entry** reuse existing sheets (`ScanView` via DailyLogSheet, `ManualEntryView`)
  - **Search Open Food Facts** opens `OpenFoodFactsSearchView` — Enter-only search, filtered usable results, tap to review details
  - **Result action**: Same pattern as ManualEntryView — "Add to Journal" or "Add to Journal & Food Bank" via toolbar Menu
- **Settings**: `@AppStorage("off.contributeEnabled")` toggle (default: `false`) plus contribution status backed by `off.contributionSuccessCount` / `off.lastContributionAt`. Current code reports whether this device has recorded confirmed uploads; it does not submit writes just because the toggle is enabled.
- **Data flow**: OFF search result → `OFFProduct` struct (Codable) → converted to `NutritionEntry` / `SavedFood` with `scanMode: .manual` and brand preserved. Nutrition values from OFF are per-100g; conversion to serving-based values uses `serving_size` field when available.
- **No SPM dependency**: Direct `URLSession` calls, no OFF Swift SDK imported (keeps zero-dependency architecture).
