// OpenFoodJournal — CursorEndModifier
// Places the text cursor at the end of a TextField when it gains focus.
// AGPL-3.0 License

import SwiftUI
import UIKit

/// Globally configures all UITextFields to place the cursor at the end
/// when they become the first responder.
///
/// Apply once at the app root:
///     ContentView()
///         .cursorAtEnd()
struct CursorEndModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                // Swizzle UITextField.becomeFirstResponder to move cursor to end
                CursorEndSwizzle.activate()
            }
    }
}

extension View {
    func cursorAtEnd() -> some View {
        modifier(CursorEndModifier())
    }
}

// MARK: - One-time swizzle

private enum CursorEndSwizzle {
    static var isActive = false

    static func activate() {
        guard !isActive else { return }
        isActive = true

        let original = #selector(UITextField.becomeFirstResponder)
        let swizzled = #selector(UITextField.swizzled_becomeFirstResponder)

        guard let originalMethod = class_getInstanceMethod(UITextField.self, original),
              let swizzledMethod = class_getInstanceMethod(UITextField.self, swizzled) else { return }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
}

extension UITextField {
    @objc func swizzled_becomeFirstResponder() -> Bool {
        // Calls the original (swapped) implementation
        let result = swizzled_becomeFirstResponder()

        if result {
            // Move cursor to end after becoming first responder
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let end = self.endOfDocument
                self.selectedTextRange = self.textRange(from: end, to: end)
            }
        }

        return result
    }
}
