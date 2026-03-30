# Building a Gesture Tutorial Animation in Pure SwiftUI

**Date**: June 2025  
**Branch**: `app-store`  
**Commits**: `c2b8419` → `8700f06` (7 commits)

## The Problem

OpenFoodJournal has a radial menu — a floating "+" button that fans out four action items (Food Bank, Containers, Manual Entry, Scan) in an arc. The intended power-user gesture is **press and drag**: hold the + button, drag to your target while the menu fans out, release to select. But without instruction, every new user defaults to tap-to-open, then tap-to-select — two taps instead of one fluid gesture.

We needed an animated tutorial for the onboarding flow that teaches this drag-to-select pattern. The constraints: pure SwiftUI (no Lottie, no Rive, no external dependencies), the animation must loop forever, and it has to match the real menu's geometry exactly.

## What We Built

A self-contained `RadialMenuDemo` view that shows a finger icon pressing the + button, the radial options fanning out, the finger dragging to the Scan option, the option highlighting, and the finger releasing. The whole cycle runs about 5 seconds and loops indefinitely.

### The Phase State Machine

The entire animation is driven by a single `@State` enum:

```swift
private enum Phase: CaseIterable {
    case idle           // Plus button visible, finger off-screen
    case fingerAppears  // Finger slides into view
    case pressing       // Finger presses the button (scale-down)
    case menuOpen       // Radial options fan out
    case dragging       // Finger moves toward the Scan option
    case highlighted    // Scan option highlights
    case released       // Finger lifts, menu closes
    case pause          // Brief pause before looping
}

@State private var phase: Phase = .idle
```

Every visual property — finger position, finger opacity, finger scale, plus button scale, plus button offset, option visibility, option highlighting — is a computed property that switches on `phase`. There's no `@State` for each individual property. One source of truth.

### The Animation Driver

A `Task` loop advances through phases with `withAnimation` and `Task.sleep`:

```swift
private func startAnimation() {
    Task {
        while !Task.isCancelled {
            phase = .idle
            try? await Task.sleep(for: .seconds(0.8))
            
            withAnimation(.easeOut(duration: 0.5)) {
                phase = .fingerAppears
            }
            try? await Task.sleep(for: .seconds(0.6))
            
            withAnimation(.easeInOut(duration: 0.15)) {
                phase = .pressing
            }
            try? await Task.sleep(for: .seconds(0.2))
            
            withAnimation(.spring(duration: 0.4, bounce: 0.3)) {
                phase = .menuOpen
            }
            try? await Task.sleep(for: .seconds(0.5))
            
            withAnimation(.easeInOut(duration: 0.8)) {
                phase = .dragging
            }
            try? await Task.sleep(for: .seconds(0.85))
            
            // ... release, pause, loop
        }
    }
}
```

This pattern — `withAnimation` followed by `try? await Task.sleep` — is the SwiftUI equivalent of keyframe animation. Each `withAnimation` wraps a phase transition with its own timing curve and duration. The `sleep` gives that animation time to complete before the next phase starts.

**Why not `PhaseAnimator`?** SwiftUI's built-in `PhaseAnimator` iterates through phases automatically, but it gives you one timing curve for all transitions. We needed different curves for different moments — a snappy `easeInOut(duration: 0.15)` for the press, a bouncy `spring(duration: 0.4, bounce: 0.3)` for the fan-out, a smooth `easeInOut(duration: 0.8)` for the drag. The `Task` loop gives us per-phase timing control.

### Matching the Real Menu Geometry

The real `RadialMenuButton` places items at angles from 210° to 330° using this formula:

```swift
private func angleForIndex(_ index: Int) -> Double {
    let startAngle = 210.0
    let endAngle = 330.0
    let step = (endAngle - startAngle) / Double(items.count - 1)
    return startAngle + step * Double(index)
}

private func positionForAngle(_ degrees: Double) -> CGPoint {
    let radians = CGFloat(degrees * .pi / 180)
    return CGPoint(
        x: arcRadius * cos(radians),
        y: arcRadius * sin(radians)
    )
}
```

In SwiftUI's coordinate system (y increases downward), `sin(210°) = -0.5` and `sin(330°) = -0.5`, so both endpoints have **negative y** — placing them above the button. The midpoint at 270° has `sin(270°) = -1`, the highest point. This creates a semicircular arc above the + button, exactly matching the production layout.

