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
