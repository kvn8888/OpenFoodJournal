# Migrating from Turso to CloudKit: A SwiftData Sync Architecture Overhaul

We took a fully working iOS food journal app that synced to a Turso (libSQL) database via a custom Express REST API, and replaced the entire sync layer with Apple's native CloudKit — cutting ~1,000 lines of sync code while gaining automatic multi-device sync for $0/user. Here's every decision, mistake, and lesson from the migration.

---

## Why We Migrated

The original architecture looked like this:

```
iOS App (SwiftData local cache)
  ←→ SyncService.swift (URLSession, fire-and-forget)
  ←→ Express Proxy (routes.js, 15+ endpoints)
  ←→ Turso (libSQL, hosted on Render)
```

Every mutation — logging a meal, editing an entry, completing a container — required a local SwiftData write *plus* an async HTTP call to push the change to Turso. That's ~15 `Task { try? await syncService.createX() }` blocks scattered across view files, a 200+ line `SyncService.swift` with typed API models, and a 300+ line server with CRUD routes.

CloudKit Private Database offers:
- **$0 forever** — Data lives in the user's own iCloud storage, not ours
- **Automatic sync** — SwiftData + CloudKit = one line of configuration, zero sync code
- **Multi-device** — Works across all the user's devices with the same Apple ID
- **No server to maintain** — No Turso auth tokens, no Render hosting for data routes

The tradeoff: we lose server-side analytics, cross-platform potential (no Android/web), and real-time sync (CloudKit is eventually consistent, seconds-to-minutes). For a personal food journal, these are acceptable.

---

## Step 1: Making Models CloudKit-Compatible

CloudKit imposes strict requirements on SwiftData models that local-only SwiftData doesn't care about. This was the first and most instructive part of the migration.

### Requirement: All Stored Properties Need Defaults

Local SwiftData is fine with non-optional properties that get their values from `init()`. CloudKit is not — it needs to be able to materialize a record *before* all fields arrive over the network. Every stored property must have a default value.

Before:
```swift
@Model
final class NutritionEntry {
    var id: UUID
    var name: String
    var mealType: MealType
    var calories: Double
    // ...
}
```

After:
```swift
@Model
final class NutritionEntry {
    var id: UUID = UUID()
    var name: String = ""
    var mealType: MealType = MealType.snack
    var calories: Double = 0
    // ...
}
```

### Gotcha: Fully Qualified Enum Defaults

This one cost debugging time. SwiftData's `@Model` macro expands your class at compile time, and during expansion, the shorthand `.snack` isn't resolved correctly. You need the fully qualified `MealType.snack`:

```swift
// ❌ Compiles in normal Swift, fails in @Model expansion
var mealType: MealType = .snack

// ✅ Works in @Model
var mealType: MealType = MealType.snack
```

The error message is unhelpful — it just says the macro expansion failed. If you're migrating a SwiftData model to CloudKit and you see cryptic macro errors, check your enum defaults first.

### Requirement: No `@Attribute(.unique)`

Our `DailyLog` had `@Attribute(.unique)` on its `date` property to enforce one log per calendar day. CloudKit can't enforce server-side uniqueness constraints across devices — two devices could create a log for the same day simultaneously. We removed the attribute and rely on app-level dedup via `fetchOrCreateLog(for:)` in `NutritionStore`:

```swift
// Before
@Attribute(.unique) var date: Date

// After — no uniqueness constraint, app handles dedup
var date: Date = Date()
```

### Requirement: Optional Relationships

CloudKit relationships are inherently optional because related records may not have synced yet. Our `DailyLog → [NutritionEntry]` cascade relationship had to become optional:

```swift
// Before
@Relationship(deleteRule: .cascade, inverse: \NutritionEntry.dailyLog)
var entries: [NutritionEntry] = []

// After
@Relationship(deleteRule: .cascade, inverse: \NutritionEntry.dailyLog)
var entries: [NutritionEntry]? = []
```

This cascades through the entire codebase — every `log.entries.count`, `log.entries.reduce`, `log.entries.filter` needs updating. We added a computed property to avoid `?.` everywhere:

```swift
var safeEntries: [NutritionEntry] { entries ?? [] }
```

Then we ran a project-wide find-and-replace: `log.entries.` → `log.safeEntries.` across ~12 files. For writes, we use `log.entries?.append(entry)` with a nil guard.

---

## Step 2: Configuring the ModelContainer

The actual CloudKit configuration is surprisingly simple — one argument to `ModelConfiguration`:

```swift
let config = ModelConfiguration(
    "OpenFoodJournal",
    schema: Schema([DailyLog.self, NutritionEntry.self, SavedFood.self, 
                    TrackedContainer.self, Preferences.self]),
    cloudKitDatabase: .private("iCloud.k3vnc.OpenFoodJournal")
)
```

