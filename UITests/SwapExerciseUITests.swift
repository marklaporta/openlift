import XCTest

final class SwapExerciseUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppOpensOnWorkoutTab() throws {
        let app = XCUIApplication()
        app.launchArguments += ["OPENLIFT_UI_TESTING"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Upper A · Draft session"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Log Workout"].exists)
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

        // The list intentionally preserves its scroll position after the next
        // draft replaces the completed workout, so assert on a visible Lower A
        // exercise instead of an off-screen section header.
        XCTAssertTrue(app.staticTexts["Leg Press"].waitForExistence(timeout: 10))
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

    func testAdaptiveCycleSurfaceOpensProfileEditorAndLoadsExplicitStarter() throws {
        let app = XCUIApplication()
        app.launchArguments += ["OPENLIFT_UI_TESTING"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Cycle"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)

        let adaptiveMode = app.buttons["Adaptive Floating"]
        XCTAssertTrue(adaptiveMode.waitForExistence(timeout: 5))
        adaptiveMode.tap()
        XCTAssertTrue(app.staticTexts["Adaptive Profile"].waitForExistence(timeout: 5))

        let selection = app.buttons["adaptive.exerciseSelection"]
        scrollToElement(selection, in: app)
        selection.tap()
        XCTAssertTrue(app.navigationBars["Exercise Selection"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alternate recent"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pinned exercise"].firstMatch.exists)
        app.buttons["Done"].tap()

        let createProfile = app.buttons["New Adaptive Profile"]
        XCTAssertTrue(createProfile.waitForExistence(timeout: 5))
        createProfile.tap()
        XCTAssertTrue(app.navigationBars["New Adaptive Profile"].waitForExistence(timeout: 5))

        let profileName = app.textFields["adaptive.profileName"]
        XCTAssertTrue(profileName.waitForExistence(timeout: 5))
        XCTAssertEqual(profileName.value as? String, "New Adaptive Profile")

        let loadDemo = app.buttons["adaptive.loadDemo"]
        XCTAssertTrue(loadDemo.waitForExistence(timeout: 5))
        loadDemo.tap()
        XCTAssertEqual(profileName.value as? String, "Adaptive Starter — Review Required")
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
        XCTAssertTrue(app.staticTexts["Muscle soreness"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connective-tissue pain"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Eagerness to train"].firstMatch.exists)

        let generatePlan = app.buttons["adaptive.generatePlan"]
        scrollToElement(generatePlan, in: app)
        XCTAssertTrue(generatePlan.isEnabled)
        generatePlan.tap()

        XCTAssertTrue(app.staticTexts["2 · Design"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Chest"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Today: 2 muscle groups"].waitForExistence(timeout: 5))

        let decreaseTarget = app.buttons["adaptive.decreaseTarget"]
        XCTAssertTrue(decreaseTarget.waitForExistence(timeout: 5))
        decreaseTarget.tap()
        XCTAssertTrue(app.staticTexts["Today: 1 muscle group"].waitForExistence(timeout: 5))
        let increaseTarget = app.buttons["adaptive.increaseTarget"]
        XCTAssertTrue(increaseTarget.waitForExistence(timeout: 5))
        increaseTarget.tap()
        XCTAssertTrue(app.staticTexts["Today: 2 muscle groups"].waitForExistence(timeout: 5))

        let editReadiness = app.buttons["adaptive.editReadiness"]
        XCTAssertTrue(editReadiness.waitForExistence(timeout: 5))
        editReadiness.tap()
        XCTAssertTrue(app.staticTexts["Edit Readiness"].waitForExistence(timeout: 5))
        let updateReadiness = app.buttons["adaptive.generatePlan"]
        scrollToElement(updateReadiness, in: app)
        updateReadiness.tap()
        XCTAssertTrue(app.staticTexts["2 · Design"].waitForExistence(timeout: 10))

        let compactAddExercise = app.buttons["Add exercise to Chest"]
        scrollToElement(compactAddExercise, in: app)
        XCTAssertFalse(app.buttons["Add Exercise to Chest"].exists)
        let addComplex = app.buttons["adaptive.addComplex"]
        scrollToElement(addComplex, in: app)
        addComplex.tap()
        XCTAssertTrue(app.navigationBars["Add Complex"].waitForExistence(timeout: 5))
        app.buttons["adaptive.buildComplex.biceps"].tap()
        XCTAssertTrue(app.navigationBars["Add Movement"].waitForExistence(timeout: 5))
        let addedMovement = app.buttons["Incline Curl"].firstMatch
        XCTAssertTrue(addedMovement.waitForExistence(timeout: 5))
        addedMovement.tap()
        XCTAssertTrue(app.staticTexts["Incline Curl"].waitForExistence(timeout: 5))
        let moveAddedEarlier = app.buttons["Move Incline Curl earlier"].firstMatch
        scrollToElement(moveAddedEarlier, in: app)
        moveAddedEarlier.tap()
        let moveAddedLater = app.buttons["Move Incline Curl later"].firstMatch
        XCTAssertTrue(moveAddedLater.waitForExistence(timeout: 5))
        moveAddedLater.tap()
        let removeAdded = app.buttons["Remove Incline Curl"].firstMatch
        scrollToElement(removeAdded, in: app)
        removeAdded.tap()
        XCTAssertFalse(app.buttons["Remove Incline Curl"].exists)

        let proposedSwap = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Substitute ")
        ).firstMatch
        XCTAssertTrue(proposedSwap.waitForExistence(timeout: 5))
        proposedSwap.tap()
        XCTAssertTrue(app.navigationBars["Swap Exercise"].waitForExistence(timeout: 5))
        let musclePicker = app.buttons["swap.musclePicker"].firstMatch
        XCTAssertTrue(musclePicker.waitForExistence(timeout: 5))
        musclePicker.tap()
        let biceps = app.buttons["Biceps"].firstMatch
        XCTAssertTrue(biceps.waitForExistence(timeout: 5))
        biceps.tap()
        let proposedReplacement = app.buttons["Incline Curl"].firstMatch
        XCTAssertTrue(proposedReplacement.waitForExistence(timeout: 5))
        proposedReplacement.tap()
        XCTAssertTrue(app.staticTexts["Incline Curl"].waitForExistence(timeout: 5))
        let useWorkout = app.buttons["adaptive.useWorkout"]
        scrollToElement(useWorkout, in: app)
        useWorkout.tap()

        let executePhase = app.staticTexts["3 · Execute"]
        scrollToElement(executePhase, in: app)
        let executeAddComplex = app.buttons["adaptive.addComplex.execute"]
        XCTAssertTrue(executeAddComplex.waitForExistence(timeout: 5))
        executeAddComplex.tap()
        XCTAssertTrue(app.navigationBars["Add Complex"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["adaptive.regenerateBeforeFirstSet"].waitForExistence(timeout: 5))
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
        XCTAssertFalse(app.buttons["adaptive.regenerateBeforeFirstSet"].exists)

        lock.tap()
        let correctedReps = app.textFields["Reps"].firstMatch
        correctedReps.tap()
        correctedReps.typeText(XCUIKeyboardKey.delete.rawValue)
        correctedReps.typeText("10")
        if app.buttons["Done"].firstMatch.waitForExistence(timeout: 2) {
            app.buttons["Done"].firstMatch.tap()
        }
        lock.tap()
        XCTAssertEqual(correctedReps.value as? String, "10")

        let addToFrozen = app.buttons["Add exercise to Chest"].firstMatch
        scrollToElement(addToFrozen, in: app)
        addToFrozen.tap()
        XCTAssertTrue(app.navigationBars["Add Movement"].waitForExistence(timeout: 5))
        let addedAfterFreeze = app.buttons["Flat Dumbbell Press"].firstMatch
        XCTAssertTrue(addedAfterFreeze.waitForExistence(timeout: 5))
        addedAfterFreeze.tap()
        XCTAssertTrue(app.staticTexts["Flat Dumbbell Press"].waitForExistence(timeout: 5))
        let editFrozen = app.buttons["Edit Flat Dumbbell Press"].firstMatch
        scrollToElement(editFrozen, in: app)
        editFrozen.tap()
        app.buttons["Move Earlier"].tap()
        app.buttons["Edit Flat Dumbbell Press"].firstMatch.tap()
        app.buttons["Skip"].tap()
        let restoreAddedAfterFreeze = app.buttons["Restore Flat Dumbbell Press"].firstMatch
        scrollToElement(restoreAddedAfterFreeze, in: app)
        restoreAddedAfterFreeze.tap()
        XCTAssertTrue(app.staticTexts["Flat Dumbbell Press"].waitForExistence(timeout: 5))
        let editRestored = app.buttons["Edit Flat Dumbbell Press"].firstMatch
        scrollToElement(editRestored, in: app)
        editRestored.tap()
        app.buttons["Skip"].tap()

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

    func testAdaptiveProposalUsesHistoryForNextDoseAndPrefill() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "OPENLIFT_UI_TESTING",
            "OPENLIFT_UI_TESTING_ADAPTIVE_WORKFLOW",
            "OPENLIFT_UI_TESTING_ADAPTIVE_HISTORY"
        ]
        app.launch()

        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)
        let adaptiveMode = app.buttons["Adaptive Floating"]
        XCTAssertTrue(adaptiveMode.waitForExistence(timeout: 5))
        adaptiveMode.tap()

        app.tabBars.buttons["Workout"].tap()
        let generatePlan = app.buttons["adaptive.generatePlan"]
        scrollToElement(generatePlan, in: app)
        generatePlan.tap()

        let proposedPlan = app.staticTexts["2 · Design"]
        for _ in 0..<4 where !proposedPlan.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(proposedPlan.waitForExistence(timeout: 5))
        let proposalSummary = app.staticTexts["4 proposed exposures"]
        XCTAssertTrue(proposalSummary.waitForExistence(timeout: 5))
        for exercise in ["Flat Dumbbell Press", "Cable Row", "Bayesian Curl", "Cable Lateral Raise"] {
            XCTAssertTrue((proposalSummary.value as? String)?.contains(exercise) == true)
        }

        let increasedDose = app.staticTexts["2 sets"]
        scrollToElement(increasedDose, in: app)
        XCTAssertTrue(increasedDose.exists)
        let priorPerformance = app.staticTexts["adaptive.previous.Flat Dumbbell Press"]
        scrollToElement(priorPerformance, in: app)
        XCTAssertEqual(priorPerformance.label, "Previous: 60.0 x 9")

        let useWorkout = app.buttons["adaptive.useWorkout"]
        scrollToElement(useWorkout, in: app)
        useWorkout.tap()

        let firstWeight = app.textFields["adaptive.weight.Flat Dumbbell Press.1"]
        scrollToElement(firstWeight, in: app)
        XCTAssertEqual(firstWeight.value as? String, "60")
        let firstReps = app.textFields["adaptive.reps.Flat Dumbbell Press.1"]
        XCTAssertEqual(firstReps.value as? String, "9")
    }

    func testLogWorkoutExportsToICloudMirror() throws {
        guard ProcessInfo.processInfo.environment["OPENLIFT_RUN_ICLOUD_E2E"] == "1" else {
            throw XCTSkip("Real-device iCloud export smoke test is opt-in.")
        }

        let app = XCUIApplication()
        app.launchArguments += ["OPENLIFT_UI_TESTING"]
        app.launch()

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
