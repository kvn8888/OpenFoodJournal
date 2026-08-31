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
        let supported: Set<String> = ["journal", "food-bank", "history", "assistant", "settings", "log-food"]
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
            let attachment = XCTAttachment(screenshot: app.screenshot())
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
