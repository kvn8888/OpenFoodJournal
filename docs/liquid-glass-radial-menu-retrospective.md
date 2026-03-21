# From Material to Liquid Glass: Rebuilding the RadialMenuButton

The RadialMenuButton in OpenFoodJournal started as a floating "+" that revealed action options above it. It worked. But with the app targeting iOS 26.2, it looked like it was built in a different era — a static frosted circle in an app full of living, morphing glass. This session converted it to Liquid Glass, fixed a handful of layout bugs along the way, and ran headfirst into the most counterintuitive API decision Apple made with the new glass system.

## The Starting Point

The button was a 64pt `Circle()` filled with `.ultraThinMaterial` — iOS's frosted glass material — pinned to the bottom center of the screen. On tap, it fanned out 3–4 option circles above it in a semicircle arc. Each option used `Circle().fill(Color(.systemGray5))`, turning item-colored when highlighted. The rest of the app had been fully upgraded to Liquid Glass (`GlassEffectContainer`, `.glassEffect()`, `.buttonStyle(.glass)`) except this button.

There were also two pre-existing bugs I noticed while looking at the component:

1. The screen would darken using `Color.black.opacity` as an overlay — but not blur.
2. When the menu opened, the "+" button would jump upward toward the center of the screen.

---

## Step 1: Fixing the Layout Jump

The button lived inside an outer `ZStack` with no alignment specified:

```swift
ZStack {
    if isOpen { Color.black.opacity(0.1).ignoresSafeArea() }
    ZStack { /* option circles */ }
    plusButton
}
.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
```

The jump happened because `ZStack` defaults to `.center` alignment for its children. When the overlay appeared — expanded to full screen via `.ignoresSafeArea()` — the ZStack's frame grew to fill the screen, and both the option circles and the plus button got repositioned to the new center.

The fix was one word:

```swift
ZStack(alignment: .bottom) {
```

The `alignment` parameter on `ZStack` controls how *children* are placed within it. (The `.alignment` on `.frame()` is different — it controls how the frame itself aligns within its parent.) With `.bottom`, all children anchor to the bottom center regardless of how large the overlay grows.

---

## Step 2: Adding Background Blur

While fixing the overlay, I swapped `Color.black.opacity(0.1)` for `Rectangle().fill(.ultraThinMaterial)`. The material gives both a slight dim and a background blur in one shot — the system calculates the right opacity automatically based on the current color scheme.

```swift
Rectangle()
    .fill(.ultraThinMaterial)
    .ignoresSafeArea()
    .onTapGesture { close() }
    .transition(.opacity)
```

The `Rectangle` is needed here (not `Color`) because `.fill()` is a shape modifier. `.ultraThinMaterial` is the lightest material option; `.thinMaterial` and `.regularMaterial` step up in intensity if you want more of a frosted look.

---

## Step 3: The Liquid Glass Conversion

The core idea with Liquid Glass morphing is this: when glass-effect views overlap inside a `GlassEffectContainer`, their glass shapes merge into one. As they animate apart, the glass splits. This is the "splitting" behavior we wanted — the single plus button's glass splitting apart into the option circles as they fan out.

The structural change was wrapping both the plus button and the option circles inside a `GlassEffectContainer`:

```swift
GlassEffectContainer(spacing: 16) {
    ZStack {
        ForEach(...) { optionBubble(...) }  // options at offset (0,0) when closed
        plusButton
    }
}
```

When the menu is closed, every option circle sits at offset `(0, 0)` — directly on top of the plus button. The container sees all those glass shapes in the same position and merges them into one. When the menu opens, they animate to their arc positions (radius 110pt), and the glass splits apart.

The `spacing: 16` value determines the merge threshold. I chose 16 because adjacent open option circles have roughly a 15pt edge-to-edge gap — just under the threshold, so they remain slightly connected (an organic fan shape rather than fully isolated pills). Using `spacing: 8` gives clean separation if that's preferred.

