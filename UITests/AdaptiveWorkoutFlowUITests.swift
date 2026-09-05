import XCTest

// This end-to-end walk is one test of ~215s and is the longest class in the suite, so
// it sets the parallel floor. Splitting it into four phase classes was tried and
// measured worse, because XCUITest gives each test a fresh app launch: every phase has
// to re-run the setup of the phases before it, and the adaptive path's setup is most of
// its cost. Total test work went from ~640s to ~925s, which no worker count recovered.
//
//   one class,  3 workers   296-301s (green)
//   four classes, 3 workers      473s (green)
//   four classes, 5 workers      363s (green)
//
// Lowering the floor is only worth it if the phases can be entered directly via a launch
// argument rather than replayed through the UI. Until then, keep this whole.
final class AdaptiveWorkoutFlowUITests: OpenLiftUITestCase {
    func testAdaptiveWorkoutReadinessPreviewFreezeLockAndComplete() throws {
        let app = launchApp(["OPENLIFT_UI_TESTING_ADAPTIVE_WORKFLOW"])

        XCTAssertTrue(app.tabBars.buttons["Cycle"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)
        confirmTrainingMode("Adaptive Floating", in: app)

        app.tabBars.buttons["Workout"].tap()
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 5))
        // Eagerness is systemic, while soreness and tissue pain remain per-muscle.
        XCTAssertTrue(app.staticTexts["Eagerness to train today"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Soreness"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tissue pain"].firstMatch.exists)

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
        let editFrozen = app.descendants(matching: .any)["Edit Flat Dumbbell Press"].firstMatch
        // Prior-effort context adds height; the appended movement may be outside
        // the lazy List's realized viewport until explicitly scrolled into view.
        scrollToElement(editFrozen, in: app)
        XCTAssertTrue(app.staticTexts["Flat Dumbbell Press"].waitForExistence(timeout: 5))
        editFrozen.tap()
        app.buttons["Move Earlier"].tap()
        let editMoved = app.descendants(matching: .any)["Edit Flat Dumbbell Press"].firstMatch
        scrollToElement(editMoved, in: app)
        editMoved.tap()
        app.buttons["Skip"].tap()
        let restoreAddedAfterFreeze = app.buttons["Restore Flat Dumbbell Press"].firstMatch
        scrollToElement(restoreAddedAfterFreeze, in: app)
        restoreAddedAfterFreeze.tap()
        XCTAssertTrue(app.staticTexts["Flat Dumbbell Press"].waitForExistence(timeout: 5))
        let editRestored = app.descendants(matching: .any)["Edit Flat Dumbbell Press"].firstMatch
        scrollToElement(editRestored, in: app)
        editRestored.tap()
        app.buttons["Skip"].tap()

        let finish = app.buttons["adaptive.finishWorkout"]
        scrollToElement(finish, in: app)
        finish.tap()
        let finishConfirmation = app.buttons["Finish Workout"]
        XCTAssertTrue(finishConfirmation.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Adaptive Workout Complete"].exists)
        app.buttons["Keep Editing"].tap()
        XCTAssertTrue(finish.waitForExistence(timeout: 5))

        finish.tap()
        XCTAssertTrue(finishConfirmation.waitForExistence(timeout: 5))
        finishConfirmation.tap()
        XCTAssertTrue(app.staticTexts["Adaptive Workout Complete"].waitForExistence(timeout: 10))
        let recap = app.staticTexts["adaptive.completed.recap"]
        scrollToElement(recap, in: app)
        XCTAssertEqual(recap.label, "1 completed sets across 1 movements")
        scrollToElement(app.staticTexts["workout.save.local"], in: app)
        let completionScreenshot = XCTAttachment(screenshot: app.screenshot())
        completionScreenshot.name = "Adaptive completion and backup evidence"
        completionScreenshot.lifetime = .keepAlways
        add(completionScreenshot)
        scrollToElement(app.staticTexts["adaptive.tomorrowPrediction"], in: app)
        XCTAssertTrue(app.staticTexts["adaptive.tomorrowPrediction"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Actual readiness can change")
            ).firstMatch.exists
        )

        app.tabBars.buttons["History"].tap()
        // History is a single chronological list now, so there is no "Adaptive Workouts"
        // section header to wait on. The row labels itself instead.
        XCTAssertTrue(app.staticTexts["Adaptive"].firstMatch.waitForExistence(timeout: 10))
        let historySearch = app.searchFields["Search exercises"]
        XCTAssertTrue(historySearch.waitForExistence(timeout: 5))
        historySearch.tap()
        historySearch.typeText("Incline Curl")
        XCTAssertTrue(app.staticTexts["Incline Curl"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["60 × 10"].waitForExistence(timeout: 5))
    }
}
