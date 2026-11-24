import Testing
import UIKit
@testable import OpenFoodJournal

struct NumericInputTests {
    @Test(arguments: [
        ("1.5", 1.5), ("1,5", 1.5), ("0", 0.0), (" 42.25 ", 42.25),
        ("0,75", 0.75), (",5", 0.5), ("-2,5", -2.5), ("1.", 1.0)
    ])
    func parsesDecimal(_ text: String, expected: Double) {
        #expect(OFJNumericInput.parse(text) == expected)
    }

    @Test(arguments: ["", " ", "abc", "1.2.3", "1,2,3", "1.2,3", "1,2.3", ".", "1 000", "inf", "1e3"])
    func rejectsMalformedInput(_ text: String) {
        #expect(OFJNumericInput.parse(text) == nil)
    }

    @MainActor
    @Test func selectsKeyboardForDeviceIdiom() {
        #expect(OFJNumericInput.keyboardType(for: .pad) == .numbersAndPunctuation)
        #expect(OFJNumericInput.keyboardType(for: .phone) == .decimalPad)
        #expect(OFJNumericInput.defaultKeyboardType == OFJNumericInput.keyboardType(for: UIDevice.current.userInterfaceIdiom))
    }
}
