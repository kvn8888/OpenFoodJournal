// OpenFoodJournal — CursorEndModifier
// Configures shared text-field behavior at the app root.
// AGPL-3.0 License

import SwiftUI
import UIKit
import ObjectiveC

/// Globally configures text input behavior:
/// - places the cursor at the end when a UITextField becomes first responder
/// - dismisses the keyboard when tapping outside text inputs
///
/// Apply once at the app root:
///     ContentView()
///         .cursorAtEnd()
struct CursorEndModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(KeyboardDismissInstaller())
            .onAppear {
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

// MARK: - Tap outside to dismiss keyboard

private struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardDismissHostView {
        let view = KeyboardDismissHostView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: KeyboardDismissHostView, context: Context) {
        uiView.coordinator = context.coordinator
        uiView.installIfNeeded()
    }

    func makeCoordinator() -> KeyboardDismissCoordinator {
        KeyboardDismissCoordinator()
    }
}

private final class KeyboardDismissHostView: UIView {
    weak var coordinator: KeyboardDismissCoordinator?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installIfNeeded()
    }

    func installIfNeeded() {
        guard let window, let coordinator else { return }
        coordinator.install(on: window)
    }
}

private final class KeyboardDismissCoordinator: NSObject, UIGestureRecognizerDelegate {
    private static var associationKey: UInt8 = 0
    private let gestureName = "OpenFoodJournal.dismissKeyboardOnTap"

    func install(on window: UIWindow) {
        guard window.gestureRecognizers?.contains(where: { $0.name == gestureName }) != true else {
            return
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboardIfNeeded(_:)))
        tap.name = gestureName
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        objc_setAssociatedObject(
            window,
            &Self.associationKey,
            self,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    @objc private func dismissKeyboardIfNeeded(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let window = recognizer.view as? UIWindow else { return }

        let location = recognizer.location(in: window)
        if let tappedView = window.hitTest(location, with: nil),
           tappedView.isInsideTextInput {
            return
        }

        window.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

private extension UIView {
    var isInsideTextInput: Bool {
        if self is UITextField || self is UITextView {
            return true
        }
        return superview?.isInsideTextInput ?? false
    }
}
