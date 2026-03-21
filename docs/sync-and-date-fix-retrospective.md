# Two Bugs, One Root Cause: When Local-First Goes Too Far

OpenFoodJournal had a sync architecture that could charitably be called "write-only cloud" — data flowed up to the server on every mutation but never came back down. Separately, every food entry was quietly logging itself to today's date regardless of what day the user had selected. Both bugs stem from the same design instinct: always trust the client, never look back.

## The Starting Point

### Sync: Push Without Pull

The app's sync strategy was local-first — SwiftData writes happen immediately for UI responsiveness, then a background `Task` fires an HTTP call to push the change to the Turso server. Every create, update, and delete was covered:

```swift
// Fire-and-forget — every mutation pushes to the server
let sync = syncService
Task { try? await sync?.createEntry(entry, date: date) }
```

The pull side? It existed in exactly one place: a `guard logs.isEmpty` check on launch that fetched everything from the server only if SwiftData was completely empty — i.e., first install. After that, the server was never consulted again.

Two pull methods sat in `SyncService`, fully implemented but never called:
- `fetchChanges(since:)` — incremental sync, takes a timestamp
- `fetchGoals()` — fetches calorie/macro targets

The consequence: if you edited your calorie goal to 2400 in Turso directly (or if a push silently failed due to `try?` swallowing the error), the app would happily display 2000 forever.

### Date: Everything Goes to Today

When the user taps a day in the `WeeklyCalendarStrip`, `selectedDate` updates and the journal shows that day's entries. But when the user taps the "+" button to add food, the selected date wasn't flowing through to every entry path:

| Entry Flow | Date Passed? |
|------------|-------------|
| Manual Entry | Yes — `ManualEntryView(defaultDate: selectedDate)` |
| Scan | No — `ScanResultSheet` hardcoded `.now` |
| Food Bank | No — `LogFoodSheet` initialized `logDate` as `.now` |
| Containers | No — `CompleteContainerSheet` hardcoded `.now` |

Three out of four paths silently ignored the selected date. The manual entry path worked by coincidence — it was the first one built, and the date parameter was added then. The others were added later and nobody wired the date through.

---

## Step 1: Sync on Every Launch

The fix for sync was straightforward — remove the `guard logs.isEmpty` gate and use `fetchChanges(since:)` for incremental sync after the first pull:

```swift
private func pullFromServer() async {
    do {
        let response: SyncResponse
        if let lastSync = syncService.lastSyncDate {
            response = try await syncService.fetchChanges(since: lastSync)
        } else {
            response = try await syncService.fetchAll()
        }
        nutritionStore.applySync(response, userGoals: userGoals)
    } catch {
        // Non-fatal — local data still works
    }
}
```

For this to work across launches, `lastSyncDate` needed to be persisted. It was a plain `var` on `SyncService` that reset to `nil` every launch. One change to back it with `UserDefaults`:

```swift
var lastSyncDate: Date? {
    get { UserDefaults.standard.object(forKey: "sync.lastSyncDate") as? Date }
    set { UserDefaults.standard.set(newValue, forKey: "sync.lastSyncDate") }
}
```

### From Insert-Only to Upsert

The bigger change was in `applySync`. The old version was insert-only — it checked if a UUID existed locally and skipped it if so. That's fine for first-install population, but useless for ongoing sync where existing records may have been updated on the server.

The new version fetches all existing records into dictionaries keyed by UUID, then either updates the existing record or inserts a new one:

```swift
let existingEntryMap = Dictionary(
    uniqueKeysWithValues: existingEntries.map { ($0.id, $0) }
)

for apiEntry in response.nutritionEntries {
    if let existing = existingEntryMap[entryUUID] {
        // Update all fields from server
        existing.name = apiEntry.name
        existing.calories = apiEntry.calories
        // ... etc
    } else {
        // Insert new record
        let entry = NutritionEntry(...)
        modelContext.insert(entry)
    }
}
```

This also fixed two gaps: **containers** were never synced down at all (the old `applySync` didn't touch `TrackedContainer`), and **user goals** were never pulled from the server. Both are now handled.

The tradeoff here is that the server wins on conflict. If you edit an entry locally and the server has different data, the next sync overwrites your local changes. For a single-user food journal that's fine — there's no multi-device editing happening. If that changes, we'd need timestamps and a "last write wins" comparison.

---

## Step 2: Threading the Date

The date fix was mechanical but touched six files. The pattern was the same everywhere: add a `logDate` parameter (defaulting to `.now` for backward compatibility), pass `selectedDate` from `DailyLogView`, and use `logDate` instead of `.now` in the logging call.

For the scan flow, there's a subtlety: the camera opens as one sheet, the user takes a photo, the camera dismisses, then the scan result appears as a *separate* sheet after the background Gemini analysis completes. The selected date needs to survive that gap. I captured it in a `@State` property when the scan is initiated:

```swift
@State private var scanDate: Date = .now

// When the user taps "Scan" in the radial menu
RadialMenuItem(
    id: "scan",
    ...
    action: {
        scanDate = selectedDate   // Capture the date now
        presentedSheet = .scan
    }
)

// Later, when the scan result comes back
ScanResultSheet(entry: entry, logDate: scanDate)
```

This means the entry logs to whatever day was selected when the user opened the camera, not when the scan finishes. That's the right behavior — if you're logging yesterday's lunch, the 10-second Gemini delay shouldn't change the target date.

---

## Step 3: Photo Library in the Camera

While working on the scan flow, I added a photo library picker to the camera view. The use case: you took a photo of your meal earlier and want to scan it now.

SwiftUI's `PhotosPicker` from the PhotosUI framework handles the heavy lifting. One button in the top bar, one modifier on the view:

```swift
Button {
    showPhotoPicker = true
} label: {
    Image(systemName: "photo.on.rectangle")
        .frame(width: 40, height: 40)
}
.buttonStyle(.glass)
```

The picker returns a `PhotosPickerItem`, which gets loaded as `Data` and converted to `UIImage` — the same type the camera capture produces. From there, the existing `scanService.scanInBackground(image:mode:)` path handles everything:

```swift
.onChange(of: photoSelection) { _, newItem in
    guard let newItem else { return }
    Task {
        if let data = try? await newItem.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            scanService.scanInBackground(image: image, mode: mode)
            dismiss()
        }
    }
}
```

The mode toggle (Label vs Photo) still applies — if you select a photo of a nutrition label, it should be scanned in label mode with Gemini Flash. If it's a photo of food, photo mode with Gemini Pro.

---

## What's Next

- **Conflict resolution**: The current upsert strategy is server-wins. If the app ever supports multiple devices, we'd need `updated_at` timestamp comparison. For now, single-device makes this moot.
- **Sync feedback**: All sync errors are silently caught. A small indicator in Settings showing last sync time and any errors would help debug connectivity issues.
- **Incremental push retries**: Failed pushes (`try?` swallowing errors) are currently lost forever. A retry queue backed by UserDefaults would close the gap.
- **Delete sync**: The pull doesn't handle server-side deletions yet. If a record is deleted on the server, the local copy persists. This requires either a "deleted_ids" field in the sync response or tombstone records.

---

"Push without pull" is a backup strategy, not a sync strategy. The moment you need the data to flow both ways — even just for goals — you need the pull.
