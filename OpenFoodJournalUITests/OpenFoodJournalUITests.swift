//
//  OpenFoodJournalUITests.swift
//  OpenFoodJournalUITests
//
//  Created by Kevin Chen on 3/19/26.
//

import XCTest

final class OpenFoodJournalUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["OFJ_UI_TEST_MODE"] = "1"
        app.launch()
    }

    @MainActor
    func testSeparateProvidersAzureConnectionAndContextPresets() throws {
        app.tabBars.buttons["Settings"].tap()

        let scanProvider = app.descendants(matching: .any)["settings.scan-provider"]
        XCTAssertTrue(scrollToElement(scanProvider))

        let assistantProvider = app.descendants(matching: .any)["settings.assistant-provider"]
        XCTAssertTrue(scrollToElement(assistantProvider))
        assistantProvider.tap()
        let azureChoice = app.buttons["Azure OpenAI"]
        XCTAssertTrue(azureChoice.waitForExistence(timeout: 2))
        azureChoice.tap()

        let context = app.descendants(matching: .any)["settings.context-budget"]
        XCTAssertTrue(scrollToElement(context))
        context.tap()
        let maximum = app.buttons["Maximum"]
        XCTAssertTrue(maximum.waitForExistence(timeout: 2))
        maximum.tap()

        let solTest = app.descendants(matching: .any)["settings.azure-test.gpt-5.6-sol"]
        XCTAssertTrue(scrollToElement(solTest))
        solTest.tap()
        let status = app.descendants(matching: .any)["settings.azure-status.gpt-5.6-sol"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertEqual(status.label, "Connected")
    }

    @MainActor
    func testInterruptedRunResponseInfoSourceAndStop() throws {
        app.tabBars.buttons["Assistant"].tap()

        let continueButton = app.descendants(matching: .any)["assistant.continue"]
        XCTAssertTrue(scrollToElement(continueButton), app.debugDescription)
        continueButton.tap()

        let completedResponse = app.staticTexts["UI test response with a durable source."]
        XCTAssertTrue(completedResponse.waitForExistence(timeout: 5))
        completedResponse.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 2))
        app.buttons["Info"].tap()
        XCTAssertTrue(app.navigationBars["Response Info"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Context Window"].exists)
        app.buttons["Done"].tap()

        let source = app.descendants(matching: .any)["assistant.source.0"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(source.label.contains("Test source"))

        let input = app.textFields["assistant.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 2))
        input.tap()
        input.typeText("UI_TEST_BLOCK")
        app.buttons["assistant.send"].tap()

        let stop = app.buttons["assistant.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        stop.tap()
        XCTAssertTrue(app.staticTexts["The Assistant run was stopped."].waitForExistence(timeout: 3))
    }

    private func scrollToElement(_ element: XCUIElement) -> Bool {
        if element.exists && element.isHittable { return true }
        for _ in 0..<8 {
            app.swipeUp()
            if element.exists && element.isHittable { return true }
        }
        return element.exists
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let measuredApp = XCUIApplication()
            measuredApp.launchEnvironment["OFJ_UI_TEST_MODE"] = "1"
            measuredApp.launch()
        }
    }
}
