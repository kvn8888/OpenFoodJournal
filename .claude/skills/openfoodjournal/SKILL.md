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
  └─ ContentView (5-tab TabView)
       ├─ Journal tab → DailyLogView (WeeklyCalendarStrip, macro summary, meal sections, FAB)
       ├─ Food Bank tab → FoodBankView (searchable, sortable saved food list)
       ├─ Containers tab → ContainerListView (active/completed container tracking)
       ├─ History tab → HistoryView (date picker, MacroChartView, day detail)
       └─ Settings tab → SettingsView (goals, health, data export)
```

**Service injection**: All services (`NutritionStore`, `ScanService`, `SyncService`, `HealthKitService`, `UserGoals`) are created in `MacrosApp.init()` and passed via `.environment()`. Views consume them with `@Environment(ServiceType.self)`.

**Sheet management**: `DailyLogView` uses a single `DailyLogSheet` enum with `.sheet(item:)` — never multiple booleans.

## Data Models

See [references/models.md](references/models.md) for full property lists.

- **`DailyLog`** — `@Model`, keyed by `@Attribute(.unique) date` normalized to midnight. Owns `[NutritionEntry]` via cascade delete.
- **`NutritionEntry`** — `@Model`, stores core macros (cal/protein/carbs/fat) + dynamic `micronutrients: [String: MicronutrientValue]` + brand/servingQuantity/servingUnit/servingMappings. `@Attribute(.externalStorage)` on `sourceImage`.
- **`SavedFood`** — `@Model`, reusable food template in Food Bank. Same fields as NutritionEntry minus meal/log context. Created from entries or manual input.
- **`TrackedContainer`** — `@Model`, weight-based container tracking. Snapshots food nutrition at creation time. Start weight → final weight → derived consumption via `consumedServings` math.
- **`UserGoals`** — `@Observable @MainActor`, uses `@ObservationIgnored @AppStorage` for each goal property to avoid property-wrapper conflicts.
- **`MealType`** — enum: `.breakfast`, `.lunch`, `.dinner`, `.snack`
- **`ScanMode`** — enum: `.label`, `.foodPhoto`, `.manual`
- **`ServingMapping`** — Codable struct with `from: ServingAmount` / `to: ServingAmount` for per-food unit conversions (e.g. 1 cup = 244g)
- **`MicronutrientValue`** — Codable struct with `value: Double` / `unit: String` for dynamic micronutrient storage

## Services

See [references/services.md](references/services.md) for full API contracts.

- **`NutritionStore`** — SwiftData CRUD. `log()`, `fetchLog()`, `fetchLogs()`, `delete()`, `exportCSV()`. Has optional `syncService` reference for fire-and-forget server sync on mutations.
- **`SyncService`** — `@Observable @MainActor`. Handles all HTTP communication with the Turso-backed REST API at `/api/*`. Typed API models (`APIEntry`, `APIFood`, `APIContainer`, `APIGoals`, `SyncResponse`). Fire-and-forget pattern: local SwiftData write first, then async sync to server. Injected into views via `@Environment(SyncService.self)`.
- **`ScanService`** — Multipart POST to Render proxy → Gemini → `NutritionEntry` (not yet inserted). User reviews in `ScanResultCard` before committing.
- **`HealthKitService`** — Opt-in Apple Health writes (one `HKQuantitySample` per macro). Reads `activeEnergyBurned`.
- **`UserGoals`** — Daily targets for cal/protein/carbs/fat, persisted in UserDefaults.

## View Map

See [references/views.md](references/views.md) for detailed view hierarchy and notable patterns.

## Scan Flow (Core Value Prop)

```
User taps Scan → CameraController (AVCaptureSession) → JPEG
  → ScanService.scan(image, mode) → multipart POST to /scan
  → Gemini 2.5 Flash → GeminiNutritionResponse
  → NutritionEntry (NOT inserted yet)
  → ScanResultCard (editable) → User taps "Add to Log"
  → NutritionStore.log(entry, to: date) → SwiftData insert
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

## Current State (Last Updated: 2026-03-20)

- App structure complete: all models, services, and views implemented
- 5-tab layout: Journal, Food Bank, Containers, History, Settings
- Builds successfully with `xcodebuild` (generic/platform=iOS)
- Render proxy deployed at `openfoodjournal.onrender.com` (Gemini proxy + Turso REST API)
- Food Bank: save foods from scan/manual entry, browse/search/sort, log to journal
- Container Tracking: create from Food Bank food, enter start weight, complete with final weight → derived nutrition logged
- Serving Mappings: per-food unit conversions (e.g. "1 cup = 244g"), editable in EditEntryView
- WeeklyCalendarStrip with progress rings on DailyLogView
- Comprehensive micronutrient tracking: 30 FDA nutrients with daily values, summary view with progress bars
- Turso DB integration: server-side schema + REST API complete, iOS SyncService with fire-and-forget mutations
- Entitlements configured: Camera, HealthKit privacy descriptions in Info.plist
- No unit tests beyond Xcode template stubs
- **TODO**: Deploy server with Turso env vars on Render, implement full sync-on-launch to populate local cache from server
