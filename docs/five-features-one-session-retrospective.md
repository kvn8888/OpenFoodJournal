# Five Features, One Session: Manual Entry, Scan Timing, Calendar Rings, and the Art of Small Changes

This session tackled five separate feature requests in a single sitting — each small enough to implement in under an hour, but collectively transforming the app's observability, navigation flow, and data entry flexibility. The thread connecting them: turning implicit information into explicit UI and closing gaps between related features that should have been connected all along.

---

## The Feature List

1. **Manual entry gets a brand field and food bank save** — previously, manual entries couldn't be saved as reusable foods
2. **Hide the Gemini prompt for label scans** — the context prompt is useful for food photos but confusing for structured OCR
3. **Log scan processing time in milliseconds** — instrument the scan pipeline for optimization visibility
4. **Replace the system calendar with calorie-ring progress** — match the weekly calendar strip's at-a-glance nutrition feedback
5. **Macro comparison cards navigate to nutrition detail** — close a dead-end in the History tab's information hierarchy

Each one is a 20–80 line change. None required new dependencies, new screens, or architectural changes. The interesting part is how each one taught something about SwiftUI patterns.

---

## Feature 1: Manual Entry → Food Bank Bridge

### The Problem

ManualEntryView let you type in a food name, pick a meal, enter macros, and add it to your journal. But it had no brand field (so "Protein Bar" from Costco looked identical to one from Trader Joe's), and no way to save the entry as a reusable `SavedFood` in the Food Bank.

Meanwhile, `EditFoodSheet` (the Food Bank editor) had a brand field and saved to the food bank — but couldn't log directly to the journal. Two sheets doing half the job each.

### The Implementation

The fix had three parts:

**1. Add the brand field with proper focus chain:**

```swift
enum ManualEntryField: Hashable {
    case name, brand, calories, protein, carbs, fat
}

// In the form body:
TextField("Brand (optional)", text: $brand)
    .focused($focusedField, equals: .brand)

// Focus chain: name → brand → calories → protein → carbs → fat
.onSubmit {
    switch focusedField {
    case .name: focusedField = .brand
    case .brand: focusedField = .calories
    // ... etc
    }
}
```

The focus chain matters for keyboard UX on iOS. Without it, tapping "Next" on the keyboard after typing the food name would dismiss the keyboard entirely instead of advancing to the brand field. `@FocusState` with enum cases and `onSubmit` gives you sequential field navigation for free.

**2. Replace the "Add" button with a Menu:**

```swift
ToolbarItem(placement: .confirmationAction) {
    Menu {
        Button {
            save(saveToFoodBank: true)
        } label: {
            Label("Add to Journal & Food Bank", systemImage: "bookmark.fill")
        }
        
        Button {
            save(saveToFoodBank: false)
        } label: {
            Label("Add to Journal", systemImage: "plus")
        }
    } label: {
        Text("Add")
    }
}
```

SwiftUI's `Menu` in a toolbar renders as a dropdown on tap — perfect for a two-option confirmation action. The primary action (journal + food bank) gets the filled bookmark icon, reinforcing that it's the "save for later" path.

**3. Create SavedFood when requested:**

```swift
private func save(saveToFoodBank: Bool) {
    let entry = NutritionEntry(/* ... all fields ... */)
    nutritionStore.addEntry(entry, to: logDate)
    
    if saveToFoodBank {
        let savedFood = SavedFood(from: entry)
        savedFood.brand = brand
        modelContext.insert(savedFood)
        syncService.createFood(savedFood)
    }
    dismiss()
}
```

`SavedFood(from:)` is an existing convenience initializer that copies macros/micros from a `NutritionEntry`. We just set the brand separately and let SwiftData's `modelContext.insert()` handle persistence. The sync call is fire-and-forget — if it fails, the food is still saved locally.

### Lesson Learned

When two sheets (ManualEntryView, EditFoodSheet) do overlapping things, sometimes the right fix isn't merging them into one view — it's giving each one the missing capability. ManualEntryView's job is "quick log from keyboard." EditFoodSheet's job is "curate your food bank." Adding food bank save to ManualEntryView bridges the gap without disrupting either workflow.

---

## Feature 2: Conditional Prompt for Scan Modes

### The Problem

When you scan a nutrition label, the app showed a text field asking for context (e.g., "walnut shrimp"). That prompt makes sense for food photos where Gemini needs to identify the dish, but for nutrition labels the data is already structured — the extra prompt just confuses users and potentially confuses the OCR model.

### The Implementation

One line of SwiftUI conditional rendering:

```swift
// In promptOverlay(image:)
if mode == .foodPhoto {
    HStack(spacing: 8) {
        TextField("Add context, e.g. \"walnut shrimp\"", text: $promptText)
            .font(.subheadline)
            // ... styling
    }
    .glassEffect(in: .capsule)
    .padding(.horizontal, 32)
}
```

`mode` is a `@State private var mode: ScanMode = .label` toggled by a `Picker` in the camera overlay. When the user captures a photo, the prompt overlay reads the current `mode` value. For `.label`, the TextField simply doesn't render — the user sees their photo and the Retake/Analyze buttons directly.

### Why This Is Interesting

The fix is trivial, but the pattern is worth highlighting: **conditional UI based on user-selected mode, not data state.** Most SwiftUI conditionals check data (`if items.isEmpty`, `if let error`). This one checks intent — the user declared "I'm scanning a label" by selecting the mode, so the UI adapts to that intent. The `@State` variable does double duty as UI state (which picker segment is selected) and business logic (which Gemini model to use and whether to show the prompt).

---

## Feature 3: Scan Performance Instrumentation

### The Problem

Scans go through a multi-step pipeline: image resize → JPEG compression → multipart upload to Render → Render proxies to Gemini → JSON response → parse into NutritionEntry. We had no visibility into how long this took, making optimization impossible.

### The Implementation

Swift's `ContinuousClock` provides nanosecond-precision timing without the footgun of `Date()` comparisons (which can be affected by system clock changes):

```swift
func scan(image: UIImage, mode: ScanMode, prompt: String? = nil) async throws -> NutritionEntry {
    let scanStart = ContinuousClock.now
    
    // ... resize, compress, upload, parse ...
    
    let durationMs = Int(scanStart.duration(to: .now)
        .components.attoseconds / 1_000_000_000_000_000)
    
    lastScanDurationMs = durationMs
    entry.scanDurationMs = durationMs
    
    print("📸 Scan completed in \(durationMs)ms (mode: \(mode.rawValue))")
    return entry
}
```

The duration is stored in three places:
1. **Console** (`print`) — for development debugging
2. **Observable property** (`lastScanDurationMs`) — for real-time UI display
3. **Model property** (`entry.scanDurationMs`) — for historical analysis

The model addition is a single optional Int on `NutritionEntry`:

```swift
@Model final class NutritionEntry {
    // ...
    var scanDurationMs: Int?  // nil for manual entries
}
```

SwiftData handles the lightweight schema migration automatically — new optional properties with nil defaults don't require a migration plan.

The UI display in ScanResultCard:

```swift
if let ms = entry.scanDurationMs {
    Label("\(ms)ms", systemImage: "timer")
        .font(.caption2)
        .foregroundStyle(.secondary)
}
```

### The Attosecond Gotcha

`ContinuousClock.Duration` stores time as attoseconds (10⁻¹⁸ seconds). The conversion to milliseconds requires dividing by 10¹⁵:

```swift
duration.components.attoseconds / 1_000_000_000_000_000
```

This is a common trap. If you use `1_000_000_000` (nanoseconds) you get microseconds, not milliseconds. If you use `1_000_000_000_000` (picoseconds) you get seconds. The 15-zero denominator converts attoseconds → milliseconds directly.

An alternative approach uses the `components` tuple:

```swift
let (seconds, attoseconds) = duration.components
let ms = seconds * 1000 + attoseconds / 1_000_000_000_000_000
```

Both work. The single-division version is simpler for our use case since scans are always under 60 seconds.

---

## Feature 4: Calendar Grid with Calorie Progress Rings

### The Problem

The History tab used `DatePicker("Select date", ...).datePickerStyle(.graphical)` — Apple's built-in monthly calendar. It works, but it's a black box: every day looks the same regardless of whether you ate 200 or 2000 calories. Meanwhile, the `WeeklyCalendarStrip` on the Journal tab showed calorie progress rings for each day of the current week. The History calendar deserved the same visual feedback.

### The Implementation

`CalendarGridView` is a custom monthly calendar built from scratch with `LazyVGrid`:

```swift
struct CalendarGridView: View {
    @Binding var selectedDate: Date
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals
    
    @State private var displayedMonth: Date = .now
    
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
```

**The grid math** is the most interesting part. A month grid needs empty cells before the first day to align with the correct weekday column:

```swift
private func daysInMonth() -> [Date?] {
    let start = startOfMonth(for: displayedMonth)
    guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
    
    // Days before the 1st that need blank cells
    let firstWeekday = calendar.component(.weekday, from: start)
    let leadingBlanks = (firstWeekday - calendar.firstWeekday + 7) % 7
    
    var days: [Date?] = Array(repeating: nil, count: leadingBlanks)
    
    for day in range {
        if let date = calendar.date(byAdding: .day, value: day - 1, to: start) {
            days.append(date)
        }
    }
    return days
}
```

The `% 7` modular arithmetic handles locale-dependent first weekday (Sunday in US, Monday in Europe). Without it, the grid would be misaligned for non-US locales.

**Each day cell** is a `ZStack` with three layers:

```swift
private func dayCell(for date: Date) -> some View {
    ZStack {
        // 1. Background track ring (faint circle)
        Circle().stroke(.secondary.opacity(0.15), lineWidth: 2)
        
        // 2. Progress ring (colored arc from top, clockwise)
        Circle()
            .trim(from: 0, to: min(progress, 1.0))
            .stroke(ringColor(for: progress),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
        
        // 3. Day number text
        Text("\(calendar.component(.day, from: date))")
    }
}
```

The `.rotationEffect(.degrees(-90))` is crucial — `Circle().trim()` starts drawing at the 3 o'clock position by default. Rotating by -90° moves the start to 12 o'clock, which is the expected behavior for a progress ring.

**Color thresholds** match the `WeeklyCalendarStrip` exactly:

| Range | Color | Meaning |
|-------|-------|---------|
| < 50% | Red | Way under |
| 50–80% | Yellow | Getting there |
| 80–95% | Light green | Almost |
| 95–105% | Green | On target |
| 105–120% | Orange | Slightly over |
| > 120% | Purple | Way over |

**Month navigation** uses swipe gestures in addition to chevron buttons:

```swift
.gesture(
    DragGesture(minimumDistance: 50, coordinateSpace: .local)
        .onEnded { value in
            if value.translation.width < -50 && !isCurrentMonth {
                // Swipe left → next month
                withAnimation(.spring(duration: 0.3)) {
                    displayedMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth)!
                }
            } else if value.translation.width > 50 {
                // Swipe right → previous month
                withAnimation(.spring(duration: 0.3)) {
                    displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth)!
                }
            }
        }
)
```

The `minimumDistance: 50` prevents accidental swipes when tapping day cells. Forward navigation is disabled past the current month (`!isCurrentMonth` guard) since future days have no data.

### The Type Mismatch Bug

The first build failed with three errors in CalendarGridView:

```
Cannot convert value of type 'ShapeStyle' to expected argument type 'Color'
```

The culprit was ternary expressions mixing `Color` and `HierarchicalShapeStyle`:

```swift
// ❌ Broken — .primary is HierarchicalShapeStyle, Color.blue is Color
.foregroundStyle(isToday ? .blue : .primary)

// ✅ Fixed — both branches return Color
.foregroundStyle(isToday ? Color.blue : Color.primary)
```

In SwiftUI, `.blue` in a `foregroundStyle` context resolves to `Color.blue`, but `.primary` resolves to `HierarchicalShapeStyle.primary` — they're different types. Swift's type inference can't find a common supertype for the ternary, so it fails. The fix is explicit `Color.` prefixes on both branches to guarantee the same concrete type.

This is a common SwiftUI gotcha. The rule: **if a ternary feeds into a generic `ShapeStyle` parameter, make both branches the same concrete type.**

---

## Feature 5: Macro Cards → Nutrition Detail Navigation

### The Problem

The History tab shows week-over-week macro comparison cards (calories, protein, carbs, fat) in a grid. Tapping them did nothing — a dead end in the navigation hierarchy. The natural expectation is that tapping a nutrition summary should take you to the detailed nutrition view.

### The Implementation

```swift
NavigationLink {
    NutritionDetailView()
} label: {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ForEach(comparisonCards) { card in
            ComparisonCard(card: card)
        }
    }
}
.buttonStyle(.plain)
```

The `.buttonStyle(.plain)` is critical. Without it, `NavigationLink` adds a disclosure indicator and applies its own button styling, which conflicts with the card's existing visual design. `.plain` tells SwiftUI "this is a navigation link but don't change how it looks."

Wrapping the entire `LazyVGrid` (not individual cards) means any tap in the grid navigates. This is intentional — the whole section is a single navigation target, not four separate ones. If we later want per-macro deep links, we'd wrap individual `ComparisonCard` views instead.

---

## What I Got Right

1. **Incremental changes, each independently testable.** Each feature was committed separately (or could have been). None depended on any other. If the calendar change had broken something, I could revert it without losing the scan timing work.

2. **Reusing existing patterns.** The ring color thresholds in CalendarGridView copy WeeklyCalendarStrip exactly. The `SavedFood(from:)` initializer already existed. The `SyncService.createFood()` method was already there. No new infrastructure needed.

3. **Using `ContinuousClock` instead of `Date()`** for timing. `Date()` is wall-clock time — it can jump when the system syncs NTP, when the user crosses time zones, or when the device sleeps. `ContinuousClock` measures monotonic elapsed time, which is what you want for performance measurement.

## What I Got Wrong

1. **The initial CalendarGridView had a type mismatch** in ternary expressions. I should have used explicit `Color.` prefixes from the start — it's a known SwiftUI pattern. The fix was fast, but the first build failure was avoidable.

2. **Didn't add `id` transitions to the month animation.** The `.spring(duration: 0.3)` on month change animates the layout, but the grid content just appears — it doesn't slide in from the side like a page turn. A `.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))` keyed by `displayedMonth` would give a much more polished month-change animation. This is a UX gap I left on the table.

## Key Takeaways for Other Developers

1. **SwiftUI `Menu` in toolbars** is underused. When a confirmation button needs two variants (save vs. save+bookmark, submit vs. submit+share), `Menu` gives you a native dropdown without custom sheet management.

2. **`@FocusState` with enum cases** is the right way to handle multi-field forms. Don't use separate `@FocusState` bools for each field — one enum with `onSubmit` switching gives you sequential keyboard navigation.

3. **`ContinuousClock` for timing, `Date()` for timestamps.** If you're measuring "how long did this take," use `ContinuousClock`. If you're recording "when did this happen," use `Date()`.

4. **Custom calendars aren't that hard.** The entire CalendarGridView is ~230 lines including comments. The hardest part is the leading-blanks math (`(firstWeekday - calendar.firstWeekday + 7) % 7`), and that's a well-known formula. If the system `DatePicker(.graphical)` doesn't give you what you need, building your own is often faster than fighting the system's constraints.

5. **`Circle().trim(from:to:).rotationEffect(.degrees(-90))`** is the canonical SwiftUI progress ring. Memorize it. The -90° rotation moves the start from 3 o'clock to 12 o'clock.
