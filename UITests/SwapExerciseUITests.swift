import XCTest

// XCUITest parallelizes by class, not by file. These cases used to live in a single
// class, so enabling parallel testing bought nothing. They are split by domain here —
// still one file, so the Xcode project needs no new file references — with the shared
// launch/scroll/readiness helpers hoisted onto a common base.
//
// The split is balanced by measured runtime so no worker is left waiting on a long tail:
// the adaptive end-to-end walk (~215s) gets a class to itself and sets the floor, and
// the remaining classes land near 100-120s each.
//
// Run with `-maximum-parallel-testing-workers 3`. Measured on the M4 (10 cores, 4 of
// them performance):
//
//   serial      ~640s
//   3 workers    296-301s, green across three runs
//   5 workers    317s, one flaky failure (was 352s / two before the settle wait below)
//
// Five clones oversubscribe the performance cores; the resulting scroll lag leaves
// scrollToElement unable to land on its target. Three workers is also the optimal
// split regardless, since the ~215s adaptive class sets the floor.
//
// Note that test plans cannot pin the worker count — IDEFoundation's test-plan schema
// has parallelizable, parallelizationMode, testExecutionOrdering and the timeout keys,
// but no worker-count option. The xcodebuild flag is the only lever, so runs started
// from Xcode's GUI use a worker count Xcode chooses and can still hit the flake.
class OpenLiftUITestCase: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    fileprivate func launchApp(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["OPENLIFT_UI_TESTING"] + extraArguments
        app.launch()
        return app
    }

    // Fixed Cycle gates the workout list behind a dated readiness observation. The
    // form opens pre-filled with the all-clear defaults, so submitting once is enough
    // to reach the exercise sections.
    fileprivate func submitFixedReadiness(in app: XCUIApplication) {
        let submit = app.buttons["fixed.submitReadiness"]
        scrollToElement(submit, in: app)
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.tap()

        // Asserting absence with `waitForExistence` can never return early, so it burned
        // the full timeout on every call. Wait on the predicate instead: it completes as
        // soon as the form is gone.
        let dismissed = XCTWaiter().wait(
            for: [
                expectation(
                    for: NSPredicate(format: "exists == false"),
                    evaluatedWith: submit
                )
            ],
            timeout: 5
        )
        XCTAssertEqual(dismissed, .completed)

        // The submit button sits below the per-muscle sections, so the list is left
        // scrolled down when the workout content replaces the readiness form.
        for _ in 0..<8 {
            app.swipeDown()
        }
    }

    fileprivate func dismissExpectedICloudCycleAlertIfPresent(in app: XCUIApplication) {
        let alert = app.alerts["Cycle Error"]
        guard alert.waitForExistence(timeout: 2) else { return }
        XCTAssertTrue(alert.staticTexts["Could not access the OpenLift cycles folder in iCloud Drive."].exists)
        alert.buttons["OK"].tap()
    }

    fileprivate func confirmTrainingMode(_ name: String, in app: XCUIApplication) {
        let mode = app.buttons[name]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.tap()
        let confirmation = app.buttons["Use \(name)"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
    }

    // `for ... where` is a filter, not a break: the original form kept iterating and
    // re-evaluated `isHittable` all 32 times even once the element was on screen, and
    // each of those checks forces a full accessibility snapshot of the list.
    //
    // Those redundant checks were also acting as an accidental ~30s settle while a
    // screen transition finished. Breaking early removes that, so wait for existence
    // explicitly first. It returns immediately when the element is already present, and
    // genuinely off-screen rows in a lazy List still fall through to the scroll loops.
    fileprivate func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        if element.waitForExistence(timeout: 5), element.isHittable { return }
        for _ in 0..<16 {
            if element.isHittable { break }
            app.swipeUp()
        }
        for _ in 0..<16 {
            if element.isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))

        // Parallel simulator clones contend for CPU, so a scroll can still be settling
        // once the swipe budget is spent — the loops above poll isHittable faster than
        // the animation lands. Give the layout a bounded chance to catch up instead of
        // failing on a transient state. Returns immediately when already hittable.
        if !element.isHittable {
            _ = XCTWaiter().wait(
                for: [
                    expectation(
                        for: NSPredicate(format: "isHittable == true"),
                        evaluatedWith: element
                    )
                ],
                timeout: 10
            )
        }
        XCTAssertTrue(element.isHittable)
    }
}

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

    func testLogWorkoutExportsToICloudMirror() throws {
        guard ProcessInfo.processInfo.environment["OPENLIFT_RUN_ICLOUD_E2E"] == "1" else {
            throw XCTSkip("Real-device iCloud export smoke test is opt-in.")
        }

        let app = launchApp()

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
}

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

    func testRotationWorkoutFinishAdvancesToNextDraft() throws {
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

        // Readiness is recorded per draft session, so the next draft re-arms the gate
        // and has to be cleared before its exercises render.
        submitFixedReadiness(in: app)

        // The list intentionally preserves its scroll position after the next
        // draft replaces the completed workout, so assert on a visible Lower A
        // exercise instead of an off-screen section header.
        scrollToElement(app.staticTexts["Leg Press"], in: app)
        XCTAssertTrue(app.staticTexts["Leg Press"].waitForExistence(timeout: 10))
    }
}

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

