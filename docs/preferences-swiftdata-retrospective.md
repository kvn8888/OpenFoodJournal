# Retrospective: Migrating @AppStorage to SwiftData for Syncable Preferences

**Date**: 2025-07-21  
**Commit**: `7b8c3a8` (feat), `e442be4` (docs)  
**Scope**: Preferences model, Turso sync, MacroSummaryBar migration

## The Problem

OpenFoodJournal has a daily macro summary bar with 5 configurable "ring slots" — each slot can display a macro (protein, carbs, fat, calories) or any micronutrient (sodium, fiber, etc.). Originally, these slot configs were stored using `@AppStorage` (UserDefaults):

```swift
@AppStorage("summaryBar.slot1") private var slot1 = "macro_protein"
@AppStorage("summaryBar.slot2") private var slot2 = "macro_carbs"
// ... etc
```

This worked fine for a single device, but had a critical limitation: **`@AppStorage` doesn't sync**. The app already has a Turso-backed sync system that keeps nutrition entries, saved foods, and containers in sync across devices. Preferences were the missing piece — if a user customized their rings on their iPhone, their iPad would still show defaults.

## The Solution

Replace `@AppStorage` with a SwiftData `@Model` that slots into the existing sync pipeline.

### 1. The Preferences Model (Singleton Pattern)

SwiftData models are designed for collections (many rows), but preferences are inherently a singleton (one row per user). The key design decision was a static factory:

```swift
@Model
final class Preferences {
    // Each slot stores a nutrient ID string like "macro_protein" or "sodium"
    var ringSlot1: String = "macro_protein"
    var ringSlot2: String = "macro_carbs"
    var ringSlot3: String = "macro_fat"
    var ringSlot4: String = ""  // empty = shows + button
    var ringSlot5: String = ""
    
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    
    init() {}
    
    /// Fetches the single Preferences row, or creates one with defaults.
    @MainActor
    static func current(in context: ModelContext) -> Preferences {
        let descriptor = FetchDescriptor<Preferences>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let prefs = Preferences()
        context.insert(prefs)
        return prefs
    }
}
```

**Why a static factory?** SwiftData doesn't have a built-in "singleton" concept. Using `@Query` in views will return an array. The factory ensures exactly one row exists — called once at app startup to seed the store, then views use `@Query` to observe it.

**Gotcha**: The factory is `@MainActor` because `ModelContext` operations must happen on the main actor in SwiftUI apps. The `@discardableResult` annotation on the call site in `MacrosApp.init()` makes it clear we're calling for the side effect (seeding), not the return value.

### 2. Migrating Views from @AppStorage to @Query

The before/after in `MacroSummaryBar` is instructive:

**Before** (5 separate UserDefaults keys):
```swift
@AppStorage("summaryBar.slot1") private var slot1 = "macro_protein"
@AppStorage("summaryBar.slot2") private var slot2 = "macro_carbs"
@AppStorage("summaryBar.slot3") private var slot3 = "macro_fat"
@AppStorage("summaryBar.slot4") private var slot4 = ""
@AppStorage("summaryBar.slot5") private var slot5 = ""
```

**After** (single model query):
```swift
@Query private var allPrefs: [Preferences]
private var prefs: Preferences? { allPrefs.first }

private var slotIDs: [String] {
    guard let p = prefs else {
        return ["macro_protein", "macro_carbs", "macro_fat", "", ""]
    }
    return [p.ringSlot1, p.ringSlot2, p.ringSlot3, p.ringSlot4, p.ringSlot5]
}
```

The `@Query` approach is elegant because SwiftData automatically observes changes — when any sheet modifies `prefs.ringSlot1`, the summary bar re-renders immediately without manual state management.

### 3. Sheet Bindings with @Bindable

The trickiest part was making sheets edit the model directly. SwiftData's `@Bindable` property wrapper enables two-way binding to model properties:

```swift
private struct NutrientPickerSheet: View {
    @Bindable var preferences: Preferences
    let slotIndex: Int
    
    private func setSlot(_ value: String) {
        switch slotIndex {
        case 1: preferences.ringSlot1 = value
        case 2: preferences.ringSlot2 = value
        case 3: preferences.ringSlot3 = value
        case 4: preferences.ringSlot4 = value
        default: preferences.ringSlot5 = value
        }
        preferences.updatedAt = Date()
    }
}
```

The parent view passes the model reference when presenting the sheet:
```swift
.sheet(isPresented: $showEditSheet, onDismiss: syncPreferences) {
    if let p = prefs {
        SlotEditSheet(preferences: p, allSlotIDs: slotIDs)
    }
}
```

**Key insight**: The `if let p = prefs` unwrap is necessary because `allPrefs.first` returns optional. The sheet only presents if preferences exist (which they always should after app init seeds them).

### 4. The Edit Sheet's NavigationLink Pattern

The `SlotEditSheet` uses `ReferenceWritableKeyPath<Preferences, String>` to avoid duplicating slot-switching logic:

```swift
private func slotRow(index: Int, keyPath: ReferenceWritableKeyPath<Preferences, String>) -> some View {
    NavigationLink {
        InlineNutrientPicker(
            preferences: preferences,
            keyPath: keyPath,
            otherSlotIDs: otherIDs
        )
    } label: {
        // Show current nutrient name or "Empty — tap to add"
    }
}
```

Each `InlineNutrientPicker` receives the keyPath and writes directly:
```swift
private func select(_ value: String) {
    preferences[keyPath: keyPath] = value
    preferences.updatedAt = Date()
    dismiss()  // Pops back to the edit sheet
}
```

This is a clean pattern for editing individual properties of a model inside a NavigationStack — the keyPath eliminates the need for a slot-index-to-property switch statement in the picker.

