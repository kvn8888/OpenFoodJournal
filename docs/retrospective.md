# From Xcode Template to a Real App: Building Macros in One Session

We started with a stock CoreData Xcode template — the one with `Item`, `Persistence.swift`, and a `NavigationView` listing timestamps — and turned it into a fully structured iOS 26 food journaling app. This document is the honest account of every decision, every mistake, and why the final code looks the way it does.

---

## The Starting Point

The project was a fresh Xcode "App" target with CoreData checked. That gave us:

- `Persistence.swift` — a boilerplate `NSPersistentContainer` wrapper
- `ContentView.swift` — a `NavigationView` (deprecated since iOS 16) listing `Item` entities by timestamp
- `OpenFoodJournal.xcdatamodeld` — a single `Item` entity with one `timestamp: Date` attribute

None of this was useful. The PRD called for SwiftData (not CoreData), `@Observable` (not `ObservableObject`), the iOS 18 `Tab` API, and Liquid Glass throughout. The template was a starting gun, not a foundation.

---

## Step 1: Designing the Architecture Before Writing Any Code

Before touching a file, we used a planning agent to design the full structure. This was worth doing because the data model has a relationship that's easy to get wrong: a `NutritionEntry` belongs to a `DailyLog`, and `DailyLog` is keyed by calendar date.

The key decisions made upfront:

**SwiftData over CoreData** — SwiftData uses the `@Model` macro, composes with SwiftUI's `@Environment`, and gets CloudKit sync for free with one line. CoreData requires a coordinator, context threading discipline, and manual CloudKit setup.

**`@Observable` over `ObservableObject`** — iOS 17's `@Observable` macro replaces the entire `@Published` + `ObservableObject` pattern. Views only re-render when the specific properties they read change, not the whole object. It also means you use `@State` to own objects instead of `@StateObject`, which is one fewer thing to explain to yourself at 2am.

**Services injected via `@Environment`** — Three `@Observable` classes (`NutritionStore`, `ScanService`, `HealthKitService`) are created once in `MacrosApp`, passed down via `.environment()`, and consumed with `@Environment(ServiceType.self)`. No singletons, no global state.

**Enum-based sheet management** — A single `DailyLogSheet` enum with `.sheet(item:)` instead of three separate `@State private var showX: Bool` properties. One state property, one sheet modifier, no "two sheets open at once" bugs.

```swift
enum DailyLogSheet: Identifiable {
    case scan
    case manualEntry
    case editEntry(NutritionEntry)

    var id: String {
        switch self {
        case .scan: "scan"
        case .manualEntry: "manualEntry"
        case .editEntry(let e): "edit-\(e.id)"
        }
    }
}
```

---

## Step 2: The Data Models

Three models, two of them SwiftData `@Model` classes and one a plain `@Observable`.

**`NutritionEntry`** holds everything from a single food log: the core four macros (calories, protein, carbs, fat) plus optional extended fields (fiber, sugar, sodium, etc.) that only get populated from label scans. Large image data gets `@Attribute(.externalStorage)` — this tells SwiftData to store the bytes in a separate file rather than inline in the SQLite row, keeping queries fast.

**`DailyLog`** has `@Attribute(.unique)` on its `date` property (normalized to midnight), which prevents duplicate logs for the same day at the database level. The `entries` relationship uses `deleteRule: .cascade` — delete the log, delete all its entries. Computed totals (`totalCalories`, etc.) are plain Swift `var`s, not stored attributes. SwiftData would try to persist them otherwise.

**`UserGoals`** is the interesting one. It uses `UserDefaults` via `@AppStorage` but needs to be `@Observable` so views update when goals change. The problem: `@AppStorage` is itself a property wrapper, and `@Observable` wraps stored properties too. Two property wrapper transformations on the same property is a compiler error.

The fix is `@ObservationIgnored`:

```swift
@Observable @MainActor final class UserGoals {
    // @ObservationIgnored prevents the conflict between
    // @Observable's tracking and @AppStorage's storage
    @ObservationIgnored @AppStorage("goals.calories") var dailyCalories: Double = 2000
    @ObservationIgnored @AppStorage("goals.protein")  var dailyProtein: Double = 150
}
```

`@ObservationIgnored` opts that property out of `@Observable`'s tracking — but `@AppStorage` already notifies SwiftUI through UserDefaults KVO, so views still update. Two notification systems, one property, zero conflicts.

---

## Step 3: The Scanning Pipeline

The camera pipeline is the core value prop of the app — "log a meal in under 15 seconds" — so it got the most architectural thought.

The flow is: `AVCaptureSession` → JPEG → multipart POST to Render proxy → Gemini 2.5 Flash → JSON → `NutritionEntry`.

`CameraController` is an `@Observable @MainActor` class that owns the `AVCaptureSession`. It's `@MainActor` because it drives UI state (`isReady`, `torchOn`), but photo capture itself needs to bridge to a delegate callback. We handle that with `CheckedContinuation` — Swift's structured concurrency bridge for callback-based APIs:

```swift
func capturePhoto() async -> UIImage? {
    await withCheckedContinuation { continuation in
        photoContinuation = continuation
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// Delegate fires on AVFoundation's queue (nonisolated)
nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
    Task { @MainActor in photoContinuation?.resume(returning: image) }
}
```

`nonisolated` tells the compiler "this function runs off the main actor" — required because `AVCapturePhotoCaptureDelegate` is called on AVFoundation's internal queue, not the main thread. We then hop back to `@MainActor` explicitly with `Task { @MainActor in }` to touch the continuation safely.

The `ScanService` sends a `multipart/form-data` POST (image + mode string) to the Render proxy, decodes a `GeminiNutritionResponse: Codable`, and maps it to a `NutritionEntry` that is **not yet inserted** into SwiftData. The user sees it in `ScanResultCard`, edits what's wrong, then taps "Add to Log" — that's when it gets inserted. This "review before committing" pattern is what keeps the 15-second promise realistic.

---

## Step 4: The Liquid Glass UI

iOS 26 introduced Liquid Glass — a material that blurs, refracts, and reacts to touch. The rules are simple but strict:

1. Multiple glass elements that coexist must be wrapped in `GlassEffectContainer`. Glass can't sample through other glass — they need a shared sampling region.
2. `.glassEffect()` goes **after** layout and appearance modifiers.
3. `.interactive()` only on elements that actually respond to input.
4. `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` for buttons.

The floating scan FAB uses `glassEffectID` with a `@Namespace` so the button morphs smoothly when it expands:

```swift
GlassEffectContainer(spacing: 12) {
    HStack(spacing: 12) {
        if isExpanded {
            Button("Manual") { ... }
                .buttonStyle(.glass)
                .glassEffectID("manual", in: namespace)
                .transition(.scale.combined(with: .opacity))
        }
        Button { ... } label: { ... }
            .buttonStyle(.glassProminent)
            .glassEffectID("scan", in: namespace)
    }
}
```

Because the deployment target is iOS 26.2, there's no `#available` gating needed anywhere. The whole app assumes Liquid Glass.

---

## The Gotcha: Six Compiler Errors That Shared Two Root Causes