final class AdaptiveProposalUITests: OpenLiftUITestCase {
    func testAdaptiveCycleSurfaceOpensProfileEditorAndLoadsExplicitStarter() throws {
        let app = launchApp()

        XCTAssertTrue(app.tabBars.buttons["Log"].waitForExistence(timeout: 5))
        app.tabBars.buttons["History"].tap()
        XCTAssertFalse(app.buttons["Log Workout"].exists)
        XCTAssertTrue(app.tabBars.buttons["Cycle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Import"].exists)
        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)

        confirmTrainingMode("Adaptive Floating", in: app)
        XCTAssertTrue(app.staticTexts["Adaptive Profile"].waitForExistence(timeout: 5))

        let selection = app.buttons["adaptive.exerciseSelection"]
        scrollToElement(selection, in: app)
        selection.tap()
        XCTAssertTrue(app.navigationBars["Exercise Selection"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alternate recent"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pinned exercise"].firstMatch.exists)
        app.buttons["Cancel"].tap()

        let createProfile = app.buttons["New Adaptive Profile"]
        XCTAssertTrue(createProfile.waitForExistence(timeout: 5))
        createProfile.tap()
        XCTAssertTrue(app.navigationBars["New Adaptive Profile"].waitForExistence(timeout: 5))

        let profileName = app.textFields["adaptive.profileName"]
        XCTAssertTrue(profileName.waitForExistence(timeout: 5))
        XCTAssertEqual(profileName.value as? String, "New Adaptive Profile")
        XCTAssertTrue(app.staticTexts["Maximum muscle groups: 5"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Maximum exercises: 7"].exists)
        XCTAssertTrue(app.staticTexts["Exercises per muscle: 2"].exists)
        XCTAssertTrue(app.staticTexts["Maximum working sets: 15"].exists)

        let loadDemo = app.buttons["adaptive.loadDemo"]
        XCTAssertTrue(loadDemo.waitForExistence(timeout: 5))
        loadDemo.tap()
        XCTAssertEqual(profileName.value as? String, "Adaptive Starter — Review Required")
    }

    func testAdaptiveProposalUsesHistoryForSelectionAndPrefill() throws {
        let app = launchApp([
            "OPENLIFT_UI_TESTING_ADAPTIVE_WORKFLOW",
            "OPENLIFT_UI_TESTING_ADAPTIVE_HISTORY"
        ])

        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)
        confirmTrainingMode("Adaptive Floating", in: app)

        app.tabBars.buttons["Workout"].tap()
        let generatePlan = app.buttons["adaptive.generatePlan"]
        scrollToElement(generatePlan, in: app)
        generatePlan.tap()

        let proposedPlan = app.staticTexts["2 · Design"]
        for _ in 0..<4 {
            if proposedPlan.isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(proposedPlan.waitForExistence(timeout: 5))
        for exercise in ["Flat Dumbbell Press", "Cable Row"] {
            let plannedExercise = app.staticTexts[exercise]
            scrollToElement(plannedExercise, in: app)
            XCTAssertTrue(plannedExercise.exists)
        }

        let splitDose = app.staticTexts["2 sets"].firstMatch
        scrollToElement(splitDose, in: app)
        XCTAssertTrue(splitDose.exists)
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
}

// The longest walk in the suite (~215s): readiness -> design -> execute -> complete ->
// history. It sets the parallel floor, so it gets a class to itself.
final class AdaptiveWorkoutFlowUITests: OpenLiftUITestCase {
    func testAdaptiveWorkoutReadinessPreviewFreezeLockAndComplete() throws {
        let app = launchApp(["OPENLIFT_UI_TESTING_ADAPTIVE_WORKFLOW"])

        XCTAssertTrue(app.tabBars.buttons["Cycle"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)
        confirmTrainingMode("Adaptive Floating", in: app)

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
