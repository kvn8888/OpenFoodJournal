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
| Data Layer | SwiftData (`@Model`), CloudKit sync via `.automatic` |
| State Pattern | `@Observable` + `@Environment` injection (no singletons) |
| Bundle ID | `k3vnc.OpenFoodJournal` |
| Build System | Xcode (xcodebuild), no SPM dependencies |
| Proxy API | Render at `macros-proxy.onrender.com` (Gemini 2.5 Flash) |
| App Entry | `MacrosApp` in `OpenFoodJournalApp.swift` |

## Architecture Overview

```
MacrosApp (creates ModelContainer + 4 @Observable services)
  └─ ContentView (3-tab TabView)
       ├─ Journal tab → DailyLogView (date selector, macro summary, meal sections, FAB)
       ├─ History tab → HistoryView (date picker, MacroChartView, day detail)
       └─ Settings tab → SettingsView (goals, health, data export)
```

**Service injection**: All four services (`NutritionStore`, `ScanService`, `HealthKitService`, `UserGoals`) are created in `MacrosApp.init()` and passed via `.environment()`. Views consume them with `@Environment(ServiceType.self)`.

**Sheet management**: `DailyLogView` uses a single `DailyLogSheet` enum with `.sheet(item:)` — never multiple booleans.

## Data Models

See [references/models.md](references/models.md) for full property lists.

- **`DailyLog`** — `@Model`, keyed by `@Attribute(.unique) date` normalized to midnight. Owns `[NutritionEntry]` via cascade delete.
- **`NutritionEntry`** — `@Model`, stores core macros (cal/protein/carbs/fat) + optional extended fields. `@Attribute(.externalStorage)` on `sourceImage`.
- **`UserGoals`** — `@Observable @MainActor`, uses `@ObservationIgnored @AppStorage` for each goal property to avoid property-wrapper conflicts.
- **`MealType`** — enum: `.breakfast`, `.lunch`, `.dinner`, `.snack`
- **`ScanMode`** — enum: `.label`, `.foodPhoto`, `.manual`

## Services

See [references/services.md](references/services.md) for full API contracts.

- **`NutritionStore`** — SwiftData CRUD. `log()`, `fetchLog()`, `fetchLogs()`, `delete()`, `exportCSV()`.
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

## Current State (Last Updated: 2026-03-19)

- App structure complete: all models, services, and views implemented
- Builds successfully with `xcodebuild` after fixing 6 compiler errors (see `docs/retrospective.md`)
- Render proxy (`macros-proxy.onrender.com`) does NOT exist yet — scan will throw network error
- Entitlements not configured in Xcode — camera and HealthKit prompts won't appear
- No unit tests beyond Xcode template stubs
