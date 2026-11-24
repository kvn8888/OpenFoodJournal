import SwiftUI
import UIKit

enum OFJNumericInput {
    nonisolated static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /[+-]?(?:[0-9]+(?:[.,][0-9]*)?|[.,][0-9]+)/) != nil,
              let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")),
              value.isFinite else { return nil }
        return value
    }

    static var defaultKeyboardType: UIKeyboardType {
        keyboardType(for: UIDevice.current.userInterfaceIdiom)
    }

    static func keyboardType(for idiom: UIUserInterfaceIdiom) -> UIKeyboardType {
        idiom == .pad ? .numbersAndPunctuation : .decimalPad
    }
}

struct OFJNumericTextField: UIViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var isFocused: Binding<Bool>? = nil
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var textAlignment: NSTextAlignment = .natural
    var textColor: UIColor = .label
    var minWidth: CGFloat? = nil
    var returnKeyType: UIReturnKeyType = .done
    var onSubmit: (() -> Void)? = nil

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.keyboardType = OFJNumericInput.defaultKeyboardType
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.borderStyle = .none
        field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // SwiftUI's .keyboard toolbar does not reliably attach to UIViewRepresentable
        // responders on iPhone; provide a native Done/Next bar above .decimalPad while
        // leaving iPad free of inputAccessoryView conflicts.
        if OFJNumericInput.defaultKeyboardType == .decimalPad {
            field.inputAccessoryView = context.coordinator.makeAccessoryToolbar(
                for: field,
                returnKeyType: returnKeyType,
                hasSubmitAction: onSubmit != nil
            )
        }
        return field
    }

    func updateUIView(_ uiView: Field, context: Context) {
        context.coordinator.parent = self
        uiView.placeholder = placeholder
        uiView.font = font
        uiView.textAlignment = textAlignment
        uiView.textColor = textColor
        uiView.returnKeyType = returnKeyType
        uiView.isEnabled = context.environment.isEnabled
        if uiView.text != text {
            uiView.text = text
        }
        if OFJNumericInput.defaultKeyboardType == .decimalPad {
            context.coordinator.updateAccessoryToolbar(
                for: uiView,
                returnKeyType: returnKeyType,
                hasSubmitAction: onSubmit != nil
            )
        }

        guard let isFocused, isFocused.wrappedValue != uiView.isFirstResponder else { return }
        DispatchQueue.main.async { [weak uiView, weak coordinator = context.coordinator] in
            guard let uiView, uiView.window != nil, uiView.isEnabled,
                  let desired = coordinator?.parent.isFocused?.wrappedValue,
                  desired != uiView.isFirstResponder else { return }
            if desired {
                uiView.becomeFirstResponder()
            } else {
                uiView.resignFirstResponder()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Field, context: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        let intrinsicWidth = max(intrinsic.width, minWidth ?? 0)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? intrinsicWidth
        return CGSize(width: max(width, minWidth ?? 0), height: max(intrinsic.height, ceil(font.lineHeight)))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Field: UITextField {
        var justBeganEditing = false

        func selectAllText() {
            selectedTextRange = textRange(from: beginningOfDocument, to: endOfDocument)
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: OFJNumericTextField
        private weak var activeField: Field?
        private var configuredAccessoryShowsNext: Bool?

        init(parent: OFJNumericTextField) {
            self.parent = parent
        }

        func makeAccessoryToolbar(
            for field: Field,
            returnKeyType: UIReturnKeyType,
            hasSubmitAction: Bool
        ) -> UIToolbar {
            activeField = field
            let toolbar = UIToolbar()
            toolbar.sizeToFit()
            configureItems(on: toolbar, showsNext: returnKeyType == .next && hasSubmitAction)
            return toolbar
        }

        func updateAccessoryToolbar(
            for field: Field,
            returnKeyType: UIReturnKeyType,
            hasSubmitAction: Bool
        ) {
            activeField = field
            let showsNext = returnKeyType == .next && hasSubmitAction
            guard configuredAccessoryShowsNext != showsNext,
                  let toolbar = field.inputAccessoryView as? UIToolbar else { return }
            configureItems(on: toolbar, showsNext: showsNext)
        }

        private func configureItems(on toolbar: UIToolbar, showsNext: Bool) {
            configuredAccessoryShowsNext = showsNext
            let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            let done = UIBarButtonItem(
                title: "Done",
                style: .done,
                target: self,
                action: #selector(dismissKeyboard)
            )
            if showsNext {
                let next = UIBarButtonItem(
                    title: "Next",
                    style: .plain,
                    target: self,
                    action: #selector(submitAndAdvance)
                )
                toolbar.items = [flex, next, done]
            } else {
                toolbar.items = [flex, done]
            }
        }

        @objc private func dismissKeyboard() {
            activeField?.resignFirstResponder()
        }

        @objc private func submitAndAdvance() {
            if let onSubmit = parent.onSubmit {
                onSubmit()
            } else {
                activeField?.resignFirstResponder()
            }
        }

        @objc func editingChanged(_ field: Field) {
            field.justBeganEditing = false
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            guard let field = textField as? Field else { return }
            activeField = field
            field.justBeganEditing = true
            field.selectAllText()
            if let focus = parent.isFocused, !focus.wrappedValue {
                focus.wrappedValue = true
            }
            // UIKit's tap gesture places the caret after textFieldDidBeginEditing
            // returns on the same run-loop tick. Re-applying once on the next tick
            // ensures select-all wins without interfering with subsequent drags.
            DispatchQueue.main.async { [weak field] in
                guard let field, field.isFirstResponder, field.justBeganEditing else { return }
                field.justBeganEditing = false
                field.selectAllText()
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            (textField as? Field)?.justBeganEditing = false
            if let focus = parent.isFocused, focus.wrappedValue {
                focus.wrappedValue = false
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            if let onSubmit = parent.onSubmit {
                onSubmit()
            } else {
                textField.resignFirstResponder()
            }
            return false
        }
    }
}

extension Binding {
    func numericFocus<Field: Hashable>(equals field: Field) -> Binding<Bool> where Value == Field? {
        Binding<Bool>(
            get: { wrappedValue == field },
            set: { focused in
                if focused {
                    wrappedValue = field
                } else if wrappedValue == field {
                    wrappedValue = nil
                }
            }
        )
    }
}

extension UIFont {
    static func ofjRoundedSystemFont(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let font = systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return UIFont(descriptor: descriptor, size: size)
    }
}
