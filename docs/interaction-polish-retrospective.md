# Making It Feel Right: Swipes, Prompts, and Hidden Arrows

OpenFoodJournal had working features that didn't feel finished. The scan flow fired immediately with no chance to add context. The calendar had chevron buttons in an app full of gesture-driven interactions. The macro chart required precise taps on a tiny segmented picker. And a disclosure arrow on the macro summary card broke the visual language of the entire journal view. This session was about interaction polish — the kind of work where nothing is broken but everything gets better.

## The Starting Point

Four pain points, all UX:

1. **Scan flow**: Camera capture → immediate Gemini request. No way to tell the AI "this is walnut shrimp" or "this is an 8oz container." The prompt field I first added was on the camera view *before* capture, which meant you had to know what you were going to photograph before photographing it. And it didn't exist at all for photos picked from the library.

2. **Calendar strip**: Used left/right chevron buttons to change weeks. Every other navigation in the app — tabs, sheets, the radial menu — used gestures. The chevrons felt like a holdover from a prototype.

3. **Macro chart**: The history view's bar chart had a segmented picker (Calories / Protein / Carbs / Fat) that required precise tapping on small text. On a phone held in one hand, this is awkward.

4. **Disclosure arrow**: Wrapping the `MacroSummaryBar` in a `NavigationLink` to reach the micronutrients page added the standard iOS disclosure chevron (>) on the right side of the card. It looked wrong — this is a glass card, not a settings row.

---

## Step 1: Post-Capture Prompt Flow

The original prompt field sat on the camera view between the mode hint and the capture button. Two problems: you had to type context *before* seeing what you captured (you might not know you need to clarify until you see the photo), and for library picks the flow was capture → dismiss → send, skipping the prompt entirely.

The fix was a two-phase capture flow. After taking a photo or selecting from the library, instead of immediately calling `scanInBackground`, the camera view transitions to a confirmation overlay:

```swift
@State private var capturedImage: UIImage?

// After capture/selection, show prompt overlay instead of dismissing
if let image = capturedImage {
    promptOverlay(image: image)
        .transition(.opacity)
} else {
    cameraOverlay
        .transition(.opacity)
}
```

The overlay shows the captured image, a prompt text field, and two buttons: Retake (clears `capturedImage`, returns to camera) and Analyze (sends to Gemini with the optional prompt, dismisses).

The key insight: the photo library path now converges with the camera path. `onChange(of: photoSelection)` loads the image and sets `capturedImage` instead of immediately calling `scanInBackground`. Both paths land on the same prompt overlay.

```swift
.onChange(of: photoSelection) { _, newItem in
    guard let newItem else { return }
    Task {
        if let data = try? await newItem.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            withAnimation { capturedImage = image }  // → prompt overlay
        }
    }
}
```

The prompt is sent as an additional `prompt` form field in the multipart request to the Render proxy. The server-side route needs a matching change to forward it to Gemini's prompt — that's a separate task.

---

## Step 2: Scan Result Button Rework

While rethinking the scan flow, the action buttons on the result card got reworked too. Previously, "Add to Log" both logged the entry *and* auto-saved to Food Bank. "Save to Food Bank" was a separate button that only saved (no log). This conflated two actions and meant you couldn't log something without cluttering your Food Bank.

The new layout has three buttons with clear intent:

- **"Add to Log & Save"** (prominent, top) — logs to journal and saves to Food Bank. The common case for foods you'll eat again.
- **"Add to Log"** (secondary) — logs only. For one-off meals you won't repeat.
- **"Retake"** (secondary) — dismiss and re-scan.

The implementation split `onConfirm` into `onConfirm` (log only) and `onConfirmAndSave` (log + Food Bank save). The `ScanResultSheet` in `DailyLogView` provides both callbacks:

```swift
ScanResultCard(
    entry: entry,
    onConfirm: {
        nutritionStore.log(entry, to: logDate)
        // No Food Bank save
    },
    onConfirmAndSave: {
        nutritionStore.log(entry, to: logDate)
        let saved = SavedFood(from: entry)
        nutritionStore.modelContext.insert(saved)
        // ...
    },
    onRetake: { ... }
)
```

---

## Step 3: Swipeable Calendar with Drag Feel

Removing the chevron buttons and adding swipe was straightforward — a `DragGesture` that checks horizontal distance and calls the same week-navigation logic. The interesting part was making it *feel* physical.

