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
| Data Layer | SwiftData (`@Model`) local cache, Turso (libSQL) cloud primary |
| State Pattern | `@Observable` + `@Environment` injection (no singletons) |
| Bundle ID | `k3vnc.OpenFoodJournal` |
| Build System | Xcode (xcodebuild), no SPM dependencies |
| Proxy API | Render at `openfoodjournal.onrender.com` (Gemini proxy + Turso REST API) |
| App Entry | `MacrosApp` in `OpenFoodJournalApp.swift` |

## Architecture Overview

```
MacrosApp (creates ModelContainer + 5 @Observable services)
  └─ ContentView (4-tab TabView)
       ├─ Journal tab → DailyLogView (WeeklyCalendarStrip, macro summary, meal sections, RadialMenuButton)
       ├─ Food Bank tab → FoodBankView (searchable, sortable saved food list, swipe-to-edit)
       ├─ History tab → HistoryView (date picker, MacroChartView, day detail)
       └─ Settings tab → SettingsView (goals, health, data export)
```

**Radial FAB**: DailyLogView uses `RadialMenuButton` — a "+" icon at bottom center that fans out Scan / Manual / Containers / Food Bank in an upper semicircle (210°–330°). Supports tap-to-toggle and drag-to-action. Containers are accessed from here instead of a separate tab.

**Service injection**: All services (`NutritionStore`, `ScanService`, `SyncService`, `HealthKitService`, `UserGoals`) are created in `MacrosApp.init()` and passed via `.environment()`. Views consume them with `@Environment(ServiceType.self)`.

**Sheet management**: `DailyLogView` uses a single `DailyLogSheet` enum with `.sheet(item:)` — never multiple booleans.

## Data Models

See [references/models.md](references/models.md) for full property lists.

- **`DailyLog`** — `@Model`, keyed by `@Attribute(.unique) date` normalized to midnight. Owns `[NutritionEntry]` via cascade delete.
- **`NutritionEntry`** — `@Model`, stores core macros (cal/protein/carbs/fat) + dynamic `micronutrients: [String: MicronutrientValue]` + brand/serving/servingCount/servingQuantity/servingUnit/servingMappings. `@Attribute(.externalStorage)` on `sourceImage`.
- **`SavedFood`** — `@Model`, reusable food template in Food Bank. Same fields as NutritionEntry minus meal/log context. Includes `lastUsedAt: Date` (defaults to `createdAt`) for "Last Used" sorting. Created from entries or manual input.
- **`TrackedContainer`** — `@Model`, weight-based container tracking. Snapshots food nutrition at creation time. Start weight → final weight → derived consumption via `consumedServings` math.
- **`UserGoals`** — `@Observable @MainActor`, uses `@ObservationIgnored @AppStorage` for each goal property to avoid property-wrapper conflicts.
- **`MealType`** — enum: `.breakfast`, `.lunch`, `.dinner`, `.snack`
- **`ScanMode`** — enum: `.label`, `.foodPhoto`, `.manual`
- **`ServingSize`** — enum: `.mass(grams:)`, `.volume(ml:)`, `.both(grams:ml:)`. Stores canonical SI values. Has `availableUnits: [String]` (dimension-appropriate unit list), `convert(_:from:to:) -> Double?` (handles same-dimension and cross-dimension via density for `.both`). Static tables: `massConversions` (g/oz/kg/lb), `volumeConversions` (mL/cup/tbsp/tsp/fl oz/L). `type: String` returns "mass"/"volume"/"both" for JSON serialization.
- **`ServingMapping`** — Codable struct with `from: ServingAmount` / `to: ServingAmount` for per-food unit conversions (e.g. 1 cup = 244g). Legacy field kept alongside `ServingSize`.
- **`MicronutrientValue`** — Codable struct with `value: Double` / `unit: String` for dynamic micronutrient storage

## Services

See [references/services.md](references/services.md) for full API contracts.