After the initial implementation, `xcodebuild` (Swift's equivalent of `tsc --noEmit`) reported errors across six files. They looked unrelated in Xcode's issue navigator, but they came from just two mistakes:

### Root Cause 1: `.animation(.easeInOut(value:), value:)` — three files

`.easeInOut` on `Animation` is a **static property**, not a function. Writing `.easeInOut(value: x)` tries to call it as a function, which fails. The `value:` parameter belongs to the outer `.animation(_:value:)` modifier, not the animation itself.

```swift
// Wrong — tries to call .easeInOut as a function
.animation(.easeInOut(value: mode), value: mode)

// Correct — .easeInOut is the animation, value: tracks changes
.animation(.easeInOut, value: mode)
```

This appeared in `MacroRingView`, `MacroChartView`, and `ScanCaptureView`. One pattern, three files.

### Root Cause 2: Missing `import SwiftData` — five files

`ModelContainer` is defined in the `SwiftData` module, not `SwiftUI`. View files that only referenced `ModelContainer` in `#Preview` blocks compiled fine in Xcode (which imports everything transitively in previews) but failed under `xcodebuild` with `Cannot find 'ModelContainer' in scope`.

The fix was adding `import SwiftData` to every file with a preview that used `ModelContainer.preview`. This is a useful reminder: `xcodebuild` is stricter than Xcode's IDE compilation, and catches missing imports that the preview system masks.

### Root Cause 3: `ModelContainer(schema:configurations:)` doesn't exist

The initializer is `ModelContainer(for:configurations:)` — it takes the model types directly, not a `Schema` object. The `Schema` wrapper is only needed when you want to pass it explicitly (e.g. for migration).

```swift
// Wrong
ModelContainer(schema: Schema([NutritionEntry.self, DailyLog.self]), configurations: [config])

// Correct
ModelContainer(for: NutritionEntry.self, DailyLog.self, configurations: config)
```

### Root Cause 4: `private` enum inaccessible across structs in the same file

`ManualEntryView` had a `private enum Field` for focus state management. `MacroInputRow` — a separate `private struct` in the same file — referenced `ManualEntryView.Field` in its parameter types. Swift's `private` is scoped to the **declaration context** (the enclosing type), not the file. `MacroInputRow` can't see inside `ManualEntryView`.

The fix: lift the enum out of `ManualEntryView`, rename it `ManualEntryField`, and make it `fileprivate` so everything in the file can use it.

```swift
// fileprivate = visible to all types in this file, nothing outside
fileprivate enum ManualEntryField: Hashable {
    case name, calories, protein, carbs, fat, fiber, sugar, sodium, servingSize
}
```

---

## The Revision: `HierarchicalShapeStyle` vs `Color`

One error in `MacroSummaryBar` looked simple but exposed a SwiftUI type inference subtlety:

```swift
// Error: HierarchicalShapeStyle and Color are not the same type
.foregroundStyle(remaining > 0 ? .primary : .orange)
```

SwiftUI's `.primary` resolves to `HierarchicalShapeStyle`. `.orange` resolves to `Color`. A ternary expression in Swift requires both branches to be the **same type** — the compiler can't unify them. The fix is explicit `Color.primary`, which resolves both sides to `Color`:

```swift
.foregroundStyle(remaining > 0 ? Color.primary : Color.orange)
```

This is a pattern worth memorizing: whenever a ternary with SwiftUI style shorthands fails to compile, prefix one side with the concrete type and the other side will resolve to match.

---

## What's Next

The app builds and the architecture is sound. What's left before it's actually usable:

**Entitlements to add in Xcode** (can't be done from the CLI):
- `NSCameraUsageDescription` in Info.plist
- `NSHealthUpdateUsageDescription` + `NSHealthShareUsageDescription`  
- HealthKit capability
- iCloud + CloudKit capability (required for `cloudKitDatabase: .automatic`)

**The Render proxy** — `ScanService` points to `https://macros-proxy.onrender.com` which doesn't exist yet. The proxy is a small Node/Python service that accepts the multipart POST, forwards to Gemini 2.5 Flash with a structured output prompt, validates the JSON, and returns it. Without it, the scan button captures a photo and then throws a network error.

**Things I'd do differently:**
- The `CameraController` being `@Observable` inside a `View`'s `@State` works, but a dedicated `@MainActor` actor with explicit state isolation would be cleaner for the async/delegate boundary.
- `DailyLog.fetchLog()` in `NutritionStore` runs a `FetchDescriptor` every time `DailyLogView.body` recomputes. A `@Query` macro in the view would be more efficient but requires passing the date predicate dynamically — which SwiftData's `@Query` doesn't support natively yet. The current approach is correct, just not zero-cost.
- The `UserGoals` `@ObservationIgnored` pattern is correct but fragile — a future developer adding a new `@AppStorage` property without `@ObservationIgnored` will get a cryptic compiler error. Worth a code comment on each property explaining why.

---

The hardest part of this session wasn't the code — it was that `xcodebuild` and Xcode's IDE compiler disagree on what's valid, and you don't find out until you run the build CLI. Run `xcodebuild` early and often.

---

# Flexible Serving Sizes & Container Weight Tracking

Building a food journal that works like real humans eat — not one serving at a time, but by the handful, by the cup, by the "I ate some cereal from this box over two days." This retrospective covers the design and implementation of two complementary features: per-food unit mappings and container-based weight tracking.

---

## The Problem

Most food tracking apps assume you eat in neat, label-defined servings. Real life is messier:

1. **Unit confusion**: A nutrition label says "serving size: 39g" but you measured 1 cup of cereal. How many grams is that for *this specific cereal*? Different cereals have different densities.
2. **Grazing over time**: You open a box of crackers, eat from it over several days, and want to know total consumed nutrition — not per-serving, per-day math.

Both problems share a root cause: the app needs to understand the *relationship between weight and servings* for each specific food.

---

## Design Decision: Snapshot vs. Reference

The biggest architectural decision was whether `TrackedContainer` should *reference* a `SavedFood` (live relationship) or *snapshot* the nutrition data at creation time.

We chose **snapshot**. Here's why:

```swift
@Model
final class TrackedContainer {
    // Snapshotted — not a @Relationship
    var foodName: String
    var caloriesPerServing: Double
    var proteinPerServing: Double
    var carbsPerServing: Double
    var fatPerServing: Double
    var micronutrientsPerServing: [String: MicronutrientValue]
    var gramsPerServing: Double

    // Just an ID for "re-track" convenience
    var savedFoodID: UUID?
    // ...
}
```

**Why not a relationship?** If the user edits the SavedFood later (corrects a calorie count), that would retroactively change the nutrition derived from *already completed* containers. The container's math should reflect what the food *was* when tracking started. This is the same reason financial ledgers snapshot prices at transaction time.

**Tradeoff**: More storage (duplicated nutrition data per container). Worth it for data integrity.

---

## The Math: Weight-Based Nutrition Derivation

The core formula is simple:

```
consumed_grams = start_weight - final_weight
servings_consumed = consumed_grams / grams_per_serving
nutrient_total = servings_consumed × nutrient_per_serving
```

The container weight (box, bag, bowl) cancels out because both measurements include it. No tare weight needed if the user is consistent.

In code:

```swift
extension TrackedContainer {
    var consumedGrams: Double? {
        guard let finalWeight else { return nil }
        return max(0, startWeight - finalWeight)
    }

    var consumedServings: Double? {
        guard let grams = consumedGrams, gramsPerServing > 0 else { return nil }
        return grams / gramsPerServing
    }

    var consumedCalories: Double? {
        guard let servings = consumedServings else { return nil }
        return servings * caloriesPerServing
    }
}
```

The `max(0, ...)` guard prevents negative values if the user enters a final weight greater than start (which would mean they added food, not consumed it — handle gracefully rather than crash).

---

## Per-Food Serving Mappings

The serving mapping system uses a simple `from → to` pair structure:

```swift
struct ServingAmount: Codable, Hashable, Sendable {
    var value: Double  // e.g. 1.0
    var unit: String   // e.g. "cup"

    var displayString: String {
        let formatted = value == floor(value)
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
        return "\(formatted) \(unit)"
    }
}

struct ServingMapping: Codable, Hashable, Sendable {
    var from: ServingAmount  // e.g. 1 cup
    var to: ServingAmount    // e.g. 244 g
}
```

**Why `from/to` instead of just `unitName: String, gramsEquivalent: Double`?** Because not all conversions go to grams. A user might map "1 serving = 3 cookies" for a snack, or "1 scoop = 2 tbsp" for protein powder. The bidirectional pair is more flexible.

These mappings live on both `NutritionEntry` and `SavedFood` as `[ServingMapping]`, stored as JSON via Codable. When a food is saved to the Food Bank, its mappings travel with it.

---

## The Container UI Flow

Three views handle the lifecycle:

### 1. NewContainerSheet — "Start Tracking"
```
Pick food from Food Bank → Enter grams/serving + starting weight → Create
```

The sheet is a two-step wizard: first pick a food (reusing `SavedFoodRowView` for consistency), then enter the numeric weight data. Pre-fills grams-per-serving if the food has a gram-based serving mapping.

### 2. ContainerListView — "Overview"
Uses two `@Query` filters to show active and completed containers in separate sections:

```swift
@Query(
    filter: #Predicate<TrackedContainer> { $0.finalWeight == nil },
    sort: \TrackedContainer.startDate,
    order: .reverse
)
private var activeContainers: [TrackedContainer]
```

Active containers get a "Weigh" button. Completed ones show macro pills with the derived nutrition.

### 3. CompleteContainerSheet — "Log It"
Enter final weight → see derived nutrition in real-time → pick meal type → log to journal. The "Calculate" button triggers an animated reveal of the results section, so the math feels interactive rather than automatic.

The key interaction: the user can see *exactly* how many servings they consumed and what that means nutritionally before committing.

---

## What I Got Right

1. **Snapshot pattern** kept data integrity clean with zero cascade issues
2. **`from/to` serving pairs** are more flexible than a simple grams-equivalent and require no future migration when users want non-gram conversions
3. **Reusing `SavedFoodRowView`** in the food picker gave instant UI consistency without new code
4. **Two-step wizard** for new containers prevents overwhelming the user with one giant form
5. **`@Query` with predicates** for active/completed split means the view automatically updates when a container is completed — no manual refresh needed

## What I Got Wrong (or Could Improve)

1. **No intermediate logging**: Currently you can only log nutrition when the container is "completed." A user eating from a cereal box over a week might want to log daily estimates. The model supports this (add a `weighIn` method that creates entries for partial consumption) but the UI doesn't surface it yet.
2. **No unit conversion in logging**: The serving mapping data exists on the model but there's no UI yet for *choosing* a unit when logging from the Food Bank (e.g., "log 1 cup" instead of always using the default serving).
3. **Alert-based mapping editor**: The "Add Unit Mapping" UI uses an `.alert()` with text fields, which is cramped on iPhone. A dedicated sheet would be better for discoverability and usability.

---

## Lessons Learned

- **Snapshot > Reference** for any entity that represents "what happened" rather than "what exists now." This applies to invoices, transactions, container tracking — anything where historical accuracy matters.
- **SwiftData `@Query` with `#Predicate` is powerful** but the predicate must only reference stored properties (not computed ones). We filter on `finalWeight == nil` instead of the computed `isActive` property.
- **Build early, build often**: Every model change was followed by a `xcodebuild` run. Codable conformance on custom types (`[String: MicronutrientValue]`, `[ServingMapping]`) can fail silently in previews but break in real builds.

---

# Adding Turso as a Cloud Database: Server-First Sync for a SwiftData App

This section covers adding Turso (a hosted SQLite-compatible database via libSQL) as the primary cloud database for OpenFoodJournal, with SwiftData remaining as the local cache. The goal: every food logged, every container tracked, every goal changed — persisted to the cloud, accessible from any device.

---

## The Architecture Decision: Why Not Just CloudKit?

The app already had CloudKit sync via SwiftData's `.automatic` configuration:

```swift
let config = ModelConfiguration(
    isStoredInMemoryOnly: false,
    cloudKitDatabase: .automatic
)
```

CloudKit is zero-config and "just works" for Apple-to-Apple sync. But it has real limitations:

1. **Apple-only**: No web dashboard, no Android client, no way to query the data outside Apple's ecosystem
2. **Opaque sync**: You can't easily debug what's been synced, run migrations, or inspect the data
3. **No server-side logic**: Can't run aggregations, scheduled jobs, or trigger notifications from the database
4. **Rate limits**: CloudKit has request limits that are fine for personal use but would complicate any future multi-user features

Turso gives us a real SQL database we can query from anywhere, with a REST API we control.

---

## Choosing the Sync Pattern: Local-First with Server Push

There are three common patterns for mobile-to-server sync:

### 1. Server-first (read from server, write to server)
Every operation requires network. Fast for reads if cached, but the app is useless offline.

### 2. Local-first with background sync
Write locally, sync in the background. The app works offline, but conflict resolution gets complex.

### 3. Local-first with fire-and-forget push
Write to SwiftData immediately (user sees instant feedback), then fire an async task to push the change to the server. If the push fails, the local state is still correct — the server catches up later.

**We chose option 3.** Here's why:

- The app is a personal food journal — there's no multi-device concurrent editing to worry about
- Loss of a single sync is not catastrophic (you still have local data)
- The pattern is simple to implement: no queue, no retry logic, no conflict resolution
- Adding retry/queue later is a natural extension without rearchitecting

---

## The Server Side: Express + Turso in 700 Lines

### Database Module (`server/db.js`)

The Turso client setup is minimal by design — a single file that creates the connection and runs migrations:

```javascript
const { createClient } = require("@libsql/client");

// Turso client — uses env vars in production, local SQLite file for dev
const db = createClient({
  url: process.env.TURSO_DATABASE_URL || "file:local.db",
  authToken: process.env.TURSO_AUTH_TOKEN,
});
```

The `file:local.db` fallback is key for development — no Turso account needed to work locally.

### Schema Design

Five tables mirror the five SwiftData models:

```sql
-- daily_logs: one row per calendar day
CREATE TABLE IF NOT EXISTS daily_logs (
    id TEXT PRIMARY KEY,
    date TEXT UNIQUE NOT NULL,  -- YYYY-MM-DD, normalized
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- nutrition_entries: each food logged to a day
CREATE TABLE IF NOT EXISTS nutrition_entries (
    id TEXT PRIMARY KEY,
    daily_log_id TEXT NOT NULL REFERENCES daily_logs(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    calories REAL NOT NULL DEFAULT 0,
    protein REAL NOT NULL DEFAULT 0,
    carbs REAL NOT NULL DEFAULT 0,
    fat REAL NOT NULL DEFAULT 0,
    micronutrients TEXT NOT NULL DEFAULT '{}',  -- JSON blob
    serving_mappings TEXT NOT NULL DEFAULT '[]', -- JSON blob
    ...
);
```

The interesting choice: **micronutrients and serving_mappings are JSON blobs**, not normalized tables. SQLite (and by extension Turso) handles JSON well with `json_extract()`, and the querying pattern is always "load all micronutrients for an entry" — never "find all entries with Vitamin C > 50mg." The JSON blob matches the access pattern perfectly.

### REST API (`server/routes.js`)

The API uses Express Router with a factory pattern — the router receives the database client at construction time:

```javascript
function createRouter(db) {
    const router = require("express").Router();

    // POST /entries — create a nutrition entry
    router.post("/entries", async (req, res) => {
        const { id, date, name, meal_type, calories, protein, carbs, fat,
                micronutrients, serving_mappings, ...rest } = req.body;

        // Find or create the daily log for this date
        const logId = await findOrCreateLog(date);

        await db.execute({
            sql: `INSERT INTO nutrition_entries
                  (id, daily_log_id, name, meal_type, calories, protein, carbs, fat,
                   micronutrients, serving_mappings, ...)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ...)`,
            args: [id, logId, name, meal_type, calories, protein, carbs, fat,
                   JSON.stringify(micronutrients || {}),
                   JSON.stringify(serving_mappings || []), ...],
        });

        res.status(201).json({ id, daily_log_id: logId });
    });

    return router;
}
```

The `findOrCreateLog(date)` helper is the server's equivalent of `NutritionStore.fetchOrCreateLog()` — it ensures a daily log exists for the given date before inserting an entry.

### The Sync Endpoint

The most interesting endpoint is `GET /api/sync`:

```javascript
router.get("/sync", async (req, res) => {
    const { since } = req.query;

    // If a timestamp is provided, only return changes since then (incremental)
    // Otherwise return everything (full sync on app launch)
    const timeFilter = since
        ? { sql: "WHERE updated_at > ?", args: [since] }
        : { sql: "", args: [] };

    const [logs, entries, foods, containers, goals] = await Promise.all([
        db.execute(`SELECT * FROM daily_logs ${timeFilter.sql}`, timeFilter.args),
        db.execute(`SELECT * FROM nutrition_entries ${timeFilter.sql}`, timeFilter.args),
        db.execute(`SELECT * FROM saved_foods ${timeFilter.sql}`, timeFilter.args),
        db.execute(`SELECT * FROM tracked_containers ${timeFilter.sql}`, timeFilter.args),
        db.execute("SELECT * FROM user_goals WHERE id = 'default'"),
    ]);

    res.json({
        daily_logs: logs.rows,
        nutrition_entries: entries.rows.map(parseEntryRow),
        saved_foods: foods.rows.map(parseFoodRow),
        tracked_containers: containers.rows.map(parseContainerRow),
        user_goals: goals.rows[0] || null,
        synced_at: new Date().toISOString(),
    });
});
```

All five table queries run in parallel via `Promise.all()`. The `parseXxxRow()` helpers JSON-parse the micronutrients and serving_mappings blobs back into objects.

---

## The iOS Side: SyncService as a Thin Network Layer

### Design Principles

1. **No business logic in SyncService** — it's purely HTTP request construction and response decoding
2. **Fire-and-forget everywhere** — callers use `Task { try? await sync?.method() }` to push changes without blocking the UI
3. **`@Observable @MainActor`** — so views can show sync status (loading spinner, error banner) if desired
4. **All API types are `Codable`** — Swift's `JSONDecoder` handles the snake_case ↔ camelCase mapping via `CodingKeys`

### The API Type Layer

Each server table has a corresponding Swift struct:

```swift
struct APIEntry: Codable {
    let id: String
    let dailyLogId: String
    let name: String
    let calories: Double
    let protein: Double
    // ... all fields

    enum CodingKeys: String, CodingKey {
        case id, name, calories, protein
        case dailyLogId = "daily_log_id"
        // ... snake_case mappings
    }
}
```

These are **separate from the SwiftData models** intentionally. The API types are thin DTOs — they don't have relationships, they don't have computed properties, and they use `String` for IDs (matching the database `TEXT` primary keys). The SwiftData models use `UUID` for IDs. The translation happens at the boundary.

### Wiring Into Existing Code

The integration pattern is consistent across all mutation points. Here's how a nutrition entry gets synced:

```swift
// In NutritionStore — the original local-only method
func log(_ entry: NutritionEntry, to date: Date) {
    let log = fetchOrCreateLog(for: date)
    modelContext.insert(entry)
    entry.dailyLog = log
    log.entries.append(entry)
    save()

    // NEW: fire-and-forget sync to server
    let sync = syncService
    Task { try? await sync?.createEntry(entry, date: date) }
}
```

The `let sync = syncService` capture is deliberate — it avoids capturing `self` in the Task closure, which would create a retain cycle.

For views that don't go through NutritionStore (like Food Bank swipe-to-delete), the pattern is the same — `@Environment(SyncService.self)`:

```swift
.swipeActions(edge: .trailing, allowsFullSwipe: true) {
    Button(role: .destructive) {
        let foodId = food.id
        modelContext.delete(food)
        try? modelContext.save()
        Task { try? await syncService.deleteFood(id: foodId) }
    } label: {
        Label("Delete", systemImage: "trash")
    }
}
```

Note the `let foodId = food.id` capture *before* the delete — after `modelContext.delete(food)`, the food object may be invalidated.

### Network Helpers

The HTTP layer is minimal — four generic methods (`get`, `post`, `put`, `delete`) that all funnel through one `execute` method:

```swift
private func execute(_ request: URLRequest) async throws -> Data {
    let (data, response): (Data, URLResponse)
    do {
        (data, response) = try await session.data(for: request)
    } catch {
        let syncErr = SyncError.networkError(error)
        self.syncError = syncErr
        throw syncErr
    }

    guard let httpResponse = response as? HTTPURLResponse else {
        throw SyncError.invalidResponse
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
        let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
            ?? "Unknown error"
        throw SyncError.serverError(httpResponse.statusCode, message)
    }

    return data
}
```

The `syncError` property is `@Observable`, so any view observing `syncService.syncError` will automatically update if a sync fails.

---

## What I Got Right

1. **The fire-and-forget pattern** is the right call for a personal journal app. The user never waits for network — SwiftData is always authoritative for the current session.
2. **Separate API types from SwiftData models** keeps the boundary clean. If the API changes, you update the Codable structs — not your data model.
3. **`file:local.db` fallback** means any developer can run the server locally with `node index.js` — no Turso account needed.
4. **JSON blobs for micronutrients** match the actual access pattern and avoid a pivot table that would be queried in a way SQLite isn't optimized for.
5. **`Promise.all()` on the sync endpoint** — running all five queries in parallel instead of sequentially cuts the response time significantly.

## What I Got Wrong (or Left Undone)

1. **No sync-on-launch yet**: The `fetchAll()` method exists but nothing calls it. On first launch after installing on a new device, the user would see an empty journal. The TODO is to call `fetchAll()` in the `.task` modifier and merge server data into SwiftData.
2. **No retry queue**: If a sync push fails (airplane mode, server down), it's silently dropped. A proper implementation would queue failed mutations and replay them when connectivity returns. `BackgroundTasks` framework with `BGProcessingTask` would be the Apple-sanctioned approach.
3. **No conflict resolution**: If the user edits an entry on two devices, last-write-wins based on `updated_at` timestamp. This is fine for single-user but would need CRDTs or operational transforms for multi-user.
4. **`try? await` swallows errors**: The fire-and-forget pattern means sync failures are invisible. A future iteration should surface persistent failures in a banner or settings screen.
5. **No bulk mutation endpoint**: Deleting a daily log deletes all its entries — each entry gets a separate `DELETE /api/entries/:id` call. A `DELETE /api/daily-logs/:id` with cascade would be more efficient.

---

## Lessons Learned

- **Start with the simplest sync that could work**. Fire-and-forget with no retry is ~100 lines of code. A queue + retry + conflict resolution system is ~1000. Ship the simple version, add complexity when users actually lose data.
- **JSON blobs in SQLite are fine** when the access pattern is "load all, save all." Don't normalize just because it feels like the right thing to do. Normalize when you need to query *into* the blob.
- **The API type layer is boilerplate but invaluable**. Writing `CodingKeys` for every field is tedious, but it means the compiler catches every API/model mismatch at build time instead of crashing at runtime.
- **Capture values before mutating state**. The `let foodId = food.id` before `modelContext.delete(food)` pattern prevents use-after-free bugs. SwiftData objects become invalid after deletion.
- **Local-first doesn't mean local-only**. The architecture supports adding a full sync-on-launch mechanism without changing any of the write paths. The mutation side and the read-sync side are independent.

---

## Adding a Radial FAB, Dual-Model Scanning, and Food Bank Editing

This update tackled four user-facing features in one pass. Here's what happened and what we learned.

### Gemini Model Splitting: Flash for Labels, Pro for Meals

**The problem**: One model (`gemini-3.1-pro-preview`) was handling both nutrition label extraction and food photo estimation. Label scanning is a structured extraction task — it doesn't need deep reasoning. Food photo estimation is a harder problem — you're guessing portion sizes from visual cues, which benefits from extended thinking.

**The solution**: Two model instances in `server/index.js`:

```javascript
// Fast structured extraction for nutrition labels
const flashModel = genAI.getGenerativeModel({
  model: "gemini-2.5-flash-preview-05-20",
  generationConfig: { responseMimeType: "application/json" },
});

// High-reasoning model for food photo estimation
const proModel = genAI.getGenerativeModel({
  model: "gemini-2.5-pro-preview-06-05",
  generationConfig: {
    responseMimeType: "application/json",
    thinkingConfig: { thinkingBudget: 8192 },
  },
});
```

The `/scan` endpoint picks the model based on the `mode` parameter:

```javascript
const activeModel = mode === "label" ? flashModel : proModel;
```

**Why `thinkingBudget: 8192`**: Gemini 2.5 Pro supports "thinking tokens" — internal chain-of-thought reasoning that doesn't show up in the response but improves accuracy on complex tasks. 8192 tokens is enough for the model to reason about portion sizes, ingredient likelihood, and cooking methods without becoming slow. This is the equivalent of asking a nutritionist to "think carefully about this plate of food" before giving their estimate.

**What we got wrong initially**: We considered Gemini 3.1 Pro but settled on 2.5 Pro Preview since it has the `thinkingConfig` support in the Generative AI SDK. The model naming in Gemini's ecosystem is confusing — "3.1" doesn't necessarily mean it's newer or better for this task.

### Auto-Save Scans to Food Bank

**The problem**: After scanning a nutrition label, users had to manually tap "Save to Food Bank" — a separate action from logging the food. Nobody remembered to do this.

**The solution**: When the user confirms a scan result, we now create a `SavedFood` automatically:

```swift
ScanResultCard(
    entry: entry,
    onConfirm: {
        nutritionStore.log(entry, to: .now)

        // Auto-save to Food Bank so scanned foods are reusable
        let saved = SavedFood(from: entry)
        nutritionStore.modelContext.insert(saved)
        try? nutritionStore.modelContext.save()
        let sync = nutritionStore.syncService
        Task { try? await sync?.createFood(saved) }

        dismiss()
    },
```

**The key insight**: `SavedFood` already had a `convenience init(from: NutritionEntry)` — the model layer was ready for this. The only code needed was three lines in the confirm callback. Sometimes the best features are the ones where the architecture was already designed for a use case nobody had wired up yet.

### Food Bank Editing with EditFoodSheet

**The problem**: If Gemini returned a weird name like "Mixed Greens Salad Bowl with Chicken" when the user just wanted "Chicken Salad," there was no way to rename it.

**The solution**: A new `EditFoodSheet` view with `@Bindable var food: SavedFood`. The critical design choice:

```swift
// Local state for text fields (buffered until Save)
@State private var name: String = ""
@State private var brand: String = ""
@State private var calories: String = ""
```

We buffer text field values in `@State` properties rather than binding directly to the `@Bindable` model. This means:
1. Cancel actually cancels — the model isn't modified until the user taps Save
2. Text fields can be validated before committing
3. No partial writes to SwiftData while the user is mid-edit

The edit sheet is accessed via a swipe-left gesture in the Food Bank list:

```swift
.swipeActions(edge: .leading) {
    Button {
        foodToEdit = food
    } label: {
        Label("Edit", systemImage: "pencil")
    }
    .tint(.blue)
}
```

### The Radial FAB Menu (Drag-to-Action)

This was the biggest UI change. The old design was a glass-styled "Scan" button that expanded horizontally to show "Manual" and "Food Bank" options. The new design is a centered "+" button that reveals four options in an upper semicircle when tapped or dragged.

**The geometry**: Options fan out along an arc from 210° to 330° (with 270° being straight up). This places them naturally above the plus button in a semicircle:

```swift
private func angleForIndex(_ index: Int, total: Int) -> Double {
    guard total > 1 else { return 270.0 }
    let startAngle = 210.0   // Lower-left of arc
    let endAngle = 330.0     // Lower-right of arc
    let step = (endAngle - startAngle) / Double(total - 1)
    return startAngle + step * Double(index)
}

private func positionForAngle(_ degrees: Double) -> CGPoint {
    let radians = CGFloat(degrees * .pi / 180)
    return CGPoint(
        x: arcRadius * CoreGraphics.cos(radians),
        y: arcRadius * CoreGraphics.sin(radians)
    )
}
```

**The drag interaction**: Users can either tap to toggle the menu, or drag toward an option. The drag gesture tracks which option is closest to the finger position and highlights it:

```swift
private func closestItem(to translation: CGSize) -> RadialMenuItem? {
    for (index, item) in items.enumerated() {
        let angle = angleForIndex(index, total: items.count)
        let pos = positionForAngle(angle)
        let dx = translation.width - pos.x
        let dy = translation.height - pos.y
        let dist = sqrt(dx * dx + dy * dy)
        if dist < activationRadius { /* track closest */ }
    }
}
```

**Build error we hit**: `cos()` and `sin()` are ambiguous in SwiftUI because both `CoreGraphics` (`CGFloat -> CGFloat`) and `_DarwinFoundation1` (`Double -> Double`) provide them. The fix: explicitly call `CoreGraphics.cos(radians)` with a `CGFloat` parameter.

**The plus button follows the drag subtly** (15% of translation) to give physical feedback without leaving its position:

```swift
dragOffset = CGSize(
    width: value.translation.width * 0.15,
    height: value.translation.height * 0.15
)
```

### Moving Containers from Tab Bar to Journal

**The change**: Removed the "Containers" tab from `ContentView`'s `TabView` (5 tabs → 4) and added it as an option in the radial menu. `DailyLogSheet` gained a `.containers` case, and the sheet presents `ContainerListView()`.

**Why this works**: Containers are a food-logging action, not a top-level navigation destination. They belong in the same "add food" flow as scanning, manual entry, and the food bank. Reducing tab count from 5 to 4 also keeps the tab bar cleaner.

### Lessons Learned

- **Model the interaction before the UI**: The `RadialMenuItem` struct with `id`, `label`, `icon`, `color`, and `action` made the radial menu composable. Adding a 5th option would be one line of code.
- **Buffer edits in @State**: Never bind a text field directly to a SwiftData model unless you want every keystroke to trigger a save. Buffer in `@State`, commit on Save.
- **One model doesn't fit all**: Using a heavyweight reasoning model for structured extraction is wasteful. Match the model to the task — Flash for parsing, Pro for reasoning.
- **Fix ambiguous math with module qualification**: When `cos()` is ambiguous, `CoreGraphics.cos()` is the answer. This is a recurring issue in SwiftUI projects that import both Foundation and CoreGraphics.

---

## Chapter 7: The ServingSize Enum — Making the Data Model Honest

### The Problem with String/Double Serving Data

Before this change, serving size was stored as three independent primitives on every `NutritionEntry` and `SavedFood`:

```swift
var servingQuantity: Double?   // e.g. 1.0
var servingUnit: String?       // e.g. "cup"
var servingMappings: [ServingMapping] // explicit conversion ratios
```

This worked, but it had a conceptual hole: there's no type-level distinction between a mass serving (100 g of chicken) and a volume serving (240 mL of milk) and a serving that's both (1 cup = 240 mL = 228 g of flour). All three looked identical in the model. Any code that needed to do unit conversion had to hunt through `servingMappings` for an explicit ratio, and if none existed, it silently fell back to `1.0`.

The ask: **"The serving size could be an enum. That holds either mass or volume or both. And Gemini inserts this. And the database schema has to be updated."**

This is exactly the kind of data modelling insight that makes a codebase better — not a feature, but an improvement in how truth is represented.

### Designing the Enum

The enum needed to carry three semantic cases:

```swift
enum ServingSize {
    case mass(grams: Double)          // solid food — weight only
    case volume(ml: Double)           // liquid — volume only
    case both(grams: Double, ml: Double)  // labelled food with both (e.g. "1 cup (228g)")
}
```

Each case stores its values in SI base units (grams, millilitres) regardless of how the user sees them. This means `convert()` only needs to know how to go from one display unit to the canonical base value and back:

```swift
func convert(_ value: Double, from: String, to: String) -> Double? {
    // Mass-only: use massConversions table
    // Volume-only: use volumeConversions table
    // Both: can cross-convert via density (grams / mL)
    //       e.g. convert 1 cup to oz: cups → mL → grams → oz
}
```

The cross-dimensional path in `.both` is the clever part: if you know `grams` and `ml` for the same serving, you know the density. That lets you convert between mass and volume units for the same food, which is exactly what nutrition label math requires.

### Standard Unit Tables

Two static dictionaries map display strings to multipliers relative to the base unit:

```swift
static let massConversions: [String: Double] = [
    "g": 1.0, "oz": 28.3495, "kg": 1000.0, "lb": 453.592
]
static let volumeConversions: [String: Double] = [
    "mL": 1.0, "cup": 240.0, "tbsp": 14.787, "tsp": 4.929,
    "fl oz": 29.574, "L": 1000.0
]
```

`availableUnits` returns the appropriate list for the picker — mass types show weight units, volume types show volume units, `.both` shows all of them.

### Threading It Through the Stack

Getting typing right in one model is the easy part. The real work is threading the new type through every layer of the system without breaking anything:

**Models** — `NutritionEntry` and `SavedFood` gain `serving: ServingSize?` and `servingCount: Double`. The legacy fields (`servingQuantity`, `servingUnit`, `servingMappings`) remain for the entries created before the migration. This is additive, not breaking.

**ScanService** — `GeminiNutritionResponse` gets three new fields: `serving_type`, `serving_grams`, `serving_ml`. The mapping function builds the enum from these with a fallback chain:

```swift
let serving: ServingSize? = {
    let g = servingGrams ?? servingWeightGrams  // new field or legacy weight
    let ml = servingMl
    switch servingType {
    case "both":  if let g, let ml { return .both(grams: g, ml: ml) }; fallthrough
    case "mass":  if let g { return .mass(grams: g) }
    case "volume": if let ml { return .volume(ml: ml) }
    default:      if let g { return .mass(grams: g) }  // legacy path
    }
    return nil
}()
```

The `fallthrough` on `"both"` handles the case where Gemini says `"both"` but only provides one value — it gracefully degrades to mass-only.

**SyncService** — The API DTOs (`APIEntry`, `APIFood`) add `servingType`, `servingGrams`, `servingMl` with snake_case `CodingKeys`. The outbound request bodies in `createEntry`, `updateEntry`, `createFood`, `updateFood` send the new fields:

```swift
"serving_type": entry.serving?.type as Any,   // "mass" | "volume" | "both" | nil
"serving_grams": entry.serving?.grams as Any,
"serving_ml": entry.serving?.ml as Any,
```

Using `as Any` is idiomatic Swift for optional values in `[String: Any]` dictionaries — it sends `null` to JSON when the optional is nil.

**Server (db.js)** — Three new columns added to both `CREATE TABLE` statements. The `IF NOT EXISTS` guard means existing databases aren't touched; new databases get the columns from day one. Existing Turso rows simply have NULL for these fields, which is correct — they're pre-migration entries.

**Server (routes.js)** — The POST handlers destructure the new fields and include them in the INSERT; the PUT handlers add them to the `allowedFields` array so they're settable. This follows the existing pattern for optional fields.

**Server (index.js)** — Both Gemini prompts now ask for the three new fields with explicit rules. The key instruction for cross-dimensional foods:

> For `serving_type`: use `"mass"` if only grams known, `"volume"` if only volume known, `"both"` if the label shows both a weight and a volume for the same serving.
> For `serving_ml`: convert if label shows other volume units (1 cup = 240 mL, 1 tbsp = 15 mL, 1 fl oz = 30 mL).

Giving Gemini explicit conversion constants produces more consistent output than asking it to estimate.

**EditEntryView** — The unit picker now prefers `entry.serving?.availableUnits` (standardised unit tables) over the ad-hoc set extracted from `servingMappings`. The `unitFactor` tries the enum's `convert()` first, then falls back to `servingMappings` for custom units:

```swift
private var unitFactor: Double {
    if selectedUnit == baseUnit { return 1.0 }
    if let factor = entry.serving?.convert(1.0, from: baseUnit, to: selectedUnit) {
        return factor  // works for all standard units
    }
    return conversionFactor(from: baseUnit, to: selectedUnit) ?? 1.0  // custom units
}
```

### The Bug: Parameter Order

Swift named parameters must be passed in declaration order. The `NutritionEntry` init declares:

```swift
init(... brand: String? = nil, serving: ServingSize? = nil, servingCount: Double = 1.0, servingQuantity: Double? = nil ...)
```

The initial `ScanService` call passed `serving:` after `servingMappings:`, which is incorrect order. The compiler error was:

```
error: argument 'serving' must precede argument 'servingQuantity'
```

This is one of those errors where you need to look at the init declaration, not guess. The fix was mechanical: reorder the arguments in the call site to match the declaration.

### What We Didn't Do (Yet)

- **LogFoodSheet** still uses `+/-` stepper buttons. The next iteration should replace these with a `TextField(.decimalPad)` backed by the `serving.availableUnits` picker, the same way `EditEntryView` works.
- **Turso migration for existing rows**: The `IF NOT EXISTS` guard in `db.js` means existing databases won't get the new columns until the table is dropped and recreated. An `ALTER TABLE ... ADD COLUMN` migration script should be added for production.
- **Decoding `serving` from API responses**: `SyncResponse` carries `APIEntry`/`APIFood` with the new fields, but `fetchAll()` isn't yet wired to populate SwiftData. When that sync path is built, it will reconstruct `ServingSize` from the three column values.

### Lessons Learned

- **Type the domain, not the storage**: Storing serving size as `(Double?, String?)` is database thinking. Storing it as `ServingSize` is domain thinking. The enum makes illegal states unrepresentable — you can't have a `.both` without at least one valid dimension.
- **Additive migrations beat breaking ones**: Adding new optional fields and keeping old ones lets you ship without a migration script. Existing data still works; new data is richer.
- **Give LLMs constants, not instructions**: Telling Gemini "1 cup = 240 mL, 1 tbsp = 15 mL" in the prompt is more reliable than "convert volume units to mL". Exact constants reduce hallucination surface area.
- **Swift parameter order is positional, not semantic**: Even with named parameters, Swift enforces declaration order. When you add new properties to an `init`, always check call sites for order violations — the compiler will catch it, but only at build time.
- **`fallthrough` in Swift switch is explicit and useful**: Unlike C, Swift doesn't fallthrough by default. Using it deliberately (as in the `ServingSize` decoding switch) communicates intent: "if this condition isn't met, try the next case."

---

## Chapter 8: Sync-on-Launch and the Turso Migration — Closing the First-Install Gap

Two gaps remained after the ServingSize enum work: existing production rows in Turso were missing the three new columns (`serving_type`, `serving_grams`, `serving_ml`), and the app showed an empty journal on first install because `fetchAll()` existed but nothing called it.

Both were simple fixes. They're documented here because the patterns are reusable and the decisions are not obvious without context.

---

### Part 1: The Turso Migration

#### The Problem

Turso uses libSQL, a fork of SQLite. SQLite's `CREATE TABLE IF NOT EXISTS` is idempotent — safe to run every server startup. But it only creates new tables; it doesn't add columns to existing ones. When we added `serving_type`, `serving_grams`, and `serving_ml` to the schema in commit `6aa1486`, we updated the `CREATE TABLE` statement, which protects new databases. Existing production databases — the actual data store for real users — never received the new columns.

Any time the app tried to `INSERT INTO nutrition_entries (...serving_type...) VALUES (...)`, the server would silently fail or error because the column didn't exist in older tables. (In practice, the server was returning 500 errors for any entry created after the ServingSize update.)

#### Why Not Treat/Catch the ALTER TABLE Error?

SQLite supports `ALTER TABLE foo ADD COLUMN bar TEXT`, but it doesn't support `ALTER TABLE foo ADD COLUMN IF NOT EXISTS bar TEXT`. The `IF NOT EXISTS` clause is only valid on `CREATE TABLE`.

Three options:
1. **Try/catch the ALTER TABLE** — catch the "duplicate column" SQLite error. Brittle: couples the logic to a specific error message string.
2. **Track schema version in a table** — a `schema_versions` table with an applied migrations list. Correct but overkill for a personal app.
3. **Query `PRAGMA table_info()` first** — check if the column exists before running the ALTER. Explicit, readable, requires no new tables.

We chose option 3:

```javascript
// Check which columns exist in nutrition_entries
const entryInfo = await db.execute("PRAGMA table_info(nutrition_entries)");
const entryColumns = entryInfo.rows.map((r) => r.name);

if (!entryColumns.includes("serving_type")) {
  await db.execute(
    "ALTER TABLE nutrition_entries ADD COLUMN serving_type TEXT"
  );
  await db.execute(
    "ALTER TABLE nutrition_entries ADD COLUMN serving_grams REAL"
  );
  await db.execute(
    "ALTER TABLE nutrition_entries ADD COLUMN serving_ml REAL"
  );
  console.log(
    "[db] Migrated nutrition_entries: added serving_type, serving_grams, serving_ml"
  );
}
```

`PRAGMA table_info(table_name)` returns one row per column with fields: `cid`, `name`, `type`, `notnull`, `dflt_value`, `pk`. We only care about `name`. If `serving_type` isn't in the list, we add all three columns. Checking one column as the sentinel for the whole group is safe because we always add them together.

#### Key Properties of This Pattern

- **Idempotent on re-deploy**: Once the columns exist, `PRAGMA table_info()` returns them, the `if` block is skipped, and the startup is clean.
- **No coupling to error text**: We don't rely on SQLite's error string for duplicate-column detection.
- **Runs sequentially at startup**: The `runMigrations()` function is `async` and already `await`ed before Express starts handling requests, so no request can arrive before the schema is ready.
- **Self-documenting**: Each `if` block has a comment explaining what change it represents and when it was added.

The same pattern applies to both `nutrition_entries` and `saved_foods`. Each table gets its own `PRAGMA table_info()` check.

---

### Part 2: Sync-on-Launch

#### The Problem

`SyncService.fetchAll()` makes a `GET /api/sync` request and returns a `SyncResponse` with arrays of `APILog`, `APIEntry`, `APIFood`, etc. It was never called anywhere in the app.

On first install, a user would see an empty journal even if they had a week of data in Turso. The server was the authoritative store, but the client only fed data *to* the server, never back.

#### Where to Put the Logic

The merge logic belongs in `NutritionStore` because:
1. `NutritionStore` already owns the `ModelContext` — all SwiftData writes go through it
2. The existing `fetchOrCreateLog(for:)`, `save()`, and `fetchLog(for:)` methods are directly reusable
3. `NutritionStore` is `@MainActor @Observable`, so any view can observe sync state

The call site in `ContentView` uses a `.task` modifier — SwiftUI's structured concurrency hook for async work that should begin when the view appears:

```swift
.task {
    let logs = nutritionStore.fetchAllLogs()
    guard logs.isEmpty else { return }   // already seeded — skip

    if let response = try? await syncService.fetchAll() {
        nutritionStore.applySync(response)
    }
}
```

The `guard logs.isEmpty` check is the key design decision: **we only sync from the server on first launch**. If local data exists, we trust it. This avoids the hard problem of conflict resolution — what happens when local and server have different values for the same entry?

For a personal journal app with fire-and-forget push sync, the only time SwiftData is empty is when:
1. The app is brand new on this device
2. The user cleared the app's storage

Both are "first install" semantics. If the user has data locally, it got there by their own actions and is correct.

#### Rebuilding ServingSize from Three Columns

The `applySync` implementation needs to reverse the mapping from three flat columns back into the enum. The same fallback chain used in `ScanService.toNutritionEntry()` is extracted into a private static helper:

```swift
private static func buildServingSize(type: String?, grams: Double?, ml: Double?) -> ServingSize? {
    switch type {
    case "both":
        if let g = grams, let m = ml { return .both(grams: g, ml: m) }
        fallthrough  // degrade gracefully if one value is missing
    case "mass":
        if let g = grams { return .mass(grams: g) }
    case "volume":
        if let m = ml { return .volume(ml: m) }
    default:
        // Legacy rows have NULL for serving_type — derive from gram weight if available
        if let g = grams { return .mass(grams: g) }
    }
    return nil
}
```

Making it `static` means it's pure (no `self` dependency) and testable in isolation.

#### The Full applySync Implementation

```swift
func applySync(_ response: SyncResponse) {
    // 1. Collect existing UUIDs to avoid inserting duplicates
    let existingEntryIds = Set(
        (try? modelContext.fetch(FetchDescriptor<NutritionEntry>()))?.map(\.id) ?? []
    )
    let existingFoodIds = Set(
        (try? modelContext.fetch(FetchDescriptor<SavedFood>()))?.map(\.id) ?? []
    )

    // 2. Upsert DailyLogs — find or create by date
    //    Build a map from API ID string → DailyLog for use in step 3
    var logByDate: [String: DailyLog] = [:]
    for apiLog in response.dailyLogs {
        let date = Self.parseDate(apiLog.date) ?? .now
        let log = fetchOrCreateLog(for: date)
        logByDate[apiLog.id] = log
    }

    // 3. Insert missing NutritionEntry records
    for apiEntry in response.nutritionEntries {
        guard let entryUUID = UUID(uuidString: apiEntry.id),
              !existingEntryIds.contains(entryUUID),
              let log = logByDate[apiEntry.dailyLogId] else { continue }

        let serving = Self.buildServingSize(
            type: apiEntry.servingType, grams: apiEntry.servingGrams, ml: apiEntry.servingMl
        )
        let entry = NutritionEntry(
            id: entryUUID,
            timestamp: ISO8601DateFormatter().date(from: apiEntry.timestamp ?? "") ?? .now,
            name: apiEntry.name,
            mealType: MealType(rawValue: apiEntry.mealType) ?? .snack,
            scanMode: ScanMode(rawValue: apiEntry.scanMode ?? "manual") ?? .manual,
            confidence: apiEntry.confidence,
            calories: apiEntry.calories,
            protein: apiEntry.protein,
            carbs: apiEntry.carbs,
            fat: apiEntry.fat,
            micronutrients: apiEntry.micronutrients ?? [:],
            servingSize: apiEntry.servingSize,
            servingsPerContainer: apiEntry.servingsPerContainer,
            brand: apiEntry.brand,
            serving: serving,
            servingQuantity: apiEntry.servingQuantity,
            servingUnit: apiEntry.servingUnit,
            servingMappings: apiEntry.servingMappings ?? []
        )
        modelContext.insert(entry)
        entry.dailyLog = log
        log.entries.append(entry)
    }

    // 4. Insert missing SavedFood records
    for apiFood in response.savedFoods {
        guard let foodUUID = UUID(uuidString: apiFood.id),
              !existingFoodIds.contains(foodUUID) else { continue }

        let serving = Self.buildServingSize(
            type: apiFood.servingType, grams: apiFood.servingGrams, ml: apiFood.servingMl
        )
        let food = SavedFood(
            id: foodUUID,
            name: apiFood.name,
            brand: apiFood.brand,
            calories: apiFood.calories,
            protein: apiFood.protein,
            carbs: apiFood.carbs,
            fat: apiFood.fat,
            micronutrients: apiFood.micronutrients ?? [:],
            servingSize: apiFood.servingSize,
            servingsPerContainer: apiFood.servingsPerContainer,
            serving: serving,
            servingQuantity: apiFood.servingQuantity,
            servingUnit: apiFood.servingUnit,
            servingMappings: apiFood.servingMappings ?? [],
            originalScanMode: ScanMode(rawValue: apiFood.scanMode ?? "manual") ?? .manual
        )
        modelContext.insert(food)
    }

    save()
}
```

The structure mirrors a database upsert pattern — check for existence, skip if present, insert if absent. The three-step operation (logs → entries → foods) respects the foreign key relationship: `DailyLog` must exist before `NutritionEntry` references it.

#### Date Parsing Edge Case

The server stores dates as `"YYYY-MM-DD"` strings. `ISO8601DateFormatter` doesn't handle plain date strings (no time component) without explicit configuration. A custom `parseDate()` helper handles both:

```swift
private static func parseDate(_ string: String) -> Date? {
    // Try plain YYYY-MM-DD first
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = .current
    if let date = formatter.date(from: string) {
        return Calendar.current.startOfDay(for: date)
    }
    // Fall back to full ISO 8601 (timestamps from server logs)
    return ISO8601DateFormatter().date(from: string).map {
        Calendar.current.startOfDay(for: $0)
    }
}
```

`.startOfDay(for:)` normalizes any date to midnight in the user's time zone — matching how `NutritionStore.fetchLog(for:)` queries the SwiftData store.

---

### What We Got Right

1. **`PRAGMA table_info()` pattern** is self-documenting and reusable. Any future column addition follows the same shape.
2. **"Skip if local data exists"** is the right conflict policy for a fire-and-forget sync system. Complex conflict resolution would be premature — the app has one user and one device at a time in practice.
3. **`buildServingSize` as a private static** keeps the conversion logic in one place. Both `applySync` and `ScanService.toNutritionEntry()` use the same fallback chain — they just use different copies. A future refactor could unify them into a shared extension.
4. **`logByDate[apiLog.id]`** — keying the DailyLog map by API log ID (not date string) means the lookup in step 3 doesn't need to reparse dates. Exactly one hash lookup per entry.
5. **`guard ... else { continue }`** — using guard/continue in loops keeps the happy path un-nested. The three conditions for inserting an entry (valid UUID, not already local, parent log exists) read clearly in one line.

### What We Didn't Do (and Why)

1. **Goals sync**: `SyncResponse.userGoals` is decoded but `applySync` doesn't apply it. Merging goals into `UserGoals` (which uses `@AppStorage`) is a separate concern — `@AppStorage` keys need to be explicitly set, not bulk-overwritten from a JSON blob.
2. **Containers sync**: `TrackedContainer` is in `SyncResponse` but not in `applySync`. The data model is ready but the merge logic wasn't needed for the first-install use case (containers are typically in-progress and device-specific).
3. **Incremental sync**: `/api/sync?since=` supports a timestamp parameter for delta syncs. We always do a full sync on first launch. Adding incremental sync on subsequent launches would require storing the last sync timestamp (trivial with `@AppStorage`) and calling it more frequently.
4. **Retry on failure**: `try? await syncService.fetchAll()` swallows errors. A real implementation would retry with exponential backoff and surface a banner if sync fails after N attempts.

### Lessons Learned

- **`PRAGMA table_info()` before `ALTER TABLE`** is the idiomatic SQLite migration pattern when you don't have a schema version table. One query, one check, clean logs.
- **Design the merge function before the call site**: Writing `applySync` first meant the `ContentView` `.task` was five lines. The inverse — writing the call site first, then asking "what does this function need to do?" — leads to poorly bounded functions.
- **`try?` on the fetchAll call is fine at the call site**: The error is already captured in `SyncService.syncError` if you need to surface it. At the `.task` level, silent skip-on-error is the right behaviour — the app should always show *something*, even if sync fails.
- **Static helpers on MainActor classes are pure by necessity**: A `static` function can't access `self`, so it must be pure. Using `static` for conversion/parsing helpers enforces that they have no side effects and are independently testable.

---

## Chapter 9 — Gesture UX: Swipe Actions, Tappable Radial Menus, and Unit Mapping in Edit View

**Scope of work:** Five separate UX improvements that turned out to share a common root cause — SwiftUI gesture recognizers competing with each other in ways that produce silent bugs and invisible lag.

---

### 9.1 The `swipeActions` Silent-Failure Bug

**The problem:** EntryRowView had `.swipeActions(edge: .trailing)` for delete since the beginning. Users couldn't trigger it. No SwiftUI warning, no runtime error — the modifier just did nothing.

**Root cause:** `.swipeActions` is documented as applying to "list rows", but SwiftUI doesn't warn you when you apply it outside a `List`. It's silently ignored in `LazyVStack`, `VStack`, `ScrollView` — any container that isn't a `List`.

The DailyLog was built with `ScrollView { LazyVStack(pinnedViews: .sectionHeaders) { ForEach { MealSectionView } } }` to get sticky section headers without a `List`. The trade-off was unknowingly disabling every swipe action in the entire hierarchy.

**The fix:** Replace the `ScrollView + LazyVStack` with a `List`:

```swift
// Before: swipeActions silently ignored
ScrollView {
    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
        ForEach(MealType.allCases) { mealType in
            MealSectionView(...)  // has .swipeActions inside — never fires
        }
    }
}

// After: swipeActions work correctly
List {
    // Header rows with clear background (no separator)
    WeeklyCalendarStrip(selectedDate: $selectedDate)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))

    MacroSummaryBar(log: log, goals: goals)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

    // Meal sections — Section{} inside List = proper sticky header
    if let log, !log.entries.isEmpty {
        ForEach(MealType.allCases) { mealType in
            MealSectionView(...)  // .swipeActions now fired correctly
        }
    }
}
.listStyle(.plain)
.scrollContentBackground(.hidden)
```

The key insight: `List` doesn't require all rows to be identical. The `WeeklyCalendarStrip` and `MacroSummaryBar` become plain list rows that happen to look different. The `listRowBackground(Color.clear)` + `listRowSeparator(.hidden)` + `listRowInsets(...)` trio is the pattern for "List rows that don't look like List rows".

**What `Section{}` inside `List` does:** When `MealSectionView` returns `Section { ForEach { ... } } header: { ... }`, and it's inside a `List`, SwiftUI renders it as a proper sticky section header. The `LazyVStack(pinnedViews: .sectionHeaders)` was approximating this behavior — now we get the real thing.

**The swipe directions added:**
- Swipe left (`.trailing`): Delete — already existed on `EntryRowView`, now fires
- Swipe right (`.leading`): Edit — added to the `Button` wrapper in `MealSectionView`

```swift
// MealSectionView — .swipeActions on the Button wrapper adds leading action
Button {
    onSelect(entry)
} label: {
    EntryRowView(entry: entry, onDelete: { onDelete(entry) })
}
.buttonStyle(.plain)
.swipeActions(edge: .leading) {
    Button { onSelect(entry) } label: {
        Label("Edit", systemImage: "pencil")
    }
    .tint(.blue)
}
// Trailing delete still lives in EntryRowView — SwiftUI collects all
// .swipeActions in the row hierarchy and merges them by edge
```

---

### 9.2 The SwipeActions Lag Bug in FoodBankView

**The problem:** Swiping on food rows in the Food Bank tab felt sluggish — there was a ~150ms delay before the swipe animation started.

**Root cause:** The row was wrapped in a `Button {}`:

```swift
Button {
    selectedFood = food
} label: {
    SavedFoodRowView(food: food)
}
.swipeActions(edge: .trailing, ...) { ... }
.swipeActions(edge: .leading) { ... }
```

When you have a `Button` inside a `List` with `swipeActions`, iOS must choose between two gesture recognizers:
1. The `Button`'s tap recognizer (which fires on release)
2. The swipe recognizer (which needs to start tracking early)

To resolve this, the system waits for the touch to move enough to definitively classify it as a swipe before committing. This disambiguation window is the lag users feel.

**The fix:** Replace `Button {}` with `.contentShape(Rectangle()).onTapGesture {}`:

```swift
// Before: Button creates competing gesture recognizer
Button {
    selectedFood = food
} label: {
    SavedFoodRowView(food: food)
}
.tint(.primary)

// After: onTapGesture resolves immediately without disambiguation
SavedFoodRowView(food: food)
    .contentShape(Rectangle())  // makes the entire rectangular area tappable
    .onTapGesture { selectedFood = food }
```

Why does this work? `onTapGesture` is a higher-level modifier that doesn't create a competing `GestureRecognizer` in the same way a `Button` does. The swipe recognizer runs without needing to wait for a potential tap to resolve.

**What you lose:** The `Button` provides a visual press highlight on touch-begin. `onTapGesture` does not. In a food bank list where rows don't have rich press states, this is acceptable — but it's a tradeoff worth knowing.

**Rule of thumb:** In a `List` with `swipeActions`, prefer `onTapGesture + contentShape` over `Button` to avoid gesture lag. Use `Button` only when the press-highlight feedback is important (e.g., primary action buttons, not list navigation rows).

---

### 9.3 Making the Radial Menu Tappable and Dismissible

**The problem:** The floating radial menu opened when holding and dragging to an option. But:
1. Direct taps on option bubbles did nothing — users had to drag-and-release
2. Tapping outside the open menu didn't close it — you had to tap the plus button again

**The tappable options fix:**

```swift
optionBubble(item: item, isHighlighted: isHighlighted)
    .offset(x: position.x, y: position.y)
    .glassEffectID(item.id, in: glassNamespace)
    .glassEffectTransition(.matchedGeometry)
    .animation(.spring(duration: 0.2), value: isHighlighted)
    // NEW — direct tap on bubble triggers its action
    .onTapGesture {
        close()
        // 150ms delay: let the spring close animation start before
        // presenting the destination sheet, prevents janky transitions
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            item.action()
        }
    }
```

The 150ms delay is important. Without it, the sheet presentation and the close animation compete — the sheet appears while the bubble is still mid-animation. The delay matches what the drag-release path already used.

**The dismiss-on-outside-tap fix:**

```swift
var body: some View {
    ZStack(alignment: .bottom) {
        // Dismiss layer — sits BEHIND the GlassEffectContainer in the ZStack
        // so that taps on bubbles/plus-button are handled by those views first,
        // and only "missed" taps reach this layer.
        if isOpen {
            Color.clear
                .contentShape(Rectangle())  // gives hit-test area to a clear view
                .ignoresSafeArea()          // extends into safe areas (status bar etc.)
                .onTapGesture { close() }
        }

        GlassEffectContainer(spacing: 16) {
            ZStack {
                if isOpen { /* option bubbles with .onTapGesture */ }
                plusButton  // always present — the morph anchor
            }
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    // ... animation modifier
}
```

**Key insight: ZStack z-order determines gesture priority.** Views added later to a `ZStack` sit on top and receive gestures first. `GlassEffectContainer` comes after `Color.clear`, so:
- Taps on the glass container → handled by GlassEffectContainer's children (bubbles, plus button)
- Taps outside the glass container → fall through to `Color.clear` → dismiss

`Color.clear` doesn't have a hit-test area by default (transparent views don't intercept touches). That's why `.contentShape(Rectangle())` is mandatory — it explicitly declares "this entire rectangle area should receive taps, even though it's clear."