A bare swipe gesture with no visual feedback feels like pressing a hidden button. The user swipes and the content just pops to a new week. Adding a `dragOffset` that follows the finger during the drag makes it feel like you're pulling the calendar:

```swift
@State private var dragOffset: CGFloat = 0

.offset(x: dragOffset)
.gesture(
    DragGesture(minimumDistance: 20)
        .onChanged { value in
            let dampen: CGFloat
            if value.translation.width < 0 && isCurrentWeek {
                dampen = 0.1   // Heavy resistance at boundary
            } else {
                dampen = 0.3   // Normal dampening
            }
            dragOffset = value.translation.width * dampen
        }
        .onEnded { value in
            // Navigate or snap back...
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                dragOffset = 0
            }
        }
)
```

Three details matter here:

1. **Dampening (0.3×)**: The calendar moves at 30% of finger speed. Full 1:1 tracking would look like you're dragging the strip off-screen. The reduced ratio gives a "pulling against resistance" feel — you can see it responding but it's not going anywhere until you commit.

2. **Boundary resistance (0.1×)**: When swiping left on the current week (future — nowhere to go), the dampening drops to 10%. The calendar barely budges, signaling "this is the end" without a hard stop. This is the same rubber-band pattern iOS uses for scroll bounce.

3. **Spring snap-back**: If the swipe doesn't cross the threshold, the offset animates back to zero with a slight bounce. If it does navigate, the offset resets as the content changes — the week data updates and the strip renders the new dates at `offset: 0`.

---

## The Gotcha: The Invisible Arrow

The macro summary card needed to navigate to the micronutrient detail view on tap. The obvious SwiftUI approach:

```swift
NavigationLink {
    MicronutrientSummaryView()
} label: {
    MacroSummaryBar(log: log, goals: goals)
}
```

This works — but `NavigationLink` inside a `List` always renders a disclosure chevron (>) on the right edge. There's no built-in modifier to hide it. The card is a full-width glass effect with calorie counts and progress rings; a gray chevron wedged into the right side looked like a rendering bug.

The fix is a well-known SwiftUI workaround: put the `NavigationLink` in a hidden `.background` instead of wrapping the content:

```swift
MacroSummaryBar(log: log, goals: goals)
    .background {
        NavigationLink("", destination: MicronutrientSummaryView())
            .opacity(0)
    }
```

The `NavigationLink` still exists in the view hierarchy — it still makes the row tappable and navigates on tap — but at `opacity(0)` the chevron is invisible. The empty string label means there's no text to render either. The `MacroSummaryBar` is the visible content; the link is just plumbing.

This pattern works because `NavigationLink`'s tap behavior comes from its presence in a `NavigationStack`'s `List`, not from its visibility. iOS resolves the tap to the nearest `NavigationLink` ancestor regardless of opacity.

---

## Step 4: Swipeable Macro Chart

The macro chart swipe was simpler than the calendar because there's no drag animation needed — the chart already animates its bars and colors on category change. A `DragGesture` that cycles through `ChartMacro.allCases` by index:

```swift
.gesture(
    DragGesture(minimumDistance: 30)
        .onEnded { value in
            let horizontal = value.translation.width
            guard abs(horizontal) > abs(value.translation.height) else { return }

            if horizontal < 0, macroIndex < allCases.count - 1 {
                withAnimation { selectedMacro = allCases[macroIndex + 1] }
            } else if horizontal > 0, macroIndex > 0 {
                withAnimation { selectedMacro = allCases[macroIndex - 1] }
            }
        }
)
```

The segmented picker still works for direct selection — the swipe is additive, not a replacement. The `guard abs(horizontal) > abs(vertical)` check prevents accidental category changes during vertical scrolling in the history view.

---

## What's Next

- **Server-side prompt forwarding**: The iOS side sends a `prompt` form field, but the Express proxy doesn't forward it to Gemini yet. That's a one-line addition to the prompt template in `server/index.js`.
- **Haptic feedback on swipe navigation**: The calendar and chart swipes would benefit from a subtle `UIImpactFeedbackGenerator` tap when a navigation triggers — the same feedback the radial menu uses.
- **Calendar snap direction hint**: When dragging the calendar, the day cells could fade slightly in the direction of travel, hinting at what week is coming next.
- **Food Bank swipe consistency**: The Food Bank row interactions were separately improved (switching from `onTapGesture` to `Button` + `.buttonStyle(.plain)`) to fix swipe action jank — the same gesture coexistence issue that makes `DragGesture` tricky inside `List`.

---

The best interaction design is the kind users never notice. They just swipe and it works.