- **`NutritionStore`** — SwiftData CRUD. `log()`, `fetchLog()`, `fetchLogs()`, `delete()`, `exportCSV()`. Has optional `syncService` reference for fire-and-forget server sync on mutations. **`applySync(_ response: SyncResponse)`** merges a full server response into SwiftData — upserts DailyLogs by date, inserts missing entries/foods by UUID (skips if already local). Private helpers: `buildServingSize(type:grams:ml:) -> ServingSize?`, `parseDate(_ string:) -> Date?`.
- **`SyncService`** — `@Observable @MainActor`. Handles all HTTP communication with the Turso-backed REST API at `/api/*`. Typed API models (`APIEntry`, `APIFood`, `APIContainer`, `APIGoals`, `SyncResponse`). Fire-and-forget pattern: local SwiftData write first, then async sync to server. Injected into views via `@Environment(SyncService.self)`.
- **`ScanService`** — Resizes images to max 2000px (UIGraphicsImageRenderer) then JPEG 0.90 before multipart POST to Render proxy → Gemini → `NutritionEntry` (not yet inserted). User reviews in `ScanResultCard` before committing.
- **`HealthKitService`** — Opt-in Apple Health writes (one `HKQuantitySample` per macro). Reads `activeEnergyBurned`.
- **`UserGoals`** — Daily targets for cal/protein/carbs/fat, persisted in UserDefaults.

## View Map

See [references/views.md](references/views.md) for detailed view hierarchy and notable patterns.

## Scan Flow (Core Value Prop)

```
User taps Scan → CameraController (AVCaptureSession) → JPEG
  → ScanService.scan(image, mode) → multipart POST to /scan
  → Label mode: Gemini 3.1 Flash Lite (fast, low-latency OCR extraction)
  → Food photo mode: Gemini 3.1 Pro w/ thinkingLevel:HIGH (high reasoning)
  → GeminiNutritionResponse → NutritionEntry (NOT inserted yet)
  → ScanResultCard (editable) → User taps "Add to Journal"
  → NutritionStore.log(entry, to: date) → SwiftData insert
  → Auto-creates SavedFood in Food Bank + syncs to Turso
  → HealthKitService.write(entry) if enabled
```

## Turso Sync Architecture

```
iOS App (SwiftData local cache)
  ←→ SyncService (URLSession, fire-and-forget)
  ←→ Express Proxy (server/index.js, server/routes.js)
  ←→ Turso (libSQL, server/db.js)
```

**Strategy**: Local-first, server sync. SwiftData writes happen immediately for UI responsiveness. SyncService fires async tasks to push changes to the server. Failures are silently caught (`try?`) — the local state is always authoritative for the current session.

**Sync-on-launch**: `ContentView` `.task` checks `nutritionStore.fetchAllLogs().isEmpty`. If empty (first install), calls `syncService.fetchAll()` + `nutritionStore.applySync(_:)` to seed SwiftData from the server. Guard skips this on subsequent launches — local data wins.

**Turso migration pattern** (`server/db.js`): Use `PRAGMA table_info(table_name)` to check existing columns before running `ALTER TABLE ... ADD COLUMN`. Idempotent on re-deploy. Example:
```javascript
const info = await db.execute("PRAGMA table_info(nutrition_entries)");
const cols = info.rows.map(r => r.name);
if (!cols.includes("serving_type")) {
  await db.execute("ALTER TABLE nutrition_entries ADD COLUMN serving_type TEXT");
  // ...
}
```

**Server tables**: `daily_logs`, `nutrition_entries`, `saved_foods`, `tracked_containers`, `user_goals` — schema in `server/db.js`.

**API endpoints** (mounted at `/api`):
- `GET /api/sync?since=ISO_TIMESTAMP` — Full or incremental data pull
- `POST/GET/PUT/DELETE /api/entries`, `/api/foods`, `/api/containers`
- `GET/PUT /api/goals`
- Entries auto-create their parent `daily_log` on POST

