import XCTest

final class GripperModelUITests: OpenLiftUITestCase {
    func testSelectGripperModelsAndSaveHistory() {
        let app = launchApp()
        app.tabBars.buttons["Log"].tap()
        let exercisePicker = app.buttons["log.exercisePicker"].firstMatch
        XCTAssertTrue(exercisePicker.waitForExistence(timeout: 5))
        exercisePicker.tap()
        let gripper = app.buttons["Captain of Crush"].firstMatch
        scrollToElement(gripper, in: app)
        gripper.tap()
        let picker = app.buttons["log.model.1"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Weight"].firstMatch.exists)
        for label in ["G", "T", "1"] {
            picker.tap()
            app.buttons[label].firstMatch.tap()
            XCTAssertEqual(picker.value as? String, label)
        }
        let receipt = XCTAttachment(screenshot: app.screenshot())
        receipt.name = "CoC model 1 selected without pounds"; receipt.lifetime = .keepAlways; add(receipt)
        let reps = app.textFields["Reps"].firstMatch
        reps.tap(); reps.typeText("6")
        if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        let save = app.buttons["Save to History"].firstMatch
        scrollToElement(save, in: app); save.tap()
        XCTAssertTrue(app.staticTexts["Saved to History."].waitForExistence(timeout: 20))
        app.tabBars.buttons["History"].tap()
        let workout = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Off-Schedule")).firstMatch
        XCTAssertTrue(workout.waitForExistence(timeout: 10)); workout.tap()
        XCTAssertTrue(app.staticTexts["Model 1 x 6"].waitForExistence(timeout: 5))
    }
}