---

### 9.4 Sharing an Internal Sheet Between Two Views

**The problem:** `AddServingMappingSheet` was originally defined as `private struct` inside `LogFoodSheet.swift`. When we needed to reuse it in `EditEntryView.swift`, it was invisible.

**Swift access control:**
- `private struct Foo` in a file = file-private (`fileprivate`)  
- The `private` keyword at top level acts like `fileprivate` — visible only within the same file
- `internal struct Foo` (or just `struct Foo`) = visible across the entire module

**The fix:** Remove `private`:

```swift
// Before — file-private, invisible to EditEntryView.swift
private struct AddServingMappingSheet: View { ... }

// After — internal, visible anywhere in the OpenFoodJournal module
struct AddServingMappingSheet: View { ... }
```

No file reorganization needed. The sheet stays in `LogFoodSheet.swift` (it was designed there) and `EditEntryView.swift` just imports nothing extra — both are in the same module.

**When to extract vs. just make internal:** If the shared type is likely to grow (more parameters, more previews, its own tests), move it to its own file. If it's a small modal that will only ever be opened from 2-3 call sites, making it internal is sufficient. `AddServingMappingSheet` is 80 lines and unlikely to grow significantly, so internal-in-LogFoodSheet is the right call.

---

### 9.5 The LogFood Baseline Bug