**Sync integration points** — every view that creates/updates/deletes data has a corresponding `syncService` call:
- `NutritionStore`: entry log/delete/edit
- `EditEntryView`, `ScanResultCard`: SavedFood creation
- `FoodBankView`: SavedFood deletion
- `ContainerListView`: container deletion
- `NewContainerSheet`: container creation + food mapping update
- `CompleteContainerSheet`: container completion

**Environment vars** (Render): `TURSO_DATABASE_URL`, `TURSO_AUTH_TOKEN` (falls back to `file:local.db` for dev)

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

## Entitlements Still Needed (Xcode-only)

- `NSCameraUsageDescription` in Info.plist
- `NSHealthUpdateUsageDescription` + `NSHealthShareUsageDescription`
- HealthKit capability
- iCloud + CloudKit capability

## Conventions

- **Comments**: Explain *why*, not *what*. Entry-level devs should understand each function's purpose.
- **File creation**: Build large files in small chunks to avoid network errors.
- **Retrospectives**: Live in `docs/`. Update when later fixes change the story.
- **Skills**: This file is the project skill. Update it when architecture or requirements change.
- **Commits**: Descriptive messages. Push after every significant change.

**DailyLogView container**: Uses a `List` (not ScrollView+LazyVStack) with `.listStyle(.plain)` + `.scrollContentBackground(.hidden)`. `WeeklyCalendarStrip` and `MacroSummaryBar` are plain List rows with `listRowBackground(Color.clear)` + `listRowSeparator(.hidden)`. Meal sections use `MealSectionView` which returns a `Section{}` that becomes a proper sticky List section header in a List context. `.swipeActions` in `EntryRowView` (trailing delete) and `MealSectionView` (leading edit) fire correctly here.

**RadialMenuButton**: Option bubbles support direct `.onTapGesture` (as well as drag-to-select). A `Color.clear.contentShape(Rectangle()).ignoresSafeArea()` layer behind `GlassEffectContainer` dismisses the menu when tapping outside. The layer is only inserted into the ZStack when `isOpen == true`.

**Swipe mappings**:
- `FoodBankView` row: trailing (swipe left) = Edit (blue) + Delete (red, no full-swipe); leading (swipe right) = Add to journal (green)
- `MealSectionView` row: trailing (swipe left) = Delete (in `EntryRowView`); leading (swipe right) = Edit (in `MealSectionView`'s Button wrapper)

**EditEntryView**: Has full serving-mappings section (same as LogFoodSheet). `@Environment(SyncService.self)` required. Uses shared `AddServingMappingSheet` (defined in LogFoodSheet.swift, internal not private). `addMapping()` calls `nutritionStore.saveAndSyncEntry(entry)`.

## Current State (Last Updated: 2026-03-20)

- App structure complete: all models, services, and views implemented
- 5-tab layout: Journal, Food Bank, Containers, History, Settings
- Builds successfully with `xcodebuild` (generic/platform=iOS)
- Render proxy deployed at `openfoodjournal.onrender.com` (Gemini proxy + Turso REST API)
- Food Bank: save foods from scan/manual entry, browse/search/sort, log to journal
- Container Tracking: create from Food Bank food, enter start weight, complete with final weight → derived nutrition logged
- Serving Mappings: per-food unit conversions (e.g. "1 cup = 244g"), editable in EditEntryView
- WeeklyCalendarStrip: horizontally scrollable week strip with momentum snapping to week boundaries (scrollTargetLayout + scrollTargetBehavior(.viewAligned) + containerRelativeFrame). 52 weeks of history via LazyHStack of WeekID structs. Today button, progress rings per day cell.
- Comprehensive micronutrient tracking: 30 FDA nutrients with daily values, summary view with progress bars
- Turso DB integration: server-side schema + REST API complete, iOS SyncService with fire-and-forget mutations
- Entitlements configured: Camera, HealthKit privacy descriptions in Info.plist
- No unit tests beyond Xcode template stubs
- **TODO**: Deploy server with Turso env vars on Render, implement full sync-on-launch to populate local cache from server
