# Putting the Cursor Where You Expect It

Every text field in OpenFoodJournal — calorie counts, food names, serving sizes — placed the cursor at the beginning when you tapped in. If you wanted to tweak a number you'd just typed, you had to manually drag the insertion point to the end. Small friction, but the kind that makes an app feel unfinished. This session fixed it globally with a single modifier and a method swizzle.

## The Starting Point

SwiftUI's `TextField` doesn't expose cursor position. There's no `.cursorPosition(.end)` modifier, no `onFocus` callback that hands you a `UITextRange`. The framework treats the text field as a high-level abstraction — you bind a string, you get a text field, and UIKit handles the rest behind the scenes.

The app has roughly 20 `TextField` instances spread across 9 view files: manual entry, scan results, food bank editing, container tracking, serving mappings. Any solution that required touching each one individually would be fragile and easy to forget when adding new fields.

## Step 1: Finding the Right Level of Abstraction

The question was where to intervene. The options, roughly:

1. **Per-field**: Wrap each `TextField` in a custom view that uses `UIViewRepresentable` to control the underlying `UITextField`. Correct but tedious — 20 fields across 9 files, and every new field needs to remember to use the wrapper.

2. **UITextField.appearance()**: SwiftUI respects `UIAppearance` proxies for many UIKit properties (tint color, font, etc.). But `UITextField.appearance()` doesn't have a cursor-position property — `selectedTextRange` isn't an appearance attribute.

3. **Method swizzling**: Override `UITextField.becomeFirstResponder` globally so that *every* text field moves its cursor to the end when it gains focus. One-time setup, zero per-field work, automatically covers future fields.

I went with option 3 — because the behavior is truly universal (there's no text field in a food journal where "cursor at the start" is the right default) and because it requires zero ongoing maintenance.

## Step 2: The Swizzle

Method swizzling is an Objective-C runtime trick where you swap two method implementations. After swizzling, calling the original method actually runs your replacement, and vice versa. It's powerful and a little dangerous — you're reaching into UIKit's internals — but for a case this simple, it's the pragmatic choice.

The core of it:

```swift
extension UITextField {
    @objc func swizzled_becomeFirstResponder() -> Bool {
        // This calls the ORIGINAL becomeFirstResponder (they're swapped)
        let result = swizzled_becomeFirstResponder()

        if result {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let end = self.endOfDocument
                self.selectedTextRange = self.textRange(from: end, to: end)
            }
        }
        return result
    }
}
```

The confusing part — and the thing that trips up everyone who sees swizzling for the first time — is line 4. `swizzled_becomeFirstResponder()` calling itself looks like infinite recursion. But after `method_exchangeImplementations` swaps the two methods, the name `swizzled_becomeFirstResponder` points to the *original* `becomeFirstResponder` implementation. So this is actually calling Apple's code, not recursing.

The `DispatchQueue.main.async` is necessary because `becomeFirstResponder` fires *before* UIKit finishes setting up the text field's selection state. If you set `selectedTextRange` synchronously, UIKit overwrites it a moment later. The async dispatch pushes the cursor move to the next run loop tick, after UIKit has finished its setup.

## Step 3: Making It SwiftUI-Friendly

The swizzle needs to happen exactly once, as early as possible. I wrapped it in a `ViewModifier` with a static guard:

```swift
private enum CursorEndSwizzle {
    static var isActive = false

    static func activate() {
        guard !isActive else { return }
        isActive = true
        // ... method_exchangeImplementations here
    }
}

struct CursorEndModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear { CursorEndSwizzle.activate() }
    }
}
```

Applied at the app root:

```swift
ContentView()
    .cursorAtEnd()
```

The `isActive` flag ensures the swizzle runs exactly once even if the view reappears. The `onAppear` timing means it fires before any text field could possibly gain focus.

## What's Next

- **Keyboard-specific cursor behavior**: Some fields (like calorie counts) use `.keyboardType(.decimalPad)`. For numeric fields, cursor-at-end is always right. For food names, a user might want to tap into the middle of a word to fix a typo — cursor-at-end could be mildly annoying there. Worth watching for user feedback, but for now the consistency wins.
- **Selection on focus**: A step further would be to *select all* text on focus (like a browser URL bar), so typing immediately replaces the value. That's a different `selectedTextRange` call — `textRange(from: beginningOfDocument, to: endOfDocument)` — and might be the better UX for numeric fields specifically.

---

The best infrastructure is the kind nobody has to think about. Twenty text fields, zero changes.
