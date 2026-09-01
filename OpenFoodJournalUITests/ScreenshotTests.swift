import XCTest

/// Opt-in visual evidence from the real app, using only the Debug fixture store.
final class ScreenshotTests: XCTestCase {
    @MainActor
    func testCaptureSelectedScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OFJ_CAPTURE_SCREENSHOTS"] == "1" else {
            throw XCTSkip("Screenshot generation is an explicit CI action.")
        }
        continueAfterFailure = false
        let supported: Set<String> = ["journal", "nutrition", "scan", "food-bank", "history", "assistant", "settings", "log-food"]
        let selection = environment["OFJ_SCREENSHOT_SCREENS"] ?? "all"
        let screens = selection == "all" ? supported : Set(selection.split(separator: ",").map(String.init))
        let appearance = environment["OFJ_SCREENSHOT_APPEARANCE"] ?? "light"
        XCTAssertFalse(screens.isEmpty)
        XCTAssertTrue(screens.isSubset(of: supported), "Unknown screenshot selection: \(selection)")
        XCTAssertTrue(["light", "dark"].contains(appearance))

        let app = XCUIApplication()
        app.launchEnvironment["OFJ_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OFJ_SCREENSHOT_MODE"] = "1"
        app.launchEnvironment["TZ"] = "UTC"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.buttons["journal.settings"].waitForExistence(timeout: 15))

        func capture(_ screen: String) {
            // Include system chrome as displayed, even when a sheet or a
            // navigation destination owns a different app window.
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "ofj--\(screen)--\(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func tab(_ title: String) {
            let button = app.tabBars.buttons[title]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "Missing \(title) tab")
            button.tap()
        }

        if screens.contains("journal") {
            XCTAssertTrue(app.navigationBars["August 2026"].waitForExistence(timeout: 10))
            capture("journal")
        }
        if screens.contains("nutrition") {
            // The macro summary card carries an invisible NavigationLink to the
            // Nutrition page, so tapping the row is what opens it.
            let summary = app.descendants(matching: .any)["journal.nutrition"]
            XCTAssertTrue(summary.waitForExistence(timeout: 10), "Missing journal macro summary")
            summary.tap()
            XCTAssertTrue(app.navigationBars["Nutrition"].waitForExistence(timeout: 10))
            capture("nutrition")
            // NutritionDetailView hides the system back button for a custom one.
            app.buttons["Journal"].firstMatch.tap()
            XCTAssertTrue(app.buttons["journal.settings"].waitForExistence(timeout: 10))
        }
        if screens.contains("scan") {
            let add = app.descendants(matching: .any)["journal.add"]
            XCTAssertTrue(add.waitForExistence(timeout: 10))
            add.tap()
            let scan = app.descendants(matching: .any)["journal.action.scan"]
            XCTAssertTrue(scan.waitForExistence(timeout: 10))
            scan.tap()
            let preview = app.descendants(matching: .any)["scan.screenshot-preview"]
            XCTAssertTrue(preview.waitForExistence(timeout: 10), "Expected camera-free screenshot mode")
            for label in ["Scan Food", "Barcode", "Food Label", "Exit camera", "Capture photo",
                          "Choose from photo library", "Turn torch on",
                          "Set camera zoom to 0.5 times", "Set camera zoom to 1 time", "Set camera zoom to 2 times"] {
                XCTAssertTrue(app.buttons[label].exists, "Missing camera control: \(label)")
                XCTAssertTrue(app.buttons[label].isEnabled, "Unavailable preview control: \(label)")
            }
            // These actions only update local presentation state in this mode.
            app.buttons["Barcode"].tap()
            XCTAssertTrue(app.buttons["Barcode"].isSelected)
            app.buttons["Food Label"].tap()
            XCTAssertTrue(app.buttons["Food Label"].isSelected)
            app.buttons["Scan Food"].tap()
            app.buttons["Set camera zoom to 2 times"].tap()
            XCTAssertTrue(app.buttons["Set camera zoom to 2 times"].isSelected)
            app.buttons["Set camera zoom to 0.5 times"].tap()
            XCTAssertTrue(app.buttons["Set camera zoom to 0.5 times"].isSelected)
            app.buttons["Set camera zoom to 1 time"].tap()
            app.buttons["Turn torch on"].tap()
            XCTAssertTrue(app.buttons["Turn torch off"].waitForExistence(timeout: 5))
            app.buttons["Turn torch off"].tap()
            app.buttons["Capture photo"].tap()
            app.buttons["Choose from photo library"].tap()
            XCTAssertTrue(app.buttons["Exit camera"].isHittable, "Preview must not open hardware or permission UI")
            capture("scan")
            app.buttons["Exit camera"].tap()
            XCTAssertTrue(app.buttons["journal.settings"].waitForExistence(timeout: 10))
        }
        if screens.contains("food-bank") || screens.contains("log-food") {
            tab("Food Bank")
            let food = app.buttons["food-bank.food.00000000-0000-4000-8000-000000000001"]
            XCTAssertTrue(food.waitForExistence(timeout: 10), "Sample Food Bank was not seeded")
            if screens.contains("food-bank") { capture("food-bank") }
            if screens.contains("log-food") {
                food.tap()
                XCTAssertTrue(app.navigationBars["Log food"].waitForExistence(timeout: 10))
                capture("log-food")
                app.buttons["Cancel"].tap()
                XCTAssertTrue(food.waitForExistence(timeout: 10))
            }
        }
        if screens.contains("history") {
            tab("History")
            XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
            capture("history")
        }
        if screens.contains("assistant") {
            tab("Assistant")
            XCTAssertTrue(app.navigationBars["Today's nutrition"].waitForExistence(timeout: 10))
            capture("assistant")
        }
        if screens.contains("settings") {
            tab("Journal")
            app.buttons["journal.settings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
            capture("settings")
        }
        app.terminate()
    }
}