We also needed a test path that avoids CloudKit entirely (for previews and unit tests):

```swift
let isTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
if isTest {
    let testConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    container = try ModelContainer(for: schema, configurations: testConfig)
} else {
    container = try ModelContainer(for: schema, configurations: config)
}
```

### Entitlements

CloudKit requires three entitlements:
1. `com.apple.developer.icloud-services: [CloudKit]`
2. `com.apple.developer.icloud-container-identifiers: [iCloud.k3vnc.OpenFoodJournal]`
3. `aps-environment: development` (Push Notifications for CloudKit change notifications)

Plus `UIBackgroundModes: [remote-notification]` in Info.plist so the app can receive CloudKit push notifications while backgrounded.

We created `OpenFoodJournal.entitlements` and wired it into the Xcode project via `CODE_SIGN_ENTITLEMENTS` in `project.pbxproj`.

---

## Step 3: The Surgery — Removing 15+ Files of Sync Code

This was the bulk of the work. The Turso sync was deeply integrated — every view that mutated data had a corresponding `syncService` call. Here's a taste of what "fire-and-forget sync" looked like scattered across the codebase:

```swift
// In ManualEntryView, after creating an entry:
if let sync = nutritionStore.syncService {
    Task { try? await sync.createEntry(entry) }
}

// In EditFoodSheet, after deleting a food:
Task { try? await syncService.deleteFood(food.id.uuidString) }

// In ContainerListView, after deleting a container:
Task { try? await syncService.deleteContainer(container.id.uuidString) }
```

### The Removal Checklist

We went file by file, removing `SyncService` references from 15 Swift files:

| File | What Was Removed |
|------|-----------------|
| **NutritionStore.swift** | `syncService` property, all fire-and-forget Tasks, `applySync()` method (~150 lines), `parseDate()`/`buildServingSize()` helpers, renamed `saveAndSyncEntry` → `saveEntry` |
| **ContentView.swift** | `@Environment(SyncService.self)`, `pullFromServer()` method, `.task` modifier |
| **MacroSummaryBar.swift** | Environment, `syncPreferences()` method, `onDismiss:` closures |
| **GoalsEditorView.swift** | Environment, Task block for `updateGoals` |
| **SettingsView.swift** | Environment, "Server Sync" row, preview |
| **ManualEntryView.swift** | Environment, Task for `createFood` |
| **EditEntryView.swift** | Environment, `saveAndSyncEntry` → `saveEntry` |
| **LogFoodSheet.swift** | Environment, Task for `updateFood` |
| **EditFoodSheet.swift** | Environment, 2 Task blocks |
| **FoodBankView.swift** | Environment (unused) |
| **NewContainerSheet.swift** | Environment, Task block |
| **ContainerListView.swift** | Environment, 2 Task blocks |
| **CompleteContainerSheet.swift** | Environment, Task |
| **DailyLogView.swift** | `syncService` usage for `createFood` |
| **OpenFoodJournalApp.swift** | `syncService` state, `.environment()`, wiring |

After removing all references, we deleted `SyncService.swift` entirely, then ran a final grep for any remaining sync-related types:

```bash
grep -rn 'SyncService\|SyncResponse\|SyncError\|APILog\|APIEntry\|APIFood\|APIContainer\|APIGoals\|APIPreferences' --include="*.swift"
```

Zero matches. Clean removal confirmed.

### What We Kept

The Express server at `openfoodjournal.onrender.com` still runs — but only for the `/scan` endpoint that proxies food images to Google's Gemini AI. The `/api/*` Turso CRUD routes still exist on the server (for the developer's personal use on `main` branch), but the iOS app no longer calls them.

---

## Step 4: The Data Migration Tool

Users who've been journaling with the Turso backend have real data that needs to come along. We built a one-time migration view accessible from Settings → "Import from Turso Server":

```swift
struct TursoMigrationView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var serverURL: String = ""
    @State private var isMigrating = false
    // ...
    
    private func runMigration() async {
        let url = URL(string: "\(serverURL)/api/sync")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let syncData = try JSONDecoder().decode(TursoSyncResponse.self, from: data)
        try await importData(syncData)
    }
}
```

The migration:
1. Fetches all records from the old Turso `/api/sync` endpoint
2. De-duplicates by UUID (skips records that already exist locally)
3. Rebuilds DailyLog → NutritionEntry relationships
4. Converts Turso's flat serving fields (`serving_type`, `serving_grams`, `serving_ml`) back into the `ServingSize` enum
5. Writes UserGoals and Preferences to `UserDefaults` (since those use `@AppStorage`, not SwiftData)
6. Calls `modelContext.save()` — CloudKit picks up all the new records and syncs them

