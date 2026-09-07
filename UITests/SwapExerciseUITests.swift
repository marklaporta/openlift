import XCTest

final class SwapExerciseUITests: OpenLiftUITestCase {
    func testSwapExerciseCanSwitchToDifferentMuscleGroup() throws {
        let app = launchApp()

        XCTAssertTrue(app.tabBars.buttons["Workout"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Workout"].tap()
        submitFixedReadiness(in: app)

        scrollToElement(app.staticTexts["Flat Dumbbell Press"], in: app)
        XCTAssertTrue(app.staticTexts["Flat Dumbbell Press"].waitForExistence(timeout: 5))

        let swapButton = app.buttons["workout.swap.0"]
        XCTAssertTrue(swapButton.waitForExistence(timeout: 5))
        swapButton.tap()

        XCTAssertTrue(app.navigationBars["Replace Exercise in Upper A"].waitForExistence(timeout: 5))

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

    func testLogWorkoutCanCreateAndSelectNewExercise() throws {
        let app = launchApp()

        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.navigationBars["Log Workout"].waitForExistence(timeout: 5))

        let createButton = app.buttons["Create New Exercise"].firstMatch
        scrollToElement(createButton, in: app)
        createButton.tap()

        XCTAssertTrue(app.navigationBars["New Exercise"].waitForExistence(timeout: 5))
        let nameField = app.textFields["newExercise.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("UI Test Belt Squat")
        app.buttons["newExercise.create"].tap()

        XCTAssertFalse(app.navigationBars["New Exercise"].exists)
        XCTAssertTrue(app.staticTexts["UI Test Belt Squat"].waitForExistence(timeout: 5))
    }

    func testLogWorkoutSavesEnteredSetToLocalHistory() throws {

        let app = launchApp()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        let offSchedule = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Off-Schedule"))
        XCTAssertEqual(offSchedule.count, 0, "A new UI process must not discover previous sandbox exports")

        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.navigationBars["Log Workout"].waitForExistence(timeout: 10))

        let weightField = app.textFields["Weight"].firstMatch
        XCTAssertTrue(weightField.waitForExistence(timeout: 10))
        weightField.tap()
        weightField.typeText("1")

        let repsField = app.textFields["Reps"].firstMatch
        XCTAssertTrue(repsField.waitForExistence(timeout: 10))
        repsField.tap()
        repsField.typeText("1")

        let doneButton = app.buttons["Done"].firstMatch
        if doneButton.waitForExistence(timeout: 2) {
            doneButton.tap()
        }

        let saveButton = app.buttons["Save to History"].firstMatch
        scrollToElement(saveButton, in: app)
        saveButton.tap()

        XCTAssertTrue(app.staticTexts["Saved to History."].waitForExistence(timeout: 20))
        app.tabBars.buttons["History"].tap()
        let savedWorkout = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Off-Schedule")).firstMatch
        XCTAssertTrue(savedWorkout.waitForExistence(timeout: 10))
        savedWorkout.tap()
        XCTAssertTrue(app.staticTexts["Set 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 x 1"].exists)

        app.terminate()
        app.launch()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        XCTAssertEqual(offSchedule.count, 0, "A reused sandbox must not recover the prior UI process's export")
    }
}