One important fix: the option circles previously used `.scaleEffect(0.3)` in the closed state for a "pop-in" animation effect. I changed this to `1.0`. The glass merge is driven by position overlap, not scale — at 0.3 scale the glass shapes are still present but tiny, which produces a weird shrinking blob effect during open. Opacity handles the visibility transition cleanly without interfering with the merge geometry.

---

## The Gotcha: `glassEffect()` Goes on the Content, Not the Container

This is where I lost time.

**Symptom**: After converting to Liquid Glass, all the icons (the "+" and the option SF Symbols) appeared blurred — as if the glass effect was frosting over them instead of sitting behind them.

**First attempt**: I suspected the `.overlay {}` modifier was the problem — that the icon overlay was being captured as part of the glass view's render pass. I replaced `.overlay` with a `ZStack`, making the icon a sibling of the glass circle:

```swift
// First fix — still wrong
ZStack {
    Circle().fill(.clear).glassEffect(in: .circle)
    Image(systemName: item.icon)...
}
.frame(width: optionSize, height: optionSize)
```

Same result. The icons were still blurred.

**Root cause**: I had the whole model wrong. I was thinking of `.glassEffect` the way you'd think of `.background` — you apply it to a container and the glass sits behind whatever's inside. But that's not how it works.

The Apple docs state it directly:

> *"The `glassEffect(_:in:)` modifier captures the content to send to the container to render. Apply the `glassEffect(_:in:)` modifier **after** other modifiers that affect the appearance of the view."*

And their example:

```swift
Image(systemName: "scribble.variable")
    .frame(width: 80.0, height: 80.0)
    .font(.system(size: 36))
    .glassEffect()   // ← goes on the Image itself
```

`.glassEffect()` is applied *to the content view*. The glass renders **behind** that view's content. So the correct pattern is: put the icon in an `Image`, give it a frame, then apply `.glassEffect(in: .circle)`. The icon itself becomes the view; the glass is just its background.

```swift
// Correct
Image(systemName: item.icon)
    .font(.system(size: 22, weight: .semibold))
    .foregroundStyle(isHighlighted ? item.color : .primary)
    .frame(width: optionSize, height: optionSize)
    .glassEffect(
        isHighlighted ? .regular.tint(item.color.opacity(0.35)) : .regular,
        in: .circle
    )
```

No `Circle()`, no `ZStack`. The `Circle` shape in `.glassEffect(in: .circle)` tells it what *shape* to use for the glass — not what view to use as the surface. The entire separate `Circle()` view was unnecessary all along.

The same fix applies to the plus button:

```swift
Image(systemName: "plus")
    .font(.system(size: 28, weight: .bold))
    .foregroundStyle(.primary)
    .rotationEffect(.degrees(isOpen ? 45 : 0))
    .frame(width: plusSize, height: plusSize)
    .glassEffect(in: .circle)
```

Clean, direct, no intermediate views.

---

## What's Next

- **Interactive glass**: The option bubbles could benefit from `.regular.interactive()` to get the tactile press response that `buttonStyle(.glass)` provides to standard buttons. Worth trying once the morph animation feels right.
- **Spacing tuning**: `spacing: 16` is a starting point. The organic merged-fan look vs. fully-split circles is a feel preference — tweak by adjusting the `GlassEffectContainer` spacing value alone.
- **`glassEffectID` transitions**: The Apple docs describe `glassEffectID(_:in:)` for coordinating morphing between views that appear/disappear in the hierarchy. As new menu items get added or removed, this could make them morph into/out of the plus button with a proper matched-geometry glass transition rather than a simple opacity fade.

---

The lesson from `.glassEffect()` applies to a lot of SwiftUI: when an API feels like "I'm styling a container," check whether it actually means "I'm styling this view from the outside in." Sometimes the glass is the background of the thing, not the thing itself.