### 5. Full-Stack Sync

**Server (Turso)**:
```sql
CREATE TABLE IF NOT EXISTS preferences (
  id TEXT PRIMARY KEY DEFAULT 'default',
  ring_slot_1 TEXT NOT NULL DEFAULT 'macro_protein',
  ring_slot_2 TEXT NOT NULL DEFAULT 'macro_carbs',
  ring_slot_3 TEXT NOT NULL DEFAULT 'macro_fat',
  ring_slot_4 TEXT NOT NULL DEFAULT '',
  ring_slot_5 TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
)
```

The table uses a singleton pattern (`id = 'default'`) similar to the client. `INSERT OR IGNORE` seeds it on first deploy.

**API Routes**:
- `GET /api/preferences` — Returns the singleton row (or defaults if somehow missing)
- `PUT /api/preferences` — Updates all 5 slots atomically
- `/api/sync` response now includes `preferences: { ring_slot_1, ... }` for initial pull

**iOS Sync Integration**:

Push (fire-and-forget on sheet dismiss):
```swift
private func syncPreferences() {
    guard let p = prefs else { return }
    Task {
        try? await syncService.updatePreferences(p)
    }
}
```

Pull (on initial sync):
```swift
// In NutritionStore.applySync()
if let apiPrefs = response.preferences {
    let prefs = Preferences.current(in: modelContext)
    if let s1 = apiPrefs.ringSlot1 { prefs.ringSlot1 = s1 }
    // ... etc
}
```

The `try?` on push is intentional — this follows the app's established "local-first, sync-best-effort" pattern. If the server is unreachable, the local preferences are still saved in SwiftData.

## What Went Well

1. **Minimal API surface**: One new model file, one new API struct, two new routes. The Preferences model is deliberately simple — just strings and dates.

2. **SwiftData observation is free**: Unlike `@AppStorage` which requires manual `objectWillChange` coordination, `@Query` automatically re-renders when the model changes. No `onChange` handlers needed.

3. **Consistent with existing patterns**: Fire-and-forget sync, `@Environment` injection, `@Bindable` sheets — all match what the codebase already does.

## What I Got Wrong

1. **First tried `SyncService.shared`**: My initial sync call used a singleton pattern (`SyncService.shared`) that doesn't exist. The app uses `@Environment(SyncService.self)` injection exclusively. Had to add `@Environment(SyncService.self) private var syncService` to `MacroSummaryBar`. This is a reminder to check existing patterns before assuming.

2. **Property name mismatch risk**: The column names in Turso (`ring_slot_1`) must match the `CodingKeys` in `APIPreferences` (`ring_slot_1` → `ringSlot1`) which must match the property names in the `Preferences` model (`ringSlot1`). Three layers of naming to keep in sync. A typo at any layer would cause silent data loss. I verified all three aligned before committing.

## Design Decisions

**Why not merge UserGoals into Preferences?** UserGoals stores daily calorie/protein/carbs/fat targets using `@AppStorage` and is injected as `@Environment(UserGoals.self)` throughout the entire app. Merging it would require touching every view that reads goals. The Preferences model is specifically for UI customization (ring slots), not nutritional targets. Keeping them separate respects the single-responsibility principle and avoids a massive refactor.

**Why `@Query` instead of `@Environment`?** I considered making Preferences an `@Observable` class injected via `@Environment`, similar to UserGoals. But SwiftData models are already observable via `@Query`, and using `@Query` means the preferences automatically persist without manual save calls. The trade-off is that `@Query` returns an array (requiring `.first` unwrap), but this is a small ergonomic cost.

**Why `onDismiss` for sync instead of `onChange`?** Syncing on every keystroke would be wasteful. The `onDismiss` closure fires once when the sheet closes, batching all changes into a single API call. This matches the user's mental model: "I'm done editing, save it."

## Lessons for Other Developers

1. **SwiftData singletons need a factory**: If your model represents a single-row config (preferences, settings), create a `current(in:)` factory that fetches-or-creates. Seed it at app launch.

2. **`@Bindable` is your friend for model editing**: When a sheet needs to modify a SwiftData model, pass it as `@Bindable var model: MyModel`. This gives you automatic two-way binding without manual state management.

3. **`ReferenceWritableKeyPath` eliminates switch statements**: If you have multiple properties of the same type on a model (like 5 string slots), pass a keyPath to editing views instead of an index + switch.

4. **Fire-and-forget sync = `try?` + `Task {}`**: For non-critical sync (user won't lose data if it fails), wrap the network call in `try?` inside a detached `Task`. The UI stays responsive and the local state is authoritative.

5. **Match your API column names early**: When building a full-stack feature (model → table → API → client), define the column names first and work outward. Column name mismatches are the #1 source of silent data bugs in REST APIs.

## Files Changed

| File | Change |
|------|--------|
| `OpenFoodJournal/Models/Preferences.swift` | **New** — SwiftData @Model with ringSlot1..5, factory |
| `OpenFoodJournal/OpenFoodJournalApp.swift` | Added `Preferences.self` to ModelContainer, seed in init |
| `OpenFoodJournal/Services/SyncService.swift` | Added `APIPreferences` struct, `updatePreferences()`, `fetchPreferences()`, preferences in `SyncResponse` |
| `OpenFoodJournal/Services/NutritionStore.swift` | Added preferences merge in `applySync()` |
| `OpenFoodJournal/Views/DailyLog/MacroSummaryBar.swift` | Migrated from @AppStorage to @Query, all sheets use @Bindable, fire-and-forget sync on dismiss |
| `server/db.js` | Added `preferences` table + seed |
| `server/routes.js` | Added `GET/PUT /api/preferences` routes, included in sync response |
