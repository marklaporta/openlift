import XCTest

final class TrainingModeUITests: OpenLiftUITestCase {
    func testTrainingModeSwitchPreservesRotationDraft() throws {
        let app = launchApp()

        app.tabBars.buttons["Workout"].tap()
        // Submitting readiness once clears the gate for this draft and date, so the
        // draft header stays visible across the mode switches asserted below.
        submitFixedReadiness(in: app)
        XCTAssertTrue(app.staticTexts["Upper A · Draft session"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)
        let adaptiveMode = app.buttons["Adaptive Floating"]
        XCTAssertTrue(adaptiveMode.waitForExistence(timeout: 5))
        adaptiveMode.tap()
        XCTAssertTrue(app.buttons["Use Adaptive Floating"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.tap()

        app.tabBars.buttons["Workout"].tap()
        XCTAssertTrue(app.staticTexts["Upper A · Draft session"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)
        confirmTrainingMode("Adaptive Floating", in: app)

        app.tabBars.buttons["Workout"].tap()
        XCTAssertTrue(app.staticTexts["No Adaptive Profile"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Upper A · Draft session"].exists)

        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)
        let fixedMode = app.buttons["Fixed Cycle"]
        XCTAssertTrue(fixedMode.waitForExistence(timeout: 5))
        confirmTrainingMode("Fixed Cycle", in: app)

        app.tabBars.buttons["Workout"].tap()
        XCTAssertTrue(app.staticTexts["Upper A · Draft session"].waitForExistence(timeout: 5))
    }

    func testCycleTemplateMutationsRequireConfirmation() throws {
        let app = launchApp()

        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)

        let cloneButtons = app.buttons.matching(NSPredicate(format: "label == 'Clone'"))
        XCTAssertGreaterThan(cloneButtons.count, 0)
        let originalCloneCount = cloneButtons.count
        cloneButtons.firstMatch.tap()
        XCTAssertTrue(app.alerts["Clone Template?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Create Copy"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label == 'Clone'")).count,
            originalCloneCount
        )

        let activate = app.buttons["Activate"].firstMatch
        XCTAssertTrue(activate.waitForExistence(timeout: 5))
        activate.tap()
        XCTAssertTrue(app.alerts["Reset Fixed Cycle?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Activate '")).firstMatch.exists)
        app.buttons["Cancel"].tap()
    }
}
