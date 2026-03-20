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
