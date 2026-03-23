# From Static Strips to Scrollable Months: Redesigning a Food Journal's UX in One Session

A nutrition tracker lives or dies by how fast you can log a meal. If it takes more than a few seconds to find a food, enter data, and move on, people stop using it. This session tackled five pain points in OpenFoodJournal — a SwiftUI + SwiftData iOS app — all rooted in the same insight: **the UI was making common actions harder than they needed to be**.

The changes spanned 13 files across three areas: the Food Bank list, keyboard interactions, and the calendar strip. Each one had its own design challenge.

## The Starting Point

OpenFoodJournal's Food Bank is a searchable list of saved foods — things the user has scanned or manually entered. Before this session, it had three problems:

1. **Visual noise**: Each row showed a source icon (scan vs. manual) that nobody cared about after the first day of use, while the information people *did* want (macros) was hidden behind a tap.
2. **Sorting was alphabetical by default**: If you eat the same 15 foods repeatedly (most people do), you'd scroll past dozens of entries to find them.
3. **Search only matched food names**: If you remembered "Kirkland" (the brand) but not "Protein Bar" (the name), you were out of luck.

The calendar was a fixed 7-day strip (Sunday–Saturday). Want to check what you ate 3 weeks ago? Tap, tap, tap, tap, tap, tap. The keyboard had no "Done" button on numeric inputs, leaving users stranded on decimal pads with no way to dismiss.

## Step 1: Redesigning the Food Bank Row

The goal was to make each row a glanceable nutrition summary. The old `SavedFoodRowView` had this layout:

```
[Source Icon] [Name + Serving] ────────────── [Calories]
```

The new one puts calories in the strongest visual position (left, where your eye starts) and adds macro chips from the journal's existing `MacroChip` component:

```swift
HStack(spacing: 12) {
    // Left: Calorie count as the primary identifier
    VStack(alignment: .center, spacing: 2) {
        Text("\(Int(food.calories))")
            .font(.headline)
            .fontWeight(.semibold)
            .monospacedDigit()
        Text("cal")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
    .frame(width: 44)

    // Center: Food name + brand + serving
    VStack(alignment: .leading, spacing: 2) {
        if let brand = food.brand, !brand.isEmpty {
            Text(brand)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text(food.name)
            .font(.body)
            .fontWeight(.medium)
    }

    Spacer()

    // Right: Macro chips matching the journal page
    HStack(spacing: 6) {
        MacroChip(value: food.protein, color: .blue,   label: "P")
        MacroChip(value: food.carbs,   color: .green,  label: "C")
        MacroChip(value: food.fat,     color: .yellow,  label: "F")
    }
}
```