The demo uses slightly smaller dimensions (`arcRadius: 80` vs production's `110`, `optionSize: 44` vs `60`) so it fits comfortably in the onboarding page frame, but the angles and relative proportions are identical.

## Three Iterations to Get Right

### Iteration 1: The Tap-Then-Move Problem

The first version had the finger appear, press the button (scale down briefly), then scale back up and move to the camera icon. Users described it as "clicking and then moving to the camera icon and pressing again" — it looked like two separate tap actions rather than a continuous drag.

**The fix**: Keep the finger at pressed scale (0.85) for the entire press-through-drag sequence:

```swift
private var fingerIsPressed: Bool {
    switch phase {
    case .pressing, .menuOpen, .dragging, .highlighted: return true
    default: return false
    }
}
```

### Iteration 2: The Invisible Connection

Even with the finger staying pressed, there was no visual connection between the finger drag and the + button. In the real app, the + button subtly follows your finger (`translation * 0.15`), creating a rubber-band feel that communicates "this button is attached to your finger."

**The fix**: Add a `plusButtonFollowOffset` computed property:

```swift
private var plusButtonFollowOffset: CGPoint {
    switch phase {
    case .dragging, .highlighted:
        let targetPos = positionForAngle(angleForIndex(targetIndex))
        return CGPoint(x: targetPos.x * 0.15, y: targetPos.y * 0.15)
    default:
        return .zero
    }
}
```

Applied to the plus button: `.offset(x: plusButtonFollowOffset.x, y: plusButtonFollowOffset.y)`

### Iteration 3: The Midpoint Stop

The drag animation had two phases: finger moves halfway to the target, pauses, then moves the rest of the way. This made it look like the user was hesitating or searching. Real drag gestures are one continuous motion.

**The fix**: Merge the `dragging` and `highlighted` finger positions so both map to the final target position. The finger now moves from the button to the Scan icon in one 0.8-second `easeInOut` animation:

```swift
case .dragging, .highlighted:
    let targetPos = positionForAngle(angleForIndex(targetIndex))
    return CGPoint(
        x: targetPos.x + 5,
        y: 60 + targetPos.y + 15
    )
```

The `highlighted` phase still exists as a separate state (it triggers the blue highlight on the Scan option) but doesn't change the finger position — it's purely a visual feedback phase.

## Architecture Decision: One Enum vs. Many @State Variables

An alternative approach would have been multiple `@State` properties:

```swift
// DON'T DO THIS
@State private var fingerX: CGFloat = 0
@State private var fingerY: CGFloat = 200
@State private var fingerOpacity: Double = 0
@State private var fingerScale: Double = 1.0
@State private var showOptions: Bool = false
@State private var highlightedIndex: Int? = nil
@State private var plusFollowX: CGFloat = 0
@State private var plusFollowY: CGFloat = 0
```

This creates a combinatorial explosion of states. With 8 independent variables, you have to carefully coordinate which ones change at each animation step. Miss one and you get visual glitches (finger at the wrong scale, options visible when they shouldn't be, etc.).

The single-enum approach means every visual property is deterministically derived from one value. You can't have the finger in the "pressed" scale while the options are in the "idle" visibility — the phase is either `.pressing` (finger down, options hidden) or `.menuOpen` (finger down, options visible). Impossible states are impossible.

## The Onboarding Integration

The demo is page 4 of a 6-page onboarding flow (Welcome → API Key → Goals → Camera → **Radial Menu** → HealthKit):

```swift
private var radialMenuTutorialPage: some View {
    VStack(spacing: 24) {
        Spacer()
        
        Text("Quick Actions")
            .font(.largeTitle.bold())
        
        Text("Press and drag the + button to quickly select an action.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        
        RadialMenuDemo()
            .frame(height: 260)
        
        Spacer()
        nextButton
    }
    .padding()
}
```

Placed after the Camera permission page because by that point the user knows about scanning. The page also mentions "Or just tap it to see your options" — the drag gesture is presented as a power-user shortcut, not the only way.

We also added a "Show Onboarding" button in Settings > About for users who want to revisit:

```swift
Button {
    showOnboarding = true
} label: {
    Label("Show Onboarding", systemImage: "hand.wave")
}
.fullScreenCover(isPresented: $showOnboarding) {
    OnboardingView()
}
```

This required adding `@Environment(\.dismiss) private var dismiss` to `OnboardingView` and calling `dismiss()` alongside `hasCompletedOnboarding = true` — otherwise the fullScreenCover wouldn't close when triggered from Settings (the `@AppStorage` flag was already `true`).

## The Cleanup Sprint

Before building the animation, we did a cleanup sprint (commit `c2b8419`, -583 lines):

1. **Removed `sourceImage: Data?`** from `NutritionEntry` and `SavedFood` models. This property stored the original scan photo but was never displayed anywhere — pure iCloud storage waste. Removed from models, initializers, and `ScanService.toNutritionEntry()`.

2. **Deleted `TursoMigrationView.swift`** and its trigger in Settings. With CloudKit replacing Turso, the migration tool was dead code.

3. **Added App Store 5.1.2(i) disclosure** to the onboarding API key page: "When you scan food, your photo is sent to Google's Gemini API for analysis. No other personal data is shared." Apple requires explicit disclosure when apps share data with third-party AI.

4. **Updated PRIVACY.md** to reflect the BYOK architecture — no proxy server, direct Gemini REST calls, API key in Keychain.

5. **Created `docs/app-store-metadata.md`** with description, keywords (99 chars), subtitle, review notes explaining BYOK to the Apple reviewer.

## What We Learned

1. **Phase state machines are the right abstraction for complex animations.** One enum, computed properties for every visual attribute. No coordination bugs, easy to add/remove phases.

2. **`Task` + `withAnimation` + `Task.sleep` beats `PhaseAnimator` when you need per-phase timing curves.** `PhaseAnimator` is great for simple sequences, but real animations need different easing for different moments.

3. **Three iterations minimum for animation polish.** The first version "works" but looks mechanical. Each iteration catches a subtlety humans notice but developers miss: continuous press state, rubber-band follow, no midpoint stops.

4. **Match the production geometry exactly.** Using the same angle/position math as the real component means the demo looks identical. Users won't be confused when they see the real thing.

5. **The `dismiss()` gotcha with fullScreenCover.** When `OnboardingView` was only ever shown at app launch (gated by `@AppStorage`), it didn't need `dismiss()`. Making it re-showable from Settings required adding the dismiss call — the `@AppStorage` flag flip that normally "dismisses" it does nothing when it's already `true`.

## Files Changed

| File | Change |
|------|--------|
| `Views/Onboarding/RadialMenuDemo.swift` | **New** — 330-line animated gesture tutorial |
| `Views/Onboarding/OnboardingView.swift` | Added page 4 (radial menu), `dismiss()`, page count 5→6 |
| `Views/Settings/SettingsView.swift` | Added "Show Onboarding" button, removed Turso/sourceImage UI |
| `Models/NutritionEntry.swift` | Removed `sourceImage: Data?` property |
| `Models/SavedFood.swift` | Removed `sourceImage: Data?` property |
| `Services/ScanService.swift` | Removed `imageData` parameter from `toNutritionEntry` |
| `Views/FoodBank/LogFoodSheet.swift` | Removed stale Turso comments |
| `Views/FoodBank/EditFoodSheet.swift` | Removed stale Turso comments |
| `Models/Enums.swift` | Removed stale Turso comments |
| `PRIVACY.md` | Updated for BYOK (no proxy server) |
| `docs/app-store-metadata.md` | **New** — App Store listing content |

## Commits (chronological)

| Hash | Description | Delta |
|------|-------------|-------|
| `c2b8419` | Cleanup: sourceImage, Turso, AI disclosure | -583 lines |
| `83f66a3` | Privacy policy update for BYOK | +/- |
| `f710d9a` | App Store metadata | +130 lines |
| `0d45bca` | Radial menu demo animation | +330 lines |
| `7c54535` | Show Onboarding button in Settings | +14 lines |
| `fe97db6` | Finger stays pressed, plus follows | +30/-4 |
| `8700f06` | Smooth continuous drag, no midpoint stop | +11/-23 |
