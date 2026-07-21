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

    func testLogWorkoutCanCreateAndSelectNewExercise() throws {
        let app = XCUIApplication()
        app.launchArguments += ["OPENLIFT_UI_TESTING"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Log Workout"].waitForExistence(timeout: 5))

        let createButton = app.buttons["Create New Exercise"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
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

    func testRotationWorkoutFinishAdvancesToNextDraft() throws {
        let app = XCUIApplication()
        app.launchArguments += ["OPENLIFT_UI_TESTING"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Workout"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Workout"].tap()
        XCTAssertTrue(app.staticTexts["Upper A · Draft session"].waitForExistence(timeout: 5))

        let finishButton = app.buttons["Finish Workout"]
        for _ in 0..<8 where !finishButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        finishButton.tap()

        XCTAssertTrue(app.staticTexts["Lower A · Draft session"].waitForExistence(timeout: 10))
    }

    func testTrainingModeSwitchPreservesRotationDraft() throws {
        let app = XCUIApplication()
        app.launchArguments += ["OPENLIFT_UI_TESTING"]
        app.launch()

        app.tabBars.buttons["Workout"].tap()
        XCTAssertTrue(app.staticTexts["Upper A · Draft session"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)
        let adaptiveMode = app.buttons["Adaptive Floating"]
        XCTAssertTrue(adaptiveMode.waitForExistence(timeout: 5))
        adaptiveMode.tap()

        app.tabBars.buttons["Workout"].tap()
        XCTAssertTrue(app.staticTexts["No Adaptive Profile"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Upper A · Draft session"].exists)

        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)
        let fixedMode = app.buttons["Fixed Cycle"]
        XCTAssertTrue(fixedMode.waitForExistence(timeout: 5))
        fixedMode.tap()

        app.tabBars.buttons["Workout"].tap()
        XCTAssertTrue(app.staticTexts["Upper A · Draft session"].waitForExistence(timeout: 5))
    }

    func testAdaptiveCycleSurfaceOpensProfileEditorAndLoadsExplicitDemo() throws {
        let app = XCUIApplication()
        app.launchArguments += ["OPENLIFT_UI_TESTING"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Cycle"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)

        let adaptiveMode = app.buttons["Adaptive Floating"]
        XCTAssertTrue(adaptiveMode.waitForExistence(timeout: 5))
        adaptiveMode.tap()
        XCTAssertTrue(app.staticTexts["Muscle Scope"].waitForExistence(timeout: 5))

        let createProfile = app.buttons["adaptive.createProfile"]
        XCTAssertTrue(createProfile.waitForExistence(timeout: 5))
        createProfile.tap()
        XCTAssertTrue(app.navigationBars["New Adaptive Profile"].waitForExistence(timeout: 5))

        let profileName = app.textFields["adaptive.profileName"]
        XCTAssertTrue(profileName.waitForExistence(timeout: 5))
        XCTAssertEqual(profileName.value as? String, "New Adaptive Profile")

        let loadDemo = app.buttons["adaptive.loadDemo"]
        XCTAssertTrue(loadDemo.waitForExistence(timeout: 5))
        loadDemo.tap()
        XCTAssertEqual(profileName.value as? String, "Adaptive Demo — Review Required")
    }

    func testAdaptiveWorkoutReadinessPreviewFreezeLockAndComplete() throws {
        let app = XCUIApplication()
        app.launchArguments += ["OPENLIFT_UI_TESTING", "OPENLIFT_UI_TESTING_ADAPTIVE_WORKFLOW"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Cycle"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)
        let adaptiveMode = app.buttons["Adaptive Floating"]
        XCTAssertTrue(adaptiveMode.waitForExistence(timeout: 5))
        adaptiveMode.tap()

        app.tabBars.buttons["Workout"].tap()
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 5))

        let fillReadiness = app.buttons["adaptive.fillTestReadiness"]
        scrollToElement(fillReadiness, in: app)
        fillReadiness.tap()

        let generatePlan = app.buttons["adaptive.generatePlan"]
        scrollToElement(generatePlan, in: app)
        XCTAssertTrue(generatePlan.isEnabled)
        generatePlan.tap()

        XCTAssertTrue(app.staticTexts["Proposed Plan"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["UI Test Chest"].waitForExistence(timeout: 5))
        let useWorkout = app.buttons["adaptive.useWorkout"]
        scrollToElement(useWorkout, in: app)
        useWorkout.tap()

        let frozenStatus = app.staticTexts["Frozen plan"]
        scrollToElement(frozenStatus, in: app)
        let weight = app.textFields["Weight"].firstMatch
        scrollToElement(weight, in: app)
        weight.tap()
        weight.typeText("60")
        let reps = app.textFields["Reps"].firstMatch
        reps.tap()
        reps.typeText("9")
        if app.buttons["Done"].firstMatch.waitForExistence(timeout: 2) {
            app.buttons["Done"].firstMatch.tap()
        }

        let lock = app.buttons["adaptive.lockSet.1"].firstMatch
        scrollToElement(lock, in: app)
        lock.tap()
        let inProgressStatus = app.staticTexts["In progress · frozen plan"]
        scrollToElement(inProgressStatus, in: app)
        XCTAssertFalse(app.buttons["Regenerate Before First Locked Set"].exists)

        let feedbackPicker = app.buttons["adaptive.feedbackPicker"].firstMatch
        scrollToElement(feedbackPicker, in: app)
        feedbackPicker.tap()
        let justRight = app.buttons["Just right"].firstMatch
        XCTAssertTrue(justRight.waitForExistence(timeout: 5))
        justRight.tap()

        let finish = app.buttons["adaptive.finishWorkout"]
        scrollToElement(finish, in: app)
        finish.tap()
        XCTAssertTrue(app.staticTexts["Adaptive Workout Complete"].waitForExistence(timeout: 10))

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Adaptive Workouts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Adaptive Floating"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Adaptive"].waitForExistence(timeout: 5))
    }

    func testLogWorkoutExportsToICloudMirror() throws {
        guard ProcessInfo.processInfo.environment["OPENLIFT_RUN_ICLOUD_E2E"] == "1" else {
            throw XCTSkip("Real-device iCloud export smoke test is opt-in.")
        }

        let app = XCUIApplication()
        app.launchArguments += ["OPENLIFT_UI_TESTING"]
        app.launch()

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
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10))
        saveButton.tap()

        XCTAssertTrue(app.staticTexts["Saved to History."].waitForExistence(timeout: 20))
    }

    private func dismissExpectedICloudCycleAlertIfPresent(in app: XCUIApplication) {
        let alert = app.alerts["Cycle Error"]
        guard alert.waitForExistence(timeout: 2) else { return }
        XCTAssertTrue(alert.staticTexts["Could not access the OpenLift cycles folder in iCloud Drive."].exists)
        alert.buttons["OK"].tap()
    }

    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<16 where !element.isHittable {
            app.swipeUp()
        }
        for _ in 0..<16 where !element.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
    }
}