The interesting bit was the `MacroChip` reuse. It already existed in `EntryRowView` (the journal's row component), but it was declared `private struct`. One word change — dropping `private` to make it `internal` — let both views share the same component. No new abstractions, no shared module, just a visibility change.

**What I'd do differently**: In hindsight, `MacroChip` probably belongs in the `Shared/` directory as its own file rather than living inside `EntryRowView.swift`. But moving it would mean touching the Xcode project file (`project.pbxproj`), which is a merge-conflict magnet. For a solo-dev project, leaving it where it is costs nothing.

## Step 2: "Last Used" Sort and Brand Search

Most food tracking is repetitive — the user logs the same breakfast most days. An alphabetical default sort ignores this entirely.

The fix had two parts. First, adding a `lastUsedAt` timestamp to the `SavedFood` SwiftData model:

```swift
@Model
final class SavedFood {
    var lastUsedAt: Date  // New: tracks when the food was last logged
    // ...
    init(/* ... */) {
        // ...
        self.lastUsedAt = createdAt  // Defaults to creation time
    }
}
```

SwiftData handles lightweight migrations automatically for new fields, so this "just works" — existing foods get their `createdAt` as the initial `lastUsedAt` value. No migration manifest needed for additive schema changes, which is one of SwiftData's genuine wins over Core Data.

Second, setting `lastUsedAt = .now` in `LogFoodSheet` whenever a food is logged, and adding the sort option:

```swift
enum SortOrder: String, CaseIterable, Identifiable {
    case lastUsed       // New default
    case newest
    case alphabetical
    case calories
}
```

The `filteredFoods` computed property handles both sort and brand search:

```swift
private var filteredFoods: [SavedFood] {
    let filtered = searchText.isEmpty
        ? allFoods
        : allFoods.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.brand?.localizedCaseInsensitiveContains(searchText) ?? false)
        }

    switch sortOrder {
    case .lastUsed:
        return filtered.sorted { $0.lastUsedAt > $1.lastUsedAt }
    // ...
    }
}
```

The `localizedCaseInsensitiveContains` call is important for i18n correctness — it handles accented characters and locale-specific casing rules automatically. Don't use `.lowercased().contains()` for user-facing search; it breaks for Turkish İ/i, German ß, and many other cases.

## Step 3: Keyboard Done Buttons (The Boring-but-Critical Fix)

Numeric keyboards on iOS don't have a Return key. If your app presents a decimal pad without a Done button, users literally cannot dismiss the keyboard without tapping elsewhere — and some views don't have a "elsewhere" to tap.

The fix is `ToolbarItemGroup(placement: .keyboard)`:

```swift
.toolbar {
    ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { focusedField = false }
    }
}
```

This adds a "Done" button to the accessory bar above the keyboard. Simple, but there's a catch: **it only works if the view is inside a `NavigationStack`**. For views that aren't (like `ScanResultCard`), you need a different approach:

```swift
ToolbarItemGroup(placement: .keyboard) {
    Spacer()
    Button("Done") {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}
```

This sends the `resignFirstResponder` message up the responder chain — the UIKit equivalent of "whoever has the keyboard, please dismiss it." It works universally but it's a UIKit escape hatch that feels slightly wrong in pure SwiftUI code. Apple's SwiftUI team hasn't provided a native "dismiss keyboard" API yet (`.scrollDismissesKeyboard` only works for scroll views), so this is the standard workaround.

Six files needed the Done button: `ScanResultCard`, `ScanCaptureView`, `CompleteContainerSheet`, `NewContainerSheet`, `EditFoodSheet`, and `GoalsEditorView`. The audit was mechanical — search for `TextField` and `keyboardType(.decimalPad)` across the project, check if each has a dismiss mechanism, add one if not.

## Step 4: The Calendar Rewrite — From Strip to Scrollable Grid

This was the biggest change. The old `WeeklyCalendarStrip` showed one week at a time (Sunday–Saturday) with left/right swipe gestures. The request was to make it behave like the iOS Calendar app: a vertically scrollable month grid that snaps smoothly to month boundaries.

Rather than replacing the week strip entirely, I made it **expandable** — tapping the month/year header toggles between the compact week strip and a full monthly grid:

```swift
@State private var isExpanded = false

var body: some View {
    VStack(spacing: 0) {
        toggleHeader  // Tap to expand/collapse + "Today" button

        if isExpanded {
            expandedCalendar  // Full monthly grid
        } else {
            collapsedWeekStrip  // Original week strip
        }
    }
    .glassEffect(in: .rect(cornerRadius: 16))
    .animation(.spring(duration: 0.35, bounce: 0.15), value: isExpanded)
}
```

### The Month Grid

Each month is a `Section` inside a `LazyVStack` with `pinnedViews: [.sectionHeaders]` — this gives you sticky month headers that stay visible as you scroll, exactly like iOS Calendar:

```swift
ScrollView(.vertical, showsIndicators: false) {
    LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
        ForEach(months) { month in
            Section {
                monthGrid(for: month)
            } header: {
                Text(month.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    .scrollTargetLayout()
}
.scrollTargetBehavior(.viewAligned)
.frame(height: 280)
```

The `.scrollTargetLayout()` + `.scrollTargetBehavior(.viewAligned)` combination (iOS 17+) is the key to smooth snapping. When the user lifts their finger mid-scroll, SwiftUI automatically decelerates to the nearest section boundary instead of stopping at an arbitrary offset. This is the same API that makes `TabView` with `.page` style snap — it just works on any `ScrollView` with marked target content.

### The MonthID Model

Each month is identified by a `MonthID` struct that generates its own date arrays:

```swift
private struct MonthID: Hashable, Identifiable {
    let year: Int
    let month: Int

    var id: Int { year * 100 + month }

    var dates: [Date] {
        let calendar = Calendar.current
        let components = DateComponents(year: year, month: month, day: 1)
        guard let firstDay = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: firstDay)
        else { return [] }
        return range.compactMap { day in
            calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
    }

    var firstWeekdayOffset: Int {
        // Returns 0 for Sunday, 1 for Monday, etc.
        // Used to add leading empty cells so the grid aligns correctly
        let calendar = Calendar.current
        let components = DateComponents(year: year, month: month, day: 1)
        guard let firstDay = calendar.date(from: components) else { return 0 }
        return calendar.component(.weekday, from: firstDay) - 1
    }
}
```

The `firstWeekdayOffset` is critical for grid alignment. Without leading empty cells, January 1st (a Wednesday) would appear in the Sunday column. The `ForEach(0..<month.firstWeekdayOffset)` before the actual day cells fills those leading slots with `Color.clear` spacers.

### DayCellView Dual Mode

The existing `DayCellView` needed to work in both the week strip (where it shows day abbreviations like "Mon") and the month grid (where column headers handle that). A `compact` parameter controls this:

```swift
private struct DayCellView: View {
    let date: Date
    let state: DayCellState
    var compact: Bool = false

    private var circleSize: CGFloat { compact ? 30 : 34 }

    var body: some View {
        VStack(spacing: compact ? 0 : 4) {
            if !compact {
                Text(dayAbbreviation)
                    .font(.caption2)
            }
            // Progress ring + date number (shared between both modes)
            ZStack { /* ... */ }
                .frame(width: circleSize, height: circleSize)
        }
    }
}
```

This avoided duplicating the progress ring rendering logic. The `compact` parameter defaults to `false`, so existing call sites in the week strip don't need changes.

### Auto-Collapse Behavior

When you tap a date in the expanded grid, the calendar collapses back to the week strip centered on that date. This felt natural in testing — you expand to find a date, tap it, and the view gets out of your way:

```swift
.onTapGesture {
    if date <= Date.now || calendar.isDateInToday(date) {
        withAnimation(.spring(duration: 0.3)) {
            selectedDate = date
            isExpanded = false  // Collapse after selection
        }
    }
}
```

## The Gotcha: The Phantom Duplicate File

After making all changes, the build failed with:

```
error: invalid redeclaration of 'NutritionDetailView'
```

The project had two files declaring the same view: `NutritionDetailView.swift` and an untracked `MicronutrientSummaryView.swift` that contained an identical copy. It wasn't in the Xcode project file — Xcode was picking it up because Swift Package Manager-style folder references include all `.swift` files in the directory.

This is a common trap with Xcode's directory-based target membership. If you create a file, delete it from the project navigator (which only removes the `project.pbxproj` reference), but don't delete it from disk, it can silently re-emerge when Xcode or the build system decides to include all directory contents. The fix was removing the duplicate file from the working directory.

**Lesson**: If you get "invalid redeclaration" in a SwiftUI project and you're sure you only declared the type once, search the file system (`find . -name "*.swift" | xargs grep "struct MyView"`), not just the Xcode project navigator. The navigator lies.

## What's Next

The calendar's momentum snapping works via `.scrollTargetBehavior(.viewAligned)`, but the iOS Calendar app has an even smoother feel — it uses custom `UIScrollView` deceleration curves that SwiftUI doesn't expose. A future refinement could wrap a `UIScrollView` via `UIViewRepresentable` with tuned `decelerationRate` and `UIScrollViewDelegate` snapping, but the current behavior is good enough for most users.

The Food Bank's "Last Used" sort is only as good as the data. Existing foods start with `lastUsedAt = createdAt`, so the first time a user opens the app after the update, the order will match "Newest First." It self-corrects as they log meals, but a migration that backdates `lastUsedAt` from actual log entries would be more accurate.

---

Thirteen files changed, zero new dependencies added. Sometimes the best feature work isn't building new things — it's removing the friction from what's already there.
