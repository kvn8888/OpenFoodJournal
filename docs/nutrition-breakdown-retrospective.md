# DaisyDisk for Food: Building a Nutrition Breakdown View and Fixing Everything Around It

This session started with a unit conversion bug where 1 gram of milk had 160 calories, and ended with a donut-chart nutrient breakdown view, a reworked History page, and a handful of SwiftUI navigation lessons. The thread connecting all of it: making nutrition data actually useful instead of just present.

---

## The Starting Point

OpenFoodJournal had a working Nutrition view (formerly "Micronutrients") showing progress bars for FDA-tracked nutrients, a History tab with a weekly chart behind an extra tap, and Settings claiming "iCloud Sync: Automatic" despite using Turso as its cloud backend. The unit conversion system in LogFoodSheet had a bug where switching from "cup" to "g" didn't change the macros — 1 gram of milk showed 160 calories, the same as a full cup.

The session had two phases: fix the conversion bug (covered in a [separate retrospective](serving-unit-conversion-retrospective.md)), then tackle a batch of UX improvements that had been accumulating.

---

## Step 1: Renaming Micronutrients to Nutrition

The "Micronutrients" view already had a time-period picker (daily/weekly/monthly) and progress bars against FDA daily values. But it only showed micronutrients — no macros. If you wanted to see your protein intake for the week, you had to go back to the Journal tab and mentally add up the numbers.

The fix was straightforward: rename `MicronutrientSummaryView` to `NutritionDetailView`, add a "Macros" section at the top with four cards (calories, protein, carbs, fat) showing progress against goals, and add an `aggregateMacros()` method to `NutritionStore` that mirrors the existing `aggregateMicronutrients()` pattern.

The file rename was the interesting part. Xcode projects can reference Swift files by name in the `.pbxproj` file, which would break if you rename without updating. A quick grep confirmed no pbxproj references — Xcode auto-discovers Swift files in the project directory. Safe to rename.

---

## Step 2: Inlining the History View

The old History flow: tap a date on the calendar → see a summary card with "160 kcal · 3 items" → tap the card → NavigationLink pushes to `DayDetailView` → finally see what you ate. That's two taps just to glance at a day's food. For a journaling app, that friction kills the "quick check" use case.

The new flow: tap a date → entries appear inline below the calendar, grouped by meal type with section headers. No navigation push, no extra tap. The `DayDetailView` struct still exists for backward compatibility but the main History view renders everything in-place.