The Turso API response types are defined locally in the migration file (private structs), since they're only needed for this one-time import. No reason to pollute the rest of the codebase.

---

## Step 5: The Build Verification Dance

After removing ~1,000 lines of code across 15+ files, the first build attempt is always nerve-wracking. Our approach:

1. **Build with signing disabled** first (isolates compilation errors from provisioning issues):
   ```bash
   xcodebuild -project OpenFoodJournal.xcodeproj -scheme OpenFoodJournal \
     -destination generic/platform=iOS build \
     CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO
   ```

2. **Fix compilation errors** — we had one: the `TrackedContainer` initializer doesn't accept `finalWeight` or `completedDate` parameters (those are set after construction). Quick fix: call the init without those params, then set them as properties.

3. **Build with signing enabled** to verify entitlements:
   ```bash
   xcodebuild -project ... build
   ```
   This correctly failed with provisioning profile errors (expected — the profile needs iCloud + Push Notifications capabilities added in the Apple Developer portal).

Final delta: **27 files changed, +670 insertions, −1,018 deletions.** Net reduction of ~350 lines, and the remaining code is simpler — no sync Tasks, no API response types, no server communication for data operations.

---

## App Store Readiness Audit

While we were at it, we audited the app for App Store submission. Here's what we found:

### ✅ Ready
- Privacy descriptions (Camera, HealthKit read/write)
- App icon (light mode; dark/tinted auto-derived)
- Launch screen (auto-generated)
- App Transport Security (all HTTPS)
- Minimum Functionality (easily passes — AI scanning, journaling, charts, HealthKit, containers)
- Server error handling (comprehensive error enum, 30s timeout, UI feedback)

### ❌ Blockers Found
1. **No Privacy Policy** — Apple requires one for any app that collects data. Need a hosted page + link in app + `PrivacyInfo.xcprivacy` manifest
2. **Missing HealthKit entitlement** — `com.apple.developer.healthkit` wasn't in the entitlements file (iCloud was, HealthKit wasn't)
3. **AGPL-3.0 vs App Store** — The FSF has stated Apple's App Store DRM is incompatible with GPL/AGPL. Solution for sole copyright holders: dual-license (AGPL for public repo, proprietary for App Store distribution)

### ⚠️ Attention Needed
- Render free tier has 30-50s cold starts that may exceed scan timeout
- No onboarding flow for new users
- "Import from Turso Server" in Settings should be hidden for public release
- No retry logic for failed scans

---

## What I'd Do Differently

1. **Start with CloudKit from day one** if you know you're going to the App Store. Adding it later means retrofitting defaults, optional relationships, and removing all the sync plumbing you built.

2. **Use `safeEntries` from the start** instead of non-optional relationship arrays. The optional relationship pattern with a computed accessor is cleaner than finding out later that CloudKit needs it.

3. **Keep API response types in the migration file** — we nearly created them as shared models before realizing they're one-time use. Scope things to where they're needed.

4. **Test provisioning early** — the CloudKit entitlements require a paid Apple Developer account with iCloud capabilities enabled. If you don't have that configured, you'll get signing errors that look like build failures.

---

## Key Takeaways

**CloudKit + SwiftData is significantly simpler than a custom sync backend**, but only if your models are designed for it from the start. The migration cost came entirely from retrofitting CloudKit's requirements onto models designed for local-only SwiftData.

**The "fire-and-forget" pattern spreads like mold.** What starts as a simple `Task { try? await sync.create(x) }` in one view ends up in 15 files. When it's time to remove it, you're doing surgery across the entire codebase. If we'd used CloudKit from the start, none of those Tasks would have existed.

**`@Model` macro expansion is strict about enum defaults.** This isn't documented anywhere obvious. Use `MealType.snack`, never `.snack`, in default value expressions for `@Model` properties.

**One configuration line replaces hundreds of lines of sync code:**
```swift
// This single argument replaces SyncService.swift, applySync(), 
// 15 Task blocks, and all the server CRUD routes:
ModelConfiguration(cloudKitDatabase: .private("iCloud.k3vnc.OpenFoodJournal"))
```

The final architecture is dramatically simpler:

```
iOS App (SwiftData + CloudKit)
  ←→ iCloud Private Database (automatic, free, multi-device)
  
  → ScanService → Express Proxy → Gemini AI (scan-only, stateless)
```

One line of configuration. Zero sync code. Zero server maintenance for data operations. That's the pitch for CloudKit Private Database with SwiftData.
