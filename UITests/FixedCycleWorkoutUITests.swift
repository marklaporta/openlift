import XCTest

final class FixedCycleWorkoutUITests: OpenLiftUITestCase {
    func testAppOpensOnWorkoutTab() throws {
        let app = launchApp()

        // Unique coverage here is the default landing tab and the armed readiness gate.
        // Submitting readiness and asserting the draft header is exercised by five other
        // tests, so this one stops before that expensive sequence.
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 · Readiness"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Log Workout"].exists)
    }

    func testRotationWorkoutFinishShowsRecapAndNonEditableTomorrowPreview() throws {
        let app = launchApp()

        XCTAssertTrue(app.tabBars.buttons["Workout"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Workout"].tap()
        submitFixedReadiness(in: app)
        XCTAssertTrue(app.staticTexts["Upper A · Draft session"].waitForExistence(timeout: 5))

        let weight = app.textFields["fixed.weight.Flat Dumbbell Press.1"]
        scrollToElement(weight, in: app)
        weight.tap()
        weight.typeText("45")
        let reps = app.textFields["fixed.reps.Flat Dumbbell Press.1"]
        reps.tap()
        reps.typeText("10")
        app.buttons["fixed.lock.Flat Dumbbell Press.1"].tap()

        let finishButton = app.buttons["Finish Workout"]
        for _ in 0..<8 {
            if finishButton.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        finishButton.tap()

        scrollToElement(app.staticTexts["fixed.completedToday"], in: app)
        XCTAssertEqual(app.staticTexts["fixed.completedToday"].label, "Upper A complete")
        XCTAssertTrue(app.staticTexts["fixed.completedToday.recap"].label.contains("1 completed set"))

        scrollToElement(app.staticTexts["fixed.nextWorkoutPreview"], in: app)
        XCTAssertEqual(app.staticTexts["fixed.nextWorkoutPreview"].label, "Lower A")
        XCTAssertFalse(app.buttons["fixed.submitReadiness"].exists)
        XCTAssertFalse(app.textFields["fixed.weight.Leg Press.1"].exists)
    }
}
