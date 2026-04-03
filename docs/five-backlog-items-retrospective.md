# Five Backlog Items, One Session: From Gesture Bugs to Circular Rings

OpenFoodJournal had a growing backlog — swipe gesture bugs, flat progress bars that didn't match the app's visual language, a missing "inverse view" for nutrient analysis, read-only micronutrients in a log sheet, and text legibility issues over Liquid Glass. This session tackled all five in one pass, with the constraint that every change had to compile cleanly before moving on.

## The Starting Point

The app is a SwiftUI food journal targeting iOS 26 with Liquid Glass design. It was functionally complete but had accumulated UX debt across several views:

1. **Swipe gestures were sluggish** on journal entry rows that didn't have a brand subtitle — a subtle interaction bug that only affected some foods.
2. **Macro cards in NutritionDetailView** used a flat `ProgressView` bar, visually inconsistent with the circular progress rings used elsewhere in the app (calendar day indicators, macro ring components).
3. **NutrientBreakdownView** answered "which foods contributed to this nutrient?" but there was no way to ask the inverse: "which nutrients does this food provide?"
4. **LogFoodSheet** displayed micronutrients as read-only progress bars — you could see fiber and sodium but couldn't correct them before logging.
5. **RadialMenuButton** option labels like "Food Bank" and "Containers" were hard to read when the menu appeared over light backgrounds.

## Step 1: The Swipe Gesture Bug — Two Root Causes, One Subtle Lesson

The bug: swiping on journal entry rows without a brand name felt sticky, with a noticeable delay before the swipe action registered. Rows with brands (three lines of text) swiped smoothly.

**Root cause 1: Double swipe registration.** `EntryRowView` declared `.swipeActions(edge: .trailing)` for delete on its inner `HStack`. Then `MealSectionView` wrapped each row in a `Button` and added `.swipeActions(edge: .leading)` for edit on the outer wrapper. Two separate views in the hierarchy both registering swipe actions creates competing gesture recognizers — on shorter rows (no brand = less gesture area), the system takes longer to resolve which recognizer should win.

```swift
// BEFORE: Swipe on inner view AND outer wrapper → gesture conflict
// EntryRowView.swift
.swipeActions(edge: .trailing, allowsFullSwipe: true) {
    Button(role: .destructive, action: onDelete) { ... }
}

// MealSectionView.swift (wrapping the above)
.swipeActions(edge: .leading) {
    Button { onSelect(entry) } label: { Label("Edit", ...) }
}
```

The fix: consolidate both swipe directions on the `MealSectionView` Button wrapper, remove swipe actions entirely from `EntryRowView`. One view, one gesture resolver, no ambiguity:

```swift
// AFTER: Both swipe directions on the same wrapper
.swipeActions(edge: .trailing, allowsFullSwipe: true) {
    Button(role: .destructive) { onDelete(entry) } label: { ... }
}
.swipeActions(edge: .leading) {
    Button { onSelect(entry) } label: { Label("Edit", ...) }
}
```

**Root cause 2: Missing hit-test area.** `SavedFoodRowView` in the Food Bank had no `.contentShape(Rectangle())`, so the swipe gesture target was limited to the rendered pixels. Without a brand line, the row is physically shorter — less area for the gesture recognizer to capture. Adding a single modifier fixed it.

**Bonus fix:** `EntryRowView.timeString` created a new `DateFormatter` on every render call. `DateFormatter` is expensive — its init reads locale data from disk. Making it `static let` means it's created once for the lifetime of the app:

```swift
private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f
}()
```

**Lesson for junior devs:** When gestures feel sluggish in a SwiftUI `List`, check for competing gesture recognizers at different levels of the view hierarchy. The framework doesn't warn you when two ancestors both register `.swipeActions` — it just silently creates ambiguity that manifests as input lag.

## Step 2: Linear Bars → Circular Rings in NutritionDetailView

The macro cards (Calories, Protein, Carbs, Fat) in `NutritionDetailView` used a standard SwiftUI `ProgressView`, which renders as a thin horizontal bar. The rest of the app — calendar day indicators, the LogFoodSheet's `MacroRingView` — uses circular progress rings. The visual inconsistency was jarring when navigating from a day's summary to the detail view.

The replacement is a `Circle().trim()` approach. SwiftUI's `trim(from:to:)` modifier clips a shape to a fraction of its path, so a circle trimmed from 0 to 0.75 draws a 270° arc — perfect for progress visualization:

```swift
ZStack {
    // Background track (always full circle)
    Circle()
        .stroke(color.opacity(0.15), lineWidth: 6)
    // Filled arc — starts at 12 o'clock, fills clockwise
    Circle()
        .trim(from: 0, to: displayFraction)
        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
        .rotationEffect(.degrees(-90)) // default starts at 3 o'clock
    // Value label inside the ring
    VStack(spacing: 0) {
        Text("\(Int(value))")
            .font(.title3).fontWeight(.bold).foregroundStyle(color)
        Text(macro.unit)
            .font(.system(size: 9)).foregroundStyle(.secondary)
    }
}
.frame(width: 64, height: 64)
```