The "Past 7 Days" label became a "Last Week vs This Week" comparison grid. Four cards (one per macro) show this week's daily average and the percentage change from last week. The delta is color-coded: green if you're trending down (for calories, that's usually good), orange if up, gray if within 10%. This required computing averages over two separate 7-day windows:

```swift
private func avgMacro(_ keyPath: KeyPath<DailyLog, Double>, logs: [DailyLog]) -> Double {
    guard !logs.isEmpty else { return 0 }
    return logs.map { $0[keyPath: keyPath] }.reduce(0, +) / 7.0
}
```

Dividing by 7.0 (not `logs.count`) is intentional — if you only logged 3 days this week, the average should reflect the full week, not just the days you remembered to log. Otherwise a single 3000-calorie day would show as "3000 avg" instead of "429 avg."

One build failure: the ternary `abs(delta) < 10 ? .secondary : (delta > 0 ? .orange : .green)` mixed `HierarchicalShapeStyle` (`.secondary`) with `Color` (`.orange`). Known Swift gotcha — the compiler can't unify the types. Fix: `Color.secondary`, `Color.orange`, `Color.green`.

---

## Step 3: Settings Cleanup

Two changes here, both small but both removing lies from the UI.

**iCloud → Server Sync**: The Settings view showed "iCloud Sync: Automatic" as a static label. There's no iCloud integration — the app syncs to Turso via `SyncService`. The `lastSyncDate` property already existed on SyncService (persisted in UserDefaults), so the fix was just wiring it up:

```swift
HStack {
    Label("Server Sync", systemImage: "arrow.triangle.2.circlepath")
    Spacer()
    if let lastSync = syncService.lastSyncDate {
        Text(lastSync, style: .relative)
            .foregroundStyle(.secondary)
        + Text(" ago")
            .foregroundStyle(.secondary)
    } else {
        Text("Never")
            .foregroundStyle(.secondary)
    }
}
```

**Scan Photos**: "Save scan photos" became "Keep original scan photos" with a caption explaining the storage tradeoff. The toggle controls whether the camera JPEG is kept on each `NutritionEntry` via `@Attribute(.externalStorage)`. Most users don't need the photo after Gemini extracts the nutrition data, so making the consequence explicit helps them decide.

---

## Step 4: The Nutrient Breakdown — DaisyDisk for Food

This was the fun one. The idea: tap any nutrient (fiber, Vitamin C, protein, whatever) and see which foods contributed to your intake, visualized as a donut chart where each food is a colored sector proportional to its contribution.

The data pipeline: `NutritionStore.entriesForPeriod(_:)` returns all `NutritionEntry` objects in the time window. Group by food name, sum the nutrient value, sort by contribution, assign colors from a rotating palette.

```swift
var byFood: [String: Double] = [:]
for entry in entries {
    switch kind {
    case .micro(let nutrient):
        guard let micro = entry.micronutrients[nutrient.id] else { continue }
        value = micro.value
    case .macro(let macroType):
        value = macroType.value(from: entry)
    }
    byFood[entry.name, default: 0] += value
}
```

The `NutrientKind` enum lets the same view handle both macros and micros. Macros pull from top-level entry properties (`entry.calories`, `entry.protein`), micros pull from the `micronutrients` dictionary. Daily value targets come from `UserGoals` for macros and FDA reference data for micros.

Each food row shows: colored dot (matching the donut), food name, amount contributed, percentage of total, and a progress bar showing how much of the daily value that single food provided. You can immediately see "oh, my yogurt gave me 40% of today's calcium."

### The Scalability Fix

First version showed every food that had the nutrient, including foods with 0 contribution. Milk at 0g fiber showing up in the fiber breakdown is noise, not signal. And with 30+ foods logged in a month, the donut becomes an unreadable rainbow.

Two fixes:
1. Filter: `byFood.filter { $0.value > 0 }` — zero-value foods don't appear
2. Grouping: donut shows top 8 contributors with distinct colors, everything else becomes a gray "Other" slice. The full list below still shows every food for detail.

```swift
if contributions.count <= maxSlices {
    chartSlices = contributions
} else {
    let top = Array(contributions.prefix(maxSlices))
    let otherTotal = contributions.dropFirst(maxSlices).reduce(0) { $0 + $1.value }
    chartSlices = top + [FoodContribution(
        id: "_other", foodName: "Other",
        value: otherTotal, color: .gray
    )]
}
```

---

## The Gotcha: NavigationLink Inside LazyVGrid

The macro cards in the Nutrition view used `NavigationLink` inside a `LazyVGrid`. Tapping "Protein" opened breakdown pages for all four macros simultaneously. This is a known SwiftUI behavior: `NavigationLink` in a grid or non-List container shares activation state across all items in the same container.

The fix: replace `NavigationLink` with `Button` that sets a `@State var selectedMacro: MacroType?`, and use a single `.navigationDestination(item: $selectedMacro)` on the List. Now only the tapped macro navigates.

```swift
// Before (broken): NavigationLink in LazyVGrid — all four activate together
NavigationLink { NutrientBreakdownView(macro: .protein, ...) } label: { ... }

// After (fixed): Button + programmatic navigation
Button { selectedMacro = .protein } label: { ... }
// ... on the List:
.navigationDestination(item: $selectedMacro) { macro in
    NutrientBreakdownView(macro: macro, period: selectedPeriod)
}
```

## The Gotcha: Nested NavigationStacks

The nutrient breakdown had no transition animation, and pressing back returned to the Journal tab instead of the Nutrition list. Root cause: `NutritionDetailView` wrapped its body in its own `NavigationStack`, but it was already pushed inside DailyLogView's `NavigationStack`. Nested stacks create independent navigation hierarchies — pushes within the inner stack don't animate relative to the outer one, and the back button pops the wrong stack.

Fix: remove the inner `NavigationStack`. The view is a destination, not a root — it should be a plain `List` that inherits the parent's navigation context. The `NavigationLink`s for nutrient rows and the `.navigationDestination` for macros all work correctly within the parent stack.

Third navigation issue: the Liquid Glass tab bar was collapsing on scroll because of `.tabBarMinimizeBehavior(.onScrollDown)` on the `TabView`. Changed to `.never` so the tab bar stays visible at all times.

---

## What's Next

The nutrient breakdown is read-only — you can see that yogurt gave you 40% of your calcium, but you can't tap the yogurt to see its full nutrition card or log it again. Adding a NavigationLink from each contribution row to the food's detail view would close that loop.

The week-over-week comparison in History is simple percentage deltas. A sparkline or mini bar chart showing the trend over 4+ weeks would be more informative than a single "this week vs last week" snapshot.

The `entriesForPeriod` method on NutritionStore fetches and flattens all entries every time the breakdown view appears. For monthly views with hundreds of entries, this could get slow. Caching the aggregation or computing it lazily would help, but it's premature optimization until someone actually has months of data.

---

The best features aren't the ones that show you more data — they're the ones that answer "why?" without you having to ask. A progress bar says you hit 80% of your fiber goal. A donut chart says your oatmeal did the heavy lifting.
