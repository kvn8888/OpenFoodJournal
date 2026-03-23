# From Static Strips to Scrollable Weeks: Redesigning a Food Journal's UX in One Session

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

## Step 4: The Calendar Rewrite — From Discrete Swipes to Continuous Scroll

This was the biggest change. The old `WeeklyCalendarStrip` showed one week at a time (Sunday–Saturday) with a `DragGesture` that snapped forward/backward by exactly one week on each swipe. Want to check 3 weeks ago? Three deliberate swipe-and-wait gestures. The request was inspired by iOS Calendar's interaction feel: **continuous horizontal scrolling with smooth momentum that snaps to week boundaries**, not discrete tap-to-advance.

The key insight: the iOS Calendar reference wasn't about emulating a monthly grid — it was about the *interaction pattern*. Scroll freely, let momentum carry you, and the view gracefully settles on a clean boundary. Applied to weeks instead of months.

### The Architecture

The old approach used `DragGesture` with manual offset calculation. The new one uses SwiftUI's built-in scroll snapping (iOS 17+):

```swift
ScrollView(.horizontal, showsIndicators: false) {
    LazyHStack(spacing: 0) {
        ForEach(weeks) { week in
            weekRow(for: week)
                .containerRelativeFrame(.horizontal)  // Each week fills the viewport
                .id(week.id)
        }
    }
    .scrollTargetLayout()  // Marks each child as a snap target
}
.scrollTargetBehavior(.viewAligned)  // Decelerates to nearest target
```

Three APIs make this work together:

1. **`.containerRelativeFrame(.horizontal)`** — Each week row sizes itself to exactly fill the ScrollView's width. No hardcoded widths, no GeometryReader.
2. **`.scrollTargetLayout()`** — Tells SwiftUI that each child of the `LazyHStack` is a valid snap point.
3. **`.scrollTargetBehavior(.viewAligned)`** — When the user lifts their finger, the scroll velocity decelerates toward (not stops at) the nearest target. This is the smooth momentum snap.

The combination produces the iOS Calendar feel: flick hard and it glides past several weeks before settling cleanly on a boundary. Flick gently and it snaps to the adjacent week. No custom gesture math, no `UIScrollView` wrapping.

### WeekID: Modeling Scroll Targets

Each week is identified by its Sunday start date:

```swift
private struct WeekID: Hashable, Identifiable {
    let startDate: Date  // The Sunday that starts this week

    var id: TimeInterval { startDate.timeIntervalSinceReferenceDate }

    var dates: [Date] {
        (0..<7).compactMap { offset in
            Calendar.current.date(byAdding: .day, value: offset, to: startDate)
        }
    }
}
```

Using `timeIntervalSinceReferenceDate` as the ID is a trick to get a stable, unique identifier without worrying about date formatting or calendar math edge cases. Two `Date` values that represent the same moment always produce the same `TimeInterval`.

The view pre-generates 52 weeks of history:

```swift
private var weeks: [WeekID] {
    guard let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: Date.now)?.start else {
        return []
    }
    return (-weeksOfHistory...0).compactMap { offset in
        guard let sunday = calendar.date(byAdding: .weekOfYear, value: offset, to: currentWeekStart) else {
            return nil
        }
        return WeekID(startDate: calendar.startOfDay(for: sunday))
    }
}
```

`calendar.dateInterval(of: .weekOfYear, for:)` returns the Sunday–Saturday interval containing the given date. This respects the user's locale — if their calendar starts on Monday, `firstWeekday` would shift everything. Using `.weekOfYear` instead of manual arithmetic avoids that class of bugs.

### Scroll Position Sync

When the user taps "Today" or selects a date via another UI path, the scroll position needs to jump to the correct week. `ScrollViewReader` + `onChange(of:)` handles this:

```swift
ScrollViewReader { proxy in
    ScrollView(.horizontal, showsIndicators: false) {
        // ... week content ...
    }
    .onAppear {
        if let target = selectedWeekID {
            proxy.scrollTo(target.id, anchor: .center)
        }
    }
    .onChange(of: selectedDate) { _, newDate in
        if let target = weekIDForDate(newDate) {
            withAnimation(.spring(duration: 0.3)) {
                proxy.scrollTo(target.id, anchor: .center)
            }
        }
    }
}
```

The `onAppear` scroll has no animation (instant jump to the right week on first render). The `onChange` scroll animates with a spring — so tapping "Today" produces a smooth glide back to the current week.

### What I Got Wrong First

My first implementation was an expandable calendar with a collapsed week strip and an expanded vertical monthly grid. It had sticky headers, `LazyVGrid` month sections, and an expand/collapse toggle. It was technically impressive and completely missed the point.

The user's request was about **horizontal scrolling with momentum snapping** — not about showing more dates. A vertical monthly grid solves a different problem (seeing a month at a glance). The actual pain was: "I can't scroll freely through my week history." The fix was removing the `DragGesture` and replacing it with a proper `ScrollView` that has the right snapping behavior behind it.

**Lesson**: When a user references another app's interaction, focus on the *verb* (scrolls with momentum, snaps cleanly) not the *noun* (monthly grid, sticky headers). The interaction pattern is the feature, not the layout.

## The Gotcha: The Phantom Duplicate File

After making all changes, the build failed with:

```
error: invalid redeclaration of 'NutritionDetailView'
```

The project had two files declaring the same view: `NutritionDetailView.swift` and an untracked `MicronutrientSummaryView.swift` that contained an identical copy. It wasn't in the Xcode project file — Xcode was picking it up because Swift Package Manager-style folder references include all `.swift` files in the directory.

This is a common trap with Xcode's directory-based target membership. If you create a file, delete it from the project navigator (which only removes the `project.pbxproj` reference), but don't delete it from disk, it can silently re-emerge when Xcode or the build system decides to include all directory contents. The fix was removing the duplicate file from the working directory.

**Lesson**: If you get "invalid redeclaration" in a SwiftUI project and you're sure you only declared the type once, search the file system (`find . -name "*.swift" | xargs grep "struct MyView"`), not just the Xcode project navigator. The navigator lies.

## What's Next

The Food Bank's "Last Used" sort is only as good as the data. Existing foods start with `lastUsedAt = createdAt`, so the first time a user opens the app after the update, the order will match "Newest First." It self-corrects as they log meals, but a migration that backdates `lastUsedAt` from actual log entries would be more accurate.

The calendar currently generates 52 static weeks on init. If the user keeps the app open across a week boundary, the list won't update. A smarter approach would regenerate weeks lazily or observe a timer, but for a food journal that's typically opened-and-closed per meal, it's not a real issue.

---

Thirteen files changed, zero new dependencies added. Sometimes the best feature work isn't building new things — it's removing the friction from what's already there.