**The problem:** When a user logged food with a quantity and unit (e.g., "250 g"), then opened the edit sheet for that journal entry, the quantity/unit shown was wrong — it showed the food's template values ("1 serving") rather than what was actually logged.

**Root cause:** The `logButton` in `LogFoodSheet` created an entry from the food template and scaled the macros, but never updated `entry.servingQuantity` and `entry.servingUnit`:

```swift
// Before — macros scaled correctly, but baseline unset
var entry = food.toNutritionEntry(mealType: selectedMealType)
let factor = quantity / unitFactor / baseQuantity
entry.calories *= factor
entry.protein *= factor
entry.carbs *= factor
entry.fat *= factor
// Missing: entry.servingQuantity = quantity
// Missing: entry.servingUnit = selectedUnit
nutritionStore.log(entry, to: logDate)
```

`toNutritionEntry()` copies `food.servingQuantity` and `food.servingUnit` (the template's "per serving" values), not what the user typed. So the entry stored "1 serving" with macros already scaled for 250g — inconsistent state.

**The fix:** Two lines after scaling:

```swift
// After — macros scaled AND baseline matches what user typed
entry.servingQuantity = quantity    // what the user entered (e.g. 250)
entry.servingUnit = selectedUnit    // which unit they chose (e.g. "g")
nutritionStore.log(entry, to: logDate)
```

**Why this matters for EditEntryView:** `EditEntryView` uses `entry.servingQuantity` as `baseQuantity` and `entry.servingUnit` as `baseUnit`. Every scaled display value and unit conversion is relative to these. With the bug, opening the edit sheet showed macros at "1 serving" instead of "250 g" — the numbers looked identical but the unit calculation was wrong, and changing the unit would produce nonsense values.

---

### 9.6 Adding Serving Mappings to EditEntryView

**The problem:** If a food was stored as `.volume(ml: 240)` (milk, measured in mL), and the user wanted to edit a logged entry in weight (grams), they couldn't — the unit picker only showed volume units. The solution (adding a custom `"1 cup → 250 g"` mapping) was only available in `LogFoodSheet`, not in the journal edit view.

**What was added to `EditEntryView`:**

1. `@Environment(SyncService.self) private var syncService` — for the Turso push
2. `@State private var showAddMapping = false` — controls the sheet
3. `servingMappingsSection` — a `Form` section that shows existing mappings and an "Add Unit Mapping" button
4. `addMapping(_ mapping: ServingMapping)` — called by the sheet's `onAdd` callback

```swift
private var servingMappingsSection: some View {
    Section {
        if entry.servingMappings.isEmpty {
            Text("Add custom unit conversions (e.g. 1 cup = 250 g) to switch between measurement dimensions in the unit picker above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(entry.servingMappings, id: \.self) { mapping in
                HStack(spacing: 6) {
                    Text(mapping.from.displayString)
                        .fontWeight(.medium)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(mapping.to.displayString)
                    Spacer()
                }
                .font(.subheadline)
            }
        }

        Button { showAddMapping = true } label: {
            Label("Add Unit Mapping", systemImage: "plus")
        }
    } header: {
        Text("Unit Mappings")
    }
}

private func addMapping(_ mapping: ServingMapping) {
    entry.servingMappings.append(mapping)
    nutritionStore.saveAndSyncEntry(entry)  // SwiftData + Turso
}
```

The sheet is presented as:
```swift
.sheet(isPresented: $showAddMapping) {
    AddServingMappingSheet { mapping in addMapping(mapping) }
}
```

**How the unit conversion chain works:** Once a mapping is added (`{ from: 1 cup, to: 250 g }`):
1. `availableUnits` recomputes and includes "g" (from the mapping's `to.unit`)
2. User selects "g" in the picker → `selectedUnit = "g"`
3. `unitFactor`:
   - `entry.serving?.convert(1.0, from: "cup", to: "g")` → `nil` (`.volume` can't cross dimensions)
   - Falls back to `conversionFactor(from: "cup", to: "g")` which searches `entry.servingMappings` → finds the mapping → returns `250/1 = 250`
4. `displayCalories = (baseCalories / baseQuantity) / 250 * quantity` — correct cross-dimension scaling

---

### 9.7 What We Got Wrong

1. **Building the DailyLog with LazyVStack instead of List from the start.** The decision to use a ScrollView+LazyVStack was made to get "custom scrolling behavior", but in hindsight, a List with `.listStyle(.plain)` + `.scrollContentBackground(.hidden)` gives identical visual results and doesn't silently break swipe actions.

2. **Not saving `servingQuantity`/`servingUnit` in `logButton`.** This was caught weeks later when testing EditEntryView. The two-line fix was trivial — the lesson is to always verify that the data you're saving matches what the user sees.

3. **`private struct` for a reusable component.** `AddServingMappingSheet` was designed as a standalone form and was always likely to be needed from multiple call sites. Starting `private` was natural (it was initially only used in one file), but the right next step when reusing it was to promote it to its own file, not just change access control. We chose the minimal change (remove `private`) which is fine for now.

---

### 9.8 Patterns Learned

**Pattern: swipeActions needs a List.** Any time you want swipe actions, the parent must be a `List`. If your design uses a custom scroll container, the alternatives are: (a) use a `List` with custom row styling, (b) implement a `DragGesture`-based custom swipe view, or (c) put the action in a context menu instead.

**Pattern: contentShape + onTapGesture for lag-free tappable list rows.** In a `List` with `swipeActions`, replace `Button{}` wrappers with:
```swift
YourRowView()
    .contentShape(Rectangle())
    .onTapGesture { doSomething() }
```
This avoids the gesture disambiguation delay without changing visual behavior for rows without press-state styling.

**Pattern: ZStack + Color.clear dismiss layer.** The canonical pattern for "tap outside to dismiss" in a custom overlay:
```swift
ZStack {
    if isOpen {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .onTapGesture { dismiss() }
    }
    // your overlay content (sits on top, captures taps first)
    YourOverlayContent()
}
```

**Pattern: Sharing sub-views across files.** `private struct` = file-private. `struct` (implicit internal) = module-wide. For small reusable sheets, keeping them in the file where they were designed (without `private`) is fine. When a sheet grows complex enough to merit its own preview, move it to its own file.

**Pattern: Animate-then-act for gesture-triggered sheets.** When a tap or gesture should both close an overlay and present a new screen:
```swift
.onTapGesture {
    closeAnimation()  // or close()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        presentNewScreen()
    }
}
```
The 150ms let the close animation start before the new screen appears, preventing visual conflicts.


