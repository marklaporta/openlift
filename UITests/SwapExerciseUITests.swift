import XCTest

final class SwapExerciseUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSwapExerciseCanSwitchToDifferentMuscleGroup() throws {
        let app = XCUIApplication()
        app.launchArguments += ["OPENLIFT_UI_TESTING"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Workout"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Workout"].tap()

        XCTAssertTrue(app.staticTexts["Flat Dumbbell Press"].waitForExistence(timeout: 5))

        let swapButton = app.buttons["workout.swap.0"]
        XCTAssertTrue(swapButton.waitForExistence(timeout: 5))
        swapButton.tap()

        XCTAssertTrue(app.navigationBars["Swap Exercise"].waitForExistence(timeout: 5))

        let musclePicker = app.buttons["swap.musclePicker"].firstMatch
        XCTAssertTrue(musclePicker.waitForExistence(timeout: 5))
        musclePicker.tap()

        let bicepsOption = app.buttons["Biceps"].firstMatch
        XCTAssertTrue(bicepsOption.waitForExistence(timeout: 5))
        bicepsOption.tap()

        let replacement = app.buttons["Incline Curl"].firstMatch
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        replacement.tap()

        XCTAssertTrue(app.staticTexts["Incline Curl"].waitForExistence(timeout: 5))
    }
}