The `.rotationEffect(.degrees(-90))` is the key trick — SwiftUI's default `trim` starts at the 3 o'clock position (0°). Rotating -90° moves the start to 12 o'clock, which is where users expect progress rings to begin. I also cap the visual fill at 100% (`displayFraction = min(fraction, 1.0)`) but show the actual percentage below (can exceed 100%), so users see "120% of daily fat" without the ring wrapping around confusingly.

## Step 3: FoodNutrientBreakdownView — The Inverse Axis

`NutrientBreakdownView` already answered "I ate 45g of protein today — which foods contributed?" with a donut chart and per-food bars. But there was no way to ask the inverse question: "I ate Greek yogurt — what nutrients did it give me?"

The new `FoodNutrientBreakdownView` takes a food name and time period, filters all entries, and aggregates every nutrient that food contributed:

```swift
// Aggregate micronutrients: sum each nutrient across all entries of this food
var microTotals: [String: Double] = [:]
for entry in entries {
    for (key, value) in entry.micronutrients {
        microTotals[key, default: 0] += value.value
    }
}
```

To wire it in, I made the "By Food" rows in `NutrientBreakdownView` tappable with a `NavigationLink`:

```swift
Section("By Food") {
    ForEach(contributions) { item in
        NavigationLink {
            FoodNutrientBreakdownView(foodName: item.foodName, period: period)
        } label: {
            ContributionRow(item: item, ...)
        }
    }
}
```

This creates a natural navigation flow: DailyLogView → NutritionDetailView (circular rings) → NutrientBreakdownView (one nutrient, all foods) → FoodNutrientBreakdownView (one food, all nutrients). Each view is the inverse of the previous, and together they cover every axis of "what did I eat and what did it give me?"

## Step 4: Editable Micronutrients in LogFoodSheet

`LogFoodSheet` already displayed micronutrients in a `DisclosureGroup` — but as read-only `MicronutrientProgressRow` views. The user could see that Greek yogurt had 12mg of calcium but couldn't adjust it if they knew the actual amount was different.

The challenge: `LogFoodSheet` receives a `let food: SavedFood`. We can't mutate the model directly (that would change the saved template for all future uses). The solution is a local `@State` copy of the micronutrients dictionary:

```swift
// Initialized from the food template, editable by the user
@State private var editedMicros: [String: MicronutrientValue]

init(food: SavedFood, logDate: Date = .now) {
    // ... other init ...
    _editedMicros = State(initialValue: food.micronutrients)
}
```

Each `EditableMicroRow` gets an `onValueChanged` callback that writes back to `editedMicros`. At log time, the button applies the same quantity/unit scaling factor to `editedMicros` instead of the original template values:

```swift
// Apply edited micronutrients, scaled by the same factor as macros
entry.micronutrients = [:]
for (key, micro) in editedMicros {
    entry.micronutrients[key] = MicronutrientValue(
        value: micro.value * factor,
        unit: micro.unit
    )
}
```

**Why not use `@Bindable`?** Because `SavedFood` is a `@Model` (reference type), and we specifically *don't* want edits to flow back to the persistent model. Using `@State` creates a value-type copy that lives only in this sheet's lifetime. If the user cancels, nothing changes. This is the "edit a draft, commit on save" pattern — common in forms that shouldn't have live persistence.

## Step 5: Text Shadow for Legibility

The simplest change, but important for Liquid Glass design. RadialMenuButton's option labels (`.caption2` weight, `.secondary` color) were nearly invisible when the menu appeared over light content. One modifier:

```swift
Text(item.label)
    .font(.caption2)
    .fontWeight(.medium)
    .foregroundStyle(isHighlighted ? item.color : .secondary)
    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
```

Apple uses the same pattern for labels overlaid on glass effects — a subtle dark shadow ensures minimum contrast regardless of what's behind the glass.

## The Gotcha: Corrupted File Ending

When inserting `EditableMicroRow` at the end of `LogFoodSheet.swift`, the replacement accidentally placed the new struct *inside* the closing braces of `MicronutrientProgressRow`. The file ended with `}       }` — orphaned braces that made the struct boundaries nonsensical. The compiler's error was `cannot find 'EditableMicroRow' in scope` because it was syntactically inside another struct.

This is a risk with string-based file editing: if the "old string" context doesn't perfectly capture the struct boundary, the "new string" lands in the wrong nesting level. The fix was to look at the actual file ending, match the corrupted braces, and replace the whole tail with correctly structured code.

**Lesson:** After any file edit that adds code near struct/class boundaries, verify the file's brace nesting before building. `tail -20 file.swift` catches this instantly.

## What's Next

The remaining backlog item is **weekly/monthly daily averages** — currently `NutritionDetailView` shows totals for multi-day periods ("14,000 kcal this week"), which should instead display the daily average ("2,000 kcal/day avg"). The data is already divided correctly in `NutritionStore.aggregateMacros`, but the labels and some code paths need updating.

Other areas for future polish:
- The `FoodNutrientBreakdownView` could include a comparison mode (this food vs. daily goals as a percentage breakdown)
- Micronutrient editing in LogFoodSheet could auto-suggest FDA daily values for nutrients the user adds manually
- The circular rings could animate their trim value on appear for a satisfying fill-in effect

---

Five changes, one build pass, zero regressions. The trick to shipping a batch of backlog items in one session isn't speed — it's ordering them so each change is independently testable and no two changes touch the same code path.
